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
# Then, in a second scratch root, it checks what the optional display
# packages pull in (NextBSD-mesa without X, NextBSD-xlibre with it).
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
deps="NextBSD-freebsd-compat NextBSD-kernel NextBSD-userland NextBSD-contrib NextBSD-kernel-extensions pkg"
if ls "$REPO"/NextBSD-kernel-extensions-graphics-*.pkg >/dev/null 2>&1; then
  deps="$deps NextBSD-kernel-extensions-graphics"
fi
if [ "$ARCH" = amd64 ]; then
  deps="$deps NextBSD-kernel-extensions-nvidia"
fi
for p in $deps; do
  $PKG info -e "$p" || { echo "FAIL: $p not installed by NextBSD-everything (SAT solver dropped it — file conflict?)" >&2; exit 1; }
done

# 3. NextBSD-contrib's sudo must arrive setuid root: the bit is set at build time
#    and survives tar + pkg create, but a chown in any step would clear it and
#    ship a sudo that cannot escalate. Check it here, at the real extraction.
[ -u "$ROOT/usr/bin/sudo" ] || { echo "FAIL: /usr/bin/sudo is not setuid after install ($(ls -l "$ROOT/usr/bin/sudo" 2>&1))" >&2; exit 1; }

echo "OK (${ARCH}): NextBSD-everything installs cleanly; launchd + all deps present; sudo is setuid"
rm -rf "$ROOT"

# 4. The optional display packages pull in only what they need (pkg#34,
#    nextbsd-mesa#10), checked in a second scratch root:
#    - `pkg install NextBSD-mesa` (OpenGL, EGL and GBM without X) must not
#      bring NextBSD-xlibs, NextBSD-mesa-x11 or NextBSD-xlibre, by `deps` or
#      by shlibs_required;
#    - `pkg install NextBSD-xlibre` on top must bring NextBSD-mesa-x11 (the
#      server's GLX and glamor link its libGL.so.1) and NextBSD-xlibs.
ROOT=$(mktemp -d)
PKG="pkg -r $ROOT -o REPOS_DIR=$REPOS"
echo "=== pkg install NextBSD-mesa into a fresh scratch root (${ARCH}) ==="
$PKG update -f
$PKG install -y NextBSD-mesa
echo "installed: $($PKG query '%n' | sort | tr '\n' ' ')"
for p in NextBSD-mesa NextBSD-displayserver-support; do
  $PKG info -e "$p" || { echo "FAIL: pkg install NextBSD-mesa did not install $p" >&2; exit 1; }
done
for p in NextBSD-xlibs NextBSD-mesa-x11 NextBSD-xlibre; do
  if $PKG info -e "$p"; then echo "FAIL: pkg install NextBSD-mesa installed $p" >&2; exit 1; fi
done
[ -e "$ROOT/usr/X11/lib/libgbm.so.1" ] && [ -e "$ROOT/usr/X11/lib/libEGL.so.1" ] \
  || { echo "FAIL: NextBSD-mesa installed no libgbm.so.1/libEGL.so.1" >&2; exit 1; }
[ ! -e "$ROOT/usr/X11/lib/libX11.so.6" ] && [ ! -e "$ROOT/usr/X11/lib/libGL.so.1" ] \
  || { echo "FAIL: libX11.so.6 or libGL.so.1 present after pkg install NextBSD-mesa" >&2; exit 1; }
echo "OK (${ARCH}): pkg install NextBSD-mesa installs neither NextBSD-xlibs, NextBSD-mesa-x11 nor NextBSD-xlibre"

echo "=== pkg install NextBSD-xlibre into the same root (${ARCH}) ==="
$PKG install -y NextBSD-xlibre
echo "installed: $($PKG query '%n' | sort | tr '\n' ' ')"
for p in NextBSD-xlibre NextBSD-mesa NextBSD-mesa-x11 NextBSD-xlibs; do
  $PKG info -e "$p" || { echo "FAIL: pkg install NextBSD-xlibre did not install $p" >&2; exit 1; }
done
[ -e "$ROOT/usr/X11/lib/libGL.so.1" ] || { echo "FAIL: no libGL.so.1 after pkg install NextBSD-xlibre" >&2; exit 1; }
echo "OK (${ARCH}): pkg install NextBSD-xlibre installs NextBSD-mesa, NextBSD-mesa-x11 and NextBSD-xlibs"
rm -rf "$ROOT" "$REPOS"
