# nextbsd-pkg

Assembles versioned **pkg(8)** packages for NextBSD from the component repos'
`continuous` build artifacts and publishes a **flat pkg repository** to per-arch
GitHub Release tags (`continuous-amd64` / `continuous-arm64`).

## How it works

```
nextbsd-freebsd-compat ────┐
nextbsd-kernel ────────────┤  continuous artifacts
nextbsd-kernel-extensions ─┤  (raw .tar.gz, per arch)
nextbsd-userland ──────────┤
nextbsd-contrib ───────────┤
nextbsd-displayserver-support ─┤
nextbsd-xlibs ─────────────┤
nextbsd-mesa ──────────────┤
nextbsd-xlibre ────────────┤
nextbsd-gnustep-support ───┤
nextbsd-printing-support ──┤
nextbsd-gershwin-support ──┤
nextbsd-toolchain ─────────┘
               │  repository_dispatch: userland-updated / contrib-updated
               ▼
           nextbsd-pkg  ──(pkg create / pkg repo, inside a FreeBSD VM)──▶  flat repo
               │
               ▼  GitHub Release assets:  continuous-amd64 / continuous-arm64
           users:  pkg update && pkg upgrade     ISO builder:  pkg install NextBSD-everything
```

- **pkg runs in a FreeBSD VM** (vmactions) — the Linux runner only downloads the
  (public) artifacts and uploads the Release assets.
- **Triggered by `userland-updated` and `contrib-updated`**, plus
  `workflow_dispatch` as a manual escape hatch for kernel/kext-only repackages.
  PRs build but never publish.
- **Flat repo on Release assets** (asset names can't contain `/`), one tag per arch.

## Consuming the repo

Drop a `NextBSD.conf` matching your architecture into `/usr/local/etc/pkg/repos/`:

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
pkg install NextBSD-everything      # base + kernel + userland + contrib + kernel-extensions
pkg upgrade                    # rolling: picks up each new snapshot
```

## Packages

| package | amd64 | arm64 | from | depends on | in `NextBSD-everything` |
|---|:--:|:--:|---|---|:--:|
| `NextBSD-freebsd-compat` | ✓ | ✓ | nextbsd-freebsd-compat (base: libc, PAM, commands) | — | ✓ |
| `NextBSD-kernel` | ✓ | ✓ | nextbsd-kernel (kernel binary) | — | ✓ |
| `NextBSD-kernel-extensions` | ✓ | ✓ | nextbsd-kernel-extensions (kexts; 17 on amd64, the 7-kext virtio-gpu stack on arm64) | kernel | ✓ |
| `NextBSD-userland` | ✓ | ✓ | nextbsd-userland (Darwin Mach runtime + daemons) | compat, kernel | ✓ |
| `NextBSD-contrib` | ✓ | ✓ | nextbsd-contrib (third-party base programs: sudo, zsh, pico) | compat | ✓ |
| `NextBSD-displayserver-support` | ✓ | ✓ | nextbsd-displayserver-support (in `/usr`: libdrm, pixman, expat, freetype, fontconfig, libxkbcommon, xkeyboard-config, epoll-shim, the IOKit libudev, libevdev, mtdev, libinput, the linux-input shim; the `org.nextbsd.fc-cache` LaunchDaemon) | compat, userland | — |
| `NextBSD-xlibs` | ✓ | ✓ | nextbsd-xlibs (X client libraries in `/usr/X11`, libxkbcommon-x11) | compat, displayserver-support | — |
| `NextBSD-mesa` | ✓ | ✓ | nextbsd-mesa (libglvnd, Mesa, GLU in `/usr/X11`) | compat, displayserver-support, xlibs | — |
| `NextBSD-xlibre` | ✓ | ✓ | nextbsd-xlibre (XLibre 25.1.9 server, drivers, tools, libepoxy, libxcvt, libpciaccess in `/usr/X11`; the `org.nextbsd.xlibre` LaunchAgent; an empty `/var/db/xkb`). `vesa` and `vmmouse` are amd64 only | compat, displayserver-support, xlibs, mesa | — |
| `NextBSD-gnustep-support` | ✓ | ✓ | nextbsd-gnustep-support (what GNUstep needs: image formats, GnuTLS, cairo in /usr/X11, sound, SQLite, flite, FFmpeg) | compat, displayserver-support, xlibs | — |
| `NextBSD-printing-support` | ✓ | ✓ | nextbsd-printing-support (Apple's CUPS; GnuTLS from gnustep-support) | compat, userland, gnustep-support | — |
| `NextBSD-gershwin-support` | ✓ | ✓ | nextbsd-gershwin-support (what only Gershwin uses: wget, xdotool in /usr/X11, lcms2, squashfs tools) | compat, displayserver-support, xlibs | — |
| `NextBSD-toolchain` | ✓ | ✓ | nextbsd-toolchain (on-machine clang/lld 19.1.7, gmake, pkgconf, Apple's Git) | compat, userland | — |
| `NextBSD-everything` (meta) | ✓ | ✓ | — | base, kernel, userland, contrib and kernel-extensions | |

Each package repackages its repo's `continuous` artifact as is, and every package of
one run shares one snapshot version. The dependencies are the artifacts' ELF `NEEDED`
entries matched to the files the other artifacts ship.

**Not in `NextBSD-everything`:**
- The display server stack (`displayserver-support`, `xlibs`, `mesa`, `xlibre`):
  whether `NextBSD-everything` includes X is still open
  ([nextbsd#571](https://github.com/nextbsd/nextbsd/issues/571),
  [E23](https://github.com/nextbsd/nextbsd-userland/wiki/E23-Display-Server-Graphics-Stack-Plan)
  D13, step 16). Images install them by name. `NextBSD-xlibre` pulls in the rest.
- The [E24](https://github.com/nextbsd/nextbsd-userland/wiki/E24-GNUstep-Gershwin-Requirements-Direction)
  packages: Gershwin builds GNUstep itself (D10) and installs these requirements through
  its `nextbsd.txt`, and `NextBSD-toolchain` is installed by default on Gershwin images
  only (D11).

**`/etc` belongs to nextbsd-overlays, not these packages** (decision on
[#25](https://github.com/nextbsd/nextbsd-pkg/issues/25)): `/etc/fonts`, `/etc/xkb`,
`/etc/libinput`, CUPS's config, PAM stack and accounts, the `/usr/X11/lib` entry in
`/etc/ld-elf.so.conf` and `/usr/X11/bin` in `PATH`. No package ships `/usr/local` or an
ldconfig drop-in, and nothing runs `ldconfig` after install: rtld's default path already
covers `/usr/lib` and `/usr/X11/lib`. The `.pc` files stay in `/usr/libdata/pkgconfig`
and `/usr/X11/lib/pkgconfig`; there is no system-wide `PKG_CONFIG_PATH`.

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
| `NextBSD-mesa` | `libGL.so.1`, `libEGL.so.1`, `libGLESv2.so.2`, `libOpenGL.so.0`, `libGLX.so.0`, `libGLdispatch.so.0`, `libgbm.so.1`, `libGLU.so.1` |
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
copies of libX11 or freetype. NextBSD doesn't block FreeBSD repos over this. It protects base instead (maintainer
decision, 2026-10-25): NextBSD's pkg (nextbsd-contrib) lets a package that isn't
NextBSD's install only under `/usr/local` and `/var`, so a FreeBSD package can add a
second copy there but can't overwrite or remove base. The `NextBSD-*` packages are also
vital (below), so resolving a conflict with another repo's package can't remove them.
Packages in the NextBSD repo under FreeBSD's names (for example an empty `libX11` that
depends on `NextBSD-xlibs`, so the dependency resolves here first) would close the
duplicate-library gap. They are deferred and not built here.

### Vital packages and the NextBSD stamp

Every `NextBSD-*` package, `NextBSD-everything` included, has two marks in its manifest:

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
