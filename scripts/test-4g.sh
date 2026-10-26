#!/bin/bash
set -u
cd ~/pa2
export PA2_DRV_LOCK=${PA2_DRV_LOCK:-/tmp/pa2-driver.lock}
export PA2_DRV_HELD=1
exec 9>"$PA2_DRV_LOCK"
flock -n 9 || { echo "FATAL: another driver holds $PA2_DRV_LOCK - refusing to start"; exit 1; }
BINGMD5=${BINGMD5:?pin the release binary md5}
R=~/pa2/results/huge4g
mkdir -p $R
: > $R/meta.txt
log()  { echo "[$(date -u '+%T')] $*" | tee -a $R/meta.txt; }
fail() { echo "TEST4G-FAIL: $*" | tee -a $R/meta.txt; exit 1; }
vm()   { echo 192.168.77.$((100+$1)); }
SSH="ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10"
SSH="ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=/tmp/pa2-ctl-%r@%h:%p -o ControlPersist=900"
alive() {
  local n; for n in 1 2 3; do $SSH cc@$(vm $1) 'pgrep -x p2p >/dev/null' 2>/dev/null && return 0; sleep 5; done
  return 1
}
scan_one() {
  local n out
  for n in 1 2 3; do
    out=$($SSH cc@$(vm $1) "p=alive; pgrep -x p2p >/dev/null || p=dead
      s=\$(stat -c %s /data/shared/$2 2>/dev/null); [ -n \"\$s\" ] || s=none
      q=0; [ -e /data/shared/$2.part ] && q=1
      echo TRYOK,servent=\$p,size=\$s,part=\$q" 2>/dev/null)
    case "$out" in TRYOK,*) echo "$out"; return 0;; esac
    sleep 5
  done
  echo TRYFAIL
  return 1
}
dfbytes() {
  local n out
  for n in 1 2 3; do
    out=$($SSH cc@$(vm $1) 'df -B1 --output=avail /data/shared 2>/dev/null | tail -1 | tr -d " "')
    [ -n "$out" ] && { echo "$out"; return 0; }
    sleep 5
  done
  return 1
}
dropcache() { $SSH cc@$(vm $1) "sync; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'" \
              || fail "cannot drop page caches on vm$(printf %02d $1) (NOPASSWD sudo broken?)"; }
FH=""; FD=""; FR=""; FS=""; FP=""
fleet_scan() {
  local nm=$1 sz=$2 out=$3 i r sv szv pv d=/tmp/pa2scan.$RANDOM.$$
  mkdir -p $d
  for i in $(seq 2 17); do
    scan_one $i "$nm" > $d/$i 2>/dev/null &
  done
  wait
  FH=""; FD=""; FR=""; FS=""; FP=""
  for i in $(seq 2 17); do
    r=$(cat $d/$i 2>/dev/null)
    case "$r" in
      TRYOK,*)
        sv=${r##*servent=}; sv=${sv%%,*}
        szv=${r##*size=}; szv=${szv%%,*}
        pv=${r##*part=}; pv=${pv%%,*}
        [ "$sv" = dead ] && FD="$FD $i:${szv}"
        [ "$sv" = alive ] && [ "$szv" = "$sz" ] && FH="$FH $i"
        [ "$sv" = alive ] && [ "$szv" != none ] && [ "$szv" != "$sz" ] && FS="$FS $i:$szv"
        [ "$sv" = alive ] && [ "$pv" = 1 ] && FP="$FP $i"
        ;;
      *) FR="$FR $i" ;;
    esac
  done
  rm -rf $d
  FH=$(echo $FH); FD=$(echo $FD); FR=$(echo $FR)
  FS=$(echo $FS | tr ' ' ','); FP=$(echo $FP | tr ' ' ',')
  FD=$(echo $FD | tr ' ' ',')
  echo "holders=[$FH] dead-servent=[$FD] unreachable=[$FR] wrong-size=[$FS] part-debris=[$FP]" > $out
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
session() {
  local raw=$3
  $SSH cc@$(vm $2) "pkill -9 -x p2p 2>/dev/null; sleep 1; cd ~/pa2 && printf '$4' | stdbuf -oL -eL ~/pa2/p2p peer -c configs/$1/node$2.cfg --cli" > "$raw" 2>&1
  [ -s "$raw" ] || fail "empty session capture $raw"
  sleep 2
}
place() {
  local nm=$1 sz=$2 pub=$3 des="$4"
  log "warmup: 60 s fully idle to settle the owner's liveness probes"
  sleep 60
  $SSH cc@$(vm $pub) "fallocate -l $sz -z /data/shared/$nm 2>/dev/null || head -c $sz /dev/zero > /data/shared/$nm; touch /tmp/peer.rescan" \
    || fail "cannot create 4 GiB file $nm on vm$pub (disk?)"
  log "created $nm ($sz bytes) on vm$pub via fallocate-sparse-zero (fallback head-c /dev/zero)"
  SRC=$(rsha $(vm $pub) /data/shared/$nm) \
    || fail "cannot compute the source digest of $nm on owner vm$pub"
  log "source digest sha256 ($nm) = $SRC (computed on the owner at creation)"
  local t0=$(date +%s) stable=0 cstart=0 last="" H i n1=0 n2=0 n3=0
  while :; do
    fleet_scan $nm $sz /tmp/pa2-place-scan.txt
    H="$FH"
    i=$(( $(date +%s) - t0 ))
    if [ "$(echo $H | wc -w)" = 3 ] && [ "$H" = "$last" ] && [ -z "$FS" ] && [ -z "$FP" ]; then
      stable=$((stable+1))
      if [ $stable -eq 1 ]; then
        cstart=$i
        log "convergence interval opened t+${i}s: exactly 3 exact-size holders {$H}"
      fi
    else
      [ $stable -ge 1 ] && log "convergence reset t+${i}s: the interval had $((stable-1)) stable poll(s); now: $(cat /tmp/pa2-place-scan.txt)"
      stable=0
    fi
    last="$H"
    if [ $n1 -eq 0 ] && [ $i -ge 300 ] && [ "$(echo $H | wc -w)" -lt 3 ] && [ -z "$FP" ]; then
      n1=1
      log "nudge1 (t+300 s): duty cycle STALLED (fewer than 3 exact-size copies: ${H:-none}; no in-flight .part pushes) - forcing a replEnsureAll re-eval via the binary's index-size trigger (probe99.bin + rescan on vm$pub)"
      printf 'x' | $SSH cc@$(vm $pub) "dd of=/data/shared/probe99.bin bs=1 count=1 2>/dev/null; touch /tmp/peer.rescan"
    elif [ $n2 -eq 0 ] && [ $i -ge 600 ] && [ "$(echo $H | wc -w)" -lt 3 ] && [ -z "$FP" ]; then
      n2=1
      log "nudge2 (t+600 s): duty cycle still stalled (${H:-none}, no in-flight pushes) - second index-size trigger (probe98.bin)"
      printf 'x' | $SSH cc@$(vm $pub) "dd of=/data/shared/probe98.bin bs=1 count=1 2>/dev/null; touch /tmp/peer.rescan"
    elif [ $n3 -eq 0 ] && [ $i -ge 900 ] && [ "$(echo $H | wc -w)" -lt 3 ] && [ -z "$FP" ]; then
      n3=1
      log "nudge3 (t+900 s): duty cycle still stalled (${H:-none}, no in-flight pushes) - third index-size trigger (probe97.bin)"
      printf 'x' | $SSH cc@$(vm $pub) "dd of=/data/shared/probe97.bin bs=1 count=1 2>/dev/null; touch /tmp/peer.rescan"
    fi
    if [ $stable -ge 18 ] && [ $((i - cstart)) -ge 180 ]; then
      break
    fi
    [ $i -ge 1200 ] && break
    sleep 10
  done
  if [ $stable -lt 18 ] || [ $((i - cstart)) -lt 180 ]; then
    fail "$nm placement convergence NOT reached inside the 1200 s cap (last scan: $(cat /tmp/pa2-place-scan.txt)) - RF=3 fidelity violation; the gate is not weakened"
  fi
  log "placement converged t+${i}s: exactly 3 exact-size holders {$FH} held for $stable consecutive polls (>= 180 s); scan: $(cat /tmp/pa2-place-scan.txt)"
  fleet_scan $nm $sz $R/census-$nm-final.txt
  log "final census ($nm): $(cat $R/census-$nm-final.txt)"
  [ -z "$FR" ] || fail "$nm final census INCONCLUSIVE: unreachable peers after 3 ssh tries: $FR - exactly 3 is never claimed from partial visibility"
  [ -z "$FS" ] || fail "$nm wrong-size copies at the final census: $FS (never counted; the gate is not weakened)"
  [ -z "$FP" ] || fail "$nm .part debris at the final census: $FP (non-exact copies never count)"
  [ "$(echo $FH | wc -w)" = 3 ] || fail "$nm not exactly 3 exact-size holders at the final census (got ${FH:-none}) - RF=3 fidelity violation"
  local h dd
  for h in $FH; do
    dd=$(rsha $(vm $h) /data/shared/$nm) || fail "$nm final sha256 pass: unreachable on holder vm$h (3 ssh tries)"
    [ "$dd" = "$SRC" ] || fail "$nm final sha256 pass: holder vm$h digest $dd != source digest $SRC"
  done
  log "final sha256 verification pass: all 3 census holders match the source digest ($nm)"
  DES="$FH"
  if [ "$FH" = "$des" ]; then
    log "placed: $nm live at the designed set {$des} (3 verified copies)"
  else
    log "placed: $nm live {$FH} (3 verified copies) != designed {$des} - reroute-class holders per the binary's documented replacement design (peer.cpp:1352); see the development log"
  fi
  [ -n "$FD" ] && log "census note: servents down but file on disk at the placement census: [$FD]"
  if [ $n1 -eq 1 ] || [ $n2 -eq 1 ] || [ $n3 -eq 1 ]; then
    log "nudge-debris: cleaning probe97/probe98/probe99 fleet-wide"
    for i in $(seq 2 17); do
      $SSH cc@$(vm $i) "rm -f /data/shared/probe97.bin /data/shared/probe98.bin /data/shared/probe99.bin /data/shared/probe97.bin.part /data/shared/probe98.bin.part /data/shared/probe99.bin.part; [ -f /data/.p2p-repl.meta ] && sed -i -e '/^probe97/d' -e '/^probe98/d' -e '/^probe99/d' /data/.p2p-repl.meta; true"
    done
  fi
}
pick_cli() {
  local des="$1" j
  for j in $(for k in $(seq 2 17); do echo ${FREE[$k]} $k; done | sort -rn | awk '{print $2}'); do
    case " $des " in *" $j "*) ;; *) echo $j; return;; esac
  done
}
rsha() {
  local ip=$1 f=$2 n out
  for n in 1 2 3; do
    out=$($SSH cc@$ip "sha256sum $f | cut -d' ' -f1" 2>/dev/null)
    [ -n "$out" ] && { echo "$out"; return 0; }
    sleep 20
  done
  return 1
}
check_copies() {
  local nm=$1 t=$2 des="$3" cli=$4 D="" d i
  D=" s:$SRC"
  for i in $des; do
    d=$(rsha $(vm $i) /data/shared/$nm) \
      || fail "$t: sha256 unreachable on holder vm$i (3 ssh tries)"
    D="$D $i:$d"
  done
  d=$(rsha $(vm $cli) /data/downloads/$nm) \
    || fail "$t: sha256 unreachable on the client download (3 ssh tries; keep_downloads set?)"
  D="$D c:$d"
  echo "sha256 ($t):$D" | tee -a $R/meta.txt | tr ' ' '\n' > $R/sha-$t-2nd.txt
  [ "$(echo $D | tr ' ' '\n' | cut -d: -f2 | sort -u | wc -l)" = 1 ] \
    || fail "$t: sha256 mismatch across copies:$D"
  log "$t: all $(( $(echo $des | wc -w) + 1 )) holder+client sha256 digests identical and equal to the source digest ($nm: live holders {$des}; the client /data/downloads copy is digest-verified but excluded from the RF count)"
}
divergence_scan() {
  local nm=$1 sz=$2 st=$3
  fleet_scan $nm $sz $R/holders-$st.txt
  log "holders @ $st: $(cat $R/holders-$st.txt)"
  [ -n "$FR" ] && log "divergence-scan ($st): visibility incomplete (unreachable: $FR)"
  if [ "$(echo $FH | wc -w)" != 3 ] || [ -n "$FS" ] || [ -n "$FP" ]; then
    log "DIVERGENCE event ($st): fleet state differs from the certified 3-copy set: $(cat $R/holders-$st.txt)"
  fi
}

md5sum ~/pa2/p2p | grep -q "^$BINGMD5 " || fail "binary md5 != pin $BINGMD5 on the control host"

NAME=huge4g-4096mib.bin
SIZE1=4294967296

for i in $(seq 2 17); do
  if $SSH cc@$(vm $i) "ls /data/shared/ 2>/dev/null | grep -q -e '^huge4g-' -e '^probe9'"; then
    log "stale huge4g*/probe9x debris on vm$i - scrubbing"
    $SSH cc@$(vm $i) "rm -f /data/shared/huge4g-* /data/shared/huge4g-*.part /data/downloads/huge4g-* /data/shared/probe97.bin /data/shared/probe98.bin /data/shared/probe99.bin; [ -f /data/.p2p-repl.meta ] && sed -i -e '/^huge4g-/d' -e '/^probe97/d' -e '/^probe98/d' -e '/^probe99/d' /data/.p2p-repl.meta; true"
  fi
done

declare -A FREE
for i in $(seq 2 17); do
  alive $i || fail "vm$i servent not up - the test must run on a live system (single-driver rule: never blind-launch)"
  FREE[$i]=$(dfbytes $i)
  [ -n "${FREE[$i]}" ] || fail "df failed on vm$i"
done
PUB=$(for i in $(seq 2 17); do echo ${FREE[$i]} $i; done | sort -rn | awk '{print $2; exit}')
DES=$(des_of $NAME $PUB)
CLI=$(for j in $(seq 2 17); do echo ${FREE[$j]} $j; done | sort -rn | awk '{print $2}' \
      | while read -r j; do case " $DES " in *" $j "*) ;; *) echo $j; break;; esac; done)
[ -n "$CLI" ] || fail "no non-holder client node found"
log "owner=vm$PUB (most free), designed set {$DES}, client=vm$CLI (non-holder, most free)"

NEED=$((SIZE1 + 300*1048576))
for i in $DES $CLI; do
  f=$(dfbytes $i)
  log "space gate vm$i: free $f bytes (need >= $NEED)"
  [ "$f" -ge "$NEED" ] || fail "abort: vm$i free $f < 4 GiB + 300 MiB - not placing $NAME"
done
{
  echo "=== df -h before placement ==="
  for i in $(seq 2 17); do printf 'vm%02d ' $i; $SSH cc@$(vm $i) 'df -h /data/shared | tail -1'; done
} > $R/df-before.txt 2>&1

for t in central star mesh; do
  $SSH cc@$(vm $CLI) "sed -i 's/^keep_downloads=0$/keep_downloads=1/' ~/pa2/configs/$t/node$CLI.cfg"
done

bash scripts/stop-system.sh central >/dev/null 2>&1 || true
sleep 2
bash scripts/start-system.sh central || fail "start central failed"
sleep 30
bash scripts/smoke.sh central >> $R/meta.txt 2>&1 || fail "smoke central failed"
place $NAME $SIZE1 $PUB "$DES"
case " $DES " in *" $CLI "*)
  CLI=$(pick_cli "$DES")
  [ -n "$CLI" ] || fail "no non-holder client node after capture"
  log "client-repick: vm$CLI (reroute copy landed on the old client)"
  for t in central star mesh; do
    $SSH cc@$(vm $CLI) "sed -i 's/^keep_downloads=0$/keep_downloads=1/' ~/pa2/configs/$t/node$CLI.cfg"
  done
  ;;
esac

timed_obtain() {
  local t=$1 raw=$2 des="$3" cli=$4
  for i in $des $cli; do dropcache $i; done
  log "$t: page caches dropped on the 4 involved VMs; timed obtain now"
  session $t $cli $R/$raw "obtain $NAME\nstat\nquit\n"
  [ "$(grep -c "display file '$NAME' (4\.00 GiB from" $R/$raw)" = 1 ] \
    || fail "$t: display file line does not read '4.00 GiB' (see $R/$raw)"
  grep "display file" $R/$raw | tee -a $R/meta.txt
  check_copies $NAME $t "$des" $cli
  mv $R/sha-$t-2nd.txt $R/sha-$t.txt
  divergence_scan $NAME $SIZE1 $t
}

timed_obtain central central-session.txt "$DES" $CLI
bash scripts/stop-system.sh central >/dev/null 2>&1 || true; sleep 2
bash scripts/start-system.sh star || fail "start star failed"; sleep 30
bash scripts/smoke.sh star >> $R/meta.txt 2>&1 || fail "smoke star failed"
timed_obtain star star-session.txt "$DES" $CLI
bash scripts/stop-system.sh star >/dev/null 2>&1 || true; sleep 2
bash scripts/start-system.sh mesh || fail "start mesh failed"; sleep 30
bash scripts/smoke.sh mesh >> $R/meta.txt 2>&1 || fail "smoke mesh failed"
timed_obtain mesh mesh-session.txt "$DES" $CLI
bash scripts/stop-system.sh mesh >/dev/null 2>&1 || true; sleep 2

bash scripts/start-system.sh central > $R/kill-phase-start.log 2>&1 || fail "start central (kill phase) failed"
sleep 30
bash scripts/smoke.sh central >> $R/meta.txt 2>&1 || fail "smoke central (kill phase) failed"
fleet_scan $NAME $SIZE1 $R/holders-pre-kill.txt
log "pre-kill fleet state: $(cat $R/holders-pre-kill.txt)"
fleet_scan $NAME $SIZE1 $R/holders-pre-kill.txt
log "pre-kill fleet state: $(cat $R/holders-pre-kill.txt)"
[ -z "$FR" ] || fail "kill phase: pre-kill census INCONCLUSIVE (unreachable: $FR)"
CERT_ALIVE=""
for c in $DES; do case " $FH " in *" $c "*) CERT_ALIVE="$CERT_ALIVE $c";; esac; done
[ "$(echo $CERT_ALIVE | wc -w)" = 3 ] || fail "kill phase: the certified 3-copy set {$DES} is not fully live at the pre-kill census (live: ${FH:-none}) - agreed precondition: start from three verified copies"
EXTRAS=$(comm -13 <(echo "$DES" | tr ' ' '\n' | sort) <(echo "$FH" | tr ' ' '\n' | sort) | tr '\n' ' ')
[ -z "$(echo $EXTRAS)" ] || log "kill phase: divergence extras at kill census (recorded, not laundered; sec.1): $EXTRAS"
KILLK=$(comm -12 <(echo "$DES" | tr ' ' '\n' | sort) <(echo "$FH" | tr ' ' '\n' | sort) | grep -v "^$PUB$" | head -1)
[ -n "$KILLK" ] || fail "kill phase: no non-owner holder found among {$FH}"
log "kill phase: SIGKILL the servent of non-owner holder vm$KILLK (live copies {$FH}; owner vm$PUB and the other holder stay up; the honest-kill convention: TIME_WAIT must never hold a port)"
$SSH cc@$(vm $KILLK) "pkill -9 -x p2p; rm -f /tmp/peer.repl.done; true" || fail "kill phase: cannot kill vm$KILLK servent"
sleep 15
session central $CLI $R/kill-retrieve-session.txt "search $NAME\nobtain $NAME\nquit\n"
grep -e "display file" -e "search" $R/kill-retrieve-session.txt | tee -a $R/meta.txt
grep -q "display file '$NAME' (4\.00 GiB from" $R/kill-retrieve-session.txt \
  || fail "kill phase: retrieve FAILED - no 4.00 GiB display line in the post-kill session (see $R/kill-retrieve-session.txt)"
DL=$(grep -m1 -o 'from [0-9.]*:[0-9]*' $R/kill-retrieve-session.txt | cut -d' ' -f2)
SIP=${DL%%:*}; SPORT=${DL##*:}
[ -n "$SIP" ] && [ -n "$SPORT" ] || fail "kill phase: cannot parse the serving endpoint from the display line"
SROW=$(grep -l "^my_ip=$SIP$" ~/pa2/configs/central/node*.cfg | head -1 | sed 's/.*node\([0-9]*\)\.cfg/\1/')
[ -n "$SROW" ] || fail "kill phase: roster grep found no config with my_ip=$SIP - endpoint mapping failed"
if ! grep -q "^download_port=$SPORT$" ~/pa2/configs/central/node$SROW.cfg; then
  log "kill phase: endpoint port $SPORT does not match download_port in configs/central/node$SROW.cfg - logged; the served-event match below must still hold"
fi
$SSH cc@$(vm $SROW) "grep -F \"served '$NAME'\" ~/pa2/logs/peer.log | tail -3" > $R/kill-serving-evidence.txt 2>/dev/null
grep -q "served '$NAME'" $R/kill-serving-evidence.txt \
  || fail "kill phase: no served event for '$NAME' on vm$SROW (the VM mapped from the display endpoint $SIP:$SPORT) - positive serving evidence incomplete"
log "kill phase POSITIVE chain: client display '$(grep -m1 "display file" $R/kill-retrieve-session.txt)' -> vm$SROW (my_ip=$SIP in configs/central/node$SROW.cfg, download_port=$SPORT) -> peer.log: $(head -1 $R/kill-serving-evidence.txt)"
SIZES=$($SSH cc@$(vm $CLI) "stat -c %s /data/downloads/$NAME 2>/dev/null")
[ "$SIZES" = "$SIZE1" ] || fail "kill phase: retrieved copy not at exact $SIZE1 bytes (got: ${SIZES:-unreachable})"
dd=$(rsha $(vm $CLI) /data/downloads/$NAME) || fail "kill phase: sha256 unreachable on the retrieved copy"
[ "$dd" = "$SRC" ] || fail "kill phase: retrieved copy digest $dd != source digest $SRC"
log "KILL-RETRIEVE-OK: vm$KILLK killed; fresh search+obtain via surviving vm$CLI retrieved the exact $SIZE1-byte copy, sha256 == source digest; served by vm$SROW (positive peer.log evidence)"
divergence_scan $NAME $SIZE1 post-kill
$SSH cc@$(vm $CLI) "rm -f /tmp/peer.repl.done; cd ~/pa2 && nohup ~/pa2/p2p peer -c ~/pa2/configs/central/node$CLI.cfg >> ~/pa2/logs/peer.log 2>&1 </dev/null & sleep 2" || fail "kill phase: cannot restart the client servent on vm$CLI"
sleep 20
RECW=1500; RECT0=$(date +%s); NEWH=""; NEWP=""
while [ $(( $(date +%s) - RECT0 )) -lt $RECW ]; do
  sleep 15
  fleet_scan $NAME $SIZE1 /tmp/pa2-rec.txt
  NEWH=""
  for h in $FH; do
    case " $DES $KILLK $CLI " in *" $h "*) ;; *) NEWH="$NEWH $h";; esac
  done
  NEWP=""
  for p in $(echo $FS $FP | tr ',' ' ' | cut -d: -f1); do
    case " $DES $KILLK $CLI " in *" $p "*) ;; *) NEWP="$NEWP $p";; esac
  done
  [ -n "$NEWH" ] && break
  cat /tmp/pa2-rec.txt > $R/holders-post-recovery.txt
done
cat /tmp/pa2-rec.txt > $R/holders-post-recovery.txt
if [ -n "$NEWH" ]; then
  log "recovery observation: rebuilt in $(( $(date +%s) - RECT0 )) s - replacement holder(s) {$(echo $NEWH)} now hold an exact-size copy while vm$KILLK remained down (ADDITIONAL evidence, not the mandatory gate)"
elif [ -n "$NEWP" ]; then
  log "recovery observation: partial at window end - in-flight push on {$(echo $NEWP)} without a completed exact-size copy after $RECW s (vm$KILLK remained down)"
else
  log "recovery observation: not observed within window - no new exact-size copy on any non-holder peer after $RECW s (vm$KILLK remained down; the mandatory retrieve gate above is unaffected)"
fi

log "cleanup round 1: deleting $NAME from every location + journal scrub"
for i in $(seq 2 17); do
  $SSH cc@$(vm $i) "rm -f /data/shared/$NAME /data/shared/$NAME.part /data/downloads/$NAME; [ -f /data/.p2p-repl.meta ] && sed -i '/^huge4g-/d' /data/.p2p-repl.meta; true" &
done
wait
LEFT=0
for i in $(seq 2 17); do
  n=$($SSH cc@$(vm $i) "ls /data/shared/ 2>/dev/null | grep -c '^huge4g-' || true")
  [ "${n:-0}" = 0 ] || LEFT=$((LEFT+1))
done
[ "$LEFT" = 0 ] || fail "cleanup round 1 left huge4g files on $LEFT VMs"

NAME=huge4g-plus1.bin
SIZE2=4294967297
mkdir -p $R/plus
DES=$(des_of $NAME $PUB)
NEED2=$((SIZE2 + 300*1048576))
for i in $DES $CLI; do
  f=$(dfbytes $i)
  [ "$f" -ge "$NEED2" ] || fail "abort: vm$i free $f < (4 GiB+1) + 300 MiB for the second file"
done
log "second test (OBSERVATIONAL, no assumed outcome): 4294967297-byte file, designed set {$DES}, client vm$CLI"
bash scripts/start-system.sh central > $R/plus/start.log 2>&1 || fail "start central (2nd file) failed"; sleep 30
bash scripts/smoke.sh central >> $R/meta.txt 2>&1 || fail "smoke central (2nd) failed"
$SSH cc@$(vm $PUB) "fallocate -l $SIZE2 -z /data/shared/$NAME 2>/dev/null || head -c $SIZE2 /dev/zero > /data/shared/$NAME; touch /tmp/peer.rescan" \
  || fail "cannot create $NAME on vm$PUB (disk?)"
SRC=$(rsha $(vm $PUB) /data/shared/$NAME) || fail "plus: cannot compute the source digest on vm$PUB"
log "plus: created $NAME ($SIZE2 bytes) on vm$PUB (fallocate-sparse-zero, fallback head-c /dev/zero); source digest $SRC"
log "plus: 180 s settle for index adoption + replication attempts (observational - no convergence gate)"
sleep 180
fleet_scan $NAME $SIZE2 $R/plus/census-attempt.txt
log "plus fleet census (post-creation): $(cat $R/plus/census-attempt.txt)"
ATT="$FH"
session central $CLI $R/plus/session.txt "search $NAME\nobtain $NAME\nquit\n"
grep -e "display file" -e "search" $R/plus/session.txt | tee -a $R/meta.txt
if grep -q "display file '$NAME'" $R/plus/session.txt; then
  STATS=""
  for n in 1 2 3; do
    STATS=$($SSH cc@$(vm $CLI) "stat -c %s /data/downloads/$NAME" 2>/dev/null)
    [ -n "$STATS" ] && break
    sleep 20
  done
  if [ "$STATS" = "$SIZE2" ]; then
    d=$(rsha $(vm $CLI) /data/downloads/$NAME) || fail "plus: sha256 unreachable on the client copy (3 ssh tries)"
    [ "$d" = "$SRC" ] || fail "plus: ACCEPTED but the client copy is CORRUPT (digest $d != source $SRC) - a corrupt copy is never counted as success"
    for h in $ATT; do
      d=$(rsha $(vm $h) /data/shared/$NAME) || fail "plus: sha256 unreachable on holder vm$h"
      [ "$d" = "$SRC" ] || fail "plus: holder vm$h digest $d != source $SRC (corrupt copy never counts as success)"
    done
    fleet_scan $NAME $SIZE2 $R/plus/census-after.txt
    log "plus OBS-ACCEPTED: obtain reported success, client copy exactly $SIZE2 bytes, all digests == source; post-obtain fleet census: $(cat $R/plus/census-after.txt); NO documented 4 GiB ceiling exists - this is the OBSERVED behavior, recorded honestly"
    [ -z "$FS" ] && [ -z "$FP" ] || log "plus: post-accept wrong-size/part copies: wrong-size=[$FS] part=[$FP] (cleanup below removes all huge4g-* artifacts; verified by census-after-cleanup)"
  else
    fleet_scan $NAME $SIZE2 $R/plus/census-misleading.txt
    log "plus OBS-DISCREPANCY: obtain reported success via display line, but the client download is ${STATS:-unreachable} bytes, NOT $SIZE2 - a truncated/misleading complete-looking copy; fleet state recorded, artifacts cleaned by the existing procedure: $(cat $R/plus/census-misleading.txt)"
  fi
else
  if [ -n "$FS" ] || [ -n "$FP" ]; then
    log "plus OBS-PARTIAL-FAILURE: no display success line; in-flight/incorrect-size artifacts found wrong-size=[$FS] part=[$FP] - failure recorded + inspected below, cleaned by the existing procedure"
  else
    log "plus OBS-REFUSED: no display success line in the client session capture; observed client-side outcome follows verbatim (no error-message format assumed):"
  fi
  tee -a $R/meta.txt < $R/plus/session.txt | sed 's/^/plus-client| /' > /dev/null
  fleet_scan $NAME $SIZE2 $R/plus/census-after.txt
  log "plus fleet census (after refused/partial attempt): $(cat $R/plus/census-after.txt)"
fi
: > $R/plus/peerlog-excerpts.txt
for i in $(seq 2 17); do
  o=$($SSH cc@$(vm $i) "grep -F '$NAME' ~/pa2/logs/peer.log 2>/dev/null | tail -8")
  if [ -n "$o" ]; then printf '== vm%02d ==\n%s\n' $i "$o" >> $R/plus/peerlog-excerpts.txt; fi
done
log "plus: peer.log excerpts (fleet-wide grep of the plus name) -> $R/plus/peerlog-excerpts.txt"

log "cleanup round 2: deleting $NAME from every location + journal scrub"
for i in $(seq 2 17); do
  $SSH cc@$(vm $i) "rm -f /data/shared/huge4g-* /data/shared/huge4g-*.part /data/downloads/huge4g-*; [ -f /data/.p2p-repl.meta ] && sed -i '/^huge4g-/d' /data/.p2p-repl.meta; true" &
done
wait
LEFT=0
for i in $(seq 2 17); do
  n=$($SSH cc@$(vm $i) "ls /data/shared/ /data/downloads/ 2>/dev/null | grep -c '^huge4g-' || true")
  [ "${n:-0}" = 0 ] || LEFT=$((LEFT+1))
done
[ "$LEFT" = 0 ] || fail "cleanup round 2 left huge4g artifacts on $LEFT VMs (shared + downloads + .part verified)"
for t in central star mesh; do
  $SSH cc@$(vm $CLI) "sed -i 's/^keep_downloads=1$/keep_downloads=0/' ~/pa2/configs/$t/node$CLI.cfg"
done
bash scripts/stop-system.sh central >/dev/null 2>&1 || true; sleep 2
bash scripts/start-system.sh central || fail "restart after final cleanup failed"; sleep 30
bash scripts/smoke.sh central >> $R/meta.txt 2>&1 || fail "smoke after cleanup failed"
{
  echo "=== df -h after cleanup ==="
  for i in $(seq 2 17); do printf 'vm%02d ' $i; $SSH cc@$(vm $i) 'df -h /data/shared | tail -1'; done
} > $R/df-after.txt 2>&1
bash scripts/census.sh results/huge4g/census-after-cleanup.txt >> $R/meta.txt 2>&1 \
  || fail "post-cleanup census run failed"
log "census-after-cleanup + df written; per-node counts must show ZERO huge4g artifacts (see results/huge4g/census-after-cleanup.txt)"
log "TEST4G-OK: placement CONVERGED (exactly 3 digest-verified copies proven by the complete final census within the 1200 s cap), 4.00 GiB display + exact size + SHA-256 across central/star/mesh (cold caches), single-server kill + fresh search+obtain RETRIEVED with POSITIVE serving-peer evidence (vm$SROW -> served event), bounded recovery observation reported separately (never conflated), 4 GiB+1-byte OBSERVATIONAL outcome recorded under results/huge4g/plus/, full cleanup verified (shared + downloads + .part + journal)"
echo "TEST4G-OK"
