#!/usr/bin/env bash
# install-focal-66.sh — install the locally-built php7.2 -66+focal11 debs on a
# focal (20.04) box, matching exactly the packages already installed there.
# Based on the exact flow proven on ca-vs-web-worker-04.
#
# Run ON the target focal box, from the directory holding the *.deb files
# (e.g. the deploy/ folder you scp'd over). Example:
#     scp deploy/*.deb panagos@ca-vs-web-master:/tmp/php66/
#     ssh panagos@ca-vs-web-master
#     cd /tmp/php66 && bash install-focal-66.sh
#
# What it does, in order:
#   1. sanity checks (focal, debs present, is a sury-7.2 box below -66)
#   2. installs ONLY the -66 builds of php7.2 packages already installed
#   3. restarts apache (and php7.2-fpm if active)
#   4. holds the packages so apt won't revert them to focal's -43
#   5. verifies: version string, changelog CVE, extensions still load
#
# It does NOT change memory_limit or app config, and does NOT autoremove.
# SNAPSHOT THE VM FIRST (Proxmox) — this is your rollback.
set -uo pipefail

DEBDIR="${1:-$PWD}"
VER_TAG="focal11"
say(){ printf '\n>>> %s\n' "$*"; }
die(){ printf '\n!!! %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || SUDO=sudo
SUDO="${SUDO:-}"

# --- 1. sanity ---------------------------------------------------------------
. /etc/os-release 2>/dev/null || true
[[ "${VERSION_CODENAME:-}" == "focal" ]] || die "not a focal (20.04) box — codename='${VERSION_CODENAME:-unknown}'. These debs are built for focal only."

cd "$DEBDIR" || die "cannot cd to $DEBDIR"
ls *"$VER_TAG"*.deb >/dev/null 2>&1 || die "no *${VER_TAG}*.deb files in $DEBDIR. scp the deploy/ debs here first."

cur="$(dpkg-query -W -f='${Version}' php7.2-common 2>/dev/null || true)"
[[ -n "$cur" ]] || die "php7.2-common not installed here — is this the right box? (expected a sury 7.2 focal box)"
case "$cur" in
  *+"$VER_TAG") say "php7.2-common already at $cur — looks already patched. Re-running is safe (idempotent)." ;;
  *deb.sury.org*) say "current php7.2-common: $cur  → will upgrade to -66+${VER_TAG}" ;;
  *) die "php7.2-common is '$cur' — not a sury build. This installer is only for sury-7.2 focal boxes." ;;
esac

# --- 2. build the install list from what's actually installed ---------------
mapfile -t PKGS < <(dpkg -l | awk '/^.i  (php7.2|libapache2-mod-php7.2)/{print $2}')
[[ ${#PKGS[@]} -gt 0 ]] || die "no php7.2 packages found installed."

say "installed php7.2 packages on this box:"; printf '   %s\n' "${PKGS[@]}"

LIST=()
missing=()
for p in "${PKGS[@]}"; do
  f=$(ls "${p}"_*"${VER_TAG}"_*.deb 2>/dev/null | head -1)
  if [[ -n "$f" ]]; then LIST+=("./$f"); else missing+=("$p"); fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  say "NOTE: these installed packages have NO -66 deb in this folder (likely PECL/third-party, built separately):"
  printf '   %s\n' "${missing[@]}"
  say "They are PHP *core*-independent extensions; the CVE is in core, which we ARE patching. They will be held at their current version. Confirm they still load (step 5)."
fi

[[ ${#LIST[@]} -gt 0 ]] || die "no matching -66 debs to install."

say "will install ${#LIST[@]} package(s):"; printf '   %s\n' "${LIST[@]}"

# --- 3. install (apt resolves libzip5 etc. from focal's own archive) --------
say "installing (apt will pull any needed focal deps like libzip5 from the Ubuntu archive)"
$SUDO apt-get install -y "${LIST[@]}" || die "apt install failed — review output above. Nothing committed if it errored on deps; VM snapshot is your rollback."

# --- 4. restart SAPI --------------------------------------------------------
if systemctl is-active --quiet apache2 2>/dev/null; then say "restarting apache2"; $SUDO systemctl restart apache2; fi
if systemctl is-active --quiet php7.2-fpm 2>/dev/null; then say "restarting php7.2-fpm"; $SUDO systemctl restart php7.2-fpm; fi

# --- 5. hold so apt can't downgrade to focal's -43 --------------------------
say "holding php7.2 packages (focal PPA only has -43; hold prevents silent downgrade)"
$SUDO apt-mark hold "${PKGS[@]}" >/dev/null
echo "   held: ${PKGS[*]}"

# --- 6. verify ---------------------------------------------------------------
say "VERIFICATION"
v="$(php7.2 -v 2>/dev/null | head -1)"
echo "   $v"
case "$v" in
  *"-66+"*"$VER_TAG"*) echo "   [OK] version is -66+${VER_TAG}" ;;
  *) echo "   [WARN] version string does not show -66+${VER_TAG} — check manually"; ;;
esac

if zcat /usr/share/doc/php7.2-common/changelog.Debian.gz 2>/dev/null | grep -qiE 'CVE-2026-10961[89]'; then
  echo "   [OK] changelog names CVE-2026-109618/109619"
else
  echo "   [WARN] CVE not found in changelog — check manually"
fi

# extension load check (the cross-release ABI risk)
exts=$(php7.2 -m 2>/dev/null | grep -iE 'imagick|redis|igbinary|ssh2|memcached|mongodb|apcu' | tr '\n' ' ')
echo "   loaded PECL-ish extensions: ${exts:-none detected}"
if php7.2 -v 2>&1 | grep -qi 'unable to load'; then
  echo "   [WARN] a dynamic extension failed to load — see: php7.2 -v 2>&1 | grep -i 'unable to load'"
else
  echo "   [OK] no extension load errors"
fi

# apache workers restarted after upgrade?
if pgrep -x apache2 >/dev/null 2>&1; then
  echo "   apache workers running (started: $(ps -eo lstart,cmd | awk '/[a]pache2/{print $2,$3,$4,$5; exit}'))"
fi

say "DONE on $(hostname -s). Remember: (a) set memory_limit to a real value if it's -1, (b) test the app (store page, admin, checkout, an imagick/zip path), (c) hunt logs back to 2026-10-20."
echo "   memory_limit is currently: $(php7.2 -i 2>/dev/null | awk -F'=>' '/^memory_limit/{print $2; exit}' | xargs)"
