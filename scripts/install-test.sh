#!/bin/sh
# install-test.sh — Layer B of the nextbsd#370 gate. Runs in the packaging VM
# AFTER build.sh produced out/repo, BEFORE the workflow's publish step. Really
# installs NextBSD-server into a scratch root from the just-built flat repo —
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
# packages pull in (NextBSD-mesa without X, NextBSD-xlibre with it) and
# installs NextBSD-gnustep; in a third, that the transitional
# NextBSD-everything installs NextBSD-server (and NextBSD-desktop, when it was
# built); and in a fourth, that `pkg upgrade` from the published repo to this
# one keeps every package (nextbsd/nextbsd#680).
set -eux

ARCH="${ARCH:-amd64}"
# pkg's ABI uses 'aarch64' for 64-bit ARM; artifacts/tags use 'arm64'.
case "$ARCH" in arm64) ABIARCH=aarch64 ;; *) ABIARCH="$ARCH" ;; esac

REPO="$PWD/out/repo"
ls "$REPO"/packagesite* >/dev/null 2>&1 || { echo "FATAL: no catalog in $REPO (build.sh did not run?)" >&2; exit 1; }

# NextBSD's pkg-static, which build.sh unpacked into tool/ from the
# nextbsd-contrib artifact: the packages carry the NextBSD ABI, which only
# NextBSD's pkg knows, and this is the pkg that installs them on NextBSD. As
# in build.sh it gets an explicit empty config (-C) and repo directory (-R).
NBPKGBIN="$PWD/tool/root/usr/sbin/pkg-static"
[ -x "$NBPKGBIN" ] || { echo "FATAL: no $NBPKGBIN (build.sh did not run?)" >&2; exit 1; }

ROOT=$(mktemp -d)
REPOS=$(mktemp -d)
# The repository is named NextBSD, as on a NextBSD system: NextBSD's pkg lets
# packages from any other repository install only under /usr/local and /var,
# and takes pkg itself only from NextBSD.
cat > "$REPOS/NextBSD.conf" <<CONF
NextBSD: { url: "file://$REPO", enabled: yes, signature_type: none }
CONF

# Pin the target ABI in the ENVIRONMENT (ABI/OSVERSION), not with `-o ABI=`:
# with `-r <root>` pkg derives its ABI from the (empty) root, and only the
# environment wins the repo arch-check. Same values as build.sh stamps:
# NextBSD:27:<arch>, OSVERSION 2700000. Cross-arch is fine: arm64 packages
# (NextBSD:27:aarch64) are only untarred here, never executed.
NBOSVERSION=2700000
export ASSUME_ALWAYS_YES=yes
export ABI="NextBSD:$((NBOSVERSION / 100000)):${ABIARCH}"
export OSVERSION="${NBOSVERSION}"
PKG="$NBPKGBIN -C $PWD/tool/pkg.conf -R $REPOS -r $ROOT"

echo "=== install NextBSD-server into a scratch root (${ARCH}, real extraction) ==="
$PKG update -f
$PKG install -y NextBSD-server

echo "=== assert the install is COMPLETE (no package silently dropped) ==="
# 1. A working init must be present — the human-obvious proxy for "userland landed".
[ -x "$ROOT/sbin/launchd" ]  || { echo "FAIL: install produced no /sbin/launchd — NextBSD-userland was dropped" >&2; exit 1; }
[ -x "$ROOT/bin/launchctl" ] || { echo "FAIL: install produced no /bin/launchctl" >&2; exit 1; }

# 2. The general form: every NextBSD-server dependency must actually be
#    registered. The failure mode was a green install that excluded a package;
#    exit code alone would not catch it, `pkg info -e` per dep does.
deps="NextBSD-freebsd-compat NextBSD-bootloader NextBSD-kernel NextBSD-userland NextBSD-contrib NextBSD-kernel-extensions pkg"
if ls "$REPO"/NextBSD-kernel-extensions-graphics-*.pkg >/dev/null 2>&1; then
  deps="$deps NextBSD-kernel-extensions-graphics"
fi
if [ "$ARCH" = amd64 ]; then
  deps="$deps NextBSD-kernel-extensions-nvidia"
fi
for p in $deps; do
  $PKG info -e "$p" || { echo "FAIL: $p not installed by NextBSD-server (SAT solver dropped it — file conflict?)" >&2; exit 1; }
done
# SystemVersion.plist belongs to NextBSD-server (nextbsd/nextbsd#536, #680).
SYSVER=/System/Library/CoreServices/SystemVersion.plist
_owner=$($PKG which -q "$SYSVER" || true)
[ "${_owner%-[0-9]*}" = NextBSD-server ] || { echo "FAIL: $SYSVER is owned by '${_owner}', not NextBSD-server" >&2; exit 1; }

# 3. NextBSD-contrib's sudo must arrive setuid root: the bit is set at build time
#    and survives tar + pkg create, but a chown in any step would clear it and
#    ship a sudo that cannot escalate. Check it here, at the real extraction.
[ -u "$ROOT/usr/bin/sudo" ] || { echo "FAIL: /usr/bin/sudo is not setuid after install ($(ls -l "$ROOT/usr/bin/sudo" 2>&1))" >&2; exit 1; }

echo "OK (${ARCH}): NextBSD-server installs cleanly; launchd + all deps present; sudo is setuid"
rm -rf "$ROOT"

# 4. The optional display packages pull in only what they need (pkg#34,
#    nextbsd-mesa#10), checked in a second scratch root:
#    - `pkg install NextBSD-mesa` (OpenGL, EGL and GBM without X) must not
#      bring NextBSD-xlibs, NextBSD-mesa-x11 or NextBSD-xlibre, by `deps` or
#      by shlibs_required;
#    - `pkg install NextBSD-xlibre` on top must bring NextBSD-mesa-x11 (the
#      server's GLX and glamor link its libGL.so.1) and NextBSD-xlibs.
ROOT=$(mktemp -d)
PKG="$NBPKGBIN -C $PWD/tool/pkg.conf -R $REPOS -r $ROOT"
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

# 5. NextBSD-gnustep (nextbsd/nextbsd#674) on top: the GNUstep core in
#    /System/Library, with the libraries it links.
echo "=== pkg install NextBSD-gnustep into the same root (${ARCH}) ==="
$PKG install -y NextBSD-gnustep
for p in NextBSD-gnustep NextBSD-userland NextBSD-gnustep-support NextBSD-printing-support NextBSD-mesa-x11; do
  $PKG info -e "$p" || { echo "FAIL: pkg install NextBSD-gnustep did not install $p" >&2; exit 1; }
done
for f in /System/Library/Libraries/libgnustep-base.so /System/Library/Libraries/libgnustep-gui.so \
         /System/Library/Preferences/GNUstep.conf /System/Library/Tools/gdomap; do
  [ -e "$ROOT$f" ] || { echo "FAIL: no $f after pkg install NextBSD-gnustep" >&2; exit 1; }
done
echo "OK (${ARCH}): pkg install NextBSD-gnustep installs the GNUstep core and what it links"

# 6. The transitional NextBSD-everything (nextbsd/nextbsd#680) is empty and
#    installs NextBSD-server; NextBSD-desktop, when nextbsd-desktop has
#    published, installs NextBSD-server, NextBSD-gnustep and the desktop.
ROOT=$(mktemp -d)
PKG="$NBPKGBIN -C $PWD/tool/pkg.conf -R $REPOS -r $ROOT"
echo "=== pkg install NextBSD-everything (transitional) into a fresh scratch root (${ARCH}) ==="
$PKG update -f
$PKG install -y NextBSD-everything
[ -z "$($PKG query '%Fp' NextBSD-everything)" ] || { echo "FAIL: NextBSD-everything owns files" >&2; exit 1; }
for p in NextBSD-server $deps; do
  $PKG info -e "$p" || { echo "FAIL: pkg install NextBSD-everything did not install $p" >&2; exit 1; }
done
echo "OK (${ARCH}): the transitional NextBSD-everything installs NextBSD-server and the whole core OS"
if ls "$REPO"/NextBSD-desktop-[0-9]*.pkg >/dev/null 2>&1; then
  echo "=== pkg install NextBSD-desktop into the same root (${ARCH}) ==="
  $PKG install -y NextBSD-desktop
  for p in NextBSD-desktop NextBSD-desktop-apps NextBSD-gnustep NextBSD-server $deps; do
    $PKG info -e "$p" || { echo "FAIL: pkg install NextBSD-desktop did not install $p (or removed it)" >&2; exit 1; }
  done
  echo "OK (${ARCH}): pkg install NextBSD-desktop installs NextBSD-server, NextBSD-gnustep and the desktop apps"
else
  echo "=== no NextBSD-desktop in this repo (nextbsd-desktop has not published); not tested ==="
fi

# 7. Upgrade from the published repo (nextbsd/nextbsd#680): install
#    NextBSD-everything from continuous-${ARCH} as it is now, then
#    `pkg upgrade` from this run's repo. Every package installed before must
#    still be installed after, NextBSD-server must be installed, and
#    SystemVersion.plist must be there, owned by NextBSD-server, with this
#    run's build. Skipped when the published repo can't be fetched.
PUBURL="https://github.com/nextbsd/nextbsd-pkg/releases/download/continuous-${ARCH}"
PUBREPOS=$(mktemp -d)
cat > "$PUBREPOS/NextBSD.conf" <<CONF
NextBSD: { url: "${PUBURL}", enabled: yes, signature_type: none }
CONF
ROOT=$(mktemp -d)
OPKG="$NBPKGBIN -C $PWD/tool/pkg.conf -R $PUBREPOS -r $ROOT"
PKG="$NBPKGBIN -C $PWD/tool/pkg.conf -R $REPOS -r $ROOT"
echo "=== upgrade test: NextBSD-everything from ${PUBURL}, then pkg upgrade from this repo (${ARCH}) ==="
if $OPKG update -f && $OPKG install -y NextBSD-everything; then
  before=$($OPKG query '%n' | sort)
  echo "before: $(echo "$before" | tr '\n' ' ')"
  $PKG update -f
  $PKG upgrade -y
  after=$($PKG query '%n' | sort)
  echo "after:  $(echo "$after" | tr '\n' ' ')"
  for p in $before NextBSD-server; do
    echo "$after" | grep -qx "$p" || { echo "FAIL: $p is not installed after pkg upgrade" >&2; exit 1; }
  done
  _owner=$($PKG which -q "$SYSVER" || true)
  [ "${_owner%-[0-9]*}" = NextBSD-server ] || { echo "FAIL: after pkg upgrade $SYSVER is owned by '${_owner}', not NextBSD-server" >&2; exit 1; }
  _new=$($PKG query '%v' NextBSD-server)
  grep -q "<string>${_new##*.}</string>" "$ROOT$SYSVER" || { echo "FAIL: after pkg upgrade $SYSVER does not carry build ${_new##*.}" >&2; exit 1; }
  echo "OK (${ARCH}): pkg upgrade from the published repo keeps every package, installs NextBSD-server ${_new} and keeps SystemVersion.plist"
else
  echo "=== upgrade test skipped: could not install NextBSD-everything from ${PUBURL} ==="
fi
