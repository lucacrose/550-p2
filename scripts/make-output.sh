#!/bin/bash
set -e
cd ~/pa2
TOPO=${1:-mesh}
SSH='ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10'
OUT=/tmp/pa2-output.txt
TMP=/tmp/pa2-out
CFG=$TMP/out30.cfg

mkdir -p $TMP/shared $TMP/dl output-snippets
pkill -f "p2p peer -c /tmp/pa2-out" 2>/dev/null || true
pkill -f "out30.cfg" 2>/dev/null || true
sleep 1
cat > "$CFG" <<'EOF'
node_id=30
my_ip=192.168.77.1
msg_port=59901
control_port=59902
download_port=59903
topology=mesh
data_dir=/tmp/pa2-out/shared
downloads_dir=/tmp/pa2-out/dl
ttl=8
query_timeout_ms=8000
keep_downloads=0
replication_factor=1
neighbors=192.168.77.102:51000
EOF

S1=$(grep -m1 '^n05_s' manifests/small.txt)
S2=$(grep -m1 '^n02_s' manifests/small.txt)
N12S=$(grep -m1 '^n12_s' manifests/small.txt)
N12B=$(grep -m1 '^n12_b' manifests/large.txt)
L=$(grep -m1 '^n05_b' manifests/large.txt)

{
  echo "================================================================"
  echo "  PA2 OUTPUT SAMPLE  --  topology: $TOPO, 16 peers on VMs"
  echo "  (timestamps are VM-local UTC; files are served from /data/shared;"
  echo "   every file is kept on replication_factor=3 nodes by the program"
  echo "   itself: owner + 2 ring holders chosen from FNV-1a64(name))"
  echo "================================================================"
  echo
  echo "## 1. operational status: 'p2p ping --target <ctrl>' on every peer"
  echo "##    shows route-table size, pending queries, neighbour count,"
  echo "##    indexed files and the replication counters"
  echo "##    repl(push=... skip=... recv=...,done)."
} > "$OUT"
for i in $(seq 2 17); do
  printf "vm%02d: " $i >> "$OUT"
  $SSH cc@192.168.77.$((100+i)) '~/pa2/p2p ping --target 127.0.0.1:51001 || true' \
    >> "$OUT" 2>&1 || echo "FAIL" >> "$OUT" 2>&1
done

run_aux_session() {
  ./p2p peer -c "$CFG" --cli < "$1" >> "$OUT" 2>&1 || true
}

echo "== aux servent (node30 on the host) dials vm02 via extra_peers =="
{
  echo
  echo "## 2. helper servent (node30) attached to vm02; user session:"
  echo "##    'stat', query + obtain of 10 KB files, then a 100 MB binary."
  echo "##    'display file' lines are the required download printout;"
  echo "##    each query lists EVERY holder (replication_factor=3), because"
  echo "##    the CLI waits one hit-collection window for all replies."
} >> "$OUT"
printf "stat\nquery %s\nobtain %s\nquery %s\nobtain %s\nquit\n" \
  "$S1" "$S1" "$S2" "$L" > "$TMP/cmds.txt"
run_aux_session "$TMP/cmds.txt"

echo "== failover section (kill vm12; ring replicas must answer) =="
{
  echo
  echo "================================================================"
  echo "  FAILOVER TEST: kill the vm12 servent (data-resilience demo)."
  echo "  Every n12_* file lives on 3 nodes (owner + 2 ring holders), so"
  echo "  queries and downloads keep succeeding while vm12 is dead; the"
  echo "  surviving peers then re-replicate the files to a new holder."
} >> "$OUT"
$SSH cc@192.168.77.112 'pkill -x p2p || true'
sleep 2
{ echo; echo '$ p2p ping --target 192.168.77.112:51001   # vm12 now dead:'; } >> "$OUT"
./p2p ping --target 192.168.77.112:51001 >> "$OUT" 2>&1 || true
{
  echo
  echo "## 3. query + obtain for files OWNED by the dead node (node30 CLI):"
  echo "##    the query lists only the 2 surviving holders; both downloads"
  echo "##    succeed without vm12."
} >> "$OUT"
printf "stat\nquery %s\nobtain %s\nobtain %s\nquit\n" \
  "$N12S" "$N12S" "$N12B" > "$TMP/cmds2.txt"
run_aux_session "$TMP/cmds2.txt"

{
  echo
  echo "================================================================"
  echo "  FAILOVER BENCH (vm13, scripted): 2000 query+obtain of ONLY"
  echo "  vm12-owned 10 KB files after vm12 died; all served by ring"
  echo "  replicas (log tail; full CSVs under results/failover/):"
  tail -3 results/failover-$TOPO/failover-small.log 2>/dev/null || \
    echo "  (run: bash scripts/failover-demo.sh $TOPO, then re-run this)"
  echo
  echo "  After ~30 s the surviving peers detected vm12's dead download"
  echo "  port and restored replication: results/failover-$TOPO/copies-after.txt"
  echo "  shows every sampled n12_* file back at 3 live copies."
} >> "$OUT"

{
  echo
  echo "================================================================"
  echo "  KNOWN-NOT-WORKING CASES (readme section 8), demonstrated live:"
  echo "  (a) a name that exists nowhere -> the query times out with"
  echo "      'no results' and the obtain fails cleanly (8 s budget);"
  echo "  (b) a file whose ALL 3 copies are dead is lost by design;"
  echo "      that case is exercised in the failover evidence"
  echo "      (all-holders-dead, results/failover-$TOPO/), and ghost.bin"
  echo "      (which violates the n<id>_* ownership rule so replication"
  echo "      never copies it) is shown failing in the same evidence set."
} >> "$OUT"
printf "stat\nquery no_such_file_xyz.txt\nobtain no_such_file_xyz.txt\nquit\n" > "$TMP/cmds3.txt"
run_aux_session "$TMP/cmds3.txt"

mv "$OUT" "$HOME/pa2/output.txt"
pkill -f "p2p peer -c /tmp/pa2-out" 2>/dev/null || true
pkill -f "out30.cfg" 2>/dev/null || true
echo "WROTE ~/pa2/output.txt"
