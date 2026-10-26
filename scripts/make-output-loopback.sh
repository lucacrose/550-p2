#!/bin/bash
set -u
TOPO=${1:?usage: make-output-loopback.sh <central|star|mesh>}
ROOT=${ROOT:-$HOME/pa2-fix}
BIN=$ROOT/p2p
S=$HOME/pa2-out-lb/$TOPO
MB=58100; CB=58200; DB=58300; IBASE=58000
N1=2; N2=17
OUT=$S/output.txt
BINDIGEST=$(md5sum $BIN | cut -d' ' -f1)
mkdir -p $S/cfg $S/logs $S/data $S/man
rm -rf $S/data/peer*
export LABP=$S

log() { echo "$*" >> $OUT; }

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
open(os.environ['LABP'] + '/cfg/out-%s-node%d.cfg' % (topo, nid), 'w').write('\n'.join(out) + '\n')
PY
}
write_index_cfg() {
  sed -e 's|192\.168\.77\.101|127.0.0.1|' -e "s|^msg_port=.*|msg_port=$IBASE|" \
      "$ROOT/configs/central/index.cfg" > $S/cfg/out-index.cfg
}
wait_port() { local ip=$1 port=$2 i=0
  while [ $i -lt 80 ]; do timeout 1 bash -c "echo > /dev/tcp/$ip/$port" 2>/dev/null \
    && return 0; sleep 0.25; i=$((i+1)); done; return 1; }
peer_ctl() { echo "127.0.0.$1:$((CB + $1))"; }
alive() { [ -f $S/node$1.pid ] && kill -0 $(cat $S/node$1.pid) 2>/dev/null; }
kill_peer() { local id=$1
  if alive $id; then kill -9 $(cat $S/node$id.pid) 2>/dev/null || true; fi; }

ping_all() { local tag=$1 i
  log "--- ping status of every peer ($tag) ---"
  for i in $(seq $N1 $N2); do
    $BIN ping --target $(peer_ctl $i) >> $OUT 2>&1 || log "peer$i: no reply"
  done
  echo >> $OUT
}

BASE=$S/base; mkdir -p $BASE
if [ ! -f $BASE/.done ]; then
  for i in $(seq 1 48); do
    id=$(( (i % (N2 - N1 + 1)) + N1 ))
    head -c 307200 /dev/urandom > $BASE/n${id}_s$i
  done
  touch $BASE/.done
fi
for i in $(seq $N1 $N2); do
  mkdir -p $S/data/peer$i/dl
  (cd $S/data/peer$i && ln -f $BASE/n${i}_* . 2>/dev/null || cp $BASE/n${i}_* .)
done
head -c 20971520 /dev/urandom > $S/data/peer9/n9_wide1.bin
cp $S/data/peer9/n9_wide1.bin $S/data/peer9/n9_wide2.bin
head -c 1048576 /dev/urandom > $S/data/peer12/ghost.bin
printf 'n9_wide1.bin\n' > $S/man/wide1.txt

for i in $(seq $N1 $N2); do write_cfg $i; done
write_index_cfg
pkill -f "$BIN peer -c $S/cfg/" 2>/dev/null || true
pkill -f "$BIN index -c $S/cfg/out-index.cfg" 2>/dev/null || true
sleep 1
$BIN index -c $S/cfg/out-index.cfg > $S/logs/index.log 2>&1 &
echo $! > $S/index.pid
wait_port 127.0.0.1 $IBASE || { echo "FATAL: index not up"; exit 1; }
for i in $(seq $N1 $N2); do
  if [ $i = 16 ]; then continue; fi
  $BIN peer -c $S/cfg/out-$TOPO-node$i.cfg < /dev/null > $S/logs/node$i.log 2>&1 &
  echo $! > $S/node$i.pid
  sleep 0.15
done
mkfifo $S/cmd.fifo
stdbuf -oL $BIN peer -c $S/cfg/out-$TOPO-node16.cfg --cli < $S/cmd.fifo \
    >> $S/logs/session.log 2>&1 &
echo $! > $S/node16.pid
exec 3<>$S/cmd.fifo
send() { echo "$1" >&3; }
for i in $(seq $N1 $N2); do
  wait_port 127.0.0.$i $((CB + i)) || { echo "FATAL: peer$i control port down"; exit 1; }
done
t0=$(date +%s); dn=0
while :; do
  dn=$(cat $S/logs/node*.log 2>/dev/null | grep -c 'REPLICATION-DONE' || true)
  [ "${dn:-0}" -ge $((N2-N1+1)) ] && break
  [ $(( $(date +%s) - t0 )) -gt 240 ] && break
  sleep 2
done

: > $OUT
log "=== PA2 demo session ($TOPO topology, rf=3) ==="
log "run $(date -u '+%F %T UTC') on a single WSL host via 127.0.0.<id> loopback"
log "addresses: my_ip=127.0.0.<node_id>, ports base msg=$MB ctl=$CB dl=$DB, index 127.0.0.1:$IBASE"
log "binary md5: $BINDIGEST"
log "replication first sweep completed on $dn/16 peers in $(( $(date +%s) - t0 ))s"
echo >> $OUT
ping_all pre-kill

log "--- operator session on peer16 (127.0.0.16:$((CB+16))) ---"
start=$(wc -l < $S/logs/session.log)
send "query n9_wide1.bin"; sleep 3
send "obtain n9_wide1.bin"
for i in 1 2 3 4 5 6 7 8 9 10; do
  tail -n +$start $S/logs/session.log | grep -q "display file 'n9_wide1.bin'" && break
  sleep 1
done
send "query n12_s1"; sleep 3
send "obtain n12_s1"; sleep 4
tail -n +$start $S/logs/session.log >> $OUT
echo >> $OUT

log "--- failover: owner of n9_wide* dies (kill -9 peer09) ---"
kill_peer 9; sleep 2
$BIN ping --target $(peer_ctl 9) >> $OUT 2>&1 || log "peer09: no reply (process dead)"
start=$(wc -l < $S/logs/session.log)
send "query n9_wide2.bin"; sleep 3
send "obtain n9_wide2.bin"
for i in $(seq 1 15); do
  tail -n +$start $S/logs/session.log | grep -q "display file 'n9_wide2.bin'" && break
  sleep 1
done
tail -n +$start $S/logs/session.log >> $OUT
echo >> $OUT

log "--- negative control: unreplicated file (fails the n<id>_* ownership rule) ---"
start=$(wc -l < $S/logs/session.log)
send "query ghost.bin"; sleep 3
kill_peer 12; sleep 2
send "query ghost.bin"; sleep 3
send "obtain ghost.bin"; sleep 4
tail -n +$start $S/logs/session.log >> $OUT
echo >> $OUT

log "--- restoration: restart peer09, poll obtain n9_wide1.bin ---"
t0=$(date +%s)
$BIN peer -c $S/cfg/out-$TOPO-node9.cfg < /dev/null >> $S/logs/node9.restart.log 2>&1 &
echo $! > $S/node9.pid
wait_port 127.0.0.9 $((CB + 9)) || log "peer09 control port did not return"
ok=0
for i in $(seq 1 60); do
  start=$(wc -l < $S/logs/session.log)
  send "obtain n9_wide1.bin"
  sleep 3
  if tail -n +$start $S/logs/session.log | grep -q "display file 'n9_wide1.bin'"; then
    ok=1; break
  fi
done
log "restore: first successful obtain after $(( $(date +%s) - t0 ))s (ok=$ok)"
start=$(wc -l < $S/logs/session.log)
send "query n9_wide1.bin"; sleep 3
send "stat"; sleep 1
send "quit"; sleep 1
exec 3>&-
tail -n +$start $S/logs/session.log >> $OUT
echo >> $OUT
ping_all post-restore
log "--- replication protocol counters (peer logs, per peer) ---"
grep -h 'REPLICATION' $S/logs/node*.log | grep -v 'display' | sort | uniq -c | head -12 >> $OUT
pkill -f "$BIN peer -c $S/cfg/" 2>/dev/null || true
pkill -f "$BIN index -c $S/cfg/out-index.cfg" 2>/dev/null || true
echo "OUTPUT-DEMO-DONE $TOPO $(md5sum $OUT | cut -d' ' -f1)"
