#!/usr/bin/env python3
import os
import sys

REPO = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(REPO)

VM01 = ("vm01", "192.168.77.101")
PEERS = [(f"vm{i:02d}", f"192.168.77.{100+i}", i) for i in range(2, 18)]

MSG_PORT = 51000
CONTROL_PORT = 51001
DL_PORT = 51002
TTL = 8

REPLICATION_FACTOR = 3

SMALL_PER_NODE = int(os.environ.get("SMALL_PER_NODE", "100000"))
LARGE_PER_NODE = int(os.environ.get("LARGE_PER_NODE", "10"))

def mesh_neighbors(pid: int):

    g = pid - 2
    row, col = divmod(g, 4)
    out = []
    for dr, dc in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        r, c = row + dr, col + dc
        if 0 <= r < 4 and 0 <= c < 4:
            out.append(2 + r * 4 + c)
    return out

def name_of(node_id: int, small: bool, seq: int) -> str:
    return f"n{node_id:02d}_s{seq:06d}.txt" if small else f"n{node_id:02d}_b{seq}.bin"

def ring_str():

    return ",".join(f"{pid}:{ip}" for _, ip, pid in PEERS)

def main():
    outdir = os.path.join(ROOT, "configs")
    mandir = os.path.join(ROOT, "manifests")
    for sub in ("central", "star", "mesh"):
        os.makedirs(os.path.join(outdir, sub), exist_ok=True)
    os.makedirs(mandir, exist_ok=True)

    ring = ring_str()
    extra = "192.168.77.1:59901"

    for name, ip, pid in PEERS:
        common = f"""
node_id={pid}
my_ip={ip}
msg_port={MSG_PORT}
control_port={CONTROL_PORT}
download_port={DL_PORT}
data_dir=/data/shared
downloads_dir=/data/downloads
ttl={TTL}
query_timeout_ms=8000
keep_downloads=0
replication_factor={REPLICATION_FACTOR}
ring_fallback=1
journal_path=/data/.p2p-repl.meta
ring={ring}
extra_peers={extra}
"""
        cfg_central = ("topology=central\nindex_ip=192.168.77.101\n"
                       "index_port=51000\n" + common)
        with open(os.path.join(outdir, "central", f"node{pid}.cfg"), "w") as f:
            f.write(cfg_central.strip() + "\n")

        if pid == 2:
            nbs = [p[1] for p in PEERS if p[2] != 2]
        else:
            nbs = ["192.168.77.102"]
        with open(os.path.join(outdir, "star", f"node{pid}.cfg"), "w") as f:
            f.write(("topology=star\nneighbors="
                     + ",".join(nbs) + common).strip() + "\n")

        with open(os.path.join(outdir, "mesh", f"node{pid}.cfg"), "w") as f:
            nbs = [f"192.168.77.{100+n}" for n in mesh_neighbors(pid)]
            f.write(("topology=mesh\nneighbors=" + ",".join(nbs) + common).strip() + "\n")

    with open(os.path.join(outdir, "central", "index.cfg"), "w") as f:
        f.write("node_id=101\nmy_ip=192.168.77.101\nmsg_port=51000\n")

    with open(os.path.join(mandir, "small.txt"), "w") as f:
        for _, _, pid in PEERS:
            for s in range(SMALL_PER_NODE):
                f.write(name_of(pid, True, s) + "\n")
    with open(os.path.join(mandir, "large.txt"), "w") as f:
        for _, _, pid in PEERS:
            for s in range(LARGE_PER_NODE):
                f.write(name_of(pid, False, s) + "\n")

    roster = [p[2] for p in PEERS]
    with open(os.path.join(mandir, "roster.txt"), "w") as f:
        f.write(" ".join(str(x) for x in roster) + "\n")

    print("replication_factor=%d (system-wide, enforced by the peer program)"
          % REPLICATION_FACTOR)
    print("configs + manifests written to", outdir, mandir)

if __name__ == "__main__":
    main()
