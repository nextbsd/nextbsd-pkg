#!/bin/sh
# install-test.sh — Layer B of the nextbsd#370 gate. Runs in the packaging VM
# AFTER build.sh produced out/repo, BEFORE the workflow's publish step. Really
# installs NextBSD-everything into a scratch root from the just-built flat repo —
# a host-side `pkg -r` extraction, no boot, exactly how the ISO builders
# (nextbsd/build.sh, gershwin-on-nextbsd/build.sh) consume the repo — and asserts
# the install is COMPLETE.
#
# Why not the old metadata dry-run (verify.sh's `pkg install -n`): a two-owners-
# of-one-path collision manifests at EXTRACTION, not in catalog metadata. The
# syslog.3.gz bug was a *successful* `pkg install` that just dropped
# NextBSD-userland (and with it /sbin/launchd). Only a real extraction plus a
# per-dependency presence check catches "installed fine, minus the OS."
set -eux

pkg --version || pkg bootstrap -y

ARCH="${ARCH:-amd64}"
# pkg's ABI uses 'aarch64' for 64-bit ARM; artifacts/tags use 'arm64'.
case "$ARCH" in arm64) ABIARCH=aarch64 ;; *) ABIARCH="$ARCH" ;; esac

REPO="$PWD/out/repo"
ls "$REPO"/packagesite* >/dev/null 2>&1 || { echo "FATAL: no catalog in $REPO (build.sh did not run?)" >&2; exit 1; }

ROOT=$(mktemp -d)
REPOS=$(mktemp -d)
cat > "$REPOS/nextbsd.conf" <<CONF
nextbsd: { url: "file://$REPO", enabled: yes, signature_type: none }
CONF

# The VM is FreeBSD 14 but the packages are FreeBSD:15; pin the ABI so pkg
# accepts the repo. Set it via the ENVIRONMENT (ABI/OSVERSION/IGNORE_OSVERSION),
# NOT `-o ABI=`: with `-r <root>` pkg derives its ABI from the (empty) root and
# the -o override doesn't win the repo arch-check, so `pkg update` rejects the
# FreeBSD:15 repo as "wrong architecture". Env vars override globally — this is
# exactly what the ISO builders (nextbsd/build.sh, gershwin-on-nextbsd) do. pkg
# requires OSVERSION when ABI is pinned; IGNORE_OSVERSION reconciles the VM's.
# Cross-arch is fine: arm64 packages (FreeBSD:15:aarch64) are only untarred here,
# never executed.
export ASSUME_ALWAYS_YES=yes
export ABI="FreeBSD:15:${ABIARCH}"
export IGNORE_OSVERSION=yes
export OSVERSION="$(uname -K)"
PKG="pkg -r $ROOT -o REPOS_DIR=$REPOS"

echo "=== install NextBSD-everything into a scratch root (${ARCH}, real extraction) ==="
$PKG update -f
$PKG install -y NextBSD-everything

echo "=== assert the install is COMPLETE (no package silently dropped) ==="
# 1. A working init must be present — the human-obvious proxy for "userland landed".
[ -x "$ROOT/sbin/launchd" ]  || { echo "FAIL: install produced no /sbin/launchd — NextBSD-userland was dropped" >&2; exit 1; }
[ -x "$ROOT/bin/launchctl" ] || { echo "FAIL: install produced no /bin/launchctl" >&2; exit 1; }

# 2. The general form: every NextBSD-everything dependency must actually be
#    registered. The failure mode was a green install that excluded a package;
#    exit code alone would not catch it, `pkg info -e` per dep does.
deps="NextBSD-freebsd-compat NextBSD-kernel NextBSD-userland NextBSD-contrib"
if [ "$ARCH" = amd64 ] && ls "$REPO"/NextBSD-kernel-extensions-*.pkg >/dev/null 2>&1; then
  deps="$deps NextBSD-kernel-extensions"
fi
for p in $deps; do
  $PKG info -e "$p" || { echo "FAIL: $p not installed by NextBSD-everything (SAT solver dropped it — file conflict?)" >&2; exit 1; }
done

# 3. NextBSD-contrib's sudo must arrive setuid root: the bit is set at build time
#    and survives tar + pkg create, but a chown in any step would clear it and
#    ship a sudo that cannot escalate. Check it here, at the real extraction.
[ -u "$ROOT/usr/bin/sudo" ] || { echo "FAIL: /usr/bin/sudo is not setuid after install ($(ls -l "$ROOT/usr/bin/sudo" 2>&1))" >&2; exit 1; }

echo "OK (${ARCH}): NextBSD-everything installs cleanly; launchd + all deps present; sudo is setuid"
rm -rf "$ROOT" "$REPOS"
