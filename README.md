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

| package | amd64 | arm64 | from |
|---|:--:|:--:|---|
| `NextBSD-freebsd-compat` | ✓ | ✓ | nextbsd-freebsd-compat (base: libc, PAM, commands) |
| `NextBSD-kernel` | ✓ | ✓ | nextbsd-kernel (kernel binary) |
| `NextBSD-kernel-extensions` | ✓ | ✓ | nextbsd-kernel-extensions (kexts; 17 on amd64, the 7-kext virtio-gpu stack on arm64) |
| `NextBSD-userland` | ✓ | ✓ | nextbsd-userland (Darwin Mach runtime + daemons) |
| `NextBSD-contrib` | ✓ | ✓ | nextbsd-contrib (third-party base programs: sudo, zsh, pico) |
| `NextBSD-gnustep-support` | ✓ | ✓ | nextbsd-gnustep-support (what GNUstep needs: image formats, GnuTLS, cairo in /usr/X11, sound, SQLite, flite, FFmpeg) |
| `NextBSD-printing-support` | ✓ | ✓ | nextbsd-printing-support (Apple's CUPS; GnuTLS from gnustep-support) |
| `NextBSD-gershwin-support` | ✓ | ✓ | nextbsd-gershwin-support (what only Gershwin uses: wget, xdotool in /usr/X11, lcms2, squashfs tools) |
| `NextBSD-toolchain` | ✓ | ✓ | nextbsd-toolchain (on-machine clang/lld 19.1.7, gmake, pkgconf, Apple's Git) |
| `NextBSD-everything` (meta) | ✓ | ✓ | depends on base, kernel, userland, contrib and kernel-extensions |

The last four are **not** in `NextBSD-everything` ([E24](https://github.com/nextbsd/nextbsd-userland/wiki/E24-GNUstep-Gershwin-Requirements-Direction)):
Gershwin builds GNUstep itself (D10) and installs these requirements through its
`nextbsd.txt`, and `NextBSD-toolchain` is installed by default on Gershwin images
only (D11). Their `/etc` (CUPS's config, PAM stack and accounts) comes from
nextbsd-overlays, not the packages. `NextBSD-gnustep-support` and
`NextBSD-gershwin-support` link the X libraries in `/usr/X11`; they gain a
`NextBSD-xlibs` dependency automatically once that package exists (#25).

## Status

**Working** (unsigned). `pkg install NextBSD-everything` resolves the full set from the
flat repo on both arches. Package signing and the pkg-in-VM ISO assembler refactor
are the remaining pre-production steps; the full design (further splits, dep pins,
versioning) is in [`docs/PLAN.json`](docs/PLAN.json).
