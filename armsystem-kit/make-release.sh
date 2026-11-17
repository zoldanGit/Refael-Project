#!/bin/bash
# Build a clean release tarball of this kit directory, without macOS junk files,
# plus a SHA256SUMS file next to it.
#   ./make-release.sh [OUTDIR]     (default OUTDIR: the parent of the kit directory)
set -euo pipefail
KIT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
NAME=$(basename -- "$KIT")
OUT=${1:-$(dirname -- "$KIT")}
[ -d "$OUT" ] || { echo "make-release.sh: $OUT is not a directory" >&2; exit 1; }
OUT=$(cd -- "$OUT" && pwd -P)
case $OUT/ in "$KIT"/*) echo 'make-release.sh: OUTDIR must be outside the kit directory' >&2; exit 1 ;; esac
TARBALL=$NAME-$(date +%Y%m%d).tar.gz

tar -C "$(dirname -- "$KIT")" -czf "$OUT/$TARBALL" \
  --exclude='.DS_Store' --exclude='._*' --exclude='__MACOSX' --exclude='.AppleDouble' \
  --exclude='.Spotlight-V100' --exclude='.Trashes' --exclude='.fseventsd' \
  --exclude='*~' --exclude='*.swp' \
  "$NAME"

# Fail if any junk slipped in anyway.
if tar -tzf "$OUT/$TARBALL" | grep -E '(^|/)(\.DS_Store|\._[^/]*|__MACOSX|\.AppleDouble)(/|$)' >&2; then
  echo 'make-release.sh: junk files found in the tarball' >&2; exit 1
fi

( cd "$OUT" && sha256sum "$TARBALL" > SHA256SUMS )
echo "Built: $OUT/$TARBALL"
echo "Sums:  $OUT/SHA256SUMS"
cat "$OUT/SHA256SUMS"
