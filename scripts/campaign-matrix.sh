#!/bin/bash
set -e
cd ~/pa2
export PA2_DRV_LOCK=${PA2_DRV_LOCK:-/tmp/pa2-driver.lock}
export PA2_DRV_HELD=1
exec 9>"$PA2_DRV_LOCK"
flock -n 9 || { echo "FATAL: another driver holds $PA2_DRV_LOCK - refusing to start"; exit 1; }
BINGMD5=${BINGMD5:?pin the release binary md5, e.g. BINGMD5=3642a8736e3c9deac79af6d023e52815}
TOPOS=${TOPOS:-central star mesh}
SSHO='ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10'
for TOPO in $TOPOS; do
  echo "=== campaign $TOPO: wipe per-VM scratch ==="
  for i in $(seq 2 17); do
    $SSHO cc@192.168.77.$((100+i)) \
      'rm -f ~/pa2/res/* ~/pa2/logs/peer.log /tmp/peer.repl.done /tmp/peer.gc /tmp/peer.gc-dry /tmp/peer.gc.log /tmp/peer.gc-dry.log /tmp/peer.gc.log.done /tmp/peer.gc-dry.log.done /tmp/cpu.sample.stop' &
  done
  $SSHO cc@192.168.77.101 'rm -f ~/pa2/logs/index.log /tmp/peer.repl.done' &
  wait
  rm -rf ~/pa2/results/vm* ~/pa2/results/$TOPO
  mkdir -p ~/pa2/results/$TOPO
  echo "=== campaign $TOPO: start system (replication drain included) ==="
  bash scripts/start-system.sh $TOPO
  echo "=== campaign $TOPO: run matrix (RUNS=3 e1-e3, RUNS_E4=7, md5-gated) ==="
  RUNS=3 RUNS_E4=${RUNS_E4:-7} BINGMD5=$BINGMD5 bash scripts/run-experiments.sh $TOPO
  echo "=== campaign $TOPO: stop system ==="
  bash scripts/stop-system.sh $TOPO
  if ! grep -q 'result=PASS' ~/pa2/results/$TOPO/meta.txt; then
    echo "CAMPAIGN-MATRIX gate FAILED for $TOPO - aborting"
    exit 1
  fi
done
echo "CAMPAIGN-MATRIX-OK"
