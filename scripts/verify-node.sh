#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$ROOT/p2p
V=$ROOT/verify
N=${1:-8}
PINGER="$ROOT/scripts/pinger.py"

rm -rf "$V"
mkdir -p "$V/logs" "$V/csv" "$V/session" "$V/cfg" "$V/manifests"

FAILS=0
gate() {
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $desc" | tee -a "$V/gates.txt"
  else
    echo "FAIL: $desc" | tee -a "$V/gates.txt"
    FAILS=$((FAILS + 1))
  fi
}

wait_port() {
  local ip=$1 port=$2 t=$3
  local end=$((SECONDS + t))
  while [ $SECONDS -lt $end ]; do
    if (exec 3<>/dev/tcp/$ip/$port) 2>/dev/null; then exec 3>&- 3<&-; return 0; fi
    sleep 0.3
  done
  return 1
}

mkdata() {
  local d=$1; mkdir -p "$d"
  local k
  for k in 1 2 3 4; do head -c 256 /dev/zero | tr '\0' "f$k" > "$d/file$k"; done
  for k in 0 1 2 3 4; do head -c 1048576 /dev/zero | tr '\0' 'B' > "$d/fileb_$k"; done
}

mkuniq() {
  local d=$1/node$2
  head -c 4096    /dev/zero | tr '\0' 's' > "$d/n${2}_s1"
  head -c 1048576 /dev/zero | tr '\0' 'b' > "$d/n${2}_b0"
}

RF=1
RING_IDS=""
FALLBACK=1
MARKDIR=""
ring_spec() {
  local base=$1 out="" n
  for n in $RING_IDS; do
    [ -n "$out" ] && out="$out,"
    out="$out$n:127.0.0.1:$((base + 300 + n))"
  done
  echo "$out"
}

write_peer_cfg() {
  local topo=$1 base=$2 dat=$3 id=$4; shift 4
  local f=$V/cfg/${CFGNAME:-$topo}-node$id.cfg
  {
    echo "topology=$topo"
    if [ "$topo" = central ]; then
      echo "index_ip=127.0.0.1"
      echo "index_port=$((base + 900))"
    fi
    echo "node_id=$id"
    echo "my_ip=127.0.0.1"
    echo "msg_port=$((base + 100 + id))"
    echo "control_port=$((base + 200 + id))"
    echo "download_port=$((base + 300 + id))"
    echo "data_dir=$dat/node$id"
    echo "downloads_dir=$dat/dl$id"
    echo "ttl=8"
    echo "query_timeout_ms=8000"
    echo "keep_downloads=0"
    echo "journal_path=$dat/.p2p-repl-node$id.meta"
    echo "ring_fallback=$FALLBACK"
    if [ -n "$MARKDIR" ]; then
      echo "rescan_marker=$MARKDIR/node$id.rescan"
      echo "gc_dry_marker=$MARKDIR/node$id.gc-dry"
      echo "gc_marker=$MARKDIR/node$id.gc"
    fi
    if [ "$RF" -gt 1 ] && [ -n "$RING_IDS" ]; then
      echo "replication_factor=$RF"
      echo "ring=$(ring_spec "$base")"
    fi
    local nlist=""
    for n in "$@"; do
      [ -n "$nlist" ] && nlist="$nlist,"
      nlist="$nlist""127.0.0.1:$((base + 100 + n))"
    done
    [ -n "$nlist" ] && echo "neighbors=$nlist"
  } > "$f"
  echo "$f"
}

start_peer() {
  local cfgf=$1 logf=$2 pid n=0
  while :; do
    "$BIN" peer -c "$cfgf" < /dev/null > "$logf" 2>&1 &
    pid=$!
    sleep 1.2
    if kill -0 "$pid" 2>/dev/null; then echo "$pid"; return 0; fi
    n=$((n + 1))
    {
      echo "== start_peer retry $n for $cfgf ($(date -u +%TZ)) =="
      ss -ltnp | grep -E "p2p|:5[1-6][0-9]{3} " || true
    } >> "$V/logs/port-squat.log" 2>&1
    if [ "$n" -ge 3 ]; then
      echo "FATAL: peer $cfgf keeps dying - see $V/logs/port-squat.log" >&2
      exit 1
    fi
    sleep 2
  done
}

killall_p2p() {
  pkill -f "p2p peer" 2>/dev/null
  pkill -f "p2p index" 2>/dev/null
  sleep 0.7
  pkill -9 -f "p2p peer" 2>/dev/null
  pkill -9 -f "p2p index" 2>/dev/null
  sleep 0.3
}

exec 9>/tmp/verify-node.lock
if ! flock -n 9; then
  echo "FATAL: another verify-node.sh instance is running - aborting" >&2
  exit 1
fi

ports_busy() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":5[1-6][0-9]{3}$"; }
wait_ports_free() {
  local i=0
  while ports_busy; do
    i=$((i + 1))
    if [ "$i" -gt 15 ]; then
      echo "FATAL: verify ports still occupied after killall_p2p:" >&2
      ss -ltnp 2>/dev/null | grep -E ":5[1-6][0-9]{3} " >&2 || true
      exit 1
    fi
    sleep 1
  done
}

ENVFILE=$V/environment.txt
{
  echo "== verification environment =="
  date -u '+utc=%Y-%m-%dT%H:%M:%SZ'
  uname -srm
  [ -r /etc/os-release ] && grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
  md5sum "$BIN" | awk '{print "binary_md5="$1}'
  g++ --version | head -1
  make --version | head -1
  python3 --version
  lscpu 2>/dev/null | grep -E '^(Model name|Architecture|CPU\(s\)|MHz)' || true
} > "$ENVFILE" 2>&1

killall_p2p
wait_ports_free
[ -x "$BIN" ] || { echo "FATAL: $BIN missing - run make first" >&2; exit 1; }

echo "=== stage A: chain TTL / deep-hit verification ==="
CH=$V/chain-data; mkdir -p "$CH"
RF=1; RING_IDS=""; FALLBACK=0
for i in 1 2 3 4 5 6 7 8; do mkdata "$CH/node$i"; done
head -c 1048576 /dev/zero | tr '\0' 'D' > "$CH/node8/deep7"
head -c 4096  /dev/zero | tr '\0' 'd' > "$CH/node8/deep8"
head -c 4096  /dev/zero | tr '\0' 'x' > "$CH/node5/deep4"
pids=""
for i in 1 2 3 4 5 6 7 8; do
  nb=""
  [ $i -gt 1 ] && nb="$((i - 1))"
  [ $i -lt 8 ] && nb="$nb $((i + 1))"
  cfg=$(write_peer_cfg chain 51000 "$CH" "$i" $nb)
  pids="$pids $(start_peer "$cfg" "$V/logs/chain-p$i.log")"
  wait_port 127.0.0.1 $((51000 + 200 + i)) 10 || echo "warn: p$i ctrl not up"
done
sleep 3
A=$V/A-chain.txt
echo "-- ping every peer (liveness + stats probe)" > "$A"
for i in 1 2 3 4 5 6 7 8; do
  "$BIN" ping --target 127.0.0.1:$((51000 + 200 + i)) >> "$A" 2>&1
done
echo "-- pinger from p1 x3 ttl=peer default(8): deep7/deep8 (7 hops) + deep4 (4 hops) + file2 (1 hop) must ALL hit" >> "$A"
python3 "$PINGER" 127.0.0.1 51201 3 deep7 deep8 deep4 file2 > "$V/pinger-ttl8.txt" 2>&1
cat "$V/pinger-ttl8.txt" >> "$A"
echo "-- negative control: TTL 6 from p1 dies before p8 (query arrives at p7" >> "$A"
echo "   with ttl<=0): deep7/deep8 must TIMEOUT, deep4 (4 hops) must still HIT" >> "$A"
python3 "$PINGER" 127.0.0.1 51201 2 deep7 deep8 deep4 --ttl 6 > "$V/pinger-ttl6.txt" 2>&1
cat "$V/pinger-ttl6.txt" >> "$A"
echo "-- deep obtain at p1: 1 client x 1 obtain of deep7 (7-hop search, 1 MiB fetch)" >> "$A"
echo deep7 > "$V/manifests/deep7.txt"
"$BIN" bench --target 127.0.0.1:51201 --clients 1 --count 1 --op obtain \
  --manifest "$V/manifests/deep7.txt" --label chain-deep7 \
  --out "$V/csv/chain-deep7.csv" > "$V/logs/bench-chain.log" 2>&1
cat "$V/logs/bench-chain.log" >> "$A"
sleep 1
grep "display file" "$V/logs/chain-p1.log" > "$V/A-obtain.txt" 2>&1 || true
cat "$V/A-obtain.txt" >> "$A"
killall_p2p
echo "stage A done"

gate "A: TTL8 query reaches deep7 (7 hops)"      grep -q "RESULT deep7 ttl=0 ok=3/3" "$V/pinger-ttl8.txt"
gate "A: TTL8 query reaches deep8"               grep -q "RESULT deep8 ttl=0 ok=3/3" "$V/pinger-ttl8.txt"
gate "A: TTL8 query reaches deep4"               grep -q "RESULT deep4 ttl=0 ok=3/3" "$V/pinger-ttl8.txt"
gate "A: TTL8 shallow control (file2)"           grep -q "RESULT file2 ttl=0 ok=3/3" "$V/pinger-ttl8.txt"
gate "A: TTL6 cannot reach deep7 (negative)"     grep -q "RESULT deep7 ttl=6 ok=0/2" "$V/pinger-ttl6.txt"
gate "A: TTL6 cannot reach deep8 (negative)"     grep -q "RESULT deep8 ttl=6 ok=0/2" "$V/pinger-ttl6.txt"
gate "A: TTL6 still reaches deep4 (control)"     grep -q "RESULT deep4 ttl=6 ok=2/2" "$V/pinger-ttl6.txt"
gate "A: deep obtain ok=1"                       grep -q "ops=1 ok=1" "$V/logs/bench-chain.log"
gate "A: display file deep7 printed"             grep -q "display file 'deep7'" "$V/A-obtain.txt"

run_topology() {
  local topo=$1 base=$2
  killall_p2p
  wait_ports_free
  local dat=$V/$topo-data
  local S=$((N + 1))
  mkdir -p "$dat"
  for i in $(seq 1 "$N"); do mkdata "$dat/node$i"; mkuniq "$dat" "$i"; done
  mkdir -p "$dat/node$S"; mkuniq "$dat" "$S"
  RF=3; RING_IDS="$(seq 1 "$N") $S"
  local idxpid=""
  if [ "$topo" = central ]; then
    {
      echo "node_id=101"
      echo "my_ip=127.0.0.1"
      echo "msg_port=$((base + 900))"
    } > "$V/cfg/$topo-index.cfg"
    local n=0
    while :; do
      "$BIN" index -c "$V/cfg/$topo-index.cfg" > "$V/logs/$topo-index.log" 2>&1 &
      idxpid=$!
      sleep 1.2
      if kill -0 "$idxpid" 2>/dev/null; then break; fi
      n=$((n + 1))
      if [ "$n" -ge 3 ]; then
        echo "FATAL: index server keeps dying" >&2
        exit 1
      fi
      sleep 2
    done
    wait_port 127.0.0.1 $((base + 900)) 10 || echo "warn: index not up"
    sleep 1
    for i in $(seq 1 "$N"); do
      cfg=$(write_peer_cfg "$topo" "$base" "$dat" "$i")
      start_peer "$cfg" "$V/logs/$topo-p$i.log" > /dev/null
      wait_port 127.0.0.1 $((base + 200 + i)) 10 || echo "warn: $topo p$i ctrl not up"
    done
  elif [ "$topo" = star ]; then
    for i in $(seq 1 "$N"); do
      local nb
      if [ "$i" = 1 ]; then
        nb="$(seq 2 "$N") $S"
      else
        nb=1
      fi
      cfg=$(write_peer_cfg "$topo" "$base" "$dat" "$i" $nb)
      start_peer "$cfg" "$V/logs/$topo-p$i.log" > /dev/null
      wait_port 127.0.0.1 $((base + 200 + i)) 10 || echo "warn: $topo p$i ctrl not up"
    done
  else
    for i in $(seq 1 "$N"); do
      local a b c extra=""
      a=$(( (i % N) + 1 ))
      b=$(( ((i + N - 2) % N) + 1 ))
      c=$(( ((i + N / 2 - 1) % N) + 1 ))
      [ "$i" = 1 ] && extra=$S
      cfg=$(write_peer_cfg "$topo" "$base" "$dat" "$i" $a $b $c $extra)
      start_peer "$cfg" "$V/logs/$topo-p$i.log" > /dev/null
      wait_port 127.0.0.1 $((base + 200 + i)) 10 || echo "warn: $topo p$i ctrl not up"
    done
  fi
  sleep 3

  local scfg
  if [ "$topo" = central ]; then
    scfg=$(write_peer_cfg "$topo" "$base" "$dat" "$S")
  else
    scfg=$(write_peer_cfg "$topo" "$base" "$dat" "$S" 1)
  fi
  local F=$V/$topo.cli.fifo
  mkfifo "$F" 2>/dev/null
  local sn=0 spid
  while :; do
    ( timeout 300 "$BIN" peer -c "$scfg" --cli < "$F" > "$V/session/$topo.txt" 2>&1 ) &
    spid=$!
    sleep 1.2
    if kill -0 "$spid" 2>/dev/null; then break; fi
    sn=$((sn + 1))
    if [ "$sn" -ge 3 ]; then
      echo "FATAL: session peer keeps dying" >&2
      exit 1
    fi
    sleep 2
  done
  ( sleep 12; python3 "$PINGER" 127.0.0.1 $((base + 201)) 1 "hot_$topo" \
      > "$V/session/$topo-propagate-pre.txt" 2>&1 ) &
  local prepid=$!
  ( sleep 40; python3 "$PINGER" 127.0.0.1 $((base + 201)) 1 "hot_$topo" \
      > "$V/session/$topo-propagate-post.txt" 2>&1 ) &
  local postpid=$!
  (
    sleep 4
    echo "stat";                                   sleep 1
    echo "query n2_s1";                            sleep 2
    echo "obtain n2_b0";                           sleep 6
    echo "query n${N}_s1";                         sleep 2
    echo "query hot_$topo";                        sleep 9
    head -c 4096 /dev/zero | tr '\0' 'H' > "$dat/node$S/hot_$topo"
    sleep 1
    echo "rescan";                                 sleep 2
    echo "query hot_$topo";                        sleep 2
    sleep 20
    echo "quit"
  ) > "$F" &
  local wpid=$!
  wait $spid 2>/dev/null || true
  wait $wpid 2>/dev/null || true
  wait $prepid 2>/dev/null || true
  wait $postpid 2>/dev/null || true
  rm -f "$F"

  for i in $(seq 2 "$N"); do echo "n${i}_s1"; done > "$V/manifests/$topo-q.txt"
  for i in $(seq 2 "$N"); do echo "n${i}_b0"; done > "$V/manifests/$topo-o.txt"
  local tgts cnt cnt_ob cl
  if [ "$topo" = central ]; then
    tgts="1"; cnt=900; cnt_ob=200; cl=4
  elif [ "$topo" = star ]; then
    tgts="$(seq 2 "$N")"; cnt=225; cnt_ob=50; cl=3
  else
    tgts="$(seq 1 "$N")"; cnt=225; cnt_ob=50; cl=3
  fi
  for r in 1 2 3; do
    local op=query query_count=$cnt man=$V/manifests/$topo-q.txt
    if [ "$r" = 3 ]; then op=obtain; query_count=$cnt_ob; man=$V/manifests/$topo-o.txt; fi
    local bpids=""
    for t in $tgts; do
      timeout 900 "$BIN" bench --target 127.0.0.1:$((base + 200 + t)) \
        --label "$topo-micro-r$r-p$t" --clients $cl --count $query_count --op $op \
        --manifest "$man" --exclude-dir "$dat/node$t" \
        --out "$V/csv/$topo-micro-r$r-p$t.csv" \
        > "$V/logs/bench-$topo-r$r-p$t.log" 2>&1 &
      bpids="$bpids $!"
    done
    for p in $bpids; do wait $p 2>/dev/null || true; done
  done

  killall_p2p
  [ -n "$idxpid" ] && wait "$idxpid" 2>/dev/null || true
  sleep 1

  local SS=$V/session/$topo.txt
  gate "B/$topo: query n2_s1 hit"          grep -qE "query 'n2_s1' -> [1-9][0-9]* hit" "$SS"
  gate "B/$topo: obtain n2_b0 display"    grep -q "display file 'n2_b0' (1.00 MiB" "$SS"
  gate "B/$topo: query n${N}_s1 hit"      grep -qE "query 'n${N}_s1' -> [1-9][0-9]* hit" "$SS"
  gate "B/$topo: hot file misses pre-rescan" \
    grep -qE "query 'hot_$topo' -> (no results|0 hit)" "$SS"
  gate "B/$topo: rescan command ran"      grep -q "index rescanned" "$SS"
  gate "B/$topo: hot file hits post-rescan" grep -qE "query 'hot_$topo' -> [1-9][0-9]* hit" "$SS"
  gate "B/$topo: probe from p1 misses before rescan" \
    grep -qE "hot_$topo .*hits_avg=0\.0" "$V/session/$topo-propagate-pre.txt"
  gate "B/$topo: probe from p1 hits after rescan" \
    grep -qE "hot_$topo .*hits_avg=[1-9]" "$V/session/$topo-propagate-post.txt"
  for t in $tgts; do
    for r in 1 2; do
      gate "B/$topo: bench query run $r p$t ok=$cnt" \
        grep -q "ops=$cnt ok=$cnt" "$V/logs/bench-$topo-r$r-p$t.log"
    done
    gate "B/$topo: bench obtain run 3 p$t ok=$cnt_ob" \
      grep -q "ops=$cnt_ob ok=$cnt_ob" "$V/logs/bench-$topo-r3-p$t.log"
  done
  if [ "$topo" != central ]; then
    gate "B/$topo: no neighbour-HELLO denials" bash -c \
      "! grep -q 'not a configured neighbour' $V/logs/$topo-p*.log"
    gate "B/$topo: p1 has connected neighbours" grep -qE 'neighbours_conn=[1-9]' \
      "$V/logs/$topo-p1.log"
    local est="channel established"
    local est_ok=1 i
    for i in $(seq 1 "$N"); do
      grep -q "$est" "$V/logs/$topo-p$i.log" || est_ok=0
    done
    gate "B/$topo: every peer established a channel" test "$est_ok" = 1
  fi
}

echo "=== stage B: mesh / star / central sessions + micro bench ==="
FALLBACK=0
run_topology mesh    52000
run_topology star    53000
run_topology central 54000

gate "CSV schema is bench v3 (query_us/dl_us/holder_ip/n_hits)" bash -c \
  "head -1 $V/csv/mesh-micro-r1-p1.csv | grep -q '^tag,ts_us,client,seq,name,op,ok,duration_us,bytes,query_us,dl_us,holder_ip,n_hits'"

echo "=== stage C: in-program replication + failover (loopback) ==="
killall_p2p
wait_ports_free
CS=$V/c-data; CN=6; mkdir -p "$CS"
for i in $(seq 1 $CN); do
  mkdir -p "$CS/node$i"
  head -c 4096    /dev/zero | tr '\0' 's' > "$CS/node$i/n${i}_s1"
  head -c 1048576 /dev/zero | tr '\0' 'b' > "$CS/node$i/n${i}_b0"
done
RF=3; RING_IDS="$(seq 1 $CN)"
copies_of() {
  local f=$1 skip=$2 c=0 i
  for i in $(seq 1 $CN); do
    [ "$i" = "$skip" ] && continue
    [ -f "$CS/node$i/$f" ] && c=$((c + 1))
  done
  echo "$c"
}
cids=""
for i in $(seq 1 $CN); do
  a=$(( (i % CN) + 1 )); b=$(( ((i + CN - 2) % CN) + 1 ))
  cfg=$(write_peer_cfg c 55000 "$CS" "$i" $a $b)
  cids="$cids $(start_peer "$cfg" "$V/logs/c-p$i.log")"
  wait_port 127.0.0.1 $((55000 + 200 + i)) 10 || echo "warn: c p$i ctrl not up"
done
CINIT=$V/C-initial.txt
for try in $(seq 1 30); do
  ok=1; : > "$CINIT"
  for i in $(seq 1 $CN); do
    for sfx in s1 b0; do
      c=$(copies_of "n${i}_${sfx}" 0)
      echo "n${i}_${sfx} $c" >> "$CINIT"
      [ "$c" = "3" ] || ok=0
    done
  done
  [ "$ok" = 1 ] && break
  sleep 1
done
echo "initial placement: $(awk '$2==3' "$CINIT" | wc -l)/$((CN * 2)) files at 3 copies"
killall_c() { for p in $cids; do kill "$p" 2>/dev/null || true; done; sleep 0.5; }

kill "$(echo $cids | cut -d' ' -f2)" 2>/dev/null || true
sleep 1
CCLIENT=1
for i in 1 3 4 5 6; do
  [ -f "$CS/node$i/n2_s1" ] && continue
  [ -f "$CS/node$i/n2_b0" ] && continue
  CCLIENT=$i; break
done
printf "n2_s1\nn2_b0\n" > "$V/manifests/c-dead.txt"
"$BIN" bench --target 127.0.0.1:$((55000 + 200 + CCLIENT)) --clients 1 --count 20 \
  --op obtain --manifest "$V/manifests/c-dead.txt" --exclude-dir "$CS/node$CCLIENT" \
  --label c-deadowner --out "$V/csv/c-deadowner.csv" \
  > "$V/logs/bench-c-dead.log" 2>&1
CRESTORE=$V/C-restore.txt
deadline=$((SECONDS + 120))
restored=0
while [ $SECONDS -lt $deadline ]; do
  sleep 5
  restored=1; : > "$CRESTORE"
  for i in $(seq 1 $CN); do
    for sfx in s1 b0; do
      c=$(copies_of "n${i}_${sfx}" 2)
      echo "n${i}_${sfx} $c" >> "$CRESTORE"
      [ "$c" = "3" ] || restored=0
    done
  done
  [ "$restored" = 1 ] && break
done
killall_c
killall_p2p
echo "stage C done"

C_INIT_OK=$(awk '$2==3' "$CINIT" 2>/dev/null | wc -l); C_INIT_OK=${C_INIT_OK:-0}
C_REST_OK=$(awk '$2==3' "$CRESTORE" 2>/dev/null | wc -l); C_REST_OK=${C_REST_OK:-0}
C_OVER=$(awk '$2>3' "$CRESTORE" 2>/dev/null | wc -l); C_OVER=${C_OVER:-0}
gate "C: initial placement puts exactly 3 copies per file" \
  test "$C_INIT_OK" -eq $((CN * 2))
gate "C: dead-owner obtain works from surviving holders" \
  grep -q "ops=20 ok=20" "$V/logs/bench-c-dead.log"
gate "C: survivors restore every file to 3 live copies" \
  test "$C_REST_OK" -eq $((CN * 2))
gate "C: dead node's copies not counted / no over-replication" \
  test "$C_OVER" -eq 0

echo "=== stage D: journal + stale-copy GC + ring fallback (loopback) ==="
killall_p2p
wait_ports_free
DS=$V/d-data; DN=6; mkdir -p "$DS"
MARKDIR=$V/d-markers; mkdir -p "$MARKDIR"
FALLBACK=1; RF=3; RING_IDS="$(seq 1 $DN)"
for i in $(seq 1 $DN); do
  mkdir -p "$DS/node$i"
  head -c 4096    /dev/zero | tr '\0' 's' > "$DS/node$i/n${i}_s1"
  head -c 1048576 /dev/zero | tr '\0' 'b' > "$DS/node$i/n${i}_b0"
done
head -c 1048576 /dev/zero | tr '\0' 'A' > "$DS/node5/arbitrary-file.bin"

d_copies_of() {
  local f=$1 skip=${2:-0} c=0 i
  for i in $(seq 1 $DN); do
    [ "$i" = "$skip" ] && continue
    [ -f "$DS/node$i/$f" ] && c=$((c + 1))
  done
  echo "$c"
}
d_holders_of() {
  local f=$1 i out=""
  for i in $(seq 1 $DN); do
    [ -f "$DS/node$i/$f" ] && out="$out $i"
  done
  echo "$out" | xargs 2>/dev/null || echo ""
}
d_designed_holders() {
  python3 - "$1" "$2" "$RING_IDS" <<'PY'
import sys
name, owner, ids = sys.argv[1], int(sys.argv[2]), sys.argv[3].split()
ring = [int(x) for x in ids]
MASK = 0xFFFFFFFFFFFFFFFF
def fnv1a64(s):
    h = 0xcbf29ce484222325
    for ch in s.encode():
        h ^= ch
        h = (h * 0x100000001b3) & MASK
    return h
N = len(ring)
start = fnv1a64(name) % N
out, k = [], 0
while len(out) < 2 and k <= N:
    cand = ring[(start + k) % N]
    if cand != owner and cand not in out:
        out.append(cand)
    k += 1
print(' '.join(str(x) for x in sorted(out)))
PY
}
d_wait_set() {
  local f=$1 want=$2 t=$3 t0=$SECONDS c=0
  while :; do
    c=$(d_copies_of "$f")
    [ "$c" = "$want" ] && break
    [ $((SECONDS - t0)) -ge "$t" ] && break
    sleep 2
  done
  echo "$c"
}

d_idx=$V/cfg/d-index.cfg
{
  echo "node_id=101"
  echo "my_ip=127.0.0.1"
  echo "msg_port=$((56000 + 900))"
} > "$d_idx"
"$BIN" index -c "$d_idx" > "$V/logs/d-index.log" 2>&1 &
d_idxpid=$!
sleep 1
wait_port 127.0.0.1 $((56000 + 900)) 10 || echo "warn: d index not up"
d_pids=""
for i in $(seq 1 $DN); do
  cfg=$(CFGNAME=d write_peer_cfg central 56000 "$DS" "$i")
  d_pids="$d_pids $(start_peer "$cfg" "$V/logs/d-p$i.log")"
  wait_port 127.0.0.1 $((56000 + 200 + i)) 10 || echo "warn: d p$i ctrl not up"
done

ARB_WANT=$(echo "5 $(d_designed_holders arbitrary-file.bin 5)" | xargs -n1 | sort -n | xargs)
ARB_N=$(d_wait_set arbitrary-file.bin 3 90)
echo "D: arbitrary-file.bin live copies = $ARB_N (want 3), designed set {$ARB_WANT}"
JHUNT=$(grep -lE "^arbitrary-file.bin[[:space:]]+5$" "$DS"/.p2p-repl-node*.meta 2>/dev/null | wc -l)
echo "D: journal lines attributing arbitrary-file.bin owner=5 on $JHUNT nodes (want 3)"

head -c 1048576 /dev/zero | tr '\0' 'L' > "$DS/node5/arbitrary-late.bin"
touch "$MARKDIR/node5.rescan"
LATE_N=$(d_wait_set arbitrary-late.bin 3 90)
LATE_SET=$(d_holders_of arbitrary-late.bin)
LATE_WANT=$(echo "5 $(d_designed_holders arbitrary-late.bin 5)" | xargs -n1 | sort -n | xargs)
RESCAN_L5=$(grep -c "index rescanned on rescan marker" "$V/logs/d-p5.log" 2>/dev/null || true)
echo "D: arbitrary-late.bin live=$LATE_N set {$LATE_SET} designed {$LATE_WANT} rescan logs on node5=${RESCAN_L5:-0}"

N1_H=$(d_designed_holders n1_s1 1)
N1_DES="1 $N1_H"
N1_STRAYS=""
for n in $(seq 1 $DN); do
  case " $N1_DES " in *" $n "*) continue ;; esac
  N1_STRAYS="$N1_STRAYS $n"
  [ $(echo $N1_STRAYS | wc -w) -ge 2 ] && break
done
N1_STRAYS=$(echo $N1_STRAYS | xargs)
for n in $N1_STRAYS; do
  cp "$DS/node1/n1_s1" "$DS/node$n/n1_s1"
  touch "$MARKDIR/node$n.rescan"
done
for try in $(seq 1 30); do
  done_all=1
  for n in $N1_STRAYS; do
    grep -q "index rescanned on rescan marker" "$V/logs/d-p$n.log" 2>/dev/null || done_all=0
  done
  [ "$done_all" = 1 ] && break
  sleep 2
done
N1_PRE=$(d_copies_of n1_s1)
echo "D: n1_s1 copies pre-GC = $N1_PRE on {$(d_holders_of n1_s1)} (want 3 designed + 2 strays on {$N1_STRAYS})"

head -c 4096 /dev/zero | tr '\0' 'Z' > "$DS/node3/legacy-arb.bin"
touch "$MARKDIR/node3.rescan"
LEG_N=$(d_wait_set legacy-arb.bin 3 90)

for i in $(seq 1 $DN); do touch "$MARKDIR/node$i.gc-dry"; done
for try in $(seq 1 40); do
  n=$(grep -l 'SUMMARY' "$MARKDIR"/node*.gc-dry.log 2>/dev/null | wc -l)
  [ "$n" -ge "$DN" ] && break
  sleep 1
done
: > "$V/D-gc-dry.txt"
for i in $(seq 1 $DN); do
  grep -h 'SUMMARY' "$MARKDIR/node$i.gc-dry.log" 2>/dev/null >> "$V/D-gc-dry.txt" || true
done
DRY_DEL=0
for n in $N1_STRAYS; do
  grep -qE "^DELETE-DRY[[:space:]]+n1_s1[[:space:]]+owner=1$" "$MARKDIR/node$n.gc-dry.log" 2>/dev/null && DRY_DEL=$((DRY_DEL + 1))
done
DRY_KEEP=$(grep -lE "^KEEP[[:space:]]+n1_s1" "$MARKDIR"/node*.gc-dry.log 2>/dev/null | wc -l)
DRY_UNK=$(grep -h 'SUMMARY' "$MARKDIR"/node*.gc-dry.log 2>/dev/null | grep -c 'unknown=0')
STRAY_STILL=$(c=0; for n in $N1_STRAYS; do [ -f "$DS/node$n/n1_s1" ] && c=$((c + 1)); done; echo $c)
echo "D: dry GC verdicts: nodes=$DN summaries=$(wc -l < "$V/D-gc-dry.txt") DELETE-DRY(n1_s1) hosts=$DRY_DEL KEEP(n1_s1) logs=$DRY_KEEP unknown0=$DRY_UNK strays still on disk=$STRAY_STILL"

for i in $(seq 1 $DN); do touch "$MARKDIR/node$i.gc"; done
for try in $(seq 1 40); do
  n=$(grep -l 'SUMMARY' "$MARKDIR"/node*.gc.log 2>/dev/null | wc -l)
  [ "$n" -ge "$DN" ] && break
  sleep 1
done
STRAY_GONE=0
for n in $N1_STRAYS; do [ ! -f "$DS/node$n/n1_s1" ] && STRAY_GONE=$((STRAY_GONE + 1)); done
N1_POST=$(d_copies_of n1_s1)
COMPACT=$(grep -l 'journal compacted' "$V"/logs/d-p*.log 2>/dev/null | wc -l)
: > "$V/D-gc.txt"
for i in $(seq 1 $DN); do
  grep -h 'SUMMARY' "$MARKDIR/node$i.gc.log" 2>/dev/null >> "$V/D-gc.txt" || true
done
D_ALL_OK=1; : > "$V/D-post.txt"
for f in n1_s1 n1_b0 n3_s1 n5_b0 arbitrary-file.bin arbitrary-late.bin legacy-arb.bin; do
  c=$(d_copies_of "$f")
  echo "$f $c" >> "$V/D-post.txt"
  [ "$c" = "3" ] || D_ALL_OK=0
done
JHUNT2=$(grep -lE "^arbitrary-file.bin[[:space:]]+5$" "$DS"/.p2p-repl-node*.meta 2>/dev/null | wc -l)
LEG_POST=$(d_copies_of legacy-arb.bin)
echo "D: real GC: strays deleted=$STRAY_GONE/$(( $(echo $N1_STRAYS | wc -w) )) n1_s1 copies=$N1_POST journal compact nodes=$COMPACT arbitrary journal nodes=$JHUNT2 legacy-arb copies=$LEG_POST all-names-at-3=$D_ALL_OK"

kill -9 "$d_idxpid" 2>/dev/null || true
sleep 1
FBCLIENT=0
for c in 1 2 3 4 5 6; do
  [ -f "$DS/node$c/arbitrary-late.bin" ] && continue
  FBCLIENT=$c; break
done
printf 'arbitrary-late.bin\n' > "$V/manifests/d-fallback.txt"
printf 'never-published-name.bin\n' > "$V/manifests/d-missing.txt"
if [ "$FBCLIENT" = 0 ]; then
  echo "D: every node holds arbitrary-late.bin - no fallback client available"
else
  "$BIN" bench --target 127.0.0.1:$((56000 + 200 + FBCLIENT)) --clients 1 --count 1 \
    --op obtain --manifest "$V/manifests/d-fallback.txt" --exclude-dir "$DS/node$FBCLIENT" \
    --label d-fallback --out "$V/csv/d-fallback.csv" \
    > "$V/logs/bench-d-fallback.log" 2>&1
  FB1=$(grep -h "\[client\] lookup failed" "$V/logs/d-p$FBCLIENT.log" 2>/dev/null | tail -1)
  "$BIN" bench --target 127.0.0.1:$((56000 + 200 + FBCLIENT)) --clients 1 --count 1 \
    --op obtain --manifest "$V/manifests/d-missing.txt" --exclude-dir "$DS/node$FBCLIENT" \
    --label d-missing --out "$V/csv/d-missing.csv" \
    > "$V/logs/bench-d-missing.log" 2>&1
  MISSFAIL=$(grep -c 'BENCH-SUMMARY ops=1 ok=0 fail=1' "$V/logs/bench-d-missing.log" 2>/dev/null || true)
  FABRICATED=$(grep -c "lookup failed for 'never-published-name.bin'" "$V/logs/d-p$FBCLIENT.log" 2>/dev/null || true)
  echo "D: fallback client node$FBCLIENT: ok line=$(grep -h 'BENCH-SUMMARY' "$V/logs/bench-d-fallback.log" 2>/dev/null | head -1)"
  echo "D: fallback line: ${FB1:-none}"
  echo "D: negative control: ops=1 ok=0 fail=1 count=${MISSFAIL:-0} fabricated-hit-lines=${FABRICATED:-0}"
fi
"$BIN" index -c "$d_idx" > "$V/logs/d-index-restart.log" 2>&1 &
d_idxpid=$!
sleep 12
REREG=$(grep -c 'registering' "$V/logs/d-index-restart.log" 2>/dev/null || true)
echo "D: index restart re-registrations = ${REREG:-0} (want $DN)"

gate "D: arbitrary name journal-adopted at boot, rf=3 copies" \
  test "$ARB_N" -eq 3
gate "D: arbitrary name sits at its designed FNV set" \
  test "$(d_holders_of arbitrary-file.bin)" = "$ARB_WANT"
gate "D: journal attributes arbitrary-file.bin owner=5 on exactly 3 nodes" \
  test "$JHUNT" -eq 3
gate "D: rescan marker adoption: arbitrary-late.bin at 3 copies" \
  test "$LATE_N" -eq 3
gate "D: rescan-adopted name sits at its designed FNV set" \
  test "$LATE_SET" = "$LATE_WANT"
gate "D: node5 consumed its rescan marker (index rescanned log)" \
  test "${RESCAN_L5:-0}" -ge 1
gate "D: strays of prefixed name pre-GC (3 designed + 2 strays)" \
  test "$N1_PRE" -eq 5
gate "D: dry GC reports DELETE-DRY for the strays, files untouched" \
  test "$DRY_DEL" -eq 2 -a "$STRAY_STILL" -eq 2
gate "D: dry GC KEEPS the designed copies (3 nodes)" \
  test "$DRY_KEEP" -eq 3
gate "D: dry GC finds no unknown-owner names" \
  test "$DRY_UNK" -eq "$DN"
gate "D: real GC deletes exactly the strays" \
  test "$STRAY_GONE" -eq 2 -a "$N1_POST" -eq 3
gate "D: real GC keeps everything designed at 3 copies" \
  test "$D_ALL_OK" -eq 1
gate "D: journal compacted after real GC (owning nodes)" \
  test "$COMPACT" -ge 1
gate "D: surviving arbitrary name keeps its journal provenance" \
  test "$JHUNT2" -eq 3
gate "D: GC never deletes self-adopted (owner=self) arbitrary names" \
  test "$LEG_POST" -eq 3
gate "D: index-dead obtain succeeds through the ring fallback" \
  grep -q 'BENCH-SUMMARY ops=1 ok=1 fail=0' "$V/logs/bench-d-fallback.log"
gate "D: fallback prints the [client] lookup failed line" \
  grep -q "\[client\] lookup failed for 'arbitrary-late.bin'" "$V/logs/d-p${FBCLIENT:-1}.log"
gate "D: never-published name still FAILS (no fabricated hit)" \
  grep -q 'BENCH-SUMMARY ops=1 ok=0 fail=1' "$V/logs/bench-d-missing.log"
gate "D: fallback probed every roster node for the unknown name, found none" \
  test "${FABRICATED:-0}" -eq 0
gate "D: index restart re-registers every peer" \
  test "${REREG:-0}" -ge "$DN"

killall_p2p
[ -n "$d_idxpid" ] && wait "$d_idxpid" 2>/dev/null || true
sleep 1
MARKDIR=""
echo "stage D done"

NPASS=$(grep -c '^PASS' "$V/gates.txt" 2>/dev/null || true); NPASS=${NPASS:-0}
{
  echo "=== verify-node SUMMARY $(date -u '+%F %T UTC') ==="
  echo "N=$N peers per topology + chain stage (rf=1) + replication stage C (rf=3)"
  echo "+ stage D (rf=3, 6 central peers): journal adoption, stale-copy GC,"
  echo "  ring fallback on index death; stage B benches use --exclude-dir like"
  echo "  the cluster runs"
  echo "gates: $NPASS PASS, $FAILS FAIL (details: verify/gates.txt)"
  echo "-- throughput lines:"
  grep -h throughput "$V"/logs/bench-*.log 2>/dev/null | sed 's/^/  /' || true
  echo "-- chain TTL probes:"
  grep '^RESULT' "$V/pinger-ttl8.txt" "$V/pinger-ttl6.txt" 2>/dev/null | sed 's/^/  /' || true
  echo "-- chain deep obtain display line(s):"
  sed 's/^/  /' "$V/A-obtain.txt" 2>/dev/null || true
  echo "-- display file count per session:"
  grep -c "display file" "$V"/session/*.txt 2>/dev/null | sed 's/^/  /' || true
  echo "-- stage C placement/restore:"
  awk '{print "  initial: "$0}' "$V/C-initial.txt" 2>/dev/null | head -4 || true
  awk '{print "  after-kill: "$0}' "$V/C-restore.txt" 2>/dev/null | head -4 || true
  echo "-- stage D GC verdict summaries (per peer):"
  sed 's/^/  dry: /' "$V/D-gc-dry.txt" 2>/dev/null || true
  sed 's/^/  gc:  /' "$V/D-gc.txt" 2>/dev/null || true
  echo "-- stage D post-GC copy counts per name (want 3):"
  awk '{print "  "$0}' "$V/D-post.txt" 2>/dev/null || true
  echo "-- stage D ring-fallback lines found in peer logs:"
  grep -h "\[client\] lookup failed" "$V"/logs/d-p*.log 2>/dev/null | sed 's/^/  /' || true
  echo "-- FAIL lines (if any):"
  grep '^FAIL' "$V/gates.txt" 2>/dev/null | sed 's/^/  /' || echo "  none"
} > "$V/SUMMARY" 2>&1
cat "$V/SUMMARY"
echo "verify tree: $V"
[ "$FAILS" -eq 0 ] || { echo "RESULT: $FAILS gate(s) FAILED" >&2; exit 1; }
echo "RESULT: all gates passed"
exit 0
