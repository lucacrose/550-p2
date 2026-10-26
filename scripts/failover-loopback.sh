#!/bin/bash
set -u
TOPO=${1:?usage: failover-lb4.sh <central|star|mesh>}
ROOT=${ROOT:-$HOME/pa2-fix}
BIN=$ROOT/p2p
S=$HOME/pa2-fo/$TOPO
MB=57100; CB=57200; DB=57300; IBASE=57000
N1=2; N2=17
RES=$ROOT/results/failover-$TOPO
NSAMP=20
BINDIGEST=$(md5sum $BIN | cut -d' ' -f1)
mkdir -p $S/cfg $S/logs $S/data $S/stats $RES
rm -f $S/logs/bench-*.log $S/failures.txt $RES/*.csv $RES/meta.txt $RES/*.txt $RES/*.log
export LABP=$S

log()  { echo "[$(date -u '+%T')] $*" | tee -a $RES/meta.txt; }
fail() { echo "ASSERT-FAIL: $*" | tee -a $RES/meta.txt $S/failures.txt; }

write_cfg() {
  local id=$1
  python3 - "$ROOT" "$TOPO" "$id" "$MB" "$CB" "$DB" "$IBASE" "$S/data/peer$id" <<'PY'
import sys, os
src, topo, nid, MB, CB, DB, IBASE, dat = sys.argv[1:9]
nid = int(nid); MB=int(MB); CB=int(CB); DB=int(DB); IBASE=int(IBASE)
def lb(ip): return '127.0.0.%d' % (int(ip.split('.')[-1]) - 100)
path = os.path.join(src, 'configs', topo, 'node%d.cfg' % nid)
lines = [l.strip() for l in open(path) if l.strip() and not l.startswith('#')]
out = []
for l in lines:
    k, _, v = l.partition('=')
    if k == 'index_ip':        l = 'index_ip=127.0.0.1'
    elif k == 'index_port':    l = 'index_port=%d' % IBASE
    elif k == 'my_ip':         l = 'my_ip=127.0.0.%d' % nid
    elif k == 'msg_port':      l = 'msg_port=%d' % (MB + nid)
    elif k == 'control_port':  l = 'control_port=%d' % (CB + nid)
    elif k == 'download_port': l = 'download_port=%d' % (DB + nid)
    elif k == 'neighbors':
        out.append('neighbors=' + ','.join(
            '%s:%d' % (lb(x.strip()), MB + (int(x.strip().split('.')[-1]) - 100))
            for x in v.split(',') if x.strip())); continue
    elif k == 'ring':

        out.append('ring=' + ','.join(
            '%s:%s:%d' % (p.strip().split(':')[0], lb(p.strip().split(':')[1]),
                          DB + int(p.strip().split(':')[0]))
            for p in v.split(','))); continue
    elif k == 'extra_peers':
        out.append('extra_peers=127.0.0.2:%d' % (CB + 2)); continue
    elif k in ('data_dir', 'downloads_dir'): continue
    out.append(l)
out.append('data_dir=' + dat)
out.append('downloads_dir=' + dat + '/dl')
open(os.environ['LABP'] + '/cfg/fo-%s-node%d.cfg' % (topo, nid), 'w').write('\n'.join(out) + '\n')
PY
  [ -s $S/cfg/fo-$TOPO-node$id.cfg ] || { echo "FATAL: no cfg for $TOPO node $id"; exit 1; }
}
write_index_cfg() {
  sed -e 's|192\.168\.77\.101|127.0.0.1|' -e "s|^msg_port=.*|msg_port=$IBASE|" \
      "$ROOT/configs/central/index.cfg" > $S/cfg/fo-index.cfg
}

wait_port() { local ip=$1 port=$2 i=0
  while [ $i -lt 80 ]; do timeout 1 bash -c "echo > /dev/tcp/$ip/$port" 2>/dev/null \
    && return 0; sleep 0.25; i=$((i+1)); done; return 1; }
peer_ctl() { echo "127.0.0.$1:$((CB + $1))"; }
alive() { [ -f $S/node$1.pid ] && kill -0 $(cat $S/node$1.pid) 2>/dev/null; }

ping_snap() { local tag=$1 i
  : > $S/stats/ping-$tag.txt
  for i in $(seq $N1 $N2); do
    $BIN ping --target $(peer_ctl $i) >> $S/stats/ping-$tag.txt 2>&1 || true
  done; }

kill_peer() { local id=$1
  if alive $id; then kill $(cat $S/node$id.pid) 2>/dev/null; sleep 1;
    kill -9 $(cat $S/node$id.pid) 2>/dev/null || true; fi; }
start_peer() { local id=$1
  $BIN peer -c $S/cfg/fo-$TOPO-node$id.cfg < /dev/null \
    >> $S/logs/node$id.restart.log 2>&1 &
  echo $! > $S/node$id.pid; }

run_bench() {
  local label=$1 cid=$2 count=$3 man=$4 cl=$5 csv=$6
  local lg=$S/logs/bench-$label.log
  $BIN bench --target $(peer_ctl $cid) --clients $cl --count $count --op obtain \
    --manifest $man --seed $(( $(date +%s%N) % 2000000000 )) \
    --out $csv --label failover-$TOPO-$label > $lg 2>&1
  local f=$(grep -c '^FAIL ' $lg); local sum=$(grep -h 'BENCH-SUMMARY' $lg | head -1)
  log "bench $label client=peer$cid count=$count FAILlines=$f | $sum"
  grep '^FAIL ' $lg | head -3 | sed 's/^/    /' >> $RES/meta.txt
}

wide_ids() { find $S/data/peer*/ -maxdepth 1 -name 'n9_wide*.bin' \
  | sed 's|.*peer\([0-9]*\)/.*|\1|' | sort -un | tr '\n' ' '; }
live_wide_ids() { for h in $(wide_ids); do alive $h && printf '%s ' $h; done; }
pick_client() {
  local c h H=$(wide_ids)
  for c in 13 16 15 14 5 3; do
    local skip=0
    for h in $H; do [ "$h" = "$c" ] && skip=1; done
    alive $c && [ $skip = 0 ] && { echo $c; return; }
  done
  echo 13; }

log "=== failover demo ($TOPO, single-host 127.0.0.N loopback) start ==="
log "binary md5: $BINDIGEST   ports: msg=57100+id ctl=57200+id dl=57300+id index=127.0.0.1:57000"
BASE=$S/base; mkdir -p $BASE
if [ ! -f $BASE/.done ]; then
  for i in $(seq 1 60); do
    id=$(( (i % (N2 - N1 + 1)) + N1 ))
    head -c 204800 /dev/urandom > $BASE/n${id}_s$i
  done
  for i in $(seq 1 8); do
    id=$(( (i % (N2 - N1 + 1)) + N1 ))
    head -c 10240000 /dev/urandom > $BASE/n${id}_b$i
  done
  touch $BASE/.done
fi
for i in $(seq $N1 $N2); do
  mkdir -p $S/data/peer$i/dl
  rm -f $S/data/peer$i/n*_s* $S/data/peer$i/n*_b* $S/data/peer$i/n9_wide*.bin \
       $S/data/peer$i/ghost.bin $S/data/peer$i/ghost2.bin
  (cd $S/data/peer$i && ln -f $BASE/n${i}_* . 2>/dev/null || cp $BASE/n${i}_* .)
done
head -c 41943040 /dev/zero | tr '\0' 'W' > $S/data/peer9/n9_wide1.bin
for w in 2 3 4 5; do head -c 41943040 /dev/urandom > $S/data/peer9/n9_wide$w.bin; done
head -c 1048576 /dev/urandom > $S/data/peer12/ghost.bin
head -c 1048576 /dev/urandom > $S/data/peer4/ghost2.bin
for f in $S/data/peer9/n9_wide{1,2,3,4,5}.bin $S/data/peer12/ghost.bin $S/data/peer4/ghost2.bin; do
  [ -s "$f" ] || { echo "FATAL: special-set seed missing: $f"; exit 1; }
done
log "special set: 5x40MiB n9_wide* ONLY on peer09; ghost.bin ONLY on peer12; ghost2.bin ONLY on peer04 (ghost names fail n<id>_* so replication never touches them)"
M=$S/man; mkdir -p $M
ls $BASE | grep '^n12_s' | head -$NSAMP > $M/n12-small.txt
printf 'n9_wide1.bin\nn9_wide2.bin\nn9_wide3.bin\nn9_wide4.bin\nn9_wide5.bin\n' > $M/wide.txt
head -1 $M/wide.txt > $M/wide1.txt
echo ghost.bin  > $M/ghost.txt
echo ghost2.bin > $M/ghost2.txt
for i in $(seq $N1 $N2); do write_cfg $i; done
write_index_cfg
pkill -f "$BIN peer -c $S/cfg/" 2>/dev/null || true
pkill -f "$BIN index -c $S/cfg/fo-index.cfg" 2>/dev/null || true
pkill -f "$BIN index -c" 2>/dev/null || true
sleep 1
$BIN index -c $S/cfg/fo-index.cfg > $S/logs/index.log 2>&1 &
echo $! > $S/index.pid
wait_port 127.0.0.1 $IBASE || { echo "FATAL: index not up"; exit 1; }
for i in $(seq $N1 $N2); do
  $BIN peer -c $S/cfg/fo-$TOPO-node$i.cfg < /dev/null > $S/logs/node$i.log 2>&1 &
  echo $! > $S/node$i.pid
  sleep 0.15
done
for i in $(seq $N1 $N2); do
  wait_port 127.0.0.$i $((CB + i)) || fail "peer$i control port never came up"
done
t0=$(date +%s); while :; do
  dn=$(cat $S/logs/node*.log 2>/dev/null | grep -c 'REPLICATION-DONE' || true)
  if [ "${dn:-0}" -ge $((N2-N1+1)) ]; then break; fi
  if [ $(( $(date +%s) - t0 )) -gt 300 ]; then log "WARN replication not done in 300s ($dn/16)"; break; fi
  sleep 2
done
log "replication first sweep: $dn/16 peers done in $(( $(date +%s) - t0 ))s"
sleep 3
ping_snap pre

CLIENT=$(pick_client)
log "obtain client = peer$CLIENT (a live peer holding NO wide replica)"
for f in n9_wide1.bin n9_wide3.bin n9_wide5.bin; do
  n=$(find $S/data/peer*/ -maxdepth 1 -name $f | wc -l)
  [ "$n" = 3 ] || fail "P1 $f has $n copies (want 3)"
done
log "P1 baseline: sampled n9_wide* names each on exactly 3 peers (owner + 2 ring holders)"
run_bench baseline-p1 $CLIENT $NSAMP $M/n12-small.txt 1 $RES/failover-small.csv

kill_peer 9
log "P2 owner-stop: peer09 (owner of every n9_wide*) killed; immediate obtain of all 5 wide files from peer$CLIENT"
run_bench owner-kill $CLIENT 5 $M/wide.txt 1 $RES/failover-large.csv
if grep -q '^FAIL obtain n9_wide' $S/logs/bench-owner-kill.log; then
  fail "P2 wide obtains should succeed via the 2 ring-holder replicas"
fi
sleep 5
CLIENT=$(pick_client)
ping_snap post-P2

if ! alive 12 || [ ! -f $S/data/peer12/ghost.bin ]; then
  start_peer 12; wait_port 127.0.0.12 $((CB + 12)) || fail "peer12 restart failed"
  head -c 1048576 /dev/urandom > $S/data/peer12/ghost.bin
  sleep 3
  log "P3 setup: peer12 (re)started and ghost.bin re-seeded for the alive baseline"
fi
run_bench ghost-alive 13 1 $M/ghost.txt 1 $RES/failover-small.csv
kill_peer 12
log "P3 ghost-stop: ghost.bin lives ONLY on peer12 and replication never copies it; after the kill the obtain MUST FAIL"
run_bench ghost-dead 13 1 $M/ghost.txt 1 $RES/failover-small.csv
if ! grep -q '^FAIL obtain ghost.bin' $S/logs/bench-ghost-dead.log; then
  fail "P3 expected a FAIL line for ghost.bin after peer12 died"
fi

for round in 1 2 3 4 5 6; do
  LH=$(live_wide_ids); [ -z "$LH" ] && break
  log "P4 round $round: killing every live holder of n9_wide*: $LH"
  for h in $LH; do kill_peer $h; done
  sleep 3
done
LH=$(live_wide_ids)
log "P4 fixed point: live holders of n9_wide* now: '${LH:-none}' (killed peers keep the file on disk but no live download server serves it)"
CLIENT=$(pick_client)
alive $CLIENT || { start_peer $CLIENT; wait_port 127.0.0.$CLIENT $((CB + CLIENT)); sleep 3; }
run_bench all-holders-dead $CLIENT 5 $M/wide.txt 1 $RES/failover-large.csv
if ! grep -q '^FAIL obtain n9_wide' $S/logs/bench-all-holders-dead.log; then
  fail "P4 expected FAIL lines for n9_wide* after every holder died"
fi

start_peer 9
wait_port 127.0.0.9 $((CB + 9)) || fail "peer09 did not restart"
log "P5 restoration: owner peer09 restarted (its 5 wide files are still on its disk); polling obtain of n9_wide1.bin from peer$CLIENT"
t0=$(date +%s); ok=0
for t in $(seq 1 60); do
  $BIN bench --target $(peer_ctl $CLIENT) --clients 1 --count 1 --op obtain \
    --manifest $M/wide1.txt --seed $(( $(date +%s) * 7 + t )) \
    --out $S/poll.csv --label poll > $S/poll.log 2>&1
  grep -q 'ok=1 fail=0' $S/poll.log && { ok=1; break; }
  sleep 2
done
T_RES=$(( $(date +%s) - t0 ))
if [ $ok = 1 ]; then
  log "P5 restore: n9_wide1.bin obtainable again after ${T_RES}s of polling"
else
  log "P5 restore: NOT obtainable within ${T_RES}s"
fi
sleep 8
LH=$(live_wide_ids)
log "P5 live holders of n9_wide* after restore window: '${LH:-none}'"
CLIENT=$(pick_client); alive $CLIENT || { start_peer $CLIENT; sleep 3; }
run_bench restored $CLIENT 5 $M/wide.txt 1 $RES/failover-large.csv

CLIENT=$(pick_client); alive $CLIENT || { start_peer $CLIENT; sleep 3; }
run_bench large-failover $CLIENT 10 $M/wide.txt 2 $RES/failover-large.csv
ping_snap post-P6

if [ "$TOPO" = mesh ]; then
  INT=""
  for c in 7 5 11 8 10; do
    if alive $c; then INT=$c; break; fi
  done
  [ -z "$INT" ] && fail "P7: no interior candidate alive" || true
  kill_peer $INT
  SRC=3; alive $SRC || SRC=6; alive $SRC || SRC=5
  log "P7 interior-stop: peer$INT (mesh interior node) killed; obtains from peer$SRC"
  run_bench interior $SRC $NSAMP $M/n12-small.txt 1 $RES/failover-small.csv
  a=$(sha256sum $S/data/peer$SRC/n12_s1 2>/dev/null | awk '{print $1}')
  b=$(sha256sum $S/data/peer9/n12_s1 2>/dev/null | awk '{print $1}')
  log "P7 data-intact check: n12_s1 sha256 peer$SRC=$a peer9=$b"
fi

if [ "$TOPO" = star ]; then
  alive 2 || { start_peer 2; sleep 4; }
  kill_peer 2
  log "P8 hub-stop: peer02 (star hub, the only leaf-leaf relay) killed -> every leaf isolated"
  alive 13 || { start_peer 13; sleep 4; }
  run_bench hub-partition 13 1 $M/ghost2.txt 1 $RES/failover-small.csv
  if ! grep -q '^FAIL obtain ghost2.bin' $S/logs/bench-hub-partition.log; then
    fail "P8 expected FAIL for ghost2.bin (lives only on peer04, unreachable across the cut)"
  fi
  a=$(sha256sum $S/data/peer4/n12_s1 2>/dev/null | awk '{print $1}')
  b=$(sha256sum $S/data/peer13/n12_s1 2>/dev/null | awk '{print $1}')
  log "P8 data-intact: n12_s1 sha256 peer04=$a peer13=$b (same hash on both sides => only routing is partitioned, data intact)"
fi

ping_snap final
{ echo "=== ping stats snapshots (per-phase counters; see drops route=/hit=) ==="
  for f in $S/stats/ping-*.txt; do
    echo "-- $(basename $f)"
    grep -m2 ' drops(' $f || head -1 $f
  done; } >> $RES/meta.txt
log "assert failures this session: $(wc -l < $S/failures.txt 2>/dev/null || echo 0)"
pkill -f "$BIN peer -c $S/cfg/" 2>/dev/null || true
pkill -f "$BIN index -c $S/cfg/fo-index.cfg" 2>/dev/null || true
echo "FAILOVER-$TOPO-DONE  evidence: $RES"
