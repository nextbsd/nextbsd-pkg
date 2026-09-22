#!/bin/sh
# check-ownership.sh — Layer A of the nextbsd#370 gate. Runs in the packaging VM
# after build.sh has staged every component, BEFORE `pkg repo`. Fails fast if any
# two component packages own the same path — the userland<->compat collision
# class (e.g. both shipping /usr/share/man/man3/syslog.3.gz) that let pkg's SAT
# solver silently drop NextBSD-userland at consumer install.
#
# Deterministic and instant (a sort/awk over the staged plists); names the exact
# path and both owners, so a new overlap fails with an obvious culprit long before
# the slower real install-test (Layer B, install-test.sh) would.
set -eu

# Component stage dirs created by build.sh. stage/everything is the empty meta —
# it owns nothing, so it is intentionally omitted.
comps="compat kernel kexts userland contrib"

owners=$(mktemp)
trap 'rm -f "$owners" "$owners.s"' EXIT
for c in $comps; do
  d="stage/$c"
  [ -d "$d" ] || continue
  # emit "<path>\t<component>" for every owned file/symlink
  ( cd "$d" && find . \( -type f -o -type l \) | sed 's#^\.##' ) \
    | sed "s#\$#	$c#" >> "$owners"
done

# Deliberate cross-package shared paths (normally empty — the five packages should
# partition the filesystem). Fixed-string matched against the reported path.
allow="scripts/allowed-shared.txt"
[ -f "$allow" ] || allow=/dev/null

# Sort by the full line (path is field 1, so identical paths cluster), then flag
# any path carried by more than one distinct component.
sort "$owners" > "$owners.s"
conflicts=$(awk -F'\t' '
  { path=$1; owner=$2
    if (path==prev) { o=o "," owner; n++ }
    else { if (n>1) print prev "  <=  " o; prev=path; o=owner; n=1 } }
  END { if (n>1) print prev "  <=  " o }' "$owners.s" \
  | { grep -vFf "$allow" || true; })

if [ -n "$conflicts" ]; then
  echo "FATAL: NextBSD component packages co-own paths (nextbsd#370):" >&2
  printf '%s\n' "$conflicts" >&2
  echo >&2
  echo "Each path must be owned by exactly ONE NextBSD-* package. Where the Darwin" >&2
  echo "userland ships an equivalent of a FreeBSD-base file, userland owns the" >&2
  echo "canonical copy and the base must strip it (nextbsd-freebsd-compat's" >&2
  echo "strip-collisions.sh). If an overlap is genuinely intended, add the path to" >&2
  echo "scripts/allowed-shared.txt." >&2
  exit 1
fi

echo "OK: no cross-package path collisions among components: $comps"
