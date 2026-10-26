#!/bin/bash
set -e
cd ~/pa2
mkdir -p results
for i in $(seq 2 17); do
  ip=192.168.77.$((100+i))
  d=results/vm$(printf "%02d" $i)
  mkdir -p "$d"
  ssh -o StrictHostKeyChecking=no -o BatchMode=yes cc@$ip \
    'cd ~/pa2 2>/dev/null && tar -cf - res logs 2>/dev/null; true' | \
    tar -xf - -C "$d" 2>/dev/null
done
echo "FETCH-OK"
