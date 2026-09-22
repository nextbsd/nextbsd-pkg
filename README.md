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
nextbsd-contrib ───────────┘
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
NextBSD: { url: "https://github.com/nextbsd-redux/nextbsd-pkg/releases/download/continuous-amd64", enabled: yes }
```

```
# arm64
NextBSD: { url: "https://github.com/nextbsd-redux/nextbsd-pkg/releases/download/continuous-arm64", enabled: yes }
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
| `NextBSD-everything` (meta) | ✓ | ✓ | depends on all of the above |

## Status

**Working** (unsigned). `pkg install NextBSD-everything` resolves the full set from the
flat repo on both arches. Package signing and the pkg-in-VM ISO assembler refactor
are the remaining pre-production steps; the full design (further splits, dep pins,
versioning) is in [`docs/PLAN.json`](docs/PLAN.json).
