#!/bin/sh
# verify.sh — runs INSIDE a fresh FreeBSD VM. Points NextBSD's pkg at the
# just-published flat repo (continuous-${ARCH} Release assets) and confirms the
# package set is queryable and that NextBSD-everything resolves the full
# dependency graph.
#
# The packages carry the NextBSD ABI (NextBSD:27:<arch>), which only NextBSD's
# pkg knows, so this runs NextBSD's pkg-static from the nextbsd-contrib
# artifact the workflow fetched into art/tool/ (amd64, as the VM is), with an
# explicit empty config (-C) and repo directory (-R), against a scratch root
# (-r) so the VM's own package database is not touched. The VM is x86 but the
# resolution is metadata-only (dry-run -n), so it validates arm64 catalogs too.
set -eux

ARCH="${ARCH:-amd64}"
# pkg's ABI uses 'aarch64' for 64-bit ARM; the release tag / artifacts use 'arm64'.
case "$ARCH" in arm64) ABIARCH=aarch64 ;; *) ABIARCH="$ARCH" ;; esac
BASE="https://github.com/nextbsd/nextbsd-pkg/releases/download/continuous-${ARCH}"
# Same values as build.sh stamps (nextbsd-kernel#376).
NBOSVERSION=2700000

mkdir -p tool/root tool/repos
tar -C tool/root -xzf art/tool/nextbsd-contrib-pkg-amd64.tar.gz ./usr/sbin/pkg-static
: > tool/pkg.conf
# Named NextBSD, as on a NextBSD system (NextBSD's pkg treats other
# repositories' packages differently).
cat > tool/repos/NextBSD.conf <<CONF
NextBSD: {
  url: "${BASE}",
  enabled: yes,
  signature_type: none,
}
CONF

# The ABI goes in the environment: with -r, pkg would otherwise derive it from
# the (empty) root.
export ABI="NextBSD:$((NBOSVERSION / 100000)):${ABIARCH}"
export OSVERSION="${NBOSVERSION}"
ROOT=$(mktemp -d)
PKG="$PWD/tool/root/usr/sbin/pkg-static -C $PWD/tool/pkg.conf -R $PWD/tool/repos -r $ROOT"

echo "=== pkg update (fetch catalog from the flat Release repo, ${ARCH}) ==="
$PKG update -f

echo "=== every NextBSD package in the ${ARCH} catalog ==="
$PKG search -r NextBSD NextBSD

echo "=== dry-run install of the whole OS (NextBSD-everything resolves the graph) ==="
$PKG install -n -y NextBSD-everything

echo "OK: ${ARCH} flat pkg repo readable; NextBSD-everything resolves the dependency graph"
