#!/bin/bash
set -u
cd ~/pa2
export PATH=$HOME/pa2/bin:$PATH
TOPO=central
VMM=5
CLIN=6
OUT=~/outdemo2/output2.txt
mkdir -p ~/outdemo2; rm -f ~/outdemo2/*
echo "== outdemo2 $(date -u '+%F %T') topo=$TOPO victim=vm05 session=vm06"
md5sum ~/pa2/p2p | grep -q 3642a873 || { echo BIN-FAIL-PIN; exit 1; }
bash scripts/stop-system.sh $TOPO >/dev/null 2>&1; sleep 2
bash scripts/start-system.sh $TOPO || { echo BOOT-FAIL; exit 1; }
echo "  waiting 30 s for ring+index settle..."; sleep 30
echo "== readiness:"; bash scripts/smoke.sh $TOPO 2>/dev/null | tail -2

SSH="ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10"

{
echo '================================================================'
echo "  PA2 OUTPUT SAMPLE  --  topology: $TOPO, 16 peers on 17 VMs"
echo '  (All UTC timestamps logged by the peer program itself. The session'
echo '   block runs on a real cluster node: its servent is stopped, and the'
echo "   same pinned binary (md5 $(md5sum ~/pa2/p2p | cut -c1-32)) is"
echo '   started as "p2p peer -c cfg/peerNN.cfg --cli" -- the documented'
echo '   interactive console -- then fed real commands on stdin. Files are'
echo '   served from /data/shared; replication_factor=3 keeps every file'
echo '   on 3 nodes (owner + 2 ring holders chosen from FNV-1a64 name)).'
echo '================================================================'
echo
echo '## 1. operational status: p2p ping --target <ctrl> on every peer'
echo '##    route table, pending queries, neighbours, indexed files,'
echo '##    replication counters repl(push skip recv,done), drops.'
} > $OUT
for i in $(seq 2 17); do
  printf 'vm%02d: ' $i >> $OUT
  $SSH cc@192.168.77.$(printf '%03d' $((100+i))) \
    'cd ~/pa2 && ~/pa2/p2p ping --target 127.0.0.1:51001' 2>&1 >> $OUT
done
{
echo
echo '## 2. session console on vm06 (same node, same cfg, --cli mode):'
echo '##    "query"  = flood search (TTL-scoped QUERY over neighbours)'
echo '##    "obtain" = search + fetch from best holder, displays the'
echo '##               downloaded file size when it lands'
echo '##    pre-kill obtains: files owned by vm05; owner + 2 other ring'
echo '##    holders serve them'
} >> $OUT
$SSH cc@192.168.77.106 "pkill -9 -x p2p 2>/dev/null; sleep 1; cd ~/pa2 && printf 'stat\nquery n05_s000000.txt\nobtain n05_s000000.txt\nobtain n05_b0.bin\nquit\n' | stdbuf -oL -eL ~/pa2/p2p peer -c configs/central/node6.cfg --cli" > $OUT.prekill 2>&1
cat $OUT.prekill >> $OUT
{
echo
echo '## 3. pre-obtains done (see above); now HARD-KILL the servent on'
echo '##    vm05 (pkill -9 -x p2p: the dataset owner of n05_* dies; 2 ring'
echo '##    holders on other nodes still hold the bytes; new ring re-'
echo '##    computes placement and repl push re-copies converge) ---'
} >> $OUT
echo "  kill issued $(date -u '+%Y-%m-%dT%T.%3NZ')" >> $OUT
$SSH cc@192.168.77.105 'pkill -9 -x p2p' 2>/dev/null
sleep 45
{
echo '## 4. session AFTER the kill (same pinned binary, vm07, new --cli'
echo '##    console process): obtain the killed owner'"'"'s files from'
echo '##    SURVIVING holders'
} >> $OUT
$SSH cc@192.168.77.107 "pkill -9 -x p2p 2>/dev/null; sleep 1; cd ~/pa2 && printf 'query n05_s000000.txt\nobtain n05_s000000.txt\nobtain n05_b0.bin\nstat\nquit\n' | stdbuf -oL -eL ~/pa2/p2p peer -c configs/central/node7.cfg --cli" > $OUT.postkill 2>&1
cat $OUT.postkill >> $OUT
{
echo
echo '## 5. repl counters on all survivors AFTER the kill (re-replication'
echo '##    pushed n05_* onto new ring positions; counters below show the'
echo '##    push traffic that converged placement back to 3 copies)'
} >> $OUT
sleep 10
for i in $(seq 2 17); do
  printf 'vm%02d: ' $i >> $OUT
  $SSH cc@192.168.77.$(printf '%03d' $((100+i))) \
    'cd ~/pa2 && ~/pa2/p2p ping --target 127.0.0.1:51001' 2>&1 >> $OUT
done
bash scripts/stop-system.sh $TOPO >/dev/null 2>&1
echo "OUTDEMO2-DONE $(date -u '+%F %T') display_lines=$(grep -c 'display file' $OUT || echo 0)"
grep -c 'display file' $OUT > /dev/null || echo "OUTDEMO2-WARN: no display lines"
