#!/bin/bash
set -e
cd ~/pa2
TOPO=${1:?topology central|star|mesh}
if [ -z "${PA2_DRV_HELD:-}" ]; then
  PA2_DRV_LOCK=${PA2_DRV_LOCK:-/tmp/pa2-driver.lock}
  exec 9>"$PA2_DRV_LOCK"
  flock -n 9 || { echo "FATAL: another driver holds $PA2_DRV_LOCK - refusing to start"; exit 1; }
  export PA2_DRV_HELD=1
fi
RUNS=${RUNS:-3}
RUNS_E4=${RUNS_E4:-$RUNS}
RDIR=~/pa2/results/$TOPO
mkdir -p "$RDIR"
SSH='ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10'
E1_NODE=6
CLIENTS=(3 4 5 6 7 8 9 10 11)
ALLPEERS=$(seq 2 17)
EXPECT_HDR='tag,ts_us,client,seq,name,op,ok,duration_us,bytes,query_us,dl_us,holder_ip,n_hits'
BINDIGEST=$(md5sum ~/pa2/p2p | cut -d' ' -f1)
if [ -n "${BINGMD5:-}" ] && [ "$BINDIGEST" != "$BINGMD5" ]; then
  echo "FATAL: ~/pa2/p2p md5 $BINDIGEST != pinned BINGMD5 $BINGMD5 - void run"; exit 1
fi
CSVMISS=0
FAILALL=0
echo "binary md5: $BINDIGEST" | tee -a "$RDIR/meta.txt"

hostms() { date +%s%3N; }

start_at_for() {
  local base=$1 node=$2 ip
  ip=192.168.77.$((100+node))
  local h1 vm h2 off
  h1=$(hostms); vm=$($SSH cc@$ip date +%s%3N); h2=$(hostms)
  off=$(( (h1 + h2) / 2 - vm ))
  echo $(( base + off ))
}

drop_caches_all() {
  local pids=() i
  for i in $ALLPEERS; do
    $SSH cc@192.168.77.$((100+i)) \
      "sync; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'" >/dev/null 2>&1 &
    pids+=($!)
  done
  wait "${pids[@]}" || true
  echo "page caches dropped on all 16 peers"
}

stats_snap() {
  local tag=$1 i ip
  : > "$RDIR/stats-$tag.txt"
  for i in $ALLPEERS; do
    ip=192.168.77.$((100+i))
    {
      echo "vm$i"
      $SSH cc@$ip "~/pa2/p2p ping --target 127.0.0.1:51001" 2>&1 \
        || echo "vm$i UNREACHABLE"
    } >> "$RDIR/stats-$tag.txt"
  done
}
stats_delta() {
  python3 - "$RDIR/stats-before.txt" "$RDIR/stats-after.txt" \
            "$RDIR/stats-delta.txt" <<'PY'
import re, sys
FIELDS = ('routes', 'pending', 'neighbours', 'files',
          'repl_push', 'repl_skip', 'repl_recv',
          'drops_route', 'drops_hit',
          'q_recv', 'q_fwd', 'q_dup', 'h_orig', 'h_relay')
RE = re.compile(r'^ping \S+: OK routes=(\d+) pending=(\d+) '
                r'neighbours=(\d+) files=(\d+) repl\(push=(\d+) skip=(\d+) '
                r'recv=(\d+)[^)]*\) drops\(route=(\d+) hit=(\d+)\)'
                r'(?: queries\(recv=(\d+) fwd=(\d+) dup=(\d+)\)'
                r' hits\(orig=(\d+) relay=(\d+)\))?')
def parse(p):
    out, cur = {}, None
    for l in open(p):
        m = re.match(r'^vm(\d+)', l)
        if m:
            cur = m.group(1)
            continue
        m = RE.match(l)
        if m and cur:
            vals = [int(g) if g is not None else 0 for g in m.groups()]
            out[cur] = dict(zip(FIELDS, vals))
    return out
b, a = parse(sys.argv[1]), parse(sys.argv[2])
with open(sys.argv[3], 'w') as f:
    f.write('# per-vm deltas of the ping counters across the experiment set\n')
    f.write('# (ping snapshot before e1 / after e4). drops_route = routeMisses\n')
    f.write('# (flooded queries nobody answered), drops_hit = hits dropped by\n')
    f.write('# the collection window; repl_push = replicas this node pushed.\n')
    f.write('# Query plane (v3 binary): q_recv = queries accepted here (TTL\n')
    f.write('# decremented, dedup done), q_fwd = per-neighbour re-sends, q_dup =\n')
    f.write('# already-seen drops; h_orig = local answers (this peer holds the\n')
    f.write('# file), h_relay = HITQUERY hops forwarded for other peers.\n')
    for n in sorted(b, key=int):
        d = {k: a.get(n, {}).get(k, 0) - b.get(n, {}).get(k, 0) for k in FIELDS}
        f.write('vm %s %s\n' % (n, ' '.join('%s=%d' % kv for kv in d.items())))
PY
}

run_bench() {
  local expid=$1 opargs=$2 count=$3 manifest=$4 r=$5 base=$6; shift 6
  local pids=() i ip extra cmd
  for i in "$@"; do
    ip=192.168.77.$((100+i))
    extra=""
    if [ "$base" -gt 0 ]; then
      extra="--seed $SEED --start-at $(start_at_for "$base" "$i")"
    else
      extra="--seed $SEED"
    fi
    cmd="~/pa2/p2p bench --target 127.0.0.1:51001 --clients 1 --count $count \
$opargs --manifest ~/pa2/manifests/$manifest --exclude-dir /data/shared \
$extra --out ~/pa2/res/${TOPO}-${expid}-vm${i}-run${r}.csv \
--label ${TOPO}-${expid}"
    ( $SSH cc@$ip "$cmd" > "$RDIR/${TOPO}-${expid}-vm${i}-run${r}.log" 2>&1 ) &
    pids+=($!)
  done
  wait "${pids[@]}" || true
}

check_run() {
  local expid=$1 r=$2 count=$3; shift 3
  local i ip hdr sum
  {
    echo "meta topo=$TOPO exp=$expid run=$r date=$(date -u '+%FT%TZ') \
seed=$SEED start_at_base=${START_BASE:-0} count=$count clients='$*' \
binary_md5=$BINDIGEST"
    for i in "$@"; do
      ip=192.168.77.$((100+i))
      hdr=$($SSH cc@$ip "head -1 ~/pa2/res/${TOPO}-${expid}-vm${i}-run${r}.csv" \
        2>/dev/null || echo MISSING)
      if [ "$hdr" != "$EXPECT_HDR" ]; then
        echo "  CSVBAD vm$i unexpected csv header: $hdr"
        CSVMISS=$((CSVMISS + 1))
      fi
    done
    for i in "$@"; do
      sum=$(grep -h 'BENCH-SUMMARY' \
        "$RDIR/${TOPO}-${expid}-vm${i}-run${r}.log" 2>/dev/null || true)
      [ -n "$sum" ] && echo "  vm$i $sum"
    done
    for i in "$@"; do
      n=$(grep -c '^FAIL ' \
        "$RDIR/${TOPO}-${expid}-vm${i}-run${r}.log" 2>/dev/null || true)
      if [ "${n:-0}" -gt 0 ]; then
        echo "  FAILNOTE vm$i emitted $n FAIL lines (see run log)"
        FAILALL=$((FAILALL + n))
      fi
    done
  } >> "$RDIR/meta.txt"
  return 0
}

run_exp() {
  local expid=$1 opargs=$2 count=$3 manifest=$4 syncrelays=$5; shift 5
  local runcount=$RUNS
  [ "$expid" = e4 ] && runcount=$RUNS_E4
  echo "== $TOPO $expid (runs=$runcount, nodes: $*) =="
  local r t0
  for r in $(seq 1 $runcount); do
    t0=$(hostms)
    SEED=$(( $(date +%s) * 1000 + r ))
    START_BASE=0
    if [ "$syncrelays" = "1" ]; then
      START_BASE=$(( $(hostms) + 5000 ))
    fi
    if [ "$expid" = "e4" ]; then
      drop_caches_all
    fi
    if [ "$expid" = "e1" ]; then
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

stats_snap before
run_exp e1 ""            10000 small.txt 0

case "$TOPO" in
  central) SAMPLE_VMS="1 2 6 10" ;;
  star)    SAMPLE_VMS="2 3 6 10" ;;
  mesh)    SAMPLE_VMS="7 2 6 10" ;;
esac
for i in $SAMPLE_VMS; do
  rm -f "$RDIR/cpu-e2-vm$i.txt"
  ( $SSH cc@192.168.77.$((100+$i)) 'bash -s' <<'EOF' > "$RDIR/cpu-e2-vm$i.txt" 2>&1
HZ=$(getconf CLK_TCK)
while [ ! -f /tmp/cpu.sample.stop ]; do
  pid=$(pgrep -x p2p | head -1)
  if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
    a=$(awk '{print $14+$15}' "/proc/$pid/stat")
    sleep 1
    b=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || echo "$a")
    awk -v a="$a" -v b="$b" -v hz="$HZ" \
      'BEGIN{d=($b-$a)/hz; if(d<0)d=0; printf "cpu %.1f\n", 100*d}'
  else
    sleep 1
  fi
done
rm -f /tmp/cpu.sample.stop
EOF
  ) &
done
echo "meta topo=$TOPO exp=e2-cpu date=$(date -u '+%FT%TZ') samplers='$SAMPLE_VMS' window=e2-bench" >> "$RDIR/meta.txt"
run_exp e2 ""            10000 small.txt 1 "${CLIENTS[@]}"
for i in $SAMPLE_VMS; do
  $SSH cc@192.168.77.$((100+$i)) 'touch /tmp/cpu.sample.stop' >/dev/null 2>&1 || true
done
sleep 2

run_exp e3 "--op obtain" 10000 small.txt 1 "${CLIENTS[@]}"
run_exp e4 "--op obtain" 10    large.txt 0 "${CLIENTS[@]}"
stats_snap after
stats_delta

echo "fetching results to host..."
bash "$HOME/pa2/scripts/fetch-results.sh" || true
for d in results/vm*; do
  cp "$d"/res/${TOPO}-*.csv "$RDIR/" 2>/dev/null || true
done
T_E1=$(ls "$RDIR"/${TOPO}-e1-vm*-run*.csv 2>/dev/null | wc -l)
T_E2=$(ls "$RDIR"/${TOPO}-e2-vm*-run*.csv 2>/dev/null | wc -l)
T_E3=$(ls "$RDIR"/${TOPO}-e3-vm*-run*.csv 2>/dev/null | wc -l)
T_E4=$(ls "$RDIR"/${TOPO}-e4-vm*-run*.csv 2>/dev/null | wc -l)
T_WANT=$(( RUNS + 18 * RUNS + 9 * RUNS_E4 ))
T_HAVE=$(( T_E1 + T_E2 + T_E3 + T_E4 ))
if [ "$T_HAVE" -ne "$T_WANT" ] || [ "$CSVMISS" -ne 0 ] || [ "$FAILALL" -ne 0 ]; then
  echo "meta topo=$TOPO exp=EVAL date=$(date -u '+%FT%TZ') csv_have=$T_HAVE csv_want=$T_WANT csv_missing_headers=$CSVMISS bench_fail_lines=$FAILALL result=FAIL" >> "$RDIR/meta.txt"
  echo "EVAL-FAIL ($TOPO): csv_have=$T_HAVE csv_want=$T_WANT csvbad=$CSVMISS faillines=$FAILALL"
  exit 1
fi
echo "meta topo=$TOPO exp=EVAL date=$(date -u '+%FT%TZ') csv_have=$T_HAVE csv_want=$T_WANT csv_missing_headers=0 bench_fail_lines=0 result=PASS" >> "$RDIR/meta.txt"
echo "EVAL-OK ($TOPO) csv=$T_HAVE/$T_WANT faillines=0"
