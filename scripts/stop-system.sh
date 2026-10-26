#!/bin/bash
TOPO=${1:-all}
case "$TOPO" in
  central) TARGETS="101 102 103 104 105 106 107 108 109 110 111 112 113 114 115 116 117" ;;
  *) TARGETS=$(seq 102 117) ;;
esac
for i in $TARGETS; do
  ip=192.168.77.$i
  ssh -o StrictHostKeyChecking=no -o BatchMode=yes cc@$ip \
    "test -f ~/pa2/index.pid && kill \$(cat ~/pa2/index.pid) 2>/dev/null; test -f ~/pa2/peer.pid && kill \$(cat ~/pa2/peer.pid) 2>/dev/null; true" &
done
wait
sleep 1
for i in $TARGETS; do
  ip=192.168.77.$i
  ssh -o StrictHostKeyChecking=no -o BatchMode=yes cc@$ip "pkill -9 -x p2p 2>/dev/null; true" &
done
wait
echo "STOP-OK"
