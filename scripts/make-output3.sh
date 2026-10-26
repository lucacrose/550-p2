#!/bin/bash
set -u
cd ~/pa2
BINGMD5=${BINGMD5:?pin the release binary md5, e.g. BINGMD5=3642a8736e3c9deac79af6d023e52815}
SSHO='ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10'
OUT=~/pa2/output.txt
RAW=~/pa2/results/output-raw
RUNLOG=~/pa2/results/outdemo3-run.log
mkdir -p results/output-raw manifests
: > "$RUNLOG"; rm -f "$RAW"/*.txt
log() { echo "[$(date -u '+%T')] $*" | tee -a "$RUNLOG"; }
die() { echo "OUT-FAIL: $*" | tee -a "$RUNLOG"; exit 1; }
md5sum ~/pa2/p2p | grep -q "^$BINGMD5 " || die "pinned binary md5 mismatch on the control host (want $BINGMD5)"

vm()  { echo 192.168.77.$((100+$1)); }
alive() { $SSHO cc@$(vm $1) 'pgrep -x p2p >/dev/null' 2>/dev/null; }
kill9() { $SSHO cc@$(vm $1) 'pkill -9 -x p2p 2>/dev/null; true'; }
holds() { $SSHO cc@$(vm $1) "ls /data/shared/$2" >/dev/null 2>&1; }
live_holders() {
  local i out=""
  for i in $(seq 2 17); do
    alive $i || continue
    holds $i "$1" && out="$out $i"
  done
  echo $out | xargs 2>/dev/null || true
}
wait_copies() {
  local t0=$(date +%s) H n
  while :; do
    H=$(live_holders "$1"); n=$(echo $H | wc -w)
    [ "$n" -eq "$2" ] && break
    [ $(( $(date +%s) - t0 )) -ge "$3" ] && break
    sleep 10
  done
  echo "$n $(echo $H)"
}
dyn_cli() {
  local c
  for c in "${@:3}"; do
    alive $c || continue
    holds $c "$1" && continue
    holds $c "$2" && continue
    echo $c; return 0
  done
  echo 0
}
des_of() {
  python3 - "$1" "$2" <<'PY'
import sys
name, owner = sys.argv[1], int(sys.argv[2])
ring = list(range(2, 18)); N = len(ring)
MASK = 0xFFFFFFFFFFFFFFFF
def fnv(s):
    h = 0xcbf29ce484222325
    for ch in s.encode():
        h ^= ch; h = (h * 0x100000001b3) & MASK
    return h
start, k, out = fnv(name) % N, 0, []
while len(out) < 2 and k <= N:
    cand = ring[(start + k) % N]
    if cand != owner and cand not in out: out.append(cand)
    k += 1
print(' '.join(str(x) for x in sorted([owner] + out)))
PY
}
mirror_ok() {
  local want got
  want=$(des_of "$1" "$2"); got=$(live_holders "$1")
  [ "$(echo $want)" = "$(echo $got | xargs 2>/dev/null || true)" ] || {
    log "DATA check failed: $1 live holders = ${got:-none}, designed = $want"; die "placement drift on $1"; }
  log "mirror ok: $1 live holders == designed {$want}"
}
session() {
  local raw=$3
  $SSHO cc@$(vm $2) "pkill -9 -x p2p 2>/dev/null; sleep 1; cd ~/pa2 && printf '$4' | stdbuf -oL -eL ~/pa2/p2p peer -c configs/$1/node$2.cfg --cli" > "$raw" 2>&1
  [ -s "$raw" ] || die "empty session capture for $raw (node $2 servent not up?)"
  cat "$raw" >> $OUT
  sleep 2
}
gc_sweep() {
  for i in $(seq 2 17); do
    $SSHO cc@$(vm $i) 'rm -f /tmp/peer.gc-dry /tmp/peer.gc-dry.log /tmp/peer.gc /tmp/peer.gc.log; touch /tmp/peer.gc-dry' &
  done
  wait
  local t0 ok
  t0=$(date +%s)
  while :; do
    ok=1
    for i in $(seq 2 17); do
      timeout 12 $SSHO cc@$(vm $i) 'grep -q SUMMARY /tmp/peer.gc-dry.log 2>/dev/null' 2>/dev/null || ok=0
    done
    if [ "$ok" = 1 ]; then break; fi
    if [ $(( $(date +%s) - t0 )) -gt 900 ]; then return 1; fi
    sleep 5
  done
  log "gc dry pass: verdicts on all 16 peers"
  for i in $(seq 2 17); do
    $SSHO cc@$(vm $i) 'touch /tmp/peer.gc' &
  done
  wait
  t0=$(date +%s)
  while :; do
    ok=1
    for i in $(seq 2 17); do
      timeout 12 $SSHO cc@$(vm $i) 'grep -q SUMMARY /tmp/peer.gc.log 2>/dev/null' 2>/dev/null || ok=0
    done
    if [ "$ok" = 1 ]; then break; fi
    if [ $(( $(date +%s) - t0 )) -gt 9000 ]; then return 1; fi
    sleep 10
  done
  for i in $(seq 2 17); do
    log "gc vm$i: $($SSHO cc@$(vm $i) 'grep -h SUMMARY /tmp/peer.gc.log 2>/dev/null || echo no-verdict' 2>/dev/null | tail -1)"
  done
  log "gc real pass complete (per-peer SUMMARY rows above)"
}
TOPO=""
start_topo() {
  TOPO=$1
  GCB=${2:-}
  log "=== outdemo3 $TOPO: wipe peer logs, start system ==="
  for i in $(seq 2 17); do
    $SSHO cc@$(vm $i) 'rm -f ~/pa2/logs/peer.log /tmp/peer.repl.done /tmp/peer.rescan' &
  done
  wait
  for i in $(seq 1 17); do
    timeout 600 $SSHO cc@$(vm $i) 'pkill -x p2p 2>/dev/null; true' &
  done
  wait
  for try in $(seq 1 10); do
    busy=""
    for i in $(seq 1 17); do
      if timeout 10 $SSHO cc@$(vm $i) 'pgrep -x p2p >/dev/null' 2>/dev/null; then
        busy="$busy vm$i"
      fi
    done
    if [ -z "$busy" ]; then
      log "verified-stop: fleet empty (try $try)"
      break
    fi
    log "verified-stop try $try: p2p still up on:$busy -- SIGKILL sweep"
    for i in $(seq 1 17); do
      timeout 60 $SSHO cc@$(vm $i) 'pkill -9 -x p2p 2>/dev/null; true' &
    done
    wait
    sleep 2
    if [ "$try" = 10 ]; then
      die "verified-stop: p2p processes survived SIGKILL on:$busy"
    fi
  done
  bash scripts/start-system.sh $TOPO >> "$RUNLOG" 2>&1 || die "start-system $TOPO failed"
  if [ "$GCB" = gc ]; then
    log "gc boundary: stale-copy GC (dry+real) while all 16 are live, then re-boot so fresh registration matches on-disk exactly (pinned binary Task-4 recipe; reclaims REPLACEMENT extras left by prior failover demos)"
    gc_sweep || die "gc sweep failed"
    bash scripts/start-system.sh $TOPO >> "$RUNLOG" 2>&1 || die "gc re-boot $TOPO failed"
  fi
  sleep 30
  bash scripts/smoke.sh $TOPO >> "$RUNLOG" 2>&1 || die "smoke $TOPO failed"
  log "=== outdemo3 $TOPO: system up (START-OK + smoke) ==="
}
stop_topo() {
  bash scripts/stop-system.sh $TOPO >> "$RUNLOG" 2>&1 || true
  log "=== outdemo3 $TOPO: system stopped ==="
}

log "outdemo3 start $(date -u '+%F %T') pin=$BINGMD5"

{
echo '================================================================'
echo '  PA2 OUTPUT SAMPLE -- all three deployments (central, star, mesh)'
echo "  16 peers on 17 Chameleon VMs (vmNN = 192.168.77.(100+NN), rf=3)"
echo "  run $(date -u '+%F %T UTC'); pinned binary md5 $BINGMD5"
echo '## header statement: every line below is machine output (p2p ping,'
echo '## in-system --cli console sessions, or the peer program log emitted'
echo '## while the session ran; the peer binary itself printed all of it).'
echo '## Nothing was typed by hand. No filtering: session captures include'
echo '## the servent log lines that interleave with the console output.'
echo '================================================================'
} > $OUT
start_topo central gc
{
echo
echo '##################### CENTRAL DEPLOYMENT ########################'
echo '## central: dedicated index server on vm01 answers every query'
echo '## (PA1 semantics); obtain downloads from the 3 live copies (owner'
echo '## + 2 FNV-1a64 ring holders) over the per-VM download plane.'
echo '## 1. p2p ping --target 127.0.0.1:51001, every peer:'
} >> $OUT
for i in $(seq 2 17); do
  printf 'vm%02d: ' $i >> $OUT
  $SSHO cc@$(vm $i) 'cd ~/pa2 && ~/pa2/p2p ping --target 127.0.0.1:51001' >> $OUT 2>&1
done
mirror_ok n05_s000000.txt 5
mirror_ok n05_b0.bin 5
{
echo '## 2. in-system --cli console on vm08: the node'"'"'s servent is replaced'
echo '##    by the SAME pinned binary in --cli mode, commands fed on stdin.'
echo '##    Target files: n05_s000000.txt (holders {5,12,13}) and n05_b0.bin'
echo '##    (holders {4,5,6}); session node vm08 is not one of the holders,'
echo '##    and the query hit list shows exactly the 3 designed copies.'
} >> $OUT
session central 8 $RAW/central-1-pre.txt 'stat\nquery n05_s000000.txt\nobtain n05_s000000.txt\nobtain n05_b0.bin\nquit\n'
{
echo
echo '## 3. HARD kill (SIGKILL) of vm05 - the OWNER of both target files.'
echo '##    The ring maintenance pass re-converges both names to 3 live'
echo '##    copies (new placement) before the post-kill session starts.'
} >> $OUT
echo "  kill issued $(date -u '+%Y-%m-%dT%T.%3NZ') on vm05" >> $OUT
kill9 5
sleep 20
log "central converge: n05_s000000.txt -> $(wait_copies n05_s000000.txt 3 300)"
log "central converge: n05_b0.bin -> $(wait_copies n05_b0.bin 3 300)"
POSTC=$(dyn_cli n05_s000000.txt n05_b0.bin 3 9 10 11 14 15 16 17 12 13)
[ "$POSTC" != 0 ] || die "no post-kill session node on central"
{
echo "## 4. post-kill --cli console on vm$POSTC (holder of NEITHER file): the"
echo '##    query now lists the 3 SURVIVING/re-converged copies and both'
echo '##    obtains succeed from holders, including the 100 MiB file.'
} >> $OUT
session central $POSTC $RAW/central-2-post.txt 'query n05_s000000.txt\nobtain n05_s000000.txt\nobtain n05_b0.bin\nstat\nquit\n'
for i in $(seq 2 17); do
  $SSHO cc@$(vm $i) "rm -f /data/shared/out-arb-* /data/downloads/out-arb-*; [ -f /data/.p2p-repl.meta ] && sed -i '/^out-arb-/d' /data/.p2p-repl.meta; true" &
done
wait
{
echo
echo '## 5. Task 1 demo: files with ARBITRARY names (the prefix rule cannot'
echo '##    name an owner for them) published on vm11 while the system runs.'
echo "##    After publishing, the demo restarts the servents (the same"
echo '##    start-system.sh central call the demo itself boots with): the'
echo '##    fresh servents find the published files at their boot scan,'
echo '##    adopt them into the provenance journal (owner=vm11) and the'
echo '##    boot replication pass places them like any dataset name:'
echo '##    out-arb-1m.bin holders {11,15,16}, out-arb-40m.bin'
echo '##    holders {6,7,11} - 3 copies each, journal-verified placement.'
echo '##    The restart also runs the built-in stale-copy GC of the binary'
echo '##    (marker-triggered: a dry pass, then the real delete pass, all'
echo '##    16 peers live) and then re-boots once more, so the index'
echo '##    registration matches the on-disk set exactly (the Task-4 GC'
echo '##    recipe of the shipped code); REPLACEMENT extras left over'
echo '##    from the failover demos above are reclaimed here.'
} >> $OUT
$SSHO cc@$(vm 11) "head -c 1048576 /dev/urandom > /data/shared/out-arb-1m.bin && head -c 41943040 /dev/urandom > /data/shared/out-arb-40m.bin && touch /tmp/peer.rescan"
log "arb restart: re-booting servents so they adopt the published names fresh"
start_topo central gc
log "central arb settle: out-arb-1m.bin -> $(wait_copies out-arb-1m.bin 3 300)"
log "central arb settle: out-arb-40m.bin -> $(wait_copies out-arb-40m.bin 3 300)"
mirror_ok out-arb-1m.bin 11
mirror_ok out-arb-40m.bin 11
{
echo '##    session on vm10 (not a holder of either name): obtains BOTH'
echo '##    arbitrary names over the network while the owner is alive:'
} >> $OUT
session central 10 $RAW/central-3-arb-alive.txt 'stat\nquery out-arb-1m.bin\nobtain out-arb-1m.bin\nobtain out-arb-40m.bin\nquit\n'
{
echo
echo '##    now HARD kill (SIGKILL) of vm11, the PUBLISHER (journal owner)'
echo '##    of both arbitrary names; placement re-converges to 3 live copies'
echo '##    and a fresh --cli console on vm12 obtains from the SURVIVING'
echo '##    ring holders - the names survive their publisher'"'"'s death:'
} >> $OUT
echo "  kill issued $(date -u '+%Y-%m-%dT%T.%3NZ') on vm11 (arbitrary-name publisher)" >> $OUT
kill9 11
sleep 20
log "central arb converge: out-arb-1m.bin -> $(wait_copies out-arb-1m.bin 3 300)"
session central 12 $RAW/central-4-arb-ownerdead.txt 'query out-arb-1m.bin\nobtain out-arb-1m.bin\nquit\n'
{
echo
echo '## 6. Task 2 demo: HARD kill (SIGKILL) of the central index server'
echo '##    (vm01). The lookup plane is dead, so the client synthesizes the'
echo '##    holder list from the placement rule instead of failing: the'
echo '##    "[client] lookup failed ..." fallback line is visible below, and'
echo '##    the obtain succeeds from probed live holders (vm09 session,'
echo '##    holder of the target file: none).'
} >> $OUT
kill9 1
sleep 3
session central 9 $RAW/central-5-indexdeath.txt 'query n05_s000000.txt\nobtain n05_s000000.txt\nquit\n'
stop_topo

start_topo star gc
{
echo
echo '###################### STAR DEPLOYMENT ##########################'
echo '## star: hub vm02 + 15 leaves; every query path is leaf->hub->leaf'
echo '## (TTL-scoped flood). Session node vm03 is a leaf and the target'
echo '## files live on OTHER leaves - every session-to-holder path crosses'
echo '## the hub (exactly 2 overlay hops).'
echo '## 1. p2p ping --target 127.0.0.1:51001, every peer:'
} >> $OUT
for i in $(seq 2 17); do
  printf 'vm%02d: ' $i >> $OUT
  $SSHO cc@$(vm $i) 'cd ~/pa2 && ~/pa2/p2p ping --target 127.0.0.1:51001' >> $OUT 2>&1
done
mirror_ok n12_s000000.txt 12
mirror_ok n12_b0.bin 12
{
echo '## 2. --cli console on leaf vm03. Target files: n12_s000000.txt'
echo '##    (holders {12,16,17}) and n12_b0.bin (holders {8,9,12}): owner'
echo '##    vm12 is a leaf too - the console on vm03 never touches the'
echo '##    holder side directly; hit list = 3 designed copies.'
} >> $OUT
session star 3 $RAW/star-1-pre.txt 'stat\nquery n12_s000000.txt\nobtain n12_s000000.txt\nobtain n12_b0.bin\nquit\n'
{
echo
echo '## 3. HARD kill (SIGKILL) of leaf vm12 (owner of both targets, one of'
echo '##    their designed holders). Maintenance re-converges to 3 live'
echo '##    copies; a NEW leaf console (a surviving non-holder leaf picked'
echo '##    dynamically below) obtains from the surviving ring holders:'
} >> $OUT
echo "  kill issued $(date -u '+%Y-%m-%dT%T.%3NZ') on vm12" >> $OUT
kill9 12
sleep 20
log "star converge: n12_s000000.txt -> $(wait_copies n12_s000000.txt 3 300)"
log "star converge: n12_b0.bin -> $(wait_copies n12_b0.bin 3 300)"
POSTS=$(dyn_cli n12_s000000.txt n12_b0.bin 4 5 6 7 9 10 11 13 14 15)
[ "$POSTS" != 0 ] || die "no post-kill session node on star"
session star $POSTS $RAW/star-2-post.txt 'query n12_s000000.txt\nobtain n12_s000000.txt\nobtain n12_b0.bin\nstat\nquit\n'
{
echo "##    (this console ran on vm$POSTS)"
echo
echo '## 4. Task 2 demo: HARD kill (SIGKILL) of the HUB vm02 - every leaf'
echo '##    loses its only overlay link. A leaf console (vm05, holder of'
echo '##    neither file) tries a query: the flood finds zero hits, and the'
echo '##    ring fallback probes the designed placements over the DATA plane'
echo '##    (overlay-only design: download ports are direct VM-to-VM).'
echo '##    The "[client] lookup failed" line is visible in the capture:'
} >> $OUT
echo "  kill issued $(date -u '+%Y-%m-%dT%T.%3NZ') on vm02 (star hub)" >> $OUT
kill9 2
sleep 3
session star 5 $RAW/star-3-hubdeath.txt 'query n12_s000000.txt\nobtain n12_s000000.txt\nquit\n'
stop_topo

start_topo mesh gc
{
echo
echo '###################### MESH DEPLOYMENT ##########################'
echo '## mesh: 4x4 grid (vm02 at (row0,col0) ... vm17 at (row3,col3)),'
echo '## TTL-scoped flood (TTL=8 covers the diameter 6).'
echo '## 1. p2p ping --target 127.0.0.1:51001, every peer:'
} >> $OUT
for i in $(seq 2 17); do
  printf 'vm%02d: ' $i >> $OUT
  $SSHO cc@$(vm $i) 'cd ~/pa2 && ~/pa2/p2p ping --target 127.0.0.1:51001' >> $OUT 2>&1
done
mirror_ok n02_s000002.txt 2
mirror_ok n02_b0.bin 2
{
echo '## 2. --cli console on vm17 = the OPPOSITE CORNER from the owner'
echo '##    vm02: target files n02_s000002.txt / n02_b0.bin, both with'
echo '##    designed holders {2,3,4} - grid distance from vm17 to holders'
echo '##    is 6/5/4 hops, so the console is >= 2 hops from every copy.'
echo '##    Hit list shows the 3 designed copies.'
} >> $OUT
session mesh 17 $RAW/mesh-1-pre.txt 'stat\nquery n02_s000002.txt\nobtain n02_s000002.txt\nobtain n02_b0.bin\nquit\n'
{
echo
echo '## 3. HARD kill (SIGKILL) of vm02, the corner that owns BOTH files and'
echo '##    one of their designed placements. The grid re-converges both'
echo '##    names to 3 live copies; the new console sits on corner vm14,'
echo '##    >= 2 hops from every surviving holder, and obtains BOTH files'
echo '##    (small + 100 MiB) across the grid:'
} >> $OUT
echo "  kill issued $(date -u '+%Y-%m-%dT%T.%3NZ') on vm02" >> $OUT
kill9 2
sleep 20
log "mesh converge: n02_s000002.txt -> $(wait_copies n02_s000002.txt 3 300)"
log "mesh converge: n02_b0.bin -> $(wait_copies n02_b0.bin 3 300)"
POSTM=$(dyn_cli n02_s000002.txt n02_b0.bin 14 5 7 9 16 15 12 11 10 6 8 13)
[ "$POSTM" != 0 ] || die "no post-kill session node on mesh"
session mesh $POSTM $RAW/mesh-2-post.txt 'query n02_s000002.txt\nobtain n02_s000002.txt\nobtain n02_b0.bin\nstat\nquit\n'
stop_topo

log "cleanup: removing out-arb-* from all VMs + journal scrub"
for i in $(seq 2 17); do
  $SSHO cc@$(vm $i) "rm -f /data/shared/out-arb-* /data/shared/out-arb-*.part /data/downloads/out-arb-*; [ -f /data/.p2p-repl.meta ] && sed -i '/^out-arb-/d' /data/.p2p-repl.meta; true" &
done
wait
LEFT=0
for i in $(seq 2 17); do
  n=$($SSHO cc@$(vm $i) 'ls /data/shared/ 2>/dev/null | grep -c "^out-arb-" || true' 2>/dev/null)
  [ "${n:-0}" = 0 ] || LEFT=$((LEFT + 1))
done
[ "$LEFT" = 0 ] || die "out-arb cleanup failed on $LEFT VMs"
log "CLEANUP-OK: no out-arb-* names on any VM, journals scrubbed"

{
echo
echo '## ================= Known limitations =========================='
echo '## (verbatim from readme.txt section 8 - the two documents are kept'
echo '## in sync; scripts/make-output3.sh re-reads the readme at capture'
echo '## time so the copy can never drift.)'
awk '/^8\. KNOWN LIMITATIONS/{f=1;print;next} f&&/^[0-9]+\.[ ]/{exit} f{print}' readme.txt
echo '## =============== end Known limitations ========================'
} >> $OUT

DL=$(grep -c 'display file .* .* from .*: download' $OUT || true)
DLF=$(grep -c "display file '.*' ... FAILED" $OUT || true)
Q3=$(grep -c -- '^\[client\] query .* -> 3 hit(s)' $OUT || true)
FB=$(grep -c '^\[client\] lookup failed' $OUT || true)
QALL=$(grep -c -- "^\[client\] query .* -> [0-9]* hit(s)" $OUT || true)
EXPECT_DL=17; EXPECT_Q3=4; EXPECT_FB=4; EXPECT_QALL=10
{
  echo "outdemo3 counts: display_lines=$DL display_failed=$DLF query_lines=$QALL three-hit-lines=$Q3 fallback_lines=$FB"
} | tee -a "$RUNLOG"
OK=1
[ "$DL" -ge "$EXPECT_DL" ] || { echo "OUT-FAIL: display file lines $DL < $EXPECT_DL" | tee -a "$RUNLOG"; OK=0; }
[ "$DLF" = 0 ] || { echo "OUT-FAIL: $DLF obtain(s) FAILED in the capture" | tee -a "$RUNLOG"; OK=0; }
[ "$Q3" -eq "$EXPECT_Q3" ] || { echo "OUT-FAIL: three-holder query lines $Q3 != $EXPECT_Q3" | tee -a "$RUNLOG"; OK=0; }
[ "$QALL" -eq "$EXPECT_QALL" ] || { echo "OUT-FAIL: total query lines $QALL != $EXPECT_QALL (stray timeout/no-result line?)" | tee -a "$RUNLOG"; OK=0; }
[ "$FB" -eq "$EXPECT_FB" ] || { echo "OUT-FAIL: fallback lines $FB != $EXPECT_FB" | tee -a "$RUNLOG"; OK=0; }
[ "$OK" = 1 ] || exit 1
log "OUTDEMO3-OK display_lines=$DL query_lines=$QALL three_hit_lines=$Q3 fallback_lines=$FB raw captures: results/output-raw/ (shipped output.txt is the same captures concatenated)"
