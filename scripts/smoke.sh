#!/bin/bash
# CLI smoke test: exercises the DiskCore scanner, treemap, trash, and
# freespace through the sauron-cli binary. Non-destructive: the file it
# trashes is created fresh and removed from the trash afterwards.
set -euo pipefail

CLI="${1:?usage: smoke.sh <path-to-sauron-cli>}"
FIXTURE="$(mktemp -d /tmp/sauron-smoke.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

pass() { echo "  ok: $1"; }
failed() { echo "  FAIL: $1" >&2; exit 1; }

echo "== fixture: $FIXTURE"
mkdir -p "$FIXTURE/big" "$FIXTURE/small"
dd if=/dev/zero of="$FIXTURE/big/three_mb.bin" bs=1m count=3 status=none
dd if=/dev/zero of="$FIXTURE/big/one_mb.bin"  bs=1m count=1 status=none
dd if=/dev/zero of="$FIXTURE/small/half_mb.bin" bs=512k count=1 status=none
# Sparse file: 100MB logical, ~0 physical
SPARSE="$FIXTURE/sparse.bin"
dd if=/dev/zero of="$SPARSE" bs=1 count=1 seek=104857600 status=none

echo "== du: physical size excludes sparse hole"
TOTAL=$("$CLI" du "$FIXTURE")
# Real data is 4.5MB; sparse file adds ~nothing. Anything under 10MB proves
# we're counting blocks, not logical size (logical would be >100MB).
[ "$TOTAL" -gt 4500000 ] || failed "total $TOTAL too small"
[ "$TOTAL" -lt 10000000 ] || failed "total $TOTAL too big — sparse file counted logically?"
pass "du total $TOTAL bytes (sparse-aware)"

echo "== scan: tree output shows children sorted by size"
SCAN=$("$CLI" scan "$FIXTURE" --depth 2 --top 5)
echo "$SCAN" | sed 's/^/  | /'
echo "$SCAN" | grep -q "big/"          || failed "scan output missing big/"
echo "$SCAN" | grep -q "three_mb.bin"  || failed "scan output missing three_mb.bin"
echo "$SCAN" | grep -q "errors: 0"     || failed "scan reported errors"
# big/ must be listed before small/ (sorted by size desc)
BIG_LINE=$(echo "$SCAN" | grep -n "big/" | head -1 | cut -d: -f1)
SMALL_LINE=$(echo "$SCAN" | grep -n "small/" | head -1 | cut -d: -f1)
[ "$BIG_LINE" -lt "$SMALL_LINE" ] || failed "children not sorted by size"
pass "scan tree ordered and complete"

echo "== layout: treemap areas proportional to weights"
LAYOUT=$("$CLI" layout 100 100 6 3 1)
echo "$LAYOUT" | sed 's/^/  | /'
AREA0=$(echo "$LAYOUT" | awk -F'area=' 'NR==1 {print int($2)}')
AREA1=$(echo "$LAYOUT" | awk -F'area=' 'NR==2 {print int($2)}')
AREA2=$(echo "$LAYOUT" | awk -F'area=' 'NR==3 {print int($2)}')
[ "$AREA0" -ge 5990 ] && [ "$AREA0" -le 6010 ] || failed "area0=$AREA0, want ~6000"
[ "$AREA1" -ge 2990 ] && [ "$AREA1" -le 3010 ] || failed "area1=$AREA1, want ~3000"
[ "$AREA2" -ge 990 ]  && [ "$AREA2" -le 1010 ] || failed "area2=$AREA2, want ~1000"
pass "areas 6000/3000/1000 as expected"

echo "== freespace"
FREE=$("$CLI" freespace | awk '{print $1}')
[ "$FREE" -gt 0 ] || failed "freespace not positive"
pass "freespace $FREE bytes"

echo "== trash: move a scratch file to trash, then clean it out of the trash"
VICTIM="$FIXTURE/victim.bin"
echo "doomed" > "$VICTIM"
OUT=$("$CLI" trash "$VICTIM")
echo "  | $OUT"
[ ! -e "$VICTIM" ] || failed "victim still exists at origin"
DEST=$(echo "$OUT" | sed 's/^trashed .* -> //')
[ -e "$DEST" ] || failed "victim not found in trash at $DEST"
rm -f "$DEST"
pass "trash round-trip"

echo ""
echo "SMOKE OK"
