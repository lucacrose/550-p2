#!/bin/bash
set -e
TOPO=${1:?need topology}
case "$TOPO" in
  central|star|mesh) ;;
  *) echo "topology must be central|star|mesh"; exit 1 ;;
esac
cd ~/pa2
SSH='ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5'

P2PBIN=${P2PBIN:-$HOME/pa2/p2p}
ASANENV=${ASANENV:-}

./scripts/stop-system.sh "$TOPO" >/dev/null 2>&1 || true
sleep 1

if [ "$TOPO" = "central" ]; then
  $SSH cc@192.168.77.101 \
    "nohup ~/pa2/p2p index -c ~/pa2/configs/central/index.cfg > ~/pa2/logs/index.log 2>&1 & echo \$! > ~/pa2/index.pid"
fi
PEERS=$(seq 2 17)

for i in $PEERS; do
  ip=192.168.77.$((100+i))
  $SSH cc@$ip \
    "sudo mkdir -p /data/shared /data/downloads; sudo chown cc /data/shared /data/downloads; find /data/shared -maxdepth 1 -name '*.part' -delete; rm -f /tmp/peer.repl.done; $ASANENV nohup $P2PBIN peer -c ~/pa2/configs/$TOPO/node$i.cfg > ~/pa2/logs/peer.log 2>&1 & echo \$! > ~/pa2/peer.pid" &
done
wait
echo "started $TOPO topology; waiting for peer readiness..."
sleep 3

for try in $(seq 1 30); do
  okcount=0; msgs=""
  for i in $PEERS; do
    ip=192.168.77.$((100+i))
    out=$($SSH cc@$ip "~/pa2/p2p ping --target 127.0.0.1:51001" 2>/dev/null) \
      && okcount=$((okcount+1)) || msgs="$msgs vm$i"
  done
  nb=$($SSH cc@192.168.77.103 \
    "~/pa2/p2p ping --target 127.0.0.1:51001 2>/dev/null" | grep -o "neighbours=[0-9]*") || nb="neighbours=ERR"
  if [ "$okcount" = "16" ]; then
    echo "all 16 peers responding (vm03: $nb)"
    case "$TOPO" in
      star) [ "$nb" = "neighbours=15" ] && echo "STAR-READY" || echo "hub link check: $nb" ;;
      mesh) echo "mesh sample: $nb" ;;
      central) echo "CENTRAL-READY (index mode reports neighbours=0)" ;;
    esac
    break
  fi
  echo "try $try: $okcount/16 peers ready ($msgs)"
  sleep 2
done

echo "waiting for in-program initial replication to finish (marker)..."
REPL_WAIT_SECS=${REPL_WAIT_SECS:-2400}
RDIR=/tmp/.repl.$$
t0=$(date +%s)
while :; do
  pending=""
  mkdir -p "$RDIR"
  for i in $PEERS; do
    ip=192.168.77.$((100+i))
    ( $SSH cc@$ip "test -f /tmp/peer.repl.done" 2>/dev/null || echo " vm$i" ) \
      > "$RDIR/$i" &
  done
  wait
  for i in $PEERS; do pending="$pending$(cat "$RDIR/$i" 2>/dev/null || true)"; done
  rm -rf "$RDIR"
  el=$(( $(date +%s) - t0 ))
  if [ -z "$pending" ]; then
    echo "initial replication pass done on all 16 peers in ${el} s"
    break
  fi
  echo "  repl ${el}s, still pushing:$pending"
  if [ "$el" -gt "$REPL_WAIT_SECS" ]; then
    echo "FATAL: replication not drained after ${REPL_WAIT_SECS}s:$pending"; exit 1
  fi
  sleep 5
done

for i in $PEERS; do
  ip=192.168.77.$((100+i))
  printf "vm%02d: " $i
  $SSH cc@$ip "~/pa2/p2p ping --target 127.0.0.1:51001 2>/dev/null" || echo FAIL
done
echo "START-OK ($TOPO)"
