# nextbsd-pkg

Assembles versioned **pkg(8)** packages for NextBSD from the component repos'
`continuous` build artifacts and publishes a **flat pkg repository** to per-arch
GitHub Release tags (`continuous-amd64` / `continuous-arm64`).

## How it works

```
nextbsd-freebsd-compat ────┐
nextbsd-kernel ────────────┤  continuous artifacts
nextbsd-kernel-extensions ─┤  (raw .tar.gz, per arch)
nextbsd-kernel-extensions-graphics ─┤
nextbsd-kernel-extensions-nvidia ─┤  (amd64)
nextbsd-userland ──────────┤
nextbsd-contrib ───────────┤
nextbsd-displayserver-support ─┤
nextbsd-xlibs ─────────────┤
nextbsd-mesa (+ mesa-x11) ─┤
nextbsd-xlibre ────────────┤
nextbsd-gnustep-support ───┤
nextbsd-printing-support ──┤
nextbsd-toolchain ─────────┤
nextbsd-gnustep ───────────┤  (the GNUstep core)
nextbsd-desktop ───────────┘  (the desktop; optional until it publishes)
               │  repository_dispatch: userland-updated / contrib-updated
               ▼
           nextbsd-pkg  ──(pkg create / pkg repo, inside a FreeBSD VM)──▶  flat repo (NextBSD:27:<arch>)
               │
               ▼  GitHub Release assets:  continuous-amd64 / continuous-arm64
           users:  pkg update && pkg upgrade     ISO builder:  pkg install NextBSD-server (or NextBSD-desktop)
```

- **Packaging runs in a VM** (vmactions); the Linux runner only downloads the
  (public) artifacts and uploads the Release assets. The VM image stays FreeBSD 15.1
  until NextBSD has its own CI guest ([E26](https://github.com/nextbsd/nextbsd/issues/587)).
  `pkg create`, `pkg repo` and `install-test.sh` use **NextBSD's own pkg** (`pkg-static`
  from the nextbsd-contrib artifact, the same build the `pkg` package ships), with an
  explicit empty config (`-C`) and repo directory (`-R`), not the VM's own pkg.
- **ABI `NextBSD:27:<arch>`** (`NextBSD:27:amd64`, `NextBSD:27:aarch64`;
  [nextbsd-kernel#376](https://github.com/nextbsd/nextbsd-kernel/issues/376)). Every
  package and the repo catalogue carry it, with osversion 2700000 (the package's
  `FreeBSD_version` annotation, pkg's name for it). `build.sh` passes `ABI` and
  `OSVERSION` to `pkg create`, which stamps both; only NextBSD's pkg knows this ABI
  (nextbsd-contrib `src/pkg`, patch 0005), and on NextBSD 27 it computes the same
  ABI by itself.
- **Install test.** `install-test.sh` installs `NextBSD-server` into a scratch root
  from a repo named `NextBSD`, then, in a second root, checks
  that `pkg install NextBSD-mesa` brings neither `NextBSD-xlibs`, `NextBSD-mesa-x11` nor
  `NextBSD-xlibre`, that `pkg install NextBSD-xlibre` brings `NextBSD-mesa`,
  `NextBSD-mesa-x11` and `NextBSD-xlibs`, and that `NextBSD-gnustep` installs on top.
  In a third root the transitional `NextBSD-everything` must install `NextBSD-server`
  (and `NextBSD-desktop`, when it was built, the desktop); in a fourth, `NextBSD-everything`
  from the published repo must `pkg upgrade` to this run's packages without losing any
  (see [NextBSD-everything becomes NextBSD-server](#nextbsd-everything-becomes-nextbsd-server)).
- **Version `27.0.0.<build>`** on every NextBSD package
  ([nextbsd#536](https://github.com/nextbsd/nextbsd/issues/536)): `27.0.0` is the
  kernel's `KERNEL-VERSION` asset (`kern.osrelease`, so it matches `uname -r`), and
  `<build>` is the workflow's `run_number`. The build time is the
  `org.nextbsd.build_date` annotation. pkg compares versions numerically, component
  by component (libpkg `pkg_version_cmp`), so `27.0.0.<build>` is newer than the
  `0.0.0.<timestamp>` versions published before it, and `pkg upgrade` moves to it.
  Rerunning a publish run keeps its `run_number`, so it republishes the same version
  and installed systems don't upgrade to it; start a new run instead.
- **`SystemVersion.plist`.** `NextBSD-server` owns
  `/System/Library/CoreServices/SystemVersion.plist`, with Darwin's keys:
  `ProductName` `NextBSD`, `ProductVersion` and `ProductUserVisibleVersion`
  `27.0.0`, `ProductBuildVersion` `<build>`, and NextBSD's `NBSDBuildDate`.
  `sw_vers(1)`, `nextbsd-version` and the login banner read it, so they show the
  version `pkg info NextBSD-server` does. A Lua post-install script in
  `NextBSD-server` rewrites `/etc/os-release` (`NAME`, `VERSION`, `VERSION_ID`,
  `BUILD_ID`, `PRETTY_NAME`) from the plist on every install and upgrade.
- **Publishing is manual** (`workflow_dispatch`). Pull requests build and install-test
  but never publish.
- **Flat repo on Release assets** (asset names can't contain `/`), one tag per arch.

## Consuming the repo

On NextBSD the repository is already configured. NextBSD's pkg reads
`/private/etc/pkg.conf` and `/private/etc/pkg/`, and `/private/etc/pkg/NextBSD.conf`
(from nextbsd-overlays, not from any package) points at
`.../releases/download/continuous-${MACHINE}` and gives the NextBSD repo a higher
`priority` (100) than any other. `CONSERVATIVE_UPGRADE` stays on (pkg's default). NextBSD
ships and configures no other repository; repositories a user adds go in
`/usr/local/etc/pkg/repos/`.

**FreeBSD packages are not supported.** A user who wants them anyway adds their own
FreeBSD repository file there, with `enabled: no`, and names it on each command with the
FreeBSD ABI, for example
`env ABI=FreeBSD:15:amd64 OSVERSION=1501000 IGNORE_OSVERSION=yes pkg install -r FreeBSD <name>`.
NextBSD's pkg lets such packages install only under `/usr/local` and `/var`. The wiki's
Installing Packages page has the full steps.

Elsewhere (building an image on another host), use NextBSD's pkg (nextbsd-contrib's
`pkg-static`) with `ABI=NextBSD:27:<arch>` and `OSVERSION=2700000` in the environment,
and a repo file for the architecture:

```
# amd64
NextBSD: { url: "https://github.com/nextbsd/nextbsd-pkg/releases/download/continuous-amd64", enabled: yes }
```

```
# arm64
NextBSD: { url: "https://github.com/nextbsd/nextbsd-pkg/releases/download/continuous-arm64", enabled: yes }
```

Then install the whole OS via a meta-package (and upgrade as CI republishes):

```sh
pkg update
pkg install NextBSD-server     # base + bootloader + kernel + userland + contrib + kernel-extensions (+ -graphics, + NVIDIA on amd64) + pkg
pkg install NextBSD-desktop    # or: NextBSD-server + GNUstep + the desktop
pkg upgrade                    # rolling: picks up each new snapshot
```

## Packages

| package | amd64 | arm64 | from | depends on | in `NextBSD-server` |
|---|:--:|:--:|---|---|:--:|
| `NextBSD-freebsd-compat` | ✓ | ✓ | nextbsd-freebsd-compat (base: libc, PAM, commands) | — | ✓ |
| `NextBSD-bootloader` | ✓ | ✓ | nextbsd-freebsd-compat's base artifact, its `/boot` (loader, `loader.efi`, Lua, `defaults/loader.conf`, images, fonts; boot blocks on amd64) | — | ✓ |
| `NextBSD-bootloader-gershwin` | ✓ | ✓ | written by `build.sh`: only `/boot/loader.conf.d/bootsplash.conf`, `bootsplash_style="grey"` (the Gershwin grey boot splash; without it the splash is black). The only file that may set `bootsplash_style` | bootloader | — |
| `NextBSD-kernel` | ✓ | ✓ | nextbsd-kernel (kernel binary; on arm64 also the Raspberry Pi 5 kernel, `/boot/kernel.RPI5/kernel`) | — | ✓ |
| `NextBSD-kernel-extensions` | ✓ | ✓ | nextbsd-kernel-extensions (kexts built from FreeBSD's driver sources, 90 on amd64 and 101 on arm64: NICs such as IntelEM and RealtekRE, Wi-Fi (the Wlan family, IntelIwlwifi with its firmware on amd64), USB and HID drivers, storage controllers, the Bluetooth stack and AutoFS; each loads when its hardware appears or when its software asks) | kernel | ✓ |
| `NextBSD-kernel-extensions-graphics` | ✓ | ✓ | nextbsd-kernel-extensions-graphics (drm graphics kexts per arch) | kernel | ✓ |
| `NextBSD-kernel-extensions-nvidia` | ✓ | — | nextbsd-kernel-extensions-nvidia (NVIDIAGraphics595 + modeset/core kexts, GSP firmware, the NVIDIA595 userland bundle) | kernel-extensions-graphics | ✓ |
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
| `NextBSD-gnustep` | ✓ | ✓ | nextbsd-gnustep's build, `nextbsd-gnustep-<arch>` (the GNUstep core from NextBSD's forks: tools-make, libobjc2, libs-base, libs-corebase, libs-gui, libs-back, libs-av; all in `/System/Library`: Libraries, Headers, Frameworks, Makefiles, Tools, Bundles, `Preferences/GNUstep.conf`). Not its SDK artifact | compat, userland, displayserver-support, xlibs, gnustep-support, printing-support, mesa-x11 | — |
| `NextBSD-desktop-apps` | ✓ | ✓ | nextbsd-desktop's build, `nextbsd-desktop-<arch>` (WindowServer, loginwindow, Workspace, the Dock in `/System/Library/CoreServices`; Terminal, the settings apps, Software, Update, Installer, XLibre in `/System/Applications`; InnerSpace, the theme, the GNUstep `GlobalDefaults`; libWindowServerClient and the WindowServer tools in `/usr`), minus its `/etc`; plus loginwindow's LaunchDaemon in `/System/Library/LaunchDaemons`. Post-install: `/etc/pam.d/loginwindow` if missing, and the graphical login enabled at boot ([below](#the-desktop-package)). **Built only once nextbsd-desktop publishes** | compat, userland, displayserver-support, xlibs, mesa, mesa-x11, xlibre, gnustep-support, printing-support, gnustep | — |
| `pkg` | ✓ | ✓ | nextbsd-contrib's pkg artifact (NextBSD's pkg(8) 2.8.4; version from its `pkg.pc`) | compat | ✓ |
| `NextBSD-server` (meta) | ✓ | ✓ | `SystemVersion.plist`, written by `build.sh`; the os-release post-install script | base, bootloader, kernel, userland, contrib, kernel-extensions-graphics, kernel-extensions (and -nvidia on amd64) and pkg | |
| `NextBSD-everything` (transitional) | ✓ | ✓ | nothing: an empty package, not vital ([below](#nextbsd-everything-becomes-nextbsd-server)) | server | |
| `NextBSD-desktop` (meta) | ✓ | ✓ | nothing. **Built only once nextbsd-desktop publishes** | server, gnustep, desktop-apps, toolchain | |

Each package repackages one of its repo's `continuous` artifacts as is (nextbsd-mesa
publishes two: `NextBSD-mesa` and `NextBSD-mesa-x11`), and every package of
one run shares one snapshot version. The dependencies are the artifacts' ELF `NEEDED`
entries matched to the files the other artifacts ship.

**Optional base packages.** `NextBSD-server` is the core OS only: base, bootloader, kernel,
userland, contrib, the kernel extensions and pkg. Everything else NextBSD publishes is an
**optional base package**: built and stamped like the core set, installed into `/usr`
or `/usr/X11` (never `/usr/local`), but only installed when a user or an image asks for
it by name, or through `NextBSD-desktop`, which brings `NextBSD-gnustep`, the desktop,
`NextBSD-toolchain` (Software.app builds apps with its git, gmake and clang) and
what they link (maintainer decision,
[nextbsd#571](https://github.com/nextbsd/nextbsd/issues/571); E47,
[nextbsd#671](https://github.com/nextbsd/nextbsd/issues/671)).

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
| `NextBSD-gnustep` | the GNUstep core, in `/System/Library` | gnustep-support, printing-support, mesa-x11 (and what they need) |

**Kernel and kexts must match.** Kexts are tied to the kernel ABI version (`27.0`), not to one
exact kernel build (nextbsd-kernel#376). The kernel artifact's `KERNEL-BUILD-ID` holds that ABI
version, and every kext records it in its Info.plist as `NBSDKernelABIVersion` and as the legacy
`NBSDKernelBuildID`, which this check compares. If any kext differs, the whole run fails before
anything is packaged: a mismatched pair boots and then panics in an unrelated driver. The ABI
version is bumped by hand (27.1.0, ...) when a kernel change needs kexts rebuilt. Rebuild the kexts against the
current kernel (nextbsd-kernel-extensions and nextbsd-kernel-extensions-graphics, then nextbsd-kernel-extensions-nvidia) and rerun.

The NVIDIA userland bundle in `NextBSD-kernel-extensions-nvidia` links libX11, libXext, libdrm
and libgbm. Its package lists them as `shlibs_required_ignore`, so pkg doesn't pull X or
Mesa into `NextBSD-server` through them. The bundle's links go into `/usr/X11`
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
its own ABI (for the NextBSD ABI, ELF files with the base's FreeBSD ABI note), so
`build.sh` runs `pkg create` with the target ABI pinned; otherwise the
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

Every `NextBSD-*` package, `NextBSD-server`, `NextBSD-desktop` and `pkg` included, has two marks
in its manifest (the transitional `NextBSD-everything` has only the stamp; it is not vital):

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

### NextBSD-everything becomes NextBSD-server

[nextbsd#680](https://github.com/nextbsd/nextbsd/issues/680). `NextBSD-server` is what
`NextBSD-everything` was: the same dependencies, `SystemVersion.plist` and the os-release
post-install script. The Server Preview images install it; the Desktop Preview images
install `NextBSD-desktop`, which requires it.

Machines installed before have `NextBSD-everything`. For a transition period it stays in
the repo as an **empty package** (comment "NextBSD (transitional)") that depends only on
`NextBSD-server` at the same snapshot version. On such a machine `pkg upgrade`:

- upgrades `NextBSD-everything` to the empty version and installs `NextBSD-server` (as a
  new dependency, so pkg marks it automatic) in one transaction, along with the usual
  upgrades of everything else;
- removes no package: everything the old `NextBSD-everything` depended on, `NextBSD-server`
  depends on;
- moves `SystemVersion.plist` from `NextBSD-everything` to `NextBSD-server`. pkg sees the
  new `NextBSD-server` conflict with the installed `NextBSD-everything` on that file and
  splits the upgrade: it deinstalls the old `NextBSD-everything` first (which owns nothing
  else), installs `NextBSD-server`, whose post-install script rewrites `/etc/os-release`,
  and installs the empty `NextBSD-everything` last. So the old package's cleanup never
  deletes the new copy.

`install-test.sh` checks this on every run, upgrading from the published repo.
`NextBSD-everything` is not vital, so `pkg delete NextBSD-everything` works and leaves the
system alone. pkg records `NextBSD-server` as automatic on an upgraded machine, but it and
everything under it are vital, so `pkg autoremove` leaves them. Once machines
have moved, `NextBSD-everything` is dropped from `build.sh`; `pkg set -A 0 NextBSD-server`
then clears the automatic flag on a machine that came through it.

### The desktop package

[nextbsd#676](https://github.com/nextbsd/nextbsd/issues/676). `NextBSD-desktop-apps` repackages
nextbsd-desktop's build, with three additions so that `pkg install NextBSD-desktop` and a
reboot come up in the graphical login:

- **Dependencies** are the build's ELF `NEEDED` entries, including `NextBSD-xlibre` for
  `libepoxy.so.0` (XLibre.app's Xnextbsd), which no other package provides.
- **`/etc/pam.d/loginwindow`.** `/etc` belongs to nextbsd-overlays, so no package owns the
  file. Its one source is nextbsd-overlays' `rootfs/private/etc/pam.d/loginwindow`, which new
  images get; the workflow downloads it and `build.sh` embeds its text in the package's Lua
  post-install script, which writes the file only where it is missing (seed.sh's rule). An
  existing file is never replaced, and `pkg delete` leaves it.
- **Booting into the desktop**, as pkgdemon/nextbsd-gnustep's `enable-loginwindow.sh` does it.
  loginwindow's LaunchDaemon plist ships inside loginwindow.app; `build.sh` also puts it into
  `/System/Library/LaunchDaemons` as a package file (its presence is what makes getty leave
  ttyv0 to the graphical login, and pkg removes it on `pkg delete`). WindowServer's
  LaunchDaemon ships `Disabled`. On a first install (not an upgrade) the post-install script
  enables `org.nextbsd.WindowServer` and `org.nextbsd.loginwindow` in launchd's overrides
  database, `/var/db/launchd.db/com.apple.launchd/overrides.plist`, which is what
  `launchctl load -w` records; the pre-deinstall script takes the entries out again on a real
  removal. Neither runs launchctl (starting the WindowServer would take the console from the
  terminal pkg runs in), so the change takes effect at the next boot. An admin who turns the
  graphical login off (`launchctl unload -w` on both plists, as `disable-loginwindow.sh` does)
  keeps it off across upgrades.
- **Configuration:** `/System/Library/Preferences/org.nextbsd.WindowServer.plist` (the
  WindowServer's system-wide settings) is an `@config` file, so an upgrade keeps an admin's
  change. The GNUstep defaults in `/System/Library/Preferences/GlobalDefaults` (`GSTheme`
  NextBSD, ...) are plain files: libs-base reads them below each user's own defaults.

### Upgrades and moved files

pkg owns each package's file list. `pkg upgrade` deletes every file the old version of a
package listed and the new one doesn't (`pkg_add_cleanup_old`), so when a library moves
from one NextBSD package to another, the upgrade removes the old copy. E25 moved libdrm,
pixman, expat, freetype, fontconfig, libxkbcommon, xkeyboard-config and the input stack
from the xlibs and xlibre artifacts into `NextBSD-displayserver-support` before
`NextBSD-xlibs` and `NextBSD-xlibre` were first packaged here, so no published package
version ever owned the old `/usr/X11` copies. Neither image build (nextbsd `build.sh`,
Gershwin's `targets/nextbsd`) unpacks the xlibs or xlibre artifacts outside pkg. A
system where someone unpacked an
old artifact by hand has unowned `/usr/X11` copies that pkg never removes: delete
`/usr/X11` before installing these packages.

## Status

**Working** (unsigned). `pkg install NextBSD-server` resolves the full set from the
flat repo on both arches. Package signing and the pkg-in-VM ISO assembler refactor
are the remaining pre-production steps; the full design (further splits, dep pins,
versioning) is in [`docs/PLAN.json`](docs/PLAN.json).
