# phpshell-php7-patches

Build and deploy patched **PHP 7.2** packages for **Ubuntu 20.04 (focal)** against
the PHP2Shell vulnerabilities **CVE-2026-109618** and **CVE-2026-109619**, plus a
set of scripts to audit and remediate a mixed PHP fleet (Ubuntu ESM, Ondřej Surý
PPA, and upstream packages).

> **Why this repo exists.** On 21 October 2026 the PHP team shipped emergency
> fixes for two critical unauthenticated RCE flaws (CVSS v4.0 9.2), collectively
> "PHP2Shell", in PHP 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12. End-of-life branches got
> no upstream fix. Ondřej Surý backported the fix to his PPA for **supported**
> Ubuntu/Debian releases — but **not for focal (20.04) PHP 7.2**, which was frozen
> on the PPA in mid-2025. Boxes stuck on focal + sury PHP 7.2 therefore had no
> package upgrade path. This repo rebuilds the fixed source for focal so those
> boxes can be patched without migrating PHP versions or the OS.

---

## ⚠️ Disclaimer

These are **unofficial, locally-rebuilt** packages. They are provided as-is, with
no warranty. The `.deb` files are **not signed by Ondřej Surý or Canonical** — they
are built from Ondřej's published jammy `-66` source on a focal toolchain. Review
the source, build them yourself, and test on a non-production box before deploying.
The maintainer of this repo is not responsible for any breakage. The durable fix is
to move off end-of-life PHP and OS releases; these packages are a stopgap.

---

## The vulnerabilities

| CVE | Class | Impact |
|-----|-------|--------|
| CVE-2026-109618 | State corruption after an out-of-memory bailout, reachable via crafted multipart upload | Unauthenticated RCE as the web-server user |
| CVE-2026-109619 | Stale request-owned global state consumed by a later request (`session.upload_progress` trigger) | Unauthenticated RCE as the web-server user |

Both execute **before application code runs**, in PHP's request/multipart parser, so
application-level authentication does not mitigate them. Any PHP SAPI that serves web
requests (mod_php, PHP-FPM, php-cgi) is affected.

**Fixed upstream versions:** PHP 8.2.35, 8.3.36, 8.4.27, 8.5.12 (21 Oct 2026).

---

## What's in here

| File | Purpose |
|------|---------|
| `build-php72-66-focal.sh` | Fetch Ondřej Surý's jammy `7.2.34-66` source and rebuild it as focal binaries. Produces installable `.deb` files. |
| `install-focal-66.sh` | Install the built `-66+focal11` debs on a focal box — only the packages already present — then restart, hold, and verify. |
| `php2shell-patch.sh` | Auto-detect a host's PHP source (Ubuntu ESM / sury PPA / upstream) and apply the right fix. Handles 7.x and 8.x. |
| `php2shell-verify.sh` | Read-only fleet audit over SSH. Reports CLEAN / VULNERABLE / NO-PHP per host, per PHP branch. |

> The prebuilt `.deb` files are **not** committed to this repo (binaries, and they
> should be rebuilt and reviewed per environment). Run `build-php72-66-focal.sh` to
> produce them.

---

## Remediation paths by platform

Which route a box needs depends on **where its PHP came from**, not just the OS:

| OS + source | PHP | Fix | How |
|-------------|-----|-----|-----|
| Ubuntu 18.04 distro | 7.2 | `…+esm14` | Ubuntu Pro / ESM (`pro attach`, `apt upgrade`) |
| Ubuntu 20.04 distro | 7.4 | `…+esm5` | Ubuntu Pro / ESM |
| Ubuntu 22.04 distro | 8.1 | `…ubuntu2.28` | Ubuntu archive (`apt upgrade`) |
| Ubuntu 24.04 distro | 8.3 | `…24.04.13` | Ubuntu archive (`apt upgrade`) |
| sury PPA (jammy/noble) | 7.2 / 7.3 / 8.x | `-66` | `apt upgrade` from the PPA |
| **sury PPA (focal)** | **7.2** | **none published** | **rebuild — this repo** |
| EOL OS (e.g. 23.04 lunar) | 8.0 | none | migrate/rebuild OS; mitigate at the edge meanwhile |

`php2shell-patch.sh` handles every row except the focal-rebuild and EOL-OS cases.

---

## Quick start

### 1. Build the focal `-66` packages

Run on a **focal (20.04) amd64** host or container that can reach Launchpad. A
disposable container keeps your servers clean:

```bash
docker run --rm -it -v "$PWD/out:/out" ubuntu:20.04 bash
# inside:
apt-get update && apt-get install -y curl sudo ca-certificates
bash build-php72-66-focal.sh
cp /tmp/php72-66-build/*.deb /out/     # debs land in ./out on the host
```

The build pulls Ondřej's **jammy** `7.2.34-66` source (`.dsc`, `.debian.tar.xz`,
`.orig.tar.xz`), installs build-deps, and rebuilds against focal. The resulting
version string is `7.2.34-66+ubuntu22.04.1+deb.sury.org+1+focal11`.

### 2. Make a deploy set (runtime debs only)

```bash
cd out
mkdir -p deploy
for f in *.deb; do
  case "$f" in *.ddeb|*-dbgsym*) continue ;; esac
  cp "$f" deploy/
done
```

### 3. Deploy to each focal box

**Snapshot the VM first** (your rollback). Then:

```bash
scp deploy/*.deb install-focal-66.sh panagos@HOST:/tmp/php66/
ssh panagos@HOST 'cd /tmp/php66 && bash install-focal-66.sh .'
```

`install-focal-66.sh`:

- refuses to run on non-focal / non-sury-7.2 boxes;
- installs only the `-66` builds of packages **already installed** on that box;
- lets `apt` pull any focal dependency it needs (e.g. `libzip5`) from the Ubuntu
  archive;
- restarts apache2 / php7.2-fpm;
- runs `apt-mark hold` so a later `apt upgrade` can't silently downgrade you to
  focal's old `-43`;
- verifies the version string, the CVE entry in the changelog, and that PECL
  extensions still load.

### 4. Verify the fleet

```bash
./php2shell-verify.sh -f hosts.txt     # user@host or host per line
```

---

## Notes & gotchas (learned the hard way)

- **focal PHP 7.2 only ever came from the sury PPA** — Ubuntu 20.04 ships 7.4
  natively, never 7.2. So there is no ESM path for focal 7.2; rebuild is the only
  package fix.
- **Cross-release ABI is fine here.** The jammy `-66` source builds and runs on
  focal because the PHP version (7.2.34) and Zend module API are unchanged — only
  the security patch differs. Existing PECL extensions (`imagick`, `redis`,
  `igbinary`, `ssh2`) built against the old `-43` continue to load against the new
  `-66` core. Always confirm with `php7.2 -m`.
- **The one dependency delta on focal is `libzip`**: the jammy build links
  `libzip5`, focal shipped `libzip4`. `apt` resolves this automatically from
  focal's own archive — no action needed.
- **`apt-mark hold` is mandatory on focal.** The PPA still advertises `-43`; without
  a hold, routine updates will try to "upgrade" (downgrade) off the fix.
- **`apt-mark hold` changes dpkg state from `ii` to `hi`.** Tools that filter on
  `^ii` will wrongly report held PHP as "not installed" — `php2shell-verify.sh`
  matches `^.i` to handle this.
- **If `memory_limit = -1`**, set a real limit after patching. The pre-patch
  mitigation advice was to set `-1`; the patched engine adds a hard internal cap and
  expects a concrete value.
- **The version string ends `+focal11`** by design — jammy source, focal rebuild.
  That is the signal your box is on the rebuilt package.

---

## Mitigations for boxes with no package fix

For EOL-OS or otherwise unpatchable boxes, reduce exposure at the edge until they are
rebuilt. These do **not** fully close the OOM/`rawkey` path, which has no PHP-config
fix — only an edge/WAF control stops it.

**php.ini** (covers the upload-progress chain, partial):

```ini
session.upload_progress.enabled = Off
session.use_only_cookies = 1
```

then restart the SAPI and purge `session.save_path`.

**Edge (HAProxy / reverse proxy):** cap or reject oversized urlencoded POST bodies
(> 1 MB), reject chunked urlencoded requests, and rate-limit large POSTs per source
IP. If the user base is known (e.g. a partner portal), an IP allowlist at the edge is
stronger than filtering.

**ModSecurity:** block multipart requests carrying a `PHPSESSID` form field, a PHP
open tag in a filename, or a form-field name ≥ 1000 bytes.

---

## Post-exploitation hunt

Patching stops future exploitation; it does not undo prior compromise. For any box
that was internet-facing before patching, hunt back to **20 October 2026** (when the
flaws became public):

- `PHP Fatal error … tried to allocate … in Unknown on line 0` in web-server error
  logs (the OOM signature — distinguish from benign missing-extension warnings).
- Bursts of large POSTs from one IP; Apache `AH00052` child-exit bursts.
- Web-server user (`www-data`/`apache`/`nginx`) spawning shells.
- New/modified files in web roots, `/tmp`, `/dev/shm`; new cron entries; new
  `authorized_keys`.

---

## References

- PHP security release, 21 Oct 2026 — <https://www.php.net/>
- Ondřej Surý PPA — <https://launchpad.net/~ondrej/+archive/ubuntu/php>
- CVE-2026-109618, CVE-2026-109619

---

## License

Scripts in this repository: MIT (see `LICENSE`). The rebuilt PHP packages are
derived from the PHP source and Ondřej Surý's Debian packaging and remain under
their respective licenses (PHP License, and the packaging's license).
