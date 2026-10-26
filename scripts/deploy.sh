#!/bin/bash
set -e
cd ~/pa2
[ -x ./p2p ] || { echo "p2p binary missing - build first"; exit 1; }
IPS=$(seq 101 117 | sed 's/^/192.168.77./')
SSHOPTS='-o StrictHostKeyChecking=no -o BatchMode=yes'
for ip in $IPS; do
  ssh $SSHOPTS cc@$ip 'mkdir -p ~/pa2/manifests ~/pa2/configs ~/pa2/logs ~/pa2/res ~/pa2/scripts' 2>/dev/null &
done
wait
echo "dirs ok"

for ip in $IPS; do
  rsync -a -e "ssh $SSHOPTS" p2p manifests configs "cc@$ip:~/pa2/" 2>/dev/null &
  rsync -a -e "ssh $SSHOPTS" scripts "cc@$ip:~/pa2/" 2>/dev/null &
done
wait
echo "DEPLOY-OK"
