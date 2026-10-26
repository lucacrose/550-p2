#!/bin/bash
set -e
cd ~/pa2
N0=${N0:-2}; N1=${N1:-17}
SMALL_PER_NODE=${SMALL_PER_NODE:-100000}
LARGE_PER_NODE=${LARGE_PER_NODE:-10}
SSH='ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10'

echo "== bootstrap /data on every node (one-time) =="
for i in $(seq $N0 $N1); do
  $SSH cc@192.168.77.$((100+i)) \
    "sudo mkdir -p /data/shared /data/downloads && sudo chown -R cc:cc /data" \
    || echo "WARN: /data bootstrap failed on vm$i"
done

echo "== launch own-dataset generation on all nodes =="
for i in $(seq $N0 $N1); do
  $SSH cc@192.168.77.$((100+i)) \
    "for p in \$(pgrep -f gen-dataset); do [ \"\$p\" != \"\$\$\" ] && kill \$p 2>/dev/null; done; rm -f ~/pa2/logs/dataset.done; SMALL_PER_NODE=$SMALL_PER_NODE LARGE_PER_NODE=$LARGE_PER_NODE nohup python3 ~/pa2/scripts/gen-dataset.py $i ~/pa2/manifests/roster.txt gen > ~/pa2/logs/dataset.log 2>&1 < /dev/null & echo launched" \
    || echo "WARN: gen launch failed on vm$i"
done

echo "== poll for dataset.done markers (up to 45 min) =="
deadline=$((SECONDS + 2700))
while [ $SECONDS -lt $deadline ]; do
  pending=""
  for i in $(seq $N0 $N1); do
    if ! $SSH cc@192.168.77.$((100+i)) \
      "grep -q 'large files created' ~/pa2/logs/dataset.log 2>/dev/null" 2>/dev/null; then
      pending="$pending vm$i"
    fi
  done
  if [ -z "$pending" ]; then
    echo "all datasets generated"; break
  fi
  echo "generating:$pending"
  sleep 15
done

echo "== verify owner file counts (replicas arrive when peers start) =="
for i in $(seq $N0 $N1); do
  $SSH cc@192.168.77.$((100+i)) "df -h / | tail -1; ls /data/shared | wc -l" &
done
wait
echo "DATA-OK"
