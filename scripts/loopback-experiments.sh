#!/bin/bash
set -e
TOPO=${1:?topology central|star|mesh}
BIN=${BIN:-$HOME/pa2-fix/p2p}
SRC=${SRC:-$HOME/pa2-fix}
LAB=$HOME/pa2-lb
export LABP=$LAB
FULL=${FULL:-1}
RUNS=${RUNS:-$([ "$FULL" = 1 ] && echo 3 || echo 1)}
N1=2; N2=17
E1_NODE=6
CLIENTS=(3 4 5 6 7 8 9 10 11)
IBASE=56900
MB=56100; CB=56200; DB=56300
EXPECT_HDR='tag,ts_us,client,seq,name,op,ok,duration_us,bytes,query_us,dl_us,holder_ip,n_hits'
CSVMISS=0
RDIR=$LAB/results/$TOPO
CFG=$LAB/cfg
LOG=$LAB/logs
mkdir -p "$RDIR" "$CFG" "$LOG" "$LAB/manifests/$TOPO"
BINDIGEST=$(md5sum "$BIN" | cut -d' ' -f1)
hostms() { date +%s%3N; }
peerip() { echo "127.0.0.$1"; }

if [ "$FULL" = 1 ]; then
  NSMALL=300; SZ_SMALL=3072; NLARGE=20; SZ_LARGE=102400
  C1=10000; C2=10000; C3=1000; C4=10
else
  NSMALL=120; SZ_SMALL=1024; NLARGE=6;  SZ_LARGE=25600
  C1=1000;  C2=1000;  C3=200;  C4=5
fi

write_cfg() {
  local id=$1
  python3 - "$SRC" "$TOPO" "$id" "$MB" "$CB" "$DB" "$IBASE" "$LAB/$TOPO/node$id" <<'PY'
import sys, os
src, topo, nid, MB, CB, DB, IBASE, dat = sys.argv[1:9]
nid = int(nid); MB = int(MB); CB = int(CB); DB = int(DB); IBASE = int(IBASE)
def lb(ip):
    return '127.0.0.%d' % (int(ip.split('.')[-1]) - 100)
path = os.path.join(src, 'configs', topo, 'node%d.cfg' % nid)
lines = [l.strip() for l in open(path) if l.strip() and not l.startswith('#')]
out = []
for l in lines:
    k, _, v = l.partition('=')
    if k == 'index_ip':      l = 'index_ip=127.0.0.1'
    elif k == 'index_port':  l = 'index_port=%d' % IBASE
    elif k == 'my_ip':       l = 'my_ip=127.0.0.%d' % nid
    elif k == 'msg_port':    l = 'msg_port=%d' % (MB + nid)
    elif k == 'control_port': l = 'control_port=%d' % (CB + nid)
    elif k == 'download_port': l = 'download_port=%d' % (DB + nid)
    elif k == 'neighbors':
        out.append('neighbors=' + ','.join(
            '%s:%d' % (lb(x.strip()), MB + (int(x.strip().split('.')[-1]) - 100))
            for x in v.split(',') if x.strip()))
        continue
    elif k == 'ring':

        parts = [p.strip() for p in v.split(',')]
        out.append('ring=' + ','.join(
            '%s:%s:%d' % (p.split(':')[0], lb(p.split(':')[1]),
                          DB + int(p.split(':')[0])) for p in parts))
        continue
    elif k == 'extra_peers':
        out.append('extra_peers=127.0.0.2:%d' % (CB + 2))
        continue
    elif k in ('data_dir', 'downloads_dir'):
        continue
    out.append(l)
out.append('data_dir=%s/data' % dat)
out.append('downloads_dir=%s/dl' % dat)
open('%s/cfg/%s-node%d.cfg' % (os.environ.get('LABP'), topo, nid), 'w').write('\n'.join(out) + '\n')
PY
  echo "$CFG/$TOPO-node$id.cfg"
}
write_index_cfg() {
  sed -e 's|192\.168\.77\.101|127.0.0.1|' -e "s|^msg_port=.*|msg_port=$IBASE|" \
      "$SRC/configs/central/index.cfg" > "$CFG/$TOPO-index.cfg"
  echo "$CFG/$TOPO-index.cfg"
}

wait_port() {
  local ip=$1 port=$2 t=${3:-15} i=0
  while [ $i -lt $((t * 4)) ]; do
    if timeout 1 bash -c "echo > /dev/tcp/$ip/$port" 2>/dev/null; then return 0; fi
    sleep 0.25; i=$((i + 1))
  done
  return 1
}
pkill_all() {
  pkill -f "$BIN peer" 2>/dev/null || true
  pkill -f "$BIN index" 2>/dev/null || true
  sleep 1
  pkill -9 -f "$BIN peer" 2>/dev/null || true
  pkill -9 -f "$BIN index" 2>/dev/null || true
}

stats_snap() {
  local tag=$1 i
  : > "$RDIR/stats-$tag.txt"
  for i in $(seq $N1 $N2); do
    "$BIN" ping --target $(peerip $i):$((CB + i)) \
      >> "$RDIR/stats-$tag.txt" 2>&1 || echo "node $i UNREACHABLE" \
      >> "$RDIR/stats-$tag.txt"
  done
}
stats_delta() {
  python3 - "$RDIR/stats-before.txt" "$RDIR/stats-after.txt" \
            "$RDIR/stats-delta.txt" <<'PY'
import re, sys
FIELDS = ('routes', 'pending', 'neighbours', 'files',
          'repl_push', 'repl_skip', 'repl_recv',
          'drops_route', 'drops_hit')
def parse(p):
    out = {}
    for l in open(p):
        m = re.match(r'ping 127\.0\.0\.(\d+):\d+: OK routes=(\d+) pending=(\d+) '
                     r'neighbours=(\d+) files=(\d+) repl\(push=(\d+) skip=(\d+) '
                     r'recv=(\d+)[^)]*\) drops\(route=(\d+) hit=(\d+)\)', l)
        if m:
            n = m.group(1)
            out[n] = dict(zip(FIELDS, map(int, m.groups()[1:])))
    return out
b, a = parse(sys.argv[1]), parse(sys.argv[2])
with open(sys.argv[3], 'w') as f:
    f.write('# per-node deltas of the ping counters across the experiment set\n')
    f.write('# (ping snapshot before e1 / after e4). drops_route = routeMisses\n')
    f.write('# (flooded queries nobody answered), drops_hit = hits dropped by\n')
    f.write('# the collection window; repl_push = replicas this node pushed.\n')
    for n in sorted(b, key=int):
        d = {k: a.get(n, {}).get(k, 0) - b.get(n, {}).get(k, 0) for k in FIELDS}
        f.write('node %s %s\n' % (n, ' '.join('%s=%d' % kv for kv in d.items())))
PY
}

run_bench() {
  local expid=$1 opargs=$2 count=$3 manifest=$4 r=$5 base=$6; shift 6
  local pids=() i extra
  for i in "$@"; do
    extra="--seed $SEED"
    [ "${base:-0}" -gt 0 ] && extra="$extra --start-at $base"
    "$BIN" bench --target $(peerip $i):$((CB + i)) --clients 1 --count $count \
      $opargs --manifest "$LAB/manifests/$TOPO/$manifest" \
      --exclude-dir "$LAB/$TOPO/node$i/data" \
      $extra --out "$RDIR/${TOPO}-${expid}-vm${i}-run${r}.csv" \
      --label ${TOPO}-${expid} > "$RDIR/${TOPO}-${expid}-vm${i}-run${r}.log" 2>&1 &
    pids+=($!)
  done
  wait "${pids[@]}" || true
}
check_run() {
  local expid=$1 r=$2 count=$3; shift 3
  {
    echo "meta topo=$TOPO mode=loopback exp=$expid run=$r date=$(date -u '+%FT%TZ') seed=$SEED start_at_base=${START_BASE:-0} count=$count clients='$*' binary_md5=$BINDIGEST"
    local i hdr
    for i in "$@"; do
      hdr=$(head -1 "$RDIR/${TOPO}-${expid}-vm${i}-run${r}.csv" 2>/dev/null || echo MISSING)
      if [ "$hdr" != "$EXPECT_HDR" ]; then
        echo "  WARN vm$i bad csv header: $hdr"
        CSVMISS=$((CSVMISS + 1))
      fi
    done
    for i in "$@"; do
      grep -h 'BENCH-SUMMARY' "$RDIR/${TOPO}-${expid}-vm${i}-run${r}.log" 2>/dev/null | sed "s/^/  vm$i /" || true
      n=$(grep -c '^FAIL ' "$RDIR/${TOPO}-${expid}-vm${i}-run${r}.log" 2>/dev/null || true)
      [ "${n:-0}" -gt 0 ] && echo "  NOTE vm$i emitted $n FAIL lines (see run log)"
    done
  } >> "$RDIR/meta.txt"
  return 0
}
run_exp() {
  local expid=$1 opargs=$2 count=$3 manifest=$4 sync=$5; shift 5
  echo "== $TOPO $expid (runs=$RUNS count=$count nodes: $*) =="
  local r t0
  for r in $(seq 1 $RUNS); do
    t0=$(hostms)
    SEED=$(( $(date +%s) * 1000 + r ))
    START_BASE=0
    [ "$sync" = 1 ] && START_BASE=$(( $(hostms) + 2000 ))
    if [ "$expid" = e4 ]; then drop_caches_all; fi
    if [ "$expid" = e1 ]; then
      run_bench "$expid" "$opargs" "$count" "$manifest" "$r" "$START_BASE" "$E1_NODE"
      check_run "$expid" "$r" "$count" "$E1_NODE"
    else
      run_bench "$expid" "$opargs" "$count" "$manifest" "$r" "$START_BASE" "$@"
      check_run "$expid" "$r" "$count" "$@"
    fi
    echo "   run $r: $(( ($(hostms) - t0) / 1000 ))s (seed=$SEED)"
    sleep 2
  done
}
DROPCACHES=0
drop_caches_all() {
  sync
  if echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; then DROPCACHES=1; return; fi
  if echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null 2>&1; then
    DROPCACHES=1; return
  fi
  echo "WARN: drop_caches unavailable (unprivileged) - e4 'cold' rows share" \
       "one kernel page cache with the warm runs; recorded in meta.txt"
}

gen_manifests() {
  local D=$LAB/data-$TOPO n s a
  (cd "$D" && ls) | grep '^n' | sort > "$LAB/manifests/$TOPO/all.txt"
  (cd "$D" && ls | grep '^n[0-9]*_s' | sort) > "$LAB/manifests/$TOPO/small.txt"
  (cd "$D" && ls | grep '^n[0-9]*_b' | sort) > "$LAB/manifests/$TOPO/large.txt"
  s=$(wc -l < "$LAB/manifests/$TOPO/small.txt")
  n=$(wc -l < "$LAB/manifests/$TOPO/large.txt")
  a=$(wc -l < "$LAB/manifests/$TOPO/all.txt")
  if [ "$s" -ne $NSMALL ] || [ "$n" -ne $NLARGE ] || [ "$a" -ne $((NSMALL + NLARGE)) ]; then
    echo "FATAL: manifest size check failed (all=$a small=$s large=$n, expect $((NSMALL+NLARGE))/$NSMALL/$NLARGE)"; exit 1
  fi
  echo "manifests for $TOPO: all=$a small=$s large=$n"
}
gen_data() {
  local D=$LAB/data-$TOPO n id i
  if [ -f "$D/.done-$NSMALL-$NLARGE" ]; then
    echo "data for $TOPO already generated"
    gen_manifests; return
  fi
  rm -rf "$D"; mkdir -p "$D"
  for i in $(seq 1 $NSMALL); do
    id=$(( (i % (N2 - N1 + 1)) + N1 ))
    head -c $((SZ_SMALL * 1024)) /dev/urandom > "$D/n${id}_s$i"
  done
  for i in $(seq 1 $NLARGE); do
    id=$(( (i % (N2 - N1 + 1)) + N1 ))
    head -c $((SZ_LARGE * 1024)) /dev/urandom > "$D/n${id}_b$i"
  done
  gen_manifests
  touch "$D/.done-$NSMALL-$NLARGE"
}
link_data() {
  local D=$LAB/data-$TOPO i
  for i in $(seq $N1 $N2); do
    mkdir -p "$LAB/$TOPO/node$i/data" "$LAB/$TOPO/node$i/dl"
    rm -f "$LAB/$TOPO/node$i"/data/n*_*
    (cd "$LAB/$TOPO/node$i/data" && ln -f "$D"/n${i}_* . 2>/dev/null || true)
  done
}

echo "== starting $TOPO system on loopback (index + $((N2 - N1 + 1)) peers) =="
pkill_all
gen_data
link_data
ICFG=$(write_index_cfg)
T_START=$(date -u '+%FT%TZ')
"$BIN" index -c "$ICFG" > "$LOG/$TOPO-index.log" 2>&1 &
IDXPID=$!
wait_port 127.0.0.1 $IBASE 15 || { echo "FATAL: index not listening"; exit 1; }
export LABP=$LAB
for i in $(seq $N1 $N2); do
  cfg=$(write_cfg $i)
  [ -s "$cfg" ] || { echo "FATAL: config for node $i empty"; exit 1; }
  "$BIN" peer -c "$cfg" < /dev/null > "$LOG/$TOPO-node$i.log" 2>&1 &
  echo $! > "$LAB/$TOPO/node$i.pid"
done
for i in $(seq $N1 $N2); do
  wait_port $(peerip $i) $((CB + i)) 20 || echo "warn: node$i ctl port not up"
done
t0=$(date +%s); done_n=0
while :; do
  done_n=$(cat "$LOG/$TOPO"-node*.log 2>/dev/null | grep -c 'REPLICATION-DONE' || true)
  if [ "$done_n" -ge $((N2 - N1 + 1)) ]; then break; fi
  if [ $(( $(date +%s) - t0 )) -gt 600 ]; then echo "WARN: replication not done after 600s"; break; fi
  sleep 2
done
echo "replication first sweep done on $done_n peers in $(( $(date +%s) - t0 ))s"
sleep 2

{
  echo "=== loopback experiment meta ($(date -u '+%FT%TZ')) ==="
  echo "mode: SINGLE-HOST 127.0.0.0/8 loopback (NOT Chameleon); node ids and"
  echo "      topology graphs identical to configs/$TOPO (vmN == 127.0.0.N)"
  echo "binary md5: $BINDIGEST"
  echo "kernel: $(uname -r)  cpus: $(nproc)  start: $T_START"
  echo "data scale: small=$NSMALL x ${SZ_SMALL}KiB large=$NLARGE x ${SZ_LARGE}KiB"
  echo "counts: e1=$C1 e2=$C2 e3=$C3 e4=$C4 runs=$RUNS"
  echo "replication: ring ids $N1..$N2 rf=3; first sweep done on $done_n peers"
  echo "drop_caches available at run time: 1=yes 0=no (unprivileged)"
} > "$RDIR/meta.txt"

stats_snap before
run_exp e1 ""            $C1 small.txt 0
run_exp e2 ""            $C2 small.txt 1 "${CLIENTS[@]}"
run_exp e3 "--op obtain" $C3 small.txt 1 "${CLIENTS[@]}"
run_exp e4 "--op obtain" $C4 large.txt 0 "${CLIENTS[@]}"
stats_snap after
stats_delta
echo "DROPCACHES=$DROPCACHES" >> "$RDIR/meta.txt"

pkill_all
echo "results: $RDIR"
if [ "$CSVMISS" -gt 0 ]; then
  echo "meta topo=$TOPO mode=loopback exp=EVAL date=$(date -u '+%FT%TZ') csv_missing=$CSVMISS result=FAIL" >> "$RDIR/meta.txt"
  echo "EVAL-FAIL ($TOPO loopback): $CSVMISS missing/bad per-node CSVs - see WARN lines above"
  exit 1
fi
echo "meta topo=$TOPO mode=loopback exp=EVAL date=$(date -u '+%FT%TZ') csv_missing=0 result=PASS" >> "$RDIR/meta.txt"
echo "EVAL-OK ($TOPO loopback)"
