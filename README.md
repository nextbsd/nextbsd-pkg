# nextbsd-pkg

Assembles versioned **pkg(8)** packages for NextBSD from the component repos'
`continuous` build artifacts and publishes a **flat pkg repository** to per-arch
GitHub Release tags (`continuous-amd64` / `continuous-arm64`).

## How it works

```
nextbsd-freebsd-compat ────┐
nextbsd-kernel ────────────┤  continuous artifacts
nextbsd-kernel-extensions ─┤  (raw .tar.gz, per arch)
nextbsd-kernel-extensions-nvidia ─┤  (amd64)
nextbsd-userland ──────────┤
nextbsd-contrib ───────────┤
nextbsd-displayserver-support ─┤
nextbsd-xlibs ─────────────┤
nextbsd-mesa (+ mesa-x11) ─┤
nextbsd-xlibre ────────────┤
nextbsd-gnustep-support ───┤
nextbsd-printing-support ──┤
nextbsd-toolchain ─────────┘
               │  repository_dispatch: userland-updated / contrib-updated
               ▼
           nextbsd-pkg  ──(pkg create / pkg repo, inside a FreeBSD VM)──▶  flat repo
               │
               ▼  GitHub Release assets:  continuous-amd64 / continuous-arm64
           users:  pkg update && pkg upgrade     ISO builder:  pkg install NextBSD-everything
```

- **Packaging runs in a FreeBSD VM** (vmactions); the Linux runner only downloads the
  (public) artifacts and uploads the Release assets. `pkg create` and `pkg repo` use
  **NextBSD's own pkg** (`pkg-static` from the nextbsd-contrib artifact, the same build
  the `pkg` package ships), with an explicit empty config (`-C`) and repo directory
  (`-R`), not the VM's FreeBSD pkg. `install-test.sh` still installs with the VM's pkg.
  It installs `NextBSD-everything` into a scratch root, then, in a second root, checks
  that `pkg install NextBSD-mesa` brings neither `NextBSD-xlibs`, `NextBSD-mesa-x11` nor
  `NextBSD-xlibre`, and that `pkg install NextBSD-xlibre` brings `NextBSD-mesa`,
  `NextBSD-mesa-x11` and `NextBSD-xlibs`.
- **Publishing is manual** (`workflow_dispatch`). Pull requests build and install-test
  but never publish.
- **Flat repo on Release assets** (asset names can't contain `/`), one tag per arch.

## Consuming the repo

On NextBSD the repository is already configured. NextBSD's pkg reads
`/private/etc/pkg.conf` and `/private/etc/pkg/`, and `/private/etc/pkg/NextBSD.conf`
(from nextbsd-overlays, not from any package) points at
`.../releases/download/continuous-${MACHINE}` and gives the NextBSD repo a higher
`priority` (100) than any other. `CONSERVATIVE_UPGRADE` stays on (pkg's default). Images
also ship FreeBSD's ports repo as `/usr/local/etc/pkg/repos/FreeBSD.conf` (built by
nextbsd `build.sh`, default priority 0), and other repositories a user adds go there too. The
shipped FreeBSD repo is **temporary** and will be dropped from the images in the future;
users who want FreeBSD packages will then add it themselves.

With another pkg (FreeBSD's, for example, building an image), use a repo file for the
architecture:

```
# amd64
NextBSD: { url: "https://github.com/nextbsd/nextbsd-pkg/releases/download/continuous-amd64", enabled: yes }
```

```
# arm64
NextBSD: { url: "https://github.com/nextbsd/nextbsd-pkg/releases/download/continuous-arm64", enabled: yes }
```

Then install the whole OS via the meta-package (and upgrade as CI republishes):

```sh
pkg update
pkg install NextBSD-everything      # base + kernel + userland + contrib + kernel-extensions (+ NVIDIA on amd64) + pkg
pkg upgrade                    # rolling: picks up each new snapshot
```

## Packages

| package | amd64 | arm64 | from | depends on | in `NextBSD-everything` |
|---|:--:|:--:|---|---|:--:|
| `NextBSD-freebsd-compat` | ✓ | ✓ | nextbsd-freebsd-compat (base: libc, PAM, commands) | — | ✓ |
| `NextBSD-kernel` | ✓ | ✓ | nextbsd-kernel (kernel binary) | — | ✓ |
| `NextBSD-kernel-extensions` | ✓ | ✓ | nextbsd-kernel-extensions (drm graphics kexts per arch, plus IntelWiFi and IntelEthernet on amd64) | kernel | ✓ |
| `NextBSD-kernel-extensions-nvidia` | ✓ | — | nextbsd-kernel-extensions-nvidia (NVIDIAGraphics595 + modeset/core kexts, GSP firmware, the NVIDIA595 userland bundle) | kernel-extensions | ✓ |
| `NextBSD-userland` | ✓ | ✓ | nextbsd-userland (Darwin Mach runtime + daemons) | compat, kernel | ✓ |
| `NextBSD-contrib` | ✓ | ✓ | nextbsd-contrib (third-party base programs: sudo, zsh, pico) | compat | ✓ |
| `NextBSD-displayserver-support` | ✓ | ✓ | nextbsd-displayserver-support (in `/usr`: libdrm, pixman, expat, freetype, fontconfig, libxkbcommon, xkeyboard-config, epoll-shim, the IOKit libudev, libevdev, mtdev, libinput, the linux-input shim; the `org.nextbsd.fc-cache` LaunchDaemon) | compat, userland | — |
| `NextBSD-xlibs` | ✓ | ✓ | nextbsd-xlibs (X client libraries in `/usr/X11`, libxkbcommon-x11) | compat, displayserver-support | — |
| `NextBSD-mesa` | ✓ | ✓ | nextbsd-mesa's core artifact, no X (in `/usr/X11`: libglvnd's EGL, GLES, OpenGL and dispatch libraries; Mesa's libgallium, `libEGL_mesa_core`, libgbm, `dri_gbm.so`, DRI drivers; GLU) | compat, displayserver-support | — |
| `NextBSD-mesa-x11` | ✓ | ✓ | nextbsd-mesa's X artifact, `nextbsd-mesa-x11-<arch>` (in `/usr/X11`: Mesa's GLX and x11 EGL vendor, libglvnd's `libGL` and `libGLX`, the GLX headers, `gl.pc`, `glx.pc`) | compat, mesa, xlibs | — |
| `NextBSD-xlibre` | ✓ | ✓ | nextbsd-xlibre (XLibre 25.1.9 server, drivers, tools, libepoxy, libxcvt, libpciaccess in `/usr/X11`; the `org.nextbsd.xlibre` LaunchAgent; an empty `/var/db/xkb`). `vesa` and `vmmouse` are amd64 only | compat, displayserver-support, xlibs, mesa, mesa-x11 | — |
| `NextBSD-gnustep-support` | ✓ | ✓ | nextbsd-gnustep-support (what GNUstep needs: image formats, GnuTLS, cairo in /usr/X11, sound, SQLite, flite, FFmpeg) | compat, displayserver-support, xlibs | — |
| `NextBSD-printing-support` | ✓ | ✓ | nextbsd-printing-support (Apple's CUPS; GnuTLS from gnustep-support) | compat, userland, gnustep-support | — |
| `NextBSD-toolchain` | ✓ | ✓ | nextbsd-toolchain (on-machine clang/lld 19.1.7, gmake, pkgconf, Apple's Git, CMake, GNU m4/autoconf/automake/libtool and their private Perl) | compat, userland | — |
| `pkg` | ✓ | ✓ | nextbsd-contrib's pkg artifact (NextBSD's pkg(8) 2.8.4; version from its `pkg.pc`) | compat | ✓ |
| `NextBSD-everything` (meta) | ✓ | ✓ | — | base, kernel, userland, contrib, kernel-extensions (and -nvidia on amd64) and pkg | |

Each package repackages one of its repo's `continuous` artifacts as is (nextbsd-mesa
publishes two: `NextBSD-mesa` and `NextBSD-mesa-x11`), and every package of
one run shares one snapshot version. The dependencies are the artifacts' ELF `NEEDED`
entries matched to the files the other artifacts ship.

**Optional base packages.** `NextBSD-everything` is the core OS only: base, kernel,
userland, contrib, kernel-extensions and pkg. Everything else NextBSD publishes is an
**optional base package**: built and stamped like the core set, installed into `/usr`
or `/usr/X11` (never `/usr/local`), but only installed when a user or an image asks for
it by name. No meta-package pulls them in (maintainer decision,
[nextbsd#571](https://github.com/nextbsd/nextbsd/issues/571)).

| optional package | installs | pulls in |
|---|---|---|
| `NextBSD-xlibre` | the X server | displayserver-support, xlibs, mesa, mesa-x11 |
| `NextBSD-mesa` | OpenGL, EGL and GBM, without X | displayserver-support |
| `NextBSD-mesa-x11` | Mesa's X parts: GLX, `libGL`, the X11 EGL vendor | mesa, xlibs |
| `NextBSD-xlibs` | X client libraries | displayserver-support |
| `NextBSD-displayserver-support` | libraries shared by display servers | — |
| `NextBSD-gnustep-support` | libraries GNUstep needs | displayserver-support, xlibs |
| `NextBSD-printing-support` | Apple's CUPS | gnustep-support |
| `NextBSD-toolchain` | the on-machine compiler and build tools | — |

**Kernel and kexts must match.** Every kext records the kernel build it was compiled for
(`NBSDKernelBuildID` in its Info.plist, nextbsd-kernel#326), and the kernel artifact carries its
own `KERNEL-BUILD-ID`. If any kext differs, the whole run fails before anything is packaged:
a mismatched pair boots and then panics in an unrelated driver. Rebuild the kexts against the
current kernel (nextbsd-kernel-extensions, then nextbsd-kernel-extensions-nvidia) and rerun.

The NVIDIA userland bundle in `NextBSD-kernel-extensions-nvidia` links libX11, libXext, libdrm
and libgbm. Its package lists them as `shlibs_required_ignore`, so pkg doesn't pull X or
Mesa into `NextBSD-everything` through them. The bundle's links go into `/usr/X11`
(`/usr/share/egl/egl_external_platform.d` for NVIDIA's EGL platform files) and ship in the
package, so they work whenever `NextBSD-mesa` or `NextBSD-xlibre` is installed later.
nextbsd-gershwin-support is deliberately **not** packaged (maintainer, 2026-10-25), and
no package depends on it.

**`/etc` belongs to nextbsd-overlays, not these packages** (decision on
[#25](https://github.com/nextbsd/nextbsd-pkg/issues/25)): `/etc/fonts`, `/etc/xkb`,
`/etc/libinput`, CUPS's config, PAM stack and accounts, the `/usr/X11/lib` entry in
`/etc/ld-elf.so.conf` and `/usr/X11/bin` in `PATH`. No package ships `/usr/local` or an
ldconfig drop-in, and nothing runs `ldconfig` after install: rtld's default path already
covers `/usr/lib` and `/usr/X11/lib`. The `.pc` files stay in `/usr/libdata/pkgconfig`
and `/usr/X11/lib/pkgconfig`; there is no system-wide `PKG_CONFIG_PATH`.

### pkg

`pkg` is NextBSD's own pkg(8). Its source is in nextbsd-contrib, under
[`src/pkg`](https://github.com/nextbsd/nextbsd-contrib/tree/main/src/pkg): a frozen copy
of upstream pkg 2.8.4 with the NextBSD patches described in its `NEXTBSD.md`. Design:
[pkg comes only from the NextBSD repo](https://github.com/nextbsd/nextbsd-pkg/wiki/NextBSD-pkg-only-from-NextBSD).

- pkg is never installed or upgraded from a repository other than `NextBSD`, and from a
  package file only if the file carries the `org.nextbsd.origin: NextBSD` stamp.
- A package not from the NextBSD repo, or a package file without the stamp, may only
  install under `/usr/local` and `/var`.
- Everything is under `/usr` (`/usr/sbin/pkg`, `pkg-static`, `libpkg.so.4`). The package
  ships **no configuration**: `/private/etc/pkg.conf` and `/private/etc/pkg/NextBSD.conf`
  come from nextbsd-overlays.
- Its version is pkg's own (`2.8.4`), not the snapshot version, so it compares correctly
  with any other repository's pkg. A rebuild at the same pkg version doesn't upgrade
  installed systems.

The compat base no longer ships FreeBSD's `/usr/sbin/pkg` bootstrap shim, its `pkg.7`
page or its key (nextbsd-freebsd-compat#62), so `pkg` owns `/usr/sbin/pkg` alone.

### Base provides the X stack

[E23](https://github.com/nextbsd/nextbsd-userland/wiki/E23-Display-Server-Graphics-Stack-Plan)
D14, [#26](https://github.com/nextbsd/nextbsd-pkg/issues/26). NextBSD has one X stack, in
base. `pkg create` records the `SONAME` of every library a package ships as its
`shlibs_provided`: pkg's `SHLIB_PROVIDE_PATHS_*` settings are unset on the build VM, so
`/usr/lib` and `/usr/X11/lib` are not filtered out. pkg only reads ELF files built for
its own ABI, so `build.sh` runs `pkg create` with the target ABI pinned; otherwise the
arm64 packages, which are built on the amd64 VM, would declare no libraries at all. The
build log prints each display package's list. For example:

| package | provides (among others) |
|---|---|
| `NextBSD-displayserver-support` | `libdrm.so.2` (and `libdrm_amdgpu.so.1`, `libdrm_radeon.so.1` on amd64), `libpixman-1.so.0`, `libexpat.so.1`, `libfreetype.so.6`, `libfontconfig.so.1`, `libxkbcommon.so.0`, `libinput.so.10`, `libevdev.so.2`, `libmtdev.so.1`, `libudev.so.0`, `libepoll-shim.so.0` |
| `NextBSD-xlibs` | `libX11.so.6`, `libxcb.so.1` and the other `libxcb-*`, `libXext.so.6`, `libXrender.so.1`, `libXft.so.2`, `libXfont2.so.2`, `libxkbcommon-x11.so.0`, `libxshmfence.so.1` |
| `NextBSD-mesa` | `libEGL.so.1`, `libGLESv2.so.2`, `libOpenGL.so.0`, `libGLdispatch.so.0`, `libgbm.so.1`, `libGLU.so.1` |
| `NextBSD-mesa-x11` | `libGL.so.1`, `libGLX.so.0`, `libGLX_mesa.so.0`, `libEGL_mesa.so.0` |
| `NextBSD-xlibre` | `libepoxy.so.0`, `libxcvt.so.0`, `libpciaccess.so.0` |

So once these packages are installed, pkg counts a FreeBSD package's
`shlibs_required` on those libraries as satisfied by NextBSD, and at run time rtld finds
`/usr/lib` and `/usr/X11/lib` before `/usr/local/lib`.

**What this can't satisfy:** pkg resolves a package's `deps` by package **name**
(`pkg_jobs_universe_process_deps`), never through `shlibs_provided` or `provides`.
A FreeBSD package that depends on `libX11`, `libxcb`, `mesa-libs`, `libdrm`, `freetype2`,
`fontconfig`, `expat` or `libinput` (most X programs do, because the ports framework
records library dependencies by name) still installs FreeBSD's copy into `/usr/local`, and
`mesa-libs` still brings `llvm19`. NextBSD's Mesa links LLVM statically and ships no
`libLLVM`, so nothing in base stands in for `llvm19`. Those `/usr/local` libraries
aren't used by programs whose search path ends at rtld's default, but a FreeBSD program
built with an `RPATH` of `/usr/local/lib` loads them, and then one process can hold two
copies of libX11 or freetype. NextBSD accepts this gap (maintainer decision, 2026-10-25). Images ship only the NextBSD
repo, and a user who adds a FreeBSD repo is responsible for what they install from it.
Base is protected another way: NextBSD's pkg (nextbsd-contrib) lets a package that isn't
NextBSD's install only under `/usr/local` and `/var`, so a FreeBSD package can add a
second copy there but can't overwrite or remove base. The `NextBSD-*` packages are vital
(below), so a conflict with another repo's package can't remove them, and pkg itself
comes only from the NextBSD repo. NextBSD will never ship placeholder packages under
FreeBSD's names (such as an empty `libX11`) to redirect those dependencies.

### Vital packages and the NextBSD stamp

Every `NextBSD-*` package, `NextBSD-everything` and `pkg` included, has two marks in its manifest:

- **`vital: true`.** pkg refuses to delete a vital package: `pkg delete` without `-f`,
  `pkg autoremove`, and removing it to resolve a conflict with another repo's package all
  fail. Upgrades still replace it as usual.
- **Annotation `org.nextbsd.origin: NextBSD`.** NextBSD's pkg lets a local package file
  without this stamp install only under `/usr/local` and `/var`, and lets only a stamped
  `pkg` replace pkg.

The build log lists both marks for every package.

**Retiring a vital package:** publish one last version of it without `vital` (in
`build.sh`, leave `NBMARK`'s `vital: true` out of that package's manifest). pkg updates
the flag as part of the upgrade, because a change to `vital` counts as a reason to
upgrade. After that the package can be deleted or autoremoved, and only then is it
dropped from the repo. On one machine, `pkg set -v 0 <name>` clears the flag by hand.
`pkg delete -f` overrides it, but leaves whatever depended on the package broken.

### Upgrades and moved files

pkg owns each package's file list. `pkg upgrade` deletes every file the old version of a
package listed and the new one doesn't (`pkg_add_cleanup_old`), so when a library moves
from one NextBSD package to another, the upgrade removes the old copy. E25 moved libdrm,
pixman, expat, freetype, fontconfig, libxkbcommon, xkeyboard-config and the input stack
from the xlibs and xlibre artifacts into `NextBSD-displayserver-support` before
`NextBSD-xlibs` and `NextBSD-xlibre` were first packaged here, so no published package
version ever owned the old `/usr/X11` copies. Neither image build (nextbsd `build.sh`,
Gershwin's `targets/nextbsd`) unpacks the xlibs or xlibre artifacts outside pkg; both
take X from FreeBSD packages in `/usr/local` today. A system where someone unpacked an
old artifact by hand has unowned `/usr/X11` copies that pkg never removes: delete
`/usr/X11` before installing these packages.

## Status

**Working** (unsigned). `pkg install NextBSD-everything` resolves the full set from the
flat repo on both arches. Package signing and the pkg-in-VM ISO assembler refactor
are the remaining pre-production steps; the full design (further splits, dep pins,
versioning) is in [`docs/PLAN.json`](docs/PLAN.json).
