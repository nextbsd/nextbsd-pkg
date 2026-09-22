#!/bin/sh
# build.sh — runs INSIDE the FreeBSD VM (vmactions). Repackages the component
# `continuous` artifacts for ${ARCH} into one pkg(8) package each (named after
# the source repo), plus a NextBSD-everything meta, into a FLAT repo (out/repo/).
#
# Arch-aware: both arches get all five packages. The kext SETS differ (arm64
# ships the drm core + virtio-gpu trio; amd64 adds Intel/AMD/Radeon/NVIDIA/
# Bochs/VBox), so kernel-extensions is built from whatever kext tarballs the
# workflow fetched for this arch — and skipped entirely if there are none. The
# packaging itself is cross-arch on the x86 VM — pkg create just tars
# already-built ELF with the ${ABI} label; it doesn't compile.
#
# Coherent-snapshot versioning (all share one version this run); UNSIGNED for now.
set -eux

pkg --version || pkg bootstrap -y

ARCH="${ARCH:-amd64}"
# pkg's ABI uses 'aarch64' for 64-bit ARM, while the artifact files are named 'arm64'.
case "$ARCH" in arm64) ABIARCH=aarch64 ;; *) ABIARCH="$ARCH" ;; esac
ABI="FreeBSD:15:${ABIARCH}"
VER="0.0.0.$(date -u +%Y%m%d%H%M%S)"

rm -rf stage out
mkdir -p out/repo

# mkpkg <name> <stagedir> <comment> <deps-ucl-or-empty>
mkpkg() {
  _name=$1; _root=$2; _comment=$3; _deps=$4
  cat > /tmp/+MANIFEST <<UCL
name: ${_name}
origin: nextbsd/${_name}
version: "${VER}"
comment: "${_comment}"
desc: "${_comment} — NextBSD ${ARCH} ${VER} snapshot."
maintainer: "dev@nextbsd.org"
www: "https://nextbsd.org"
abi: "${ABI}"
arch: "${ABI}"
prefix: "/"
UCL
  [ -n "${_deps}" ] && printf '%s\n' "${_deps}" >> /tmp/+MANIFEST
  ( cd "${_root}" && find . \( -type f -o -type l \) | sed 's#^\.##' ) | sort > /tmp/plist
  echo "=== ${_name}: $(wc -l < /tmp/plist) files ==="
  pkg create -M /tmp/+MANIFEST -p /tmp/plist -r "${_root}" -o out/repo
}

dep()  { printf 'deps: { %s: { origin: "nextbsd/%s", version: "%s" } }\n' "$1" "$1" "$VER"; }
dep2() { printf 'deps: { %s: { origin: "nextbsd/%s", version: "%s" }, %s: { origin: "nextbsd/%s", version: "%s" } }\n' "$1" "$1" "$VER" "$2" "$2" "$VER"; }

# --- 1. NextBSD-freebsd-compat (FreeBSD base: libc/libs, PAM, commands) ---
mkdir -p stage/compat
tar -C stage/compat -xzf "art/nextbsd-base-${ARCH}.tar.gz"
# base<->userland collisions are stripped UPSTREAM in nextbsd-freebsd-compat
# (scripts/strip-collisions.sh — self-policing: it fails the base build on any
# base<->userland overlap not in its allowlist), so the base tarball arrives
# already clean. No dedup needed here anymore (the old `rm -f Block.h
# Block_private.h` became a no-op once the base build owns collision policy).
mkpkg NextBSD-freebsd-compat stage/compat "NextBSD FreeBSD-compatible base (libc, libs, PAM, login, command suites)" ""

# --- 2. NextBSD-kernel (just the stripped kernel binary from the obj tree) ---
mkdir -p stage/kernel/boot/kernel
KPATH=$(tar tzf "art/nextbsd-kernel-${ARCH}.tar.gz" | grep -E 'sys/NEXTBSD/kernel$' | head -1)
echo "kernel binary in artifact: ${KPATH:-NOT FOUND}"
[ -n "$KPATH" ] || { echo "ERROR: could not locate the kernel binary in the artifact" >&2; exit 1; }
mkdir -p /tmp/kx
tar -C /tmp/kx -xzf "art/nextbsd-kernel-${ARCH}.tar.gz" "$KPATH"
cp "/tmp/kx/$KPATH" stage/kernel/boot/kernel/kernel
chmod 555 stage/kernel/boot/kernel/kernel
mkpkg NextBSD-kernel stage/kernel "NextBSD kernel (FreeBSD 15 KBI, Mach + Darwin glue baked in)" ""

# --- 3. NextBSD-kernel-extensions (every kext artifact this arch has) ---
# Glob rather than a fixed name list: the graphics asset is per-arch
# (graphics-kexts-${ARCH}.tar.gz, nextbsd-kernel-extensions#36) while the
# amd64-only ones (intelwifi/intelethernet/nvidia) stay arch-less, and the
# workflow above only ever puts THIS arch's tarballs in art/. A new kext
# artifact upstream is then packaged with no change here.
HAVE_KEXTS=0
mkdir -p stage/kexts/System/Library/Extensions
for t in art/*kext*.tar.gz; do
  [ -f "$t" ] || continue
  echo "unpacking kext artifact: $t"
  tar -C stage/kexts/System/Library/Extensions -xzf "$t"
done
if ls stage/kexts/System/Library/Extensions/*.kext >/dev/null 2>&1; then
  # Tarballs carry their build-runner uid; OSKext requires root:wheel + go-w.
  chown -R 0:0 stage/kexts
  find stage/kexts/System/Library/Extensions -maxdepth 1 \( -name '*.kext' -o -name '*.bundle' \) -exec chmod -R go-w {} +
  # NVIDIA userland bundles (NVIDIA<NNN>.bundle) are version-locked storage for the
  # X11/GL/EGL/GBM driver half. Activate each into the canonical /usr/local paths
  # (symlinks) so X (auto-detect), ld.so, GLVND and Vulkan find it. Single-branch
  # static activation — the symlinks ship in the package, targeting the bundle's
  # final /System location. The activator ships inside the bundle (from kernel-modules).
  for b in stage/kexts/System/Library/Extensions/*.bundle; do
    [ -d "$b" ] || continue
    act="$b/Contents/Resources/nvidia-activate.sh"
    [ -f "$act" ] && sh "$act" "/System/Library/Extensions/$(basename "$b")" stage/kexts
  done
  echo "=== staged kexts + userland ==="; ls -1 stage/kexts/System/Library/Extensions
  # Comment is arch-accurate: arm64 carries neither the Intel NIC/WiFi kexts nor
  # NVIDIA, so naming them unconditionally would advertise parts that aren't there.
  case "$ARCH" in
    amd64) KXCOMMENT="NextBSD kernel extensions (IntelEthernet, IntelWiFi, drm graphics + virtio-gpu + NVIDIAGraphics kexts/firmware + NVIDIA userland bundle)" ;;
    *)     KXCOMMENT="NextBSD kernel extensions (drm graphics core + virtio-gpu kexts)" ;;
  esac
  mkpkg NextBSD-kernel-extensions stage/kexts "$KXCOMMENT" "$(dep NextBSD-kernel)"
  # Guard: NextBSD-kernel-extensions MUST stay mesa/llvm-free. The NVIDIA bundle
  # vendors libgbm.so.1 (nvidia-mkbundle.sh) so pkg records it as shlibs_provided
  # and adds NO mesa-libs dependency. If a change ever drops that in-package
  # provide, `pkg create` above resolves libgbm.so.1 -> mesa-libs -> llvm19
  # (~1.9 GB) on the build VM and silently reintroduces both the bloat and the
  # /usr/local/lib/libgbm file conflict that evicts this package from images.
  # Fail the build loudly instead of shipping that.
  kxpkg=$(ls out/repo/NextBSD-kernel-extensions-*.pkg 2>/dev/null | head -1)
  if [ -n "$kxpkg" ]; then
    baddep=$(pkg query -F "$kxpkg" '%dn' 2>/dev/null | grep -iE 'mesa|llvm|gallium' || true)
    [ -z "$baddep" ] || { echo "ERROR: NextBSD-kernel-extensions gained a forbidden dependency: $baddep" >&2; echo "  libgbm.so.1 must remain shlibs_provided by the bundle (nvidia-mkbundle.sh)." >&2; exit 1; }
    echo "=== guard OK: NextBSD-kernel-extensions has no mesa/llvm dependency ==="
  fi
  HAVE_KEXTS=1
else
  echo "=== no kexts for ${ARCH} (arch-specific kexts not built) — skipping NextBSD-kernel-extensions ==="
fi

# --- 4. NextBSD-userland (Darwin Tier 0-2 runtime + daemons) ---
mkdir -p stage/userland
tar -C stage/userland -xzf "art/nextbsd-userland-${ARCH}.tar.gz"
mkpkg NextBSD-userland stage/userland "NextBSD Darwin/Mach userland (Mach, launchd, libdispatch, CoreFoundation, configd, IOKit + daemons)" "$(dep2 NextBSD-freebsd-compat NextBSD-kernel)"

# --- 5. NextBSD-contrib (third-party base programs: sudo, zsh, pico) ---
# Built by nextbsd-contrib against the compat base only, so it depends on
# NextBSD-freebsd-compat alone. Repackaged verbatim: the tarball carries the
# modes the build staged, including setuid on /usr/bin/sudo (tar as root keeps
# it, and pkg create records it).
mkdir -p stage/contrib
tar -C stage/contrib -xzf "art/nextbsd-contrib-${ARCH}.tar.gz"
mkpkg NextBSD-contrib stage/contrib "NextBSD third-party base programs (sudo, zsh, pico)" "$(dep NextBSD-freebsd-compat)"

# --- 6. NextBSD-everything (meta: installs the whole OS for this arch) ---
mkdir -p stage/everything
{
  echo "name: NextBSD-everything"
  echo "origin: nextbsd/NextBSD-everything"
  echo "version: \"${VER}\""
  echo "comment: \"NextBSD-everything meta-package (base + kernel + userland + contrib$([ "$HAVE_KEXTS" = 1 ] && echo ' + kernel-extensions'))\""
  echo "desc: \"Installs the complete NextBSD ${ARCH} OS snapshot ${VER}.\""
  echo "maintainer: \"dev@nextbsd.org\""
  echo "www: \"https://nextbsd.org\""
  echo "abi: \"${ABI}\""
  echo "arch: \"${ABI}\""
  echo "prefix: \"/\""
  echo "deps: {"
  echo "  NextBSD-freebsd-compat: { origin: \"nextbsd/NextBSD-freebsd-compat\", version: \"${VER}\" }"
  echo "  NextBSD-kernel: { origin: \"nextbsd/NextBSD-kernel\", version: \"${VER}\" }"
  echo "  NextBSD-userland: { origin: \"nextbsd/NextBSD-userland\", version: \"${VER}\" }"
  echo "  NextBSD-contrib: { origin: \"nextbsd/NextBSD-contrib\", version: \"${VER}\" }"
  [ "$HAVE_KEXTS" = 1 ] && echo "  NextBSD-kernel-extensions: { origin: \"nextbsd/NextBSD-kernel-extensions\", version: \"${VER}\" }"
  echo "}"
} > /tmp/+MANIFEST
: > /tmp/plist
pkg create -M /tmp/+MANIFEST -p /tmp/plist -r stage/everything -o out/repo

# --- Layer A (nextbsd#370): fail if any two component packages co-own a path,
#     BEFORE cataloging/publishing. Fast + deterministic; names the culprit. ---
sh scripts/check-ownership.sh

# --- catalog the flat repo ---
echo "=== packages (${ARCH}) ==="; ls -lh out/repo/*.pkg
pkg repo out/repo
echo "=== flat repo catalog ==="; ls -lh out/repo
