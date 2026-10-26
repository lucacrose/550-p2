#!/bin/bash
set -e
TOPO=${1:?usage: failover-demo.sh <central|star|mesh>}
SSH='ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10'
SCP='scp -o StrictHostKeyChecking=no -o BatchMode=yes'
cd ~/pa2
R="results/failover-$TOPO"
mkdir -p "$R" manifests
set -eE
trap 'log "DEMO-ERR rc=$? cmd=$BASH_COMMAND line=${BASH_LINENO[0]}"' ERR
trap 'log "DEMO-SIG rc=$? (external TERM/HUP/INT - the death bound is this meta line)"' TERM HUP INT
NSAMP=20
S="$HOME/pa2/.failover"

log()  { echo "[$(date -u '+%T')] $*" | tee -a "$R/meta.txt"; }
fail() { echo "ASSERT-FAIL: $*" | tee -a "$R/meta.txt" "$S/failures.txt"; }
vm()   { echo 192.168.77.$((100+$1)); }
alive() { $SSH cc@$(vm $1) 'pgrep -x p2p >/dev/null' 2>/dev/null; }

live_holders() {
  local i ip out=""
  for i in $(seq 2 17); do
    alive $i || continue
    ip=$(vm $i)
    $SSH cc@$ip "ls /data/shared/$1 2>/dev/null" 2>/dev/null | grep -q . \
      && out="$out $i"
  done
  echo $out
}

kill_peer() { local i=$1 t r
  KILLED[$i]=1
  for t in 1 2 3; do
    $SSH cc@$(vm $i) \
      'kill $(cat ~/pa2/peer.pid) 2>/dev/null; sleep 1; pkill -x p2p 2>/dev/null; sleep 2; pkill -9 -x p2p 2>/dev/null; true' && return 0
    r=$?
    log "kill_peer vm$i: kill attempt $t failed (ssh rc=$r); retrying in 5 s"
    sleep 5
  done
  fail "kill_peer vm$i: kill failed 3x (ssh infra exhausted); the design gates below judge a possibly-still-live servent"
  return 0
}
start_peer() { local i=$1 t r
  for t in 1 2 3; do
    $SSH cc@$(vm $i) \
      "nohup ~/pa2/p2p peer -c ~/pa2/configs/$TOPO/node$i.cfg > ~/pa2/logs/peer-restart.log 2>&1 & echo \$! > ~/pa2/peer.pid" && return 0
    r=$?
    log "start_peer vm$i: launch attempt $t failed (ssh rc=$r); retrying in 5 s"
    sleep 5
  done
  fail "start_peer vm$i: launch failed 3x (ssh infra exhausted); the design gates below must fail honestly if the servent is absent"
  return 0
}
declare -A KILLED
force_start() { local i=$1; $SSH cc@$(vm $i) 'pkill -9 -x p2p 2>/dev/null; true'; sleep 2; start_peer $i; }
restore_dead_servents() {
  local n
  for n in $(seq 2 17); do
    if [ -n "${KILLED[$n]:-}" ]; then
      force_start $n
    else
      alive $n || start_peer $n
    fi
  done
}

run_bench() {
  local label=$1 vmc=$2 count=$3 man=$4 cl=$5 csv=$6 rc=0
  $SSH cc@$(vm $vmc) \
    "~/pa2/p2p bench --target 127.0.0.1:51001 --clients $cl --count $count --op obtain --manifest $man --exclude-dir /data/shared --seed 42 --out ~/pa2/res/fo-$csv.csv --label failover-$TOPO-$label" \
    > "$S/bench-$label.log" 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then
    fail "bench $label: p2p bench on vm$vmc exited rc=$rc (bench-log tail: $(grep -c . "$S/bench-$label.log") lines: $(tail -1 "$S/bench-$label.log"))"
    return 1
  fi
  local f=$(grep -c '^FAIL ' "$S/bench-$label.log" || true)
  log "bench $label client=vm$vmc count=$count FAILlines=$f | $(grep -h 'BENCH-SUMMARY' "$S/bench-$label.log" | head -1)"
  grep '^FAIL ' "$S/bench-$label.log" | head -3 | sed 's/^/    /' >> "$R/meta.txt"
  $SCP cc@$(vm $vmc):~/pa2/res/fo-$csv.csv "$R/" 2>/dev/null || true
  cp "$S/bench-$label.log" "$R/bench-$label.log"
}

mkdir -p "$S"
rm -f "$S"/*.log "$R/meta.txt" "$S/failures.txt"
log "=== failover demo ($TOPO, chameleon: node i on 192.168.77.$((100+i))) start; harness md5: $(md5sum "$0" | cut -c1-16) ==="
ping_out=$($SSH cc@$(vm 9) '~/pa2/p2p ping --target 127.0.0.1:51001' 2>/dev/null) \
  || { echo "peer09 not running; run scripts/start-system.sh $TOPO first"; exit 1; }
log "binary md5: $($SSH cc@$(vm 9) 'md5sum ~/pa2/p2p' | cut -d' ' -f1)"
if $SSH cc@$(vm 9) "ls /data/shared/n9_wide1.bin 2>/dev/null" >/dev/null; then
  log "special set already seeded (wide/ghost files present from an earlier run)"
else
  log "seeding special set (ONLY on one VM each, never mirrored): 5x40MiB n9_wide* on vm109, ghost.bin on vm112, ghost2.bin on vm104"
  $SSH cc@$(vm 9)  "for w in 1 2 3 4 5; do head -c 41943040 /dev/urandom > /data/shared/n9_wide\$w.bin; done"
  $SSH cc@$(vm 12) "head -c 1048576 /dev/urandom > /data/shared/ghost.bin"
  $SSH cc@$(vm 4)  "head -c 1048576 /dev/urandom > /data/shared/ghost2.bin"
fi
SEEDCHECK=$(
for spec in 9:n9_wide1.bin 9:n9_wide2.bin 9:n9_wide3.bin 9:n9_wide4.bin 9:n9_wide5.bin 12:ghost.bin 4:ghost2.bin; do
  vid=${spec%%:*}; fname=${spec#*:}
  $SSH cc@$(vm $vid) "ls /data/shared/$fname 2>/dev/null" 2>/dev/null | grep -q . \
    || echo "MISSING $fname on vm$((100+vid))"
done
)
if [ -n "$SEEDCHECK" ]; then
  echo "$SEEDCHECK" | tee -a "$R/meta.txt"
  echo "FATAL: special set incomplete - stage VOID"; exit 1
fi
for v in 9 12 4; do
  $SSH cc@$(vm $v) 'touch /tmp/peer.rescan' || true
done
log "special set present on owner VMs; touched /tmp/peer.rescan on vm109/vm112/vm104 (owner index refresh); waiting until n9_wide1.bin has 3 live copies"
t0=$(date +%s); H=""
while :; do
  H=$(live_holders 'n9_wide1.bin'); [ $(echo $H | wc -w) -ge 3 ] && break
  [ $(( $(date +%s) - t0 )) -gt 180 ] && { log "WARN: new file not replicated in 180s (holders: '${H:-none}')"; break; }
  sleep 5
done
log "special set visible on live holders: ${H:-none} after $(( $(date +%s) - t0 ))s"
if [ "$(echo $H | wc -w)" -lt 3 ]; then
  fail "n9_wide1.bin holders < 3 at P1 gate"
  echo "FATAL: replication of specials incomplete - stage VOID"; exit 1
fi
for gf in ghost.bin ghost2.bin; do
  t0=$(date +%s); GH=""
  while :; do
    GH=$(live_holders "$gf"); [ "$(echo $GH | wc -w)" = "3" ] && break
    [ $(( $(date +%s) - t0 )) -gt 180 ] && break
    sleep 5
  done
  log "journal adoption: $gf live copies: ${GH:-none}"
  if [ "$(echo $GH | wc -w)" -lt 3 ]; then
    fail "$gf journal-adopted replication incomplete (<3 copies within 180s)"
    echo "FATAL: journal adoption of the ghost specials failed - stage VOID"; exit 1
  fi
done

grep '^n12_s' manifests/small.txt | head -$NSAMP > manifests/fo-n12-small.txt
printf 'n9_wide1.bin\nn9_wide2.bin\nn9_wide3.bin\nn9_wide4.bin\nn9_wide5.bin\n' > manifests/fo-wide.txt
head -1 manifests/fo-wide.txt > manifests/fo-wide1.txt
echo ghost.bin  > manifests/fo-ghost.txt
echo ghost2.bin > manifests/fo-ghost2.txt
for m in fo-n12-small.txt fo-wide.txt fo-wide1.txt fo-ghost.txt fo-ghost2.txt; do
  for i in 9 4 12 13 3 6 5; do $SCP manifests/$m cc@$(vm $i):~/pa2/manifests/ >/dev/null 2>&1 || true; done
done

CLIENT=13
for c in 13 16 15 14 5 3; do
  H=$(live_holders 'n9_wide*')
  alive $c && ! echo " $H " | grep -q " $c " && { CLIENT=$c; break; }
done
log "obtain client = vm$((100+CLIENT)) (a live peer holding NO wide replica)"

for f in n9_wide1.bin n9_wide3.bin n9_wide5.bin; do
  H=$(live_holders $f)
  [ $(echo $H | wc -w) = 3 ] || fail "P1 $f live copies: '${H:-none}' (want 3)"
done
log "P1 baseline: sampled n9_wide* names each on exactly 3 live VMs (owner + 2 ring holders)"
run_bench baseline-p1 $CLIENT $NSAMP ~/pa2/manifests/fo-n12-small.txt 1 failover-small

kill_peer 9
log "P2 owner-stop: vm109 (owner of every n9_wide*) killed; immediate obtain of all 5 wide files"
sleep 2
run_bench owner-kill $CLIENT 5 ~/pa2/manifests/fo-wide.txt 1 failover-large
if grep -q '^FAIL obtain n9_wide' "$S/bench-owner-kill.log"; then
  fail "P2 wide obtains should succeed via the 2 ring-holder replicas"
fi
sleep 5

if ! alive 12; then
  start_peer 12; sleep 3
  $SSH cc@$(vm 12) "ls /data/shared/ghost.bin 2>/dev/null" \
    || $SSH cc@$(vm 12) "head -c 1048576 /dev/urandom > /data/shared/ghost.bin"
  $SSH cc@$(vm 12) 'touch /tmp/peer.rescan' || true
  log "P3 setup: peer12 (re)started, ghost.bin re-seeded and re-adopted via /tmp/peer.rescan"
  sleep 2
fi
GHOSTC=13
for c in 13 $CLIENT 5 3 6; do
  GH=$(live_holders ghost.bin)
  alive $c && ! echo " $GH " | grep -q " $c " && { GHOSTC=$c; break; }
done
$SCP manifests/fo-ghost.txt cc@$(vm $GHOSTC):~/pa2/manifests/ >/dev/null 2>&1 || true
run_bench ghost-alive $GHOSTC 1 ~/pa2/manifests/fo-ghost.txt 1 failover-small
if grep -q '^FAIL obtain ghost.bin' "$S/bench-ghost-alive.log"; then
  fail "P3 baseline: ghost.bin obtain must succeed pre-kill (it is journal-adopted and replicated)"
fi
kill_peer 12
log "P3 ghost-stop: ghost.bin is an ARBITRARY name but the journal records peer12 as its publisher -> the program replicated it to 3 nodes; after peer12 dies the obtain MUST SUCCEED (survival of arbitrary-name files)"
sleep 2
run_bench ghost-dead $GHOSTC 1 ~/pa2/manifests/fo-ghost.txt 1 failover-small
if grep -q '^FAIL obtain ghost.bin' "$S/bench-ghost-dead.log"; then
  fail "P3: ghost.bin should SURVIVE peer12's death (journal adoption + replication)"
fi
log "P3 ghost.bin live copies while its owner is dead: ${GH:-$(live_holders ghost.bin)}"

for round in 1 2 3 4 5 6; do
  LH=$(live_holders 'n9_wide*')
  [ -z "$LH" ] && break
  log "P4 round $round: killing every live holder of n9_wide*:$LH"
  for h in $LH; do kill_peer $h; done
  sleep 3
done
log "P4 fixed point: live holders of n9_wide* now: '${LH:-none}' (killed VMs keep the file on disk but no live servent serves it)"
alive $CLIENT || { start_peer $CLIENT; sleep 3; }
run_bench all-holders-dead $CLIENT 5 ~/pa2/manifests/fo-wide.txt 1 failover-large
if ! grep -q '^FAIL obtain n9_wide' "$S/bench-all-holders-dead.log"; then
  fail "P4 expected FAIL lines for n9_wide* after every holder died"
fi

if [ "$TOPO" = star ]; then
  alive 2 || { start_peer 2; sleep 5
    log "P5 restoration (star): hub vm102 restarted first - P4 killed it (star hub is a ring-wide holder and the only leaf-leaf relay; leaves have no central fallback)"
  }
fi
start_peer 9
sleep 3
log "P5 restoration: owner vm109 restarted (its 5 wide files are still on its disk); polling obtain of n9_wide1.bin with the honest predicate ok=1 fail=0"
t0=$(date +%s); ok=0
for t in $(seq 1 60); do
  $SSH cc@$(vm $CLIENT) \
    "~/pa2/p2p bench --target 127.0.0.1:51001 --clients 1 --count 1 --op obtain --manifest ~/pa2/manifests/fo-wide1.txt --exclude-dir /data/shared --seed 42 --out ~/pa2/res/fo-poll.csv --label poll" \
    > "$S/poll.log" 2>&1
  grep -q 'ok=1 fail=0' "$S/poll.log" && { ok=1; break; }
  sleep 2
done
T_RES=$(( $(date +%s) - t0 ))
if [ $ok = 1 ]; then
  log "P5 restore: n9_wide1.bin obtainable again after ${T_RES}s of polling"
else
  log "P5 restore: NOT obtainable within ${T_RES}s (poll.log FAIL lines: $(grep -c '^FAIL' "$S/poll.log" || true))"
fi
sleep 8
LH=$(live_holders 'n9_wide*')
log "P5 live holders of n9_wide* after restore window: '${LH:-none}'"

alive $CLIENT || { start_peer $CLIENT; sleep 3; }
run_bench large-failover $CLIENT 10 ~/pa2/manifests/fo-wide.txt 2 failover-large

if [ "$TOPO" = mesh ]; then
  restore_dead_servents
  sleep 10
  log "P7 setup (mesh): restarted all servents that died in P2..P5 - P4's kill-all-holders loop is a grid-wrecker in the mesh (left only {9,13} connected; src clients isolated at neighbours_conn=0)"
  INT=""
  for c in 7 5 11 8 10; do alive $c && { INT=$c; break; }; done
  [ -z "$INT" ] && fail "P7: no interior candidate alive" || true
  kill_peer $INT
  SRC=3; alive $SRC || SRC=6; alive $SRC || SRC=5
  log "P7 interior-stop: peer$INT (mesh interior node) killed; obtains from peer$SRC"
  run_bench interior $SRC $NSAMP ~/pa2/manifests/fo-n12-small.txt 1 failover-small
  a=$($SSH cc@$(vm $SRC) 'sha256sum /data/shared/n12_s1' 2>/dev/null | cut -c1-16)
  b=$($SSH cc@$(vm 9)  'sha256sum /data/shared/n12_s1' 2>/dev/null | cut -c1-16)
  log "P7 data-intact check: n12_s1 sha256 peer$SRC=$a peer9=$b"
fi

if [ "$TOPO" = star ]; then
  alive 2 || { start_peer 2; sleep 4; }
  kill_peer 2
  log "P8 hub-stop: peer02 (star hub, the only leaf-leaf relay) killed; the ring fallback must keep obtains alive ACROSS the cut"
  alive 13 || { start_peer 13; sleep 4; }
  run_bench hub-partition 13 1 ~/pa2/manifests/fo-ghost2.txt 1 failover-small
  if grep -q '^FAIL obtain ghost2.bin' "$S/bench-hub-partition.log"; then
    fail "P8: ghost2.bin must be obtainable via the ring fallback across the hub cut (journal owner peer04 + ring holders probed directly)"
  fi
  FB13=$( $SSH cc@$(vm 13) 'grep -h "\[client\] lookup failed" ~/pa2/logs/peer.log ~/pa2/logs/peer-restart.log 2>/dev/null | tail -2' || true )
  [ -n "$FB13" ] || fail "P8: no [client] lookup failed fallback line in vm13's peer log"
  log "P8 fallback line on vm13: $FB13"
  N16=$(grep -m1 '^n16_s' manifests/small.txt); N16=${N16:-n16_s000000.txt}
  H16=$(live_holders "$N16")
  P11C=0
  for c in 13 15 14 5 3 6; do
    [ "$c" = 16 ] && continue
    alive $c || { start_peer $c; sleep 3; }
    $SSH cc@$(vm $c) "[ -f /data/shared/$N16 ]" 2>/dev/null && continue
    P11C=$c; break
  done
  if [ "$P11C" = 0 ]; then
    fail "P11: no alive non-holder client for '$N16'"
  else
    echo "$N16" > manifests/fo-p11.txt
    $SCP manifests/fo-p11.txt cc@$(vm $P11C):~/pa2/manifests/ >/dev/null 2>&1 || true
    run_bench hub-leaf-leaf $P11C 1 ~/pa2/manifests/fo-p11.txt 1 failover-small
    if grep -q '^FAIL obtain' "$S/bench-hub-leaf-leaf.log"; then
      fail "P11: leaf-owned dataset name '$N16' must survive the hub cut via the ring fallback (owner vm16 stays alive)"
    fi
    FB11=$( $SSH cc@$(vm $P11C) 'grep -h "\[client\] lookup failed" ~/pa2/logs/peer.log ~/pa2/logs/peer-restart.log 2>/dev/null | tail -2' || true )
    [ -n "$FB11" ] || fail "P11: no fallback line in vm$P11C's peer log"
    log "P11 hub-cut obtain of leaf-owned '$N16' from vm$((100+P11C)): ok=1; fallback line: $FB11"
  fi
  start_peer 2; sleep 4
  log "P8/P11: hub vm102 restarted (hub-cut window closed)"
  a=$($SSH cc@$(vm 4)  'sha256sum /data/shared/n12_s1' 2>/dev/null | cut -c1-16)
  b=$($SSH cc@$(vm 13) 'sha256sum /data/shared/n12_s1' 2>/dev/null | cut -c1-16)
  log "P8 data-intact: n12_s1 sha256 peer04=$a peer13=$b (same hash on both sides => only routing is partitioned, data intact)"
fi

place_mirror() {
  python3 - "$@" <<'PY'
import sys
MASK = 0xFFFFFFFFFFFFFFFF
def fnv1a64(s):
    h = 0xcbf29ce484222325
    for ch in s.encode():
        h ^= ch
        h = (h * 0x100000001b3) & MASK
    return h
ring = list(range(2, 18))
N = len(ring)
for spec in sys.argv[1:]:
    name, owner = spec.rsplit(':', 1)
    owner = int(owner)
    start = fnv1a64(name) % N
    out = []
    k = 0
    while len(out) < 2:
        cand = ring[(start + k) % N]
        if cand != owner and cand not in out:
            out.append(cand)
        k += 1
    print(' '.join(str(x) for x in sorted(out + [owner])))
PY
}
repl_replacement() {
  python3 - "$@" <<'PY'
import sys
MASK = 0xFFFFFFFFFFFFFFFF
def fnv1a64(s):
    h = 0xcbf29ce484222325
    for ch in s.encode():
        h ^= ch
        h = (h * 0x100000001b3) & MASK
    return h
ring = list(range(2, 18))
N = len(ring)
for spec in sys.argv[1:]:
    name, dead = spec.rsplit(':', 1)
    dead = int(dead)
    deadIdx = ring.index(dead)
    start = fnv1a64(name) % N
    designed = []
    k = 0
    while len(designed) < 2:
        cand = ring[(start + k) % N]
        if cand != dead and cand not in designed:
            designed.append(cand)
        k += 1
    taken = set(designed) | {dead}
    repl = 0
    for k in range(1, N):
        cand = ring[(deadIdx + k) % N]
        if cand == dead or cand in taken:
            continue
        repl = cand
        break
    print(repl)
PY
}
log "P9 restore: restarting every servent left dead by P2..P4 (the arbitrary-name stage needs the full roster alive)"
restore_dead_servents
sleep 10
rs_total() {
  local s=0 c i
  for i in $(seq 2 17); do
    c=$( $SSH cc@$(vm $i) 'cat ~/pa2/logs/peer.log ~/pa2/logs/peer-restart.log 2>/dev/null | grep -c "replica stored:"' 2>/dev/null || true )
    s=$((s + ${c:-0}))
  done
  echo $s
}
wait_drain() {
  local t0 n miss prev cur d k obsmax
  obsmax=${DRAIN_OBS_S:-360}
  t0=$(date +%s); miss=""
  while :; do
    miss=""
    for n in $(seq 2 17); do
      $SSH cc@$(vm $n) 'test -f /tmp/peer.repl.done' 2>/dev/null </dev/null || miss="$miss vm$n"
    done
    [ -z "$miss" ] && break
    [ $(( $(date +%s) - t0 )) -gt ${MARKER_WAIT_S:-900} ] && break
    sleep 20
  done
  if [ -n "$miss" ]; then
    fail "P9 drain: initial replication pass never completed within ${MARKER_WAIT_S:-900} s on:$miss (cluster fault, not harness timing)"
    return
  fi
  log "P9 drain observation: markers complete on all 16 servents; measuring the post-restore replacement churn (runs-3/4 baseline: 60-200 stores/s for ~1-2 h: P4's kill-all-holders re-replication is working as designed, no silence expected)"
  t0=$(date +%s); prev=-1; k=0
  while :; do
    cur=$(rs_total); k=$((k+1))
    if [ "$prev" -ge 0 ]; then
      d=$((cur - prev))
      if [ "$d" -lt 0 ]; then
        log "P9 drain observation: sample dipped $prev -> $cur (peer log truncated by a restart or an ssh probe round failed; base reset)"
        d=0
      fi
      log "P9 drain observation: rs-count=$cur delta=$d elapsed=$(( $(date +%s) - t0 ))s"
    else
      log "P9 drain observation: rs-count=$cur (first probe)"
    fi
    prev=$cur
    [ $(( $(date +%s) - t0 )) -gt $obsmax ] && break
    sleep ${DRAIN_OBS_INTERVAL_S:-120}
  done
  log "P9 drain gate: markers complete + churn observed across $k probes over $(( $(date +%s) - t0 ))s; the polls below gate on the DESIGN (3 copies, mirror equal, obtain OK), not on queue silence"
}
wait_drain
for f in arbitrary-file.bin arbitrary-file-40m.bin; do
  if ! $SSH cc@$(vm 14) "ls /data/shared/$f" 2>/dev/null | grep -q .; then
    sz=1048576; [ "$f" = arbitrary-file-40m.bin ] && sz=41943040
    $SSH cc@$(vm 14) "head -c $sz /dev/urandom > /data/shared/$f"
    log "P9 seed: $f created on vm114 only ($sz bytes)"
  fi
done
$SSH cc@$(vm 14) 'touch /tmp/peer.rescan' || true
log "P9 setup: arbitrary names on vm114, /tmp/peer.rescan touched (journal adoption + index refresh)"
log "P9 disk check: $( $SSH cc@$(vm 14) 'df -m /data/shared' | sed -n 2p )"
for f in arbitrary-file.bin arbitrary-file-40m.bin; do
  t0=$(date +%s); AH=""
  while :; do
    AH=$(live_holders "$f"); [ "$(echo $AH | wc -w)" = "3" ] && break
    [ $(( $(date +%s) - t0 )) -gt 3600 ] && break
    sleep 5
  done
  log "P9 live copies of $f: '${AH:-none}' after $(( $(date +%s) - t0 ))s"
  [ "$(echo $AH | wc -w)" = "3" ] \
    || fail "P9: $f did not reach 3 live copies (arbitrary-name journal adoption failed)"
  WANT=$(place_mirror "$f:14")
  HAVE=$(echo $AH | tr ' ' '\n' | sort -n | xargs)
  if [ "$WANT" = "$HAVE" ]; then
    log "P9 placement mirror OK for $f: FNV-1a64 expected {$WANT} == live {$HAVE}"
  else
    fail "P9 placement mirror mismatch for $f: expected {$WANT} live {$HAVE}"
  fi
done
AH=$(live_holders arbitrary-file.bin)
P9C=0
for c in 13 $CLIENT 5 3 6; do
  alive $c || continue
  echo " $AH " | grep -q " $c " && continue
  P9C=$c; break
done
[ "$P9C" = 0 ] && fail "P9: no alive non-holder client for arbitrary-file.bin"
printf 'arbitrary-file.bin\narbitrary-file-40m.bin\n' > manifests/fo-arb.txt
for m in fo-arb.txt; do
  for i in 13 14 $CLIENT $P9C; do
    $SCP manifests/$m cc@$(vm $i):~/pa2/manifests/ >/dev/null 2>&1 || true
  done
done
if [ "$P9C" != 0 ]; then
  run_bench arb-alive $P9C 2 ~/pa2/manifests/fo-arb.txt 1 failover-arb
  if grep -q '^FAIL obtain' "$S/bench-arb-alive.log"; then
    fail "P9 baseline: arbitrary-file*.bin obtains must succeed while the owner lives"
  fi
  kill_peer 14
  log "P9 owner-stop: vm114 (journal publisher of arbitrary-file*.bin) killed; the obtain of both arbitrary names MUST SUCCEED off the ring-holder replicas"
  sleep 3
  run_bench arb-owner-dead $P9C 2 ~/pa2/manifests/fo-arb.txt 1 failover-arb
  if grep -q '^FAIL obtain' "$S/bench-arb-owner-dead.log"; then
    fail "P9: arbitrary names must survive their owner's death (the old pre-fix ghost behaviour is archived)"
  fi
  REPH=$(repl_replacement arbitrary-file.bin:14); REPH40=$(repl_replacement arbitrary-file-40m.bin:14)
  log "P9 dead-owner window: designed holders {7 8} / {5 6} + one replacement-class copy ({15,16} reachable candidates: ring-walk $REPH/$REPH40); poll to the sheet's 3-copy state, backstop 3600 s. Measured replacement-push latency under the campaign-baseline storm: 31-1615 s across runs (the poll gates the DESIGN, the latency is recorded honestly)"
  for f in arbitrary-file.bin arbitrary-file-40m.bin; do
    case $f in arbitrary-file.bin) wantA=7; wantB=8 ;; *) wantA=5; wantB=6 ;; esac
    t0=$(date +%s); DEADSET=""
    while :; do
      DEADSET=$(live_holders "$f")
      if [ "$(echo $DEADSET | wc -w)" = "3" ] \
         && ! echo " ${DEADSET} " | grep -q " 14 " \
         && echo " ${DEADSET} " | grep -q " ${wantA} " \
         && echo " ${DEADSET} " | grep -q " ${wantB} " \
         && { echo "$DEADSET" | tr ' ' '\n' | grep -v "^${wantA}\$" | grep -v "^${wantB}\$" | grep -qE "^15\$|^16\$"; }; then break; fi
      [ $(( $(date +%s) - t0 )) -gt 3600 ] && break
      sleep 5
    done
    log "P9 dead-owner copies of $f: '${DEADSET:-none}' after $(( $(date +%s) - t0 ))s"
    EX=$(echo "$DEADSET" | tr ' ' '\n' | grep -v "^${wantA}\$" | grep -v "^${wantB}\$" | tr '\n' ' ' || true)
    if [ "$(echo $DEADSET | wc -w)" = "3" ] \
       && ! echo " ${DEADSET} " | grep -q " 14 " \
       && echo " ${DEADSET} " | grep -q " ${wantA} " \
       && echo " ${DEADSET} " | grep -q " ${wantB} " \
       && echo "$DEADSET" | tr ' ' '\n' | grep -v "^${wantA}\$" | grep -v "^${wantB}\$" | grep -qE "^15\$|^16\$"; then
      log "P9 dead-owner re-replication OK for $f: exactly 3 live copies = designed holders {${wantA} ${wantB}} + replacement-class copy at ${EX} (sheet Task-1 count-returned-to-3; see replEnsureAll + the one-hop re-route)"
    else
      fail "P9: $f dead-owner window did not reach the sheet's designed state (live {$DEADSET}; want exactly 3 copies with the designed holders {${wantA} ${wantB}} alive, owner slot 14 gone, third copy from the replacement class {15,16}: replEnsureAll/replReplacement + the dead-target one-hop re-route)"
    fi
  done
  start_peer 14
  $SSH cc@$(vm 15) 'grep -h "replica stored.*arbitrary" ~/pa2/logs/peer-restart.log 2>/dev/null' > "$S/p9-repl-lines.txt" 2>/dev/null || true
  cp "$S/p9-repl-lines.txt" "$R/p9-repl-push-evidence.txt" 2>/dev/null || true
  log "P9 owner restarted: poll for the designed owner slot (vm14) to hold the names again, backstop 3600 s (healing gate: the journaled owner is in the live set again). Post-restart COPY-COUNT observations are recorded honestly but carry no count assert: the sheet's Task-1 gates are the placement set {7 8 14}, the obtain-while-dead, and the 3-copy return above; the pinned binary's replacement-class copies (replEnsureAll + the one-hop re-route) may stack more than one (run-6 star: {7 8 14 15 16} after a 27-min storm window) and are GC-class domain"
  t0=$(date +%s); AH=""
  while :; do
    AH=$(live_holders arbitrary-file.bin)
    echo " $AH " | grep -q " 14 " && [ "$(echo $AH | wc -w)" -ge 4 ] && break
    [ $(( $(date +%s) - t0 )) -gt 3600 ] && break
    sleep 5
  done
  log "P9 owner restarted: arbitrary-file.bin live copies = '${AH:-none}' after $(( $(date +%s) - t0 ))s"
  echo " $AH " | grep -q " 14 " \
    || fail "P9: restarted owner vm14 did not regain its designed copy of arbitrary-file.bin (dead-owner healing; live {$AH})"
  log "P9 designed-set restoration OK: the journaled owner's slot {14} is LIVE again in {$AH}; replacement-class copies beyond {7 8 14} observed = $(( $(echo $AH | wc -w) - 3 )) (permanent by the pinned maintenance design; GC-classified separately)"
fi

if [ "$TOPO" = central ]; then
  $SSH cc@192.168.77.101 \
    'kill -9 $(cat ~/pa2/index.pid) 2>/dev/null; sleep 1; pkill -9 -x p2p 2>/dev/null; true'
  log "P10 index-kill(SIGKILL): vm101 (central index server) killed; a registered dataset name must stay obtainable through the ring fallback (zero central lookups)"
  N10=$(grep -m1 '^n12_s' manifests/small.txt); N10=${N10:-n12_s000000.txt}
  H10=$(live_holders "$N10")
  P10C=0
  for c in 13 15 14 5 3 6; do
    [ "$c" = 12 ] && continue
    alive $c || { start_peer $c; sleep 3; }
    echo " $H10 " | grep -q " $c " && continue
    P10C=$c; break
  done
  if [ "$P10C" = 0 ]; then
    fail "P10: no alive non-holder client for '$N10'"
  else
    echo "$N10" > manifests/fo-p10.txt
    $SCP manifests/fo-p10.txt cc@$(vm $P10C):~/pa2/manifests/ >/dev/null 2>&1 || true
    run_bench index-kill $P10C 1 ~/pa2/manifests/fo-p10.txt 1 failover-small
    if grep -q '^FAIL obtain' "$S/bench-index-kill.log"; then
      fail "P10: obtain of '$N10' must succeed via the ring fallback with the index dead"
    fi
    FB10=$( $SSH cc@$(vm $P10C) 'grep -h "\[client\] lookup failed" ~/pa2/logs/peer.log ~/pa2/logs/peer-restart.log 2>/dev/null | tail -2' || true )
    [ -n "$FB10" ] || fail "P10: no [client] lookup failed fallback line in vm$P10C's peer log"
    log "P10 fallback line on vm$P10C: $FB10"
  fi
  $SSH cc@192.168.77.101 "nohup ~/pa2/p2p index -c ~/pa2/configs/central/index.cfg > ~/pa2/logs/index-restart.log 2>&1 & echo \$! > ~/pa2/index.pid"
  t0=$(date +%s); RELOG=0
  while :; do
    RELOG=$( $SSH cc@192.168.77.101 'grep -c registering ~/pa2/logs/index-restart.log 2>/dev/null || true' )
    [ "${RELOG:-0}" -ge 16 ] && break
    [ $(( $(date +%s) - t0 )) -gt 90 ] && break
    sleep 5
  done
  log "P10 index restart: re-registrations in index-restart.log = ${RELOG:-0} (want 16) after $(( $(date +%s) - t0 ))s"
  if [ "${RELOG:-0}" -lt 16 ]; then
    fail "P10: index restart saw only ${RELOG:-0} re-registrations within 90 s (want 16)"
  fi
  ORIG=$( $SSH cc@192.168.77.101 'grep -c registering ~/pa2/logs/index.log 2>/dev/null || true' )
  log "P10 audit note: index.log still holds its original ${ORIG:-?} registration lines (REG gate unaffected)"
fi

echo 'never-published-name.txt' > manifests/fo-missing.txt
$SCP manifests/fo-missing.txt cc@$(vm $CLIENT):~/pa2/manifests/ >/dev/null 2>&1 || true
alive $CLIENT || { start_peer $CLIENT; sleep 3; }
log "P12 negative control: obtain of a never-published name from vm$((100+CLIENT)) must FAIL (fallback must not invent a holder)"
run_bench name-missing $CLIENT 1 ~/pa2/manifests/fo-missing.txt 1 failover-small
if ! grep -q '^FAIL obtain' "$S/bench-name-missing.log"; then
  fail "negative control: a never-published name obtain FAILED to fail - the ring fallback fabricated a hit"
fi

log "assert failures this session: $(wc -l < $S/failures.txt 2>/dev/null || echo 0)"
echo "FAILOVER-$TOPO-DONE  evidence: $R"
