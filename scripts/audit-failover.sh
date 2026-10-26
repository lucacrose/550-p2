#!/bin/bash
set -e
cd ~/pa2
TOPO=${1:?topology}
SSH='ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10'
R=~/pa2/results/failover-$TOPO
md5=$($SSH cc@192.168.77.109 'md5sum ~/pa2/p2p' 2>/dev/null | cut -d' ' -f1)
echo "##### failover-$TOPO audit #####"
echo "-- binary md5 seen by peer09: $md5"
echo "-- meta last lines:"; tail -6 "$R/meta.txt"
echo "-- registrations (index mode only, vm01): files= must be > 0 for all 16 --"
REG=$( $SSH cc@192.168.77.101 'grep "registering" ~/pa2/logs/index.log 2>/dev/null | tail -17' 2>/dev/null || echo "(central only)" )
echo "$REG" | head -3
ZERO=$(echo "$REG" | grep -c 'files=0' || true)
echo "zero_files_registrations=$ZERO"
echo "-- REPLICATION-DONE lines (pushed>0 expected on peer09 first pass) --"
PUSH=$( $SSH cc@192.168.77.109 'grep -h "REPLICATION-DONE" ~/pa2/logs/peer*.log 2>/dev/null | tail -3' 2>/dev/null || echo none )
echo "peer09: $PUSH"
echo "-- bench FAIL lines by label (host copies) --"
for L in "$R"/bench-*.log; do
  [ -f "$L" ] || continue
  n=$(grep -c '^FAIL ' "$L" || true)
  head=$(grep -h 'BENCH-SUMMARY' "$L" | head -1 || echo "")
  echo "  $(basename "$L"): fail_lines=$n | $head"
done
echo "-- unexpected-phase FAIL census --"
EXP="bench-all-holders-dead.log bench-name-missing.log"
BAD=0
for L in "$R"/bench-*.log; do
  [ -f "$L" ] || continue
  b=$(basename "$L")
  skip=""
  for e in $EXP; do [ "$b" = "$e" ] && skip=1; done
  [ -n "$skip" ] && continue
  n=$(grep -c '^FAIL ' "$L" || true)
  [ "${n:-0}" -gt 0 ] && { echo "  UNEXPECTED FAIL in $b (count $n)"; BAD=1; }
done
echo "-- assert failures recorded in meta:"
ASSERTS=$(grep -c 'ASSERT-FAIL' "$R/meta.txt" 2>/dev/null || true)
echo "${ASSERTS:-0}"
echo "-- render verdict --"
if [ -n "${BINGMD5:-}" ] && [ "$md5" != "$BINGMD5" ]; then
  echo "AUDIT-FAIL ($TOPO): binary md5 mismatch ($md5 != $BINGMD5)"; exit 1
fi
if [ "$ZERO" -gt 0 ] || [ "$BAD" -ne 0 ]; then
  echo "AUDIT-FAIL ($TOPO)"
  exit 1
fi
if [ "${ASSERTS:-0}" -gt 0 ]; then
  echo "AUDIT-FAIL ($TOPO): ${ASSERTS} ASSERT-FAIL line(s) recorded in meta.txt"; exit 1
fi
echo "AUDIT-OK ($TOPO)"
