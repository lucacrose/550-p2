#!/bin/bash
set -e
cd ~/pa2
export PA2_DRV_LOCK=${PA2_DRV_LOCK:-/tmp/pa2-driver.lock}
export PA2_DRV_HELD=1
exec 9>"$PA2_DRV_LOCK"
flock -n 9 || { echo "FATAL: another driver holds $PA2_DRV_LOCK - refusing to start"; exit 1; }
BINGMD5=${BINGMD5:?pin the release binary md5, e.g. BINGMD5=3642a8736e3c9deac79af6d023e52815}
OUTTOPO=${OUTTOPO:-central}
for TOPO in ${STAGES:-central star mesh}; do
  echo "=== failover $TOPO: wipe per-VM scratch ==="
  for i in $(seq 2 17); do
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 \
      cc@192.168.77.$((100+i)) 'rm -f ~/pa2/res/* ~/pa2/logs/peer.log /tmp/peer.repl.done /tmp/peer.gc /tmp/peer.gc-dry /tmp/peer.gc.log /tmp/peer.gc-dry.log /tmp/peer.gc.log.done /tmp/peer.gc-dry.log.done /tmp/cpu.sample.stop' &
  done
  ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 cc@192.168.77.101 'rm -f ~/pa2/logs/index.log' &
  wait
  echo "=== failover $TOPO: purge demo specials (owner + holder copies; ring untouched) ==="
  for i in $(seq 2 17); do
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 \
      cc@192.168.77.$((100+i)) 'rm -f /data/shared/n9_wide*.bin /data/shared/n9_wide*.bin.part /data/shared/ghost.bin /data/shared/ghost.bin.part /data/shared/ghost2.bin /data/shared/ghost2.bin.part /data/shared/arbitrary-file.bin /data/shared/arbitrary-file.bin.part /data/shared/arbitrary-file-40m.bin /data/shared/arbitrary-file-40m.bin.part' &
  done
  wait
  echo "=== failover $TOPO: df space precondition (>= 2500 MiB avail on all 16 peers) ==="
  SPC=$(mktemp)
  for i in $(seq 2 17); do
    ( a=""
      for t in 1 2 3; do
        a=$(ssh -o BatchMode=yes -o ConnectTimeout=10 cc@192.168.77.$((100+i)) \
              'df -BM --output=avail / | tail -1 | tr -d " M"' </dev/null 2>/dev/null)
        [ -n "$a" ] && break
        sleep 5
      done
      case "${a:-}" in ''|*[!0-9]*) a=0 ;; esac
      printf 'vm%03d avail=%s MiB%s\n' "$i" "$a" \
        "$([ "${a}" -ge 2500 ] || printf '  SPACE-FAIL')" >> "$SPC" ) &
  done
  wait
  sort "$SPC"
  if grep -q SPACE-FAIL "$SPC"; then
    echo "SPACE-FAIL: stage $TOPO refuses to start; free space with the binary's GC protocol (scripts/gc-run.sh dry/go per the operator lease), then relaunch"
    rm -f "$SPC"
    exit 1
  fi
  rm -f "$SPC"
  echo "=== failover $TOPO: MD5-CHECK all 17 VMs vs pin $BINGMD5 ==="
  BAD=0
  for i in $(seq 1 17); do
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 \
      cc@192.168.77.$((100+i)) 'md5sum ~/pa2/p2p' </dev/null 2>/dev/null \
      | grep -q "^$BINGMD5 " || { echo "MD5-CHECK-FAIL: vm$i"; BAD=1; }
  done
  [ $BAD -eq 0 ] && echo MD5-CHECK-OK || exit 1
  echo "=== failover $TOPO: start system ==="
  bash scripts/start-system.sh $TOPO
  echo "=== failover $TOPO: P1..P12 (P9 placement mirror, P10 index death, negative control) ==="
  BINGMD5=$BINGMD5 bash scripts/failover-demo.sh $TOPO || { rc=$?; echo "DRIVER: failover-demo $TOPO exited rc=$rc at $(date -u '+%T')Z (see the DEMO-ERR/DEMO-SIG meta traps for the failing command)"; exit $rc; }
  echo "=== failover $TOPO: stop system ==="
  bash scripts/stop-system.sh $TOPO
  echo "=== failover $TOPO: audit ==="
  bash scripts/audit-failover.sh $TOPO
done
echo "=== outdemo3: all-topology output.txt capture ==="
BINGMD5=$BINGMD5 bash scripts/make-output3.sh
grep -q 'OUTDEMO3-OK' results/outdemo3-run.log || { echo "OUT-FAIL: outdemo3 gate failed (see results/outdemo3-run.log)"; exit 1; }
[ -s ~/pa2/output.txt ] || { echo "output.txt missing - aborting"; exit 1; }
echo "CAMPAIGN-FAILOVER-OK"
