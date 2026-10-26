#!/bin/bash
set -e
cd ~/pa2
mkdir -p test/shared{1,2,3,4} test/dl{1,2,3,4} test/results test/logs
for i in 1 2 3 4; do
  echo "mesh-node-$i-testfile $(date)" > test/shared$i/mesh${i}_f1.txt
  head -c $((i * 100000)) /dev/urandom > test/shared$i/mesh${i}_f2.bin
done

gen_cfg() {
  id=$1; base=$2; shift 2
  cat > test/mesh$id.cfg <<EOF
node_id=$id
my_ip=127.0.0.1
msg_port=$((base))
control_port=$((base+1))
download_port=$((base+2))
topology=mesh
data_dir=$HOME/pa2/test/shared$id
downloads_dir=$HOME/pa2/test/dl$id
ttl=6
neighbors=$*
EOF
}
gen_cfg 1 51000 127.0.0.1:52000,127.0.0.1:54000
gen_cfg 2 52000 127.0.0.1:51000,127.0.0.1:53000
gen_cfg 3 53000 127.0.0.1:52000,127.0.0.1:54000
gen_cfg 4 54000 127.0.0.1:53000,127.0.0.1:51000

for id in 2 3 4; do
  nohup ./p2p peer -c test/mesh$id.cfg > test/logs/mesh$id.log 2>&1 &
  echo $! > test/mesh$id.pid
done
sleep 2

echo "== peer1 CLI: query + obtain of a file that lives only on node3 =="
(echo "query nonexistant-file.txt"; sleep 0.5; echo "query mesh3_f1.txt"; sleep 2.5; echo "obtain mesh3_f2.bin"; sleep 3; echo "stat"; echo "quit") \
  | ./p2p peer -c test/mesh1.cfg --cli 2>&1 | grep -vE "unknown command|CLI ready" | head -25

echo "== node2 relay evidence (hitquery relayed) =="
grep -E "HIT|relayed" test/logs/mesh2.log test/logs/mesh3.log | head -8 || true

echo "== stopping mesh =="
for id in 2 3 4; do kill $(cat test/mesh$id.pid) 2>/dev/null || true; done
sleep 1

cat > test/index.cfg <<EOF
node_id=100
my_ip=127.0.0.1
msg_port=55000
EOF
gen_central_cfg() {
  id=$1; base=$2
  cat > test/central$id.cfg <<EOF
node_id=$id
my_ip=127.0.0.1
msg_port=$((base))
control_port=$((base+1))
download_port=$((base+2))
topology=central
index_ip=127.0.0.1
index_port=55000
data_dir=$HOME/pa2/test/shared$id
downloads_dir=$HOME/pa2/test/dl$id
EOF
}
gen_central_cfg 1 51000
gen_central_cfg 2 52000
gen_central_cfg 3 53000
nohup ./p2p index -c test/index.cfg > test/logs/index.log 2>&1 &
echo $! > test/index.pid
sleep 0.5
for id in 2 3; do
  nohup ./p2p peer -c test/central$id.cfg >> test/logs/central$id.log 2>&1 &
  echo $! > test/central$id.pid
done
sleep 2
echo "== index log after registrations =="
tail -6 test/logs/index.log

echo "== client on peer1 looks up a file that only peer2 has =="
(echo "query mesh2_f1.txt"; sleep 1; echo "obtain mesh2_f2.bin"; sleep 2.5; echo "quit") \
  | ./p2p peer -c test/central1.cfg --cli 2>&1 | grep -vE "unknown command|CLI ready" | head -12

echo "== bench: 2 clients x 50 queries against peer3 =="
printf "mesh1_f1.txt\nmesh2_f1.txt\nmesh3_f1.txt\nmesh3_f2.bin\n" > test/results/mini-manifest.txt
./p2p bench --target 127.0.0.1:53001 --clients 2 --count 50 \
  --manifest test/results/mini-manifest.txt \
  --out test/results/mini.csv --label mini 2>&1 | tail -5

echo "== stopping central =="
for id in 2 3; do kill $(cat test/central$id.pid) 2>/dev/null || true; done
kill $(cat test/index.pid) 2>/dev/null || true
sleep 1
echo "SMOKE-OK"
