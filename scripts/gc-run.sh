#!/bin/bash
set -u
MODE=${1:-dry}
[ "$MODE" = dry ] || [ "$MODE" = go ] || {
  echo "usage: $0 [dry|go]" >&2; exit 2; }

cd ~/pa2
if [ -z "${PA2_DRV_HELD:-}" ]; then
  export PA2_DRV_LOCK=${PA2_DRV_LOCK:-/tmp/pa2-driver.lock}
  exec 9>"$PA2_DRV_LOCK"
  flock -n 9 || { echo "FATAL: another driver holds $PA2_DRV_LOCK - refusing to start"; exit 1; }
  export PA2_DRV_HELD=1
fi

if [ "$MODE" = go ] && [ ! -f results/gc/GO-approved ]; then
  echo "REFUSING: results/gc/GO-approved missing."
  echo "Run '$0 dry' first, review results/gc/dry/strays.txt, then"
  echo "  touch results/gc/GO-approved    # explicit operator go-ahead"
  exit 1
fi

SSHO='ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10'
LOG=$([ "$MODE" = dry ] && echo /tmp/peer.gc-dry.log || echo /tmp/peer.gc.log)
MARK=$([ "$MODE" = dry ] && echo /tmp/peer.gc-dry || echo /tmp/peer.gc)
R=$PWD/results/gc/$MODE
mkdir -p "$R"

echo "=== precondition: one p2p per VM (the roster-alive GC gate needs them) ==="
ALIVE=0
for i in $(seq 2 17); do
  n=$( $SSHO cc@192.168.77.$((100+i)) 'pgrep -xc p2p || true' 2>/dev/null )
  [ "${n:-0}" -ge 1 ] || { echo "  vm$((100+i)): NO p2p running - start the system first"; }
  ALIVE=$((ALIVE + ${n:-0}))
done
NIDX=$( $SSHO cc@192.168.77.101 'pgrep -xc p2p || true' 2>/dev/null )
echo "  p2p processes: peers=$ALIVE (want 16) index-vm=$NIDX (want 1)"
if [ "$ALIVE" -lt 16 ]; then
  echo "GC-ABORT: the system is not up; refusing to touch GC markers blind."
  exit 1
fi

echo "=== $MODE: wipe stale GC markers/verdict logs on every peer ==="
for i in $(seq 2 17); do
  $SSHO cc@192.168.77.$((100+i)) "rm -f /tmp/peer.gc /tmp/peer.gc-dry $LOG" &
done
wait
rm -f "$R"/gc-*-vm*.log "$R/summary.txt" "$R/strays.txt" 2>/dev/null

echo "=== $MODE: df before ==="
for i in $(seq 2 17); do
  echo "  vm$((100+i)): $($SSHO cc@192.168.77.$((100+i)) 'df -m /data/shared' | sed -n 2p)"
done

echo "=== $MODE: touch $MARK on 16 peers ($(date -u +%FT%TZ)) ==="
for i in $(seq 2 17); do
  $SSHO cc@192.168.77.$((100+i)) "touch $MARK" &
done
wait

echo "=== $MODE: wait for verdict logs (timeout 2400s) ==="
deadline=$(( $(date +%s) + 2400 ))
while :; do
  got=0
  for i in $(seq 2 17); do
    $SSHO cc@192.168.77.$((100+i)) "grep -q SUMMARY $LOG" 2>/dev/null && got=$((got + 1))
  done
  echo "  verdict logs ready: $got/16 ($(date -u +%T))"
  [ "$got" -ge 16 ] && break
  if [ "$(date +%s)" -gt "$deadline" ]; then
    echo "GC-FAIL: only $got/16 verdict logs after 2400s - strays NOT confirmed"
    echo "  hint: a peer that could not probe the whole roster logs"
    echo "        'gc: roster node ... not live, refusing to run' in ~/pa2/logs/peer.log"
    exit 1
  fi
  sleep 10
done

echo "=== $MODE: fetch verdict logs ==="
for i in $(seq 2 17); do
  $SSHO cc@192.168.77.$((100+i)) "cat $LOG" > "$R/gc-$MODE-vm$((100+i)).log" 2>/dev/null
done
for i in $(seq 2 17); do
  f=$R/gc-$MODE-vm$((100+i)).log
  if [ ! -s "$f" ]; then echo "GC-FAIL: empty verdict log for vm$((100+i))"; exit 1; fi
done

KEEP=0; DEL=0; UNK=0; GONE=0
for i in $(seq 2 17); do
  f=$R/gc-$MODE-vm$((100+i)).log
  KEEP=$((KEEP + $(grep -c '^KEEP' "$f" || true)))
  DEL=$((DEL + $(grep -c "^DELETE" "$f" || true)))
  UNK=$((UNK + $(grep -c '^UNKNOWN-OWNER' "$f" || true)))
  GONE=$((GONE + $(grep -c '^GONE' "$f" || true)))
done
grep -h "^DELETE" "$R"/gc-$MODE-vm*.log | awk '{print $2}' | cut -f1 | \
  sort | uniq -c | sort -nr > "$R/strays.txt"
{
  echo "gc-$MODE aggregation $(date -u +%FT%TZ)  mode=$MODE nodes=16"
  echo "keep=$KEEP $([ "$MODE" = dry ] && echo would_delete || echo deleted)=$DEL unknown_owner=$UNK gone_index=$GONE"
  echo "unique stray names in the verdict logs: $(wc -l < "$R/strays.txt")"
  echo "-- per-peer SUMMARY lines:"
  for i in $(seq 2 17); do
    echo "  vm$((100+i)): $(grep -h '^SUMMARY' "$R/gc-$MODE-vm$((100+i)).log")"
  done
  echo "-- top stray names (copy count of peers holding a stray copy):"
  head -20 "$R/strays.txt" | sed 's/^/  /'
} > "$R/summary.txt"
cat "$R/summary.txt"

echo "=== $MODE: df after ==="
for i in $(seq 2 17); do
  echo "  vm$((100+i)): $($SSHO cc@192.168.77.$((100+i)) 'df -m /data/shared' | sed -n 2p)"
done

if [ "$MODE" = dry ]; then
  echo "GC-DRY-OK verdicts in $R; stray names listed in $R/strays.txt"
  echo "NOTHING WAS DELETED. Review the list, then: touch results/gc/GO-approved"
else
  echo "GC-GO-OK deleted=$DEL stray copies; verdicts in $R"
  echo "Index entries for deleted files were dropped locally; the central index"
  echo "keeps them (merge-only I_ADDFILES) until the next system restart."
fi
