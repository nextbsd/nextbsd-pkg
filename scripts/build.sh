#!/bin/sh
# build.sh — runs INSIDE the FreeBSD VM (vmactions). Repackages the component
# `continuous` artifacts for ${ARCH} into one pkg(8) package each (named after
# the source repo), plus a NextBSD-everything meta, into a FLAT repo (out/repo/).
#
# Arch-aware: both arches get every package. The kext SETS differ (arm64
# ships the drm core + virtio-gpu trio; amd64 adds Intel/AMD/Radeon/
# Bochs/VBox, plus NVIDIA as its own package), so kernel-extensions-graphics is built from whatever kext tarballs the
# workflow fetched for this arch — and skipped entirely if there are none. The
# packaging itself is cross-arch on the x86 VM — pkg create just tars
# already-built ELF with the ${ABI} label; it doesn't compile.
#
# Coherent-snapshot versioning (all share one version this run); UNSIGNED for now.
set -eux

pkg --version || pkg bootstrap -y   # the VM's own pkg; install-test.sh uses it

ARCH="${ARCH:-amd64}"
# pkg's ABI uses 'aarch64' for 64-bit ARM, while the artifact files are named 'arm64'.
case "$ARCH" in arm64) ABIARCH=aarch64 ;; *) ABIARCH="$ARCH" ;; esac
ABI="FreeBSD:15:${ABIARCH}"
VER="0.0.0.$(date -u +%Y%m%d%H%M%S)"

rm -rf stage out tool
mkdir -p out/repo

# --- NextBSD's own pkg builds the repo (pkg#19) ---
# `pkg create`, `pkg query` and `pkg repo` below run NextBSD's pkg-static (from
# nextbsd-contrib, the same build the `pkg` package ships), not the VM's
# FreeBSD pkg. The VM is amd64 whatever ${ARCH} is, so the workflow always
# fetches the amd64 artifact as art/tool/; pkg-static is fully static and
# built for FreeBSD 15.1, so it runs on this 15.1 VM. NextBSD's pkg reads
# /private/etc/pkg.conf and /private/etc/pkg/, which the VM doesn't have, so
# it gets an explicit empty config (-C) and repo directory (-R) instead and
# never falls back to a default path.
mkdir -p tool/root tool/repos
tar -C tool/root -xzf art/tool/nextbsd-contrib-pkg-amd64.tar.gz ./usr/sbin/pkg-static
: > tool/pkg.conf
NBPKG="$PWD/tool/root/usr/sbin/pkg-static -C $PWD/tool/pkg.conf -R $PWD/tool/repos"
$NBPKG --version

# Every NextBSD-* package carries these two manifest entries:
#   vital: true -- pkg refuses to delete it (pkg delete without -f, autoremove,
#     and removal to resolve a conflict with another repo's package); upgrades
#     still replace it. To retire a package, publish one last version without
#     vital (README "Vital packages").
#   annotation org.nextbsd.origin: NextBSD -- NextBSD's pkg (nextbsd-contrib)
#     lets a local package file without it install only under /usr/local and
#     /var, and only a stamped pkg may replace pkg.
NBMARK='vital: true
annotations: { "org.nextbsd.origin": "NextBSD" }'

# mkpkg <name> <stagedir> <comment> <deps-ucl-or-empty> [<dir>...]
#   Every file and symlink in <stagedir> goes in the plist. Directories are
#   not listed (most come from the base mtree), so a package that must create
#   an EMPTY directory names it after the deps, and it is recorded as @dir.
#   pkg create records each ELF library's SONAME as shlibs_provided (pkg's
#   SHLIB_PROVIDE_PATHS_* are unset, so no path is filtered out) and each
#   NEEDED entry as shlibs_required. It skips ELF files whose arch differs
#   from its own ABI, so it runs with the TARGET ABI pinned (the VM is amd64):
#   without that, every arm64 package would declare no shlibs at all. As in
#   install-test.sh, pkg wants OSVERSION whenever ABI is pinned.
mkpkg() {
  _name=$1; _root=$2; _comment=$3; _deps=$4
  shift 4
  cat > /tmp/+MANIFEST <<UCL
name: ${_name}
origin: nextbsd/${_name}
version: "${_mver:-$VER}"
comment: "${_comment}"
desc: "${_comment} — NextBSD ${ARCH} ${VER} snapshot."
maintainer: "dev@nextbsd.org"
www: "https://nextbsd.org"
abi: "${ABI}"
arch: "${ABI}"
prefix: "/"
${NBMARK}
UCL
  [ -n "${_deps}" ] && printf '%s\n' "${_deps}" >> /tmp/+MANIFEST
  ( cd "${_root}" && find . \( -type f -o -type l \) | sed 's#^\.##' ) | sort > /tmp/plist
  for _dir in "$@"; do
    [ -d "${_root}${_dir}" ] || { echo "ERROR: ${_name}: directory ${_dir} is not in its artifact" >&2; exit 1; }
    echo "@dir ${_dir}" >> /tmp/plist
  done
  echo "=== ${_name}: $(wc -l < /tmp/plist) files ==="
  env ABI="${ABI}" OSVERSION="$(uname -K)" \
    $NBPKG create -M /tmp/+MANIFEST -p /tmp/plist -r "${_root}" -o out/repo
}

dep()  { printf 'deps: { %s: { origin: "nextbsd/%s", version: "%s" } }\n' "$1" "$1" "$VER"; }
dep2() { printf 'deps: { %s: { origin: "nextbsd/%s", version: "%s" }, %s: { origin: "nextbsd/%s", version: "%s" } }\n' "$1" "$1" "$VER" "$2" "$2" "$VER"; }
# deps <name>... : one deps block for any number of same-snapshot NextBSD-* packages.
deps() {
  _sep=
  printf 'deps: {'
  for _d in "$@"; do printf '%s %s: { origin: "nextbsd/%s", version: "%s" }' "$_sep" "$_d" "$_d" "$VER"; _sep=,; done
  printf ' }\n'
}
# repkg [-a <artifact>] [-v <version>] <name> <stage> <comment> [<dep>...] [-- <dir>...]
#   Repackages one component repo's `continuous` artifact as is:
#   art/nextbsd-<repo>-${ARCH}.tar.gz (NextBSD-<repo> lowercased; -a names
#   another art/<artifact>-${ARCH}.tar.gz) is unpacked into stage/<stage> and
#   packaged as <name>, depending on the same-snapshot NextBSD-* packages
#   listed. The package takes the snapshot version unless -v gives its own.
#   Directories after `--` are recorded as @dir (see mkpkg). Adding a repo is
#   one call here plus one download in the workflow.
repkg() {
  _rartbase=; _mver=
  while :; do
    case "$1" in
      -a) _rartbase=$2; shift 2 ;;
      -v) _mver=$2; shift 2 ;;
      *) break ;;
    esac
  done
  _rname=$1; _rstage=stage/$2; _rcomment=$3; shift 3
  _rdeps=
  while [ $# -gt 0 ] && [ "$1" != -- ]; do _rdeps="$_rdeps $1"; shift; done
  [ "${1:-}" = -- ] && shift
  _rart="art/${_rartbase:-$(echo "$_rname" | tr '[:upper:]' '[:lower:]')}-${ARCH}.tar.gz"
  mkdir -p "$_rstage"
  tar -C "$_rstage" -xzf "$_rart"
  # shellcheck disable=SC2086 # word-splitting the dep list is intended
  mkpkg "$_rname" "$_rstage" "$_rcomment" "$([ -n "$_rdeps" ] && deps $_rdeps)" "$@"
  _mver=
}

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

# The kernel's KERNEL-BUILD-ID (<commit>.<run_id>.<run_attempt>, nextbsd-kernel#326),
# from the same tarball. Every kext packaged below must have been built for it.
KIDPATH=$(tar tzf "art/nextbsd-kernel-${ARCH}.tar.gz" | grep -E 'sys/NEXTBSD/KERNEL-BUILD-ID$' | head -1)
[ -n "$KIDPATH" ] || { echo "ERROR: the kernel artifact carries no KERNEL-BUILD-ID (it predates nextbsd-kernel#326)" >&2; exit 1; }
KERNEL_BUILD_ID=$(tar -xzOf "art/nextbsd-kernel-${ARCH}.tar.gz" "$KIDPATH")
echo "kernel KERNEL-BUILD-ID: ${KERNEL_BUILD_ID}"

# check_kext_build_ids <Extensions dir>: refuse to package any kext not built for
# this kernel (pkg#12). Each kext records the kernel build it was compiled for as
# NBSDKernelBuildID in its Info.plist. A mismatched kernel + kext pair boots, then
# panics in an unrelated driver (nextbsd-kernel-extensions-graphics#46), so the whole run
# fails rather than publish it. Same comparison as nextbsd-ci's assemble-image.sh.
check_kext_build_ids() {
  _bad=0; _n=0
  for _p in $(find "$1" -path '*.kext/Contents/Info.plist' | sort); do
    _k=${_p#"$1"/}; _k=${_k%/Contents/Info.plist}
    _got=$(awk '/<key>NBSDKernelBuildID<\/key>/ {
              if ($0 !~ /<string>/) getline
              if (match($0, /<string>[^<]*<\/string>/)) print substr($0, RSTART + 8, RLENGTH - 17)
              exit
            }' "$_p")
    _n=$((_n + 1))
    if [ "$_got" != "$KERNEL_BUILD_ID" ]; then
      echo "  MISMATCH  $_k: ${_got:-<no NBSDKernelBuildID>}" >&2
      _bad=$((_bad + 1))
    fi
  done
  if [ "$_bad" -ne 0 ]; then
    echo "ERROR: $_bad of $_n kexts were not built for kernel ${KERNEL_BUILD_ID}; refusing to package." >&2
    echo "       Rebuild the kexts against the current kernel first (nextbsd-kernel-extensions-graphics," >&2
    echo "       then nextbsd-kernel-extensions-nvidia), then rerun this workflow." >&2
    exit 1
  fi
  echo "=== KERNEL-BUILD-ID: all $_n kexts in $1 built for kernel ${KERNEL_BUILD_ID} ==="
}

# no_mesa_x_llvm <package>: a kext package MUST stay free of Mesa, X and LLVM. pkg
# resolves shlibs_required against every package's shlibs_provided, so a
# libgbm.so.1 (or libX11/libXext/libdrm) left in shlibs_required would make
# `pkg install NextBSD-everything` pull NextBSD-mesa (or X) in. Fail the build
# instead of shipping that.
no_mesa_x_llvm() {
  _pkg=$(ls out/repo/"$1"-[0-9]*.pkg 2>/dev/null | head -1)
  [ -n "$_pkg" ] || { echo "ERROR: $1 was not built" >&2; exit 1; }
  _baddep=$($NBPKG query -F "$_pkg" '%dn' 2>/dev/null | grep -iE 'mesa|llvm|gallium|xlib' || true)
  [ -z "$_baddep" ] || { echo "ERROR: $1 gained a forbidden dependency: $_baddep" >&2; exit 1; }
  _badreq=$($NBPKG query -F "$_pkg" '%B' 2>/dev/null | grep -E '^lib(gbm|X11|Xext|drm)\.so' || true)
  [ -z "$_badreq" ] || { echo "ERROR: $1 requires $_badreq; it belongs in shlibs_required_ignore" >&2; exit 1; }
  echo "=== guard OK: $1 requires no Mesa, X or LLVM ==="
  echo "    shlibs_required: $($NBPKG query -F "$_pkg" '%B' | sort | tr '\n' ' ')"
  echo "    shlibs_provided: $($NBPKG query -F "$_pkg" '%b' | sort | tr '\n' ' ')"
}

# --- 3. NextBSD-kernel-extensions-graphics (every kext artifact this arch has) ---
# Built from nextbsd-kernel-extensions-graphics, which was nextbsd-kernel-extensions
# (nextbsd/nextbsd#551); the package was NextBSD-kernel-extensions (pkg#23).
# Glob rather than a fixed name list: the graphics asset is per-arch
# (graphics-kexts-${ARCH}.tar.gz, nextbsd-kernel-extensions-graphics#36), and the
# workflow above only ever puts THIS arch's tarballs in art/. The FreeBSD and
# NVIDIA kexts land in art/freebsd/ and art/nvidia/, outside this glob.
HAVE_KEXTS=0
mkdir -p stage/kexts/System/Library/Extensions
for t in art/*kext*.tar.gz; do
  [ -f "$t" ] || continue
  echo "unpacking kext artifact: $t"
  tar -C stage/kexts/System/Library/Extensions -xzf "$t"
done
if ls stage/kexts/System/Library/Extensions/*.kext >/dev/null 2>&1; then
  check_kext_build_ids stage/kexts/System/Library/Extensions
  # Tarballs carry their build-runner uid; OSKext requires root:wheel + go-w.
  chown -R 0:0 stage/kexts
  find stage/kexts/System/Library/Extensions -maxdepth 1 \( -name '*.kext' -o -name '*.bundle' \) -exec chmod -R go-w {} +
  echo "=== staged kexts ==="; ls -1 stage/kexts/System/Library/Extensions
  # Comment is arch-accurate: arm64 carries only the drm core + virtio-gpu.
  # The Intel NIC/WiFi kexts are in NextBSD-kernel-extensions (3a) and NVIDIA in
  # its own package (3b).
  case "$ARCH" in
    amd64) KXCOMMENT="NextBSD graphics kernel extensions (drm graphics + virtio-gpu kexts/firmware)" ;;
    *)     KXCOMMENT="NextBSD graphics kernel extensions (drm graphics core + virtio-gpu kexts)" ;;
  esac
  mkpkg NextBSD-kernel-extensions-graphics stage/kexts "$KXCOMMENT" "$(dep NextBSD-kernel)"
  no_mesa_x_llvm NextBSD-kernel-extensions-graphics
  HAVE_KEXTS=1
else
  echo "=== no kexts for ${ARCH} (arch-specific kexts not built) — skipping NextBSD-kernel-extensions-graphics ==="
fi

# --- 3a. NextBSD-kernel-extensions (the FreeBSD kexts; nextbsd-kernel-extensions) ---
# The FreeBSD-derived kexts from the new nextbsd-kernel-extensions (pkg#24,
# nextbsd/nextbsd#554): today IntelWiFi (with its iwlwifi firmware) and
# IntelEthernet, amd64 only. Until pkg#23 this name held the graphics kexts, and
# until pkg#24 the Intel kexts were in -graphics; an upgrade moves those files in
# one transaction, as both packages move to the same snapshot version.
# arm64 has no FreeBSD kexts yet, so there the package is empty. It still ships,
# so an older arm64 NextBSD-kernel-extensions (graphics, before pkg#23) has a
# version to upgrade to instead of staying installed and conflicting with
# -graphics over every file.
mkdir -p stage/freebsd/System/Library/Extensions
if [ -f "art/freebsd/freebsd-kexts-${ARCH}.tar.gz" ]; then
  tar -C stage/freebsd/System/Library/Extensions -xzf "art/freebsd/freebsd-kexts-${ARCH}.tar.gz"
  check_kext_build_ids stage/freebsd/System/Library/Extensions
  chown -R 0:0 stage/freebsd
  find stage/freebsd/System/Library/Extensions -maxdepth 1 -name '*.kext' -exec chmod -R go-w {} +
  echo "=== staged FreeBSD kexts ==="; ls -1 stage/freebsd/System/Library/Extensions
  FKCOMMENT="NextBSD kernel extensions (FreeBSD-derived kexts: $(cd stage/freebsd/System/Library/Extensions && ls -d *.kext | sed 's/\.kext$//' | paste -sd, - | sed 's/,/, /g'))"
elif [ "$ARCH" = amd64 ]; then
  echo "ERROR: amd64 but no freebsd-kexts-amd64.tar.gz from nextbsd-kernel-extensions" >&2
  exit 1
else
  rm -rf stage/freebsd/System
  FKCOMMENT="NextBSD kernel extensions (FreeBSD-derived kexts; none on ${ARCH} yet)"
fi
mkpkg NextBSD-kernel-extensions stage/freebsd "$FKCOMMENT" "$(dep NextBSD-kernel)"
no_mesa_x_llvm NextBSD-kernel-extensions

# --- 3b. NextBSD-kernel-extensions-nvidia (amd64; nextbsd-kernel-extensions-nvidia) ---
# NVIDIA's proprietary driver lives in its own repo and package (E21 D3, pkg#22):
# the chained NVIDIACore595 / NVIDIAModeset595 / NVIDIAGraphics595 kexts and the
# NVIDIA595.bundle userland. NVIDIAGraphics595 links IOGraphics.kext
# (OSBundleLibraries), which NextBSD-kernel-extensions-graphics ships, hence the
# dep. Its files used to be in NextBSD-kernel-extensions; NextBSD-everything
# depends on both at the same snapshot version, so an upgrade moves them in one
# transaction.
HAVE_NVIDIA=0
if [ -f art/nvidia/nvidia-kexts-amd64.tar.gz ]; then
  [ "$HAVE_KEXTS" = 1 ] || { echo "ERROR: NVIDIA kexts but no NextBSD-kernel-extensions-graphics (IOGraphics) to depend on" >&2; exit 1; }
  mkdir -p stage/nvidia/System/Library/Extensions
  tar -C stage/nvidia/System/Library/Extensions -xzf art/nvidia/nvidia-kexts-amd64.tar.gz
  check_kext_build_ids stage/nvidia/System/Library/Extensions
  chown -R 0:0 stage/nvidia
  find stage/nvidia/System/Library/Extensions -maxdepth 1 \( -name '*.kext' -o -name '*.bundle' \) -exec chmod -R go-w {} +
  # NVIDIA userland bundles (NVIDIA<NNN>.bundle) are version-locked storage for the
  # X11/GL/EGL/GBM driver half. Activate each by symlinking it into the paths X,
  # rtld, GLVND and Mesa's GBM loader search (/usr/X11, E23 D15; bundles built
  # before nextbsd-kernel-extensions-nvidia#2 link /usr/local instead). Static
  # activation: the symlinks ship in the package, targeting the bundle's final
  # /System location, so they are in place whatever is installed later and in
  # whatever order; nothing runs at install or boot. The activator ships inside
  # the bundle.
  for b in stage/nvidia/System/Library/Extensions/*.bundle; do
    [ -d "$b" ] || continue
    act="$b/Contents/Resources/nvidia-activate.sh"
    [ -f "$act" ] && sh "$act" "/System/Library/Extensions/$(basename "$b")" stage/nvidia
  done
  echo "=== staged NVIDIA kexts + userland ==="; ls -1 stage/nvidia/System/Library/Extensions
  # The NVIDIA userland bundle's GLX and GBM libraries link libX11, libXext,
  # libdrm and libgbm. Those come from NextBSD-xlibs, -displayserver-support
  # and -mesa, and pkg would pull them in through shlibs_required, putting X
  # and Mesa into NextBSD-everything (still open, nextbsd#571). The bundle's X
  # and GBM halves are only used once X or Mesa is installed, and installing
  # NextBSD-xlibre (or NextBSD-mesa) brings these libraries, so the package
  # doesn't require them. libgbm.so.1 used to be bundled so pkg saw it as
  # provided; the bundle now leaves it to NextBSD-mesa
  # (nextbsd-kernel-extensions-nvidia#2).
  KXIGNORE='shlibs_required_ignore: [ "libX11.so.6", "libXext.so.6", "libdrm.so.2", "libgbm.so.1" ]'
  mkpkg NextBSD-kernel-extensions-nvidia stage/nvidia \
    "NextBSD NVIDIA kernel extensions (NVIDIAGraphics595 + modeset/core kexts, GSP firmware, NVIDIA595 userland bundle)" \
    "$(dep NextBSD-kernel-extensions-graphics)
${KXIGNORE}"
  no_mesa_x_llvm NextBSD-kernel-extensions-nvidia
  HAVE_NVIDIA=1
elif [ "$ARCH" = amd64 ]; then
  echo "ERROR: amd64 but no nvidia-kexts-amd64.tar.gz from nextbsd-kernel-extensions-nvidia" >&2
  exit 1
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
repkg NextBSD-contrib contrib "NextBSD third-party base programs (sudo, zsh, pico)" NextBSD-freebsd-compat

# --- 6-9. Display server stack (E23 nextbsd#561, E25 nextbsd#583) ---
# One package per repo (E23 D13), each repackaged as is. Dependencies are the
# artifacts' ELF NEEDED entries matched to the files the other artifacts ship.
# None of these is in NextBSD-everything: that is still open (nextbsd#571,
# E23 step 16), so images add them by name.
#
# /etc belongs to nextbsd-overlays (pkg#25): /etc/fonts, /etc/xkb,
# /etc/libinput and the ld-elf.so.conf / PATH entries for /usr/X11 come from
# there, not from these packages. None of them ships /usr/local or an ldconfig
# drop-in, and nothing runs ldconfig after install: rtld's default path already
# covers /usr/lib and /usr/X11/lib.
#
# Base provides the X stack (E23 D14, pkg#26): pkg create records every
# library's SONAME below as shlibs_provided (libdrm.so.2, libX11.so.6,
# libxcb.so.1, libGL.so.1, libEGL.so.1, libgbm.so.1, ...), so pkg treats a
# FreeBSD package's shlibs_required on them as satisfied once these are
# installed. pkg resolves a package's `deps` by package NAME, though, and no
# declaration in these packages can satisfy a FreeBSD package's dependency on
# `libX11` or `mesa-libs`; README "Base provides the X stack" has the detail.
#
# Upgrades: pkg owns each package's file list, and `pkg upgrade` deletes the
# files the new version no longer lists (pkg_add_cleanup_old), so a library
# that moves between NextBSD packages is removed from its old place in the
# same upgrade.

# 6. NextBSD-displayserver-support: what XLibre and a GNUstep WindowServer
#    share, in /usr (E25 D4): libdrm, pixman, expat, freetype, fontconfig,
#    libxkbcommon, xkeyboard-config, epoll-shim, the IOKit libudev, libevdev,
#    mtdev, libinput and the linux-input shim, plus the org.nextbsd.fc-cache
#    LaunchDaemon. libudev links libIOKit, CoreFoundation and libdispatch from
#    the userland.
repkg NextBSD-displayserver-support displayserver "NextBSD display server support (libdrm, pixman, freetype, fontconfig, libxkbcommon, libinput, IOKit libudev)" \
  NextBSD-freebsd-compat NextBSD-userland

# 7. NextBSD-xlibs: the X client libraries in /usr/X11, plus libxkbcommon-x11
#    (E25 D5). libXft and libXfont2 link freetype and fontconfig, and
#    libxkbcommon-x11 links libxkbcommon, from displayserver-support.
repkg NextBSD-xlibs xlibs "NextBSD X client libraries in /usr/X11 (libX11, libxcb, libXext, libXft, libxkbcommon-x11, ...)" \
  NextBSD-freebsd-compat NextBSD-displayserver-support

# 8. NextBSD-mesa: nextbsd-mesa's X-free core artifact in /usr/X11: libglvnd's
#    EGL, GLES, OpenGL and dispatch libraries, Mesa's core build (libgallium
#    with LLVM linked statically, no libLLVM; libEGL_mesa_core, libgbm,
#    dri_gbm, the DRI drivers) and GLU. Links libdrm and expat from
#    displayserver-support and nothing from xlibs (nextbsd-mesa#10, pkg#34).
repkg NextBSD-mesa mesa "NextBSD OpenGL, EGL and GBM in /usr/X11 (libglvnd, Mesa, GLU; no X)" \
  NextBSD-freebsd-compat NextBSD-displayserver-support

# 8b. NextBSD-mesa-x11: nextbsd-mesa's X artifact (nextbsd-mesa-x11-<arch>):
#     Mesa's GLX (libGLX_mesa, libGLX_indirect) and x11 EGL vendor
#     (libEGL_mesa, 50_mesa.json), libglvnd's libGL and libGLX, the GLX
#     headers, gl.pc and glx.pc. They run against NextBSD-mesa's libgallium
#     and link the X client libraries.
repkg NextBSD-mesa-x11 mesa-x11 "NextBSD Mesa X11 parts in /usr/X11 (GLX, libGL, the X11 EGL vendor)" \
  NextBSD-freebsd-compat NextBSD-mesa NextBSD-xlibs

# 9. NextBSD-xlibre: the XLibre 25.1.9 server, drivers (vesa and vmmouse on
#    amd64 only), tools, libepoxy, libxcvt and libpciaccess in /usr/X11; the
#    org.nextbsd.xlibre LaunchAgent (on-demand X, disabled by default); and
#    the empty /var/db/xkb for compiled keymaps. The input stack and xkb data
#    come from displayserver-support. glamor and GLX (libglamoregl.so,
#    extensions/libglx.so) link libGL.so.1 from NextBSD-mesa-x11.
repkg NextBSD-xlibre xlibre "NextBSD X server (XLibre 25.1.9, drivers and tools in /usr/X11)" \
  NextBSD-freebsd-compat NextBSD-displayserver-support NextBSD-xlibs NextBSD-mesa NextBSD-mesa-x11 \
  -- /var/db/xkb

# Log what each display package tells pkg it provides (pkg#26).
for p in NextBSD-displayserver-support NextBSD-xlibs NextBSD-mesa NextBSD-mesa-x11 NextBSD-xlibre; do
  echo "=== $p shlibs_provided ==="
  $NBPKG query -F out/repo/"$p"-[0-9]*.pkg '%b' | sort | tr '\n' ' '; echo
done

# --- 10-12. E24 (nextbsd#574): GNUstep/Gershwin requirements + the toolchain ---
# Gershwin builds and installs GNUstep itself into /System (D10); NextBSD ships
# only what it needs, in /usr and /usr/X11. None of these three is in
# NextBSD-everything: Gershwin images list them in Gershwin's nextbsd.txt, and
# NextBSD-toolchain in particular is installed by default on Gershwin images
# only (D11). Repackaged verbatim: the artifacts carry no /etc (CUPS's config,
# PAM stack and accounts come from nextbsd-overlays), no /usr/local and no
# ldconfig drop-in, and nothing runs ldconfig after install (rtld's default
# path covers /usr/X11/lib; see pkg#25).
#
# nextbsd-gershwin-support is deliberately NOT packaged (maintainer,
# 2026-10-25), so nothing here may depend on it.

# 10. NextBSD-gnustep-support: image formats, GnuTLS (+ nettle, gmp), cairo
#     (in /usr/X11), libsndfile + libao, SQLite, flite, FFmpeg. cairo links
#     libX11, libxcb and libXrender from xlibs, and pixman, freetype and
#     fontconfig from displayserver-support.
repkg NextBSD-gnustep-support gnustep "NextBSD GNUstep support libraries (image formats, GnuTLS, cairo, sound, SQLite, flite, FFmpeg)" \
  NextBSD-freebsd-compat NextBSD-displayserver-support NextBSD-xlibs

# 11. NextBSD-printing-support: Apple's CUPS. GnuTLS comes from
#     gnustep-support; liblaunch (launch_activate_socket) and libdns_sd from
#     the userland. The compat base drops the BSD LPD suite that CUPS's lp,
#     lpr, lpq, lprm and lpc replace (nextbsd-freebsd-compat scripts/superseded).
repkg NextBSD-printing-support printing "NextBSD printing support (Apple's CUPS)" \
  NextBSD-freebsd-compat NextBSD-userland NextBSD-gnustep-support

# 12. NextBSD-toolchain: on-machine clang/lld 19.1.7, LLVM binutils, gmake,
#     pkgconf and Apple's Git (client only; libcurl from the userland).
repkg NextBSD-toolchain toolchain "NextBSD on-machine toolchain (clang/lld 19.1.7, gmake, pkgconf, Git, CMake, autotools)" \
  NextBSD-freebsd-compat NextBSD-userland

# --- 13. pkg: NextBSD's own pkg(8) (pkg#19) ---
# Built by nextbsd-contrib from its frozen pkg 2.8.4 with the NextBSD patches
# (src/pkg, NEXTBSD.md): pkg comes only from the repository named NextBSD; a
# package not from it, or a package file without org.nextbsd.origin=NextBSD,
# may only install under /usr/local and /var. Everything is under /usr. The
# package ships no configuration: /private/etc/pkg.conf and
# /private/etc/pkg/NextBSD.conf (which sets the NextBSD repo's priority) come
# from nextbsd-overlays. Its version is pkg's own (pkg.pc's Version:), not the
# snapshot, so it compares correctly with other repositories' pkg.
mkdir -p tool/pc
tar -C tool/pc -xzf "art/nextbsd-contrib-pkg-${ARCH}.tar.gz" ./usr/libdata/pkgconfig/pkg.pc
PKGVER=$(sed -n 's/^Version: *//p' tool/pc/usr/libdata/pkgconfig/pkg.pc)
[ -n "$PKGVER" ] || { echo "ERROR: no Version: in the contrib pkg artifact's pkg.pc" >&2; exit 1; }
repkg -a nextbsd-contrib-pkg -v "$PKGVER" pkg pkg "NextBSD's pkg(8) package manager (pkg only from the NextBSD repository)" \
  NextBSD-freebsd-compat

# --- 14. NextBSD-everything (meta: installs the whole OS for this arch) ---
# The display stack (nextbsd#571 is still open) and the E24 packages (D11;
# Gershwin's nextbsd.txt) are deliberately not in it.
mkdir -p stage/everything
{
  echo "name: NextBSD-everything"
  echo "origin: nextbsd/NextBSD-everything"
  echo "version: \"${VER}\""
  echo "comment: \"NextBSD-everything meta-package (base + kernel + userland + contrib + kernel-extensions + pkg$([ "$HAVE_KEXTS" = 1 ] && echo ' + kernel-extensions-graphics')$([ "$HAVE_NVIDIA" = 1 ] && echo ' + NVIDIA'))\""
  echo "desc: \"Installs the complete NextBSD ${ARCH} OS snapshot ${VER}.\""
  echo "maintainer: \"dev@nextbsd.org\""
  echo "www: \"https://nextbsd.org\""
  echo "abi: \"${ABI}\""
  echo "arch: \"${ABI}\""
  echo "prefix: \"/\""
  echo "${NBMARK}"
  echo "deps: {"
  echo "  NextBSD-freebsd-compat: { origin: \"nextbsd/NextBSD-freebsd-compat\", version: \"${VER}\" }"
  echo "  NextBSD-kernel: { origin: \"nextbsd/NextBSD-kernel\", version: \"${VER}\" }"
  echo "  NextBSD-userland: { origin: \"nextbsd/NextBSD-userland\", version: \"${VER}\" }"
  echo "  NextBSD-contrib: { origin: \"nextbsd/NextBSD-contrib\", version: \"${VER}\" }"
  echo "  pkg: { origin: \"nextbsd/pkg\", version: \"${PKGVER}\" }"
  [ "$HAVE_KEXTS" = 1 ] && echo "  NextBSD-kernel-extensions-graphics: { origin: \"nextbsd/NextBSD-kernel-extensions-graphics\", version: \"${VER}\" }"
  echo "  NextBSD-kernel-extensions: { origin: \"nextbsd/NextBSD-kernel-extensions\", version: \"${VER}\" }"
  [ "$HAVE_NVIDIA" = 1 ] && echo "  NextBSD-kernel-extensions-nvidia: { origin: \"nextbsd/NextBSD-kernel-extensions-nvidia\", version: \"${VER}\" }"
  echo "}"
} > /tmp/+MANIFEST
: > /tmp/plist
env ABI="${ABI}" OSVERSION="$(uname -K)" \
  $NBPKG create -M /tmp/+MANIFEST -p /tmp/plist -r stage/everything -o out/repo

# --- Layer A (nextbsd#370): fail if any two component packages co-own a path,
#     BEFORE cataloging/publishing. Fast + deterministic; names the culprit. ---
sh scripts/check-ownership.sh

# Log each package's vital flag and NextBSD origin stamp (see NBMARK).
echo "=== vital / org.nextbsd.origin ==="
for f in out/repo/*.pkg; do
  $NBPKG query -F "$f" '%n vital=%V' | tr '\n' ' '
  $NBPKG query -F "$f" '%At=%Av' | grep '^org\.nextbsd\.origin=' || echo "(no org.nextbsd.origin)"
done

# --- catalog the flat repo ---
echo "=== packages (${ARCH}) ==="; ls -lh out/repo/*.pkg
$NBPKG repo out/repo
echo "=== flat repo catalog ==="; ls -lh out/repo
