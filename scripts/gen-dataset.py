#!/usr/bin/env python3
import os
import random
import sys
import time

DATA_DIR = "/data/shared"
SMALL_BYTES = 10_000
LARGE_BYTES = 100 * 1024 * 1024

SMALL_PER_NODE = int(os.environ.get("SMALL_PER_NODE", "100000"))
LARGE_PER_NODE = int(os.environ.get("LARGE_PER_NODE", "10"))

def main():
    node_id = int(sys.argv[1])
    sys.argv[2] if len(sys.argv) > 2 else None
    phase = sys.argv[3] if len(sys.argv) > 3 else "gen"
    os.makedirs(DATA_DIR, exist_ok=True)

    if phase == "gen":

        for fn in os.listdir(DATA_DIR):
            os.remove(os.path.join(DATA_DIR, fn))
        rnd = random.Random(node_id * 7919 + 13)

        blocks = []
        for _ in range(64):
            lines = []
            for _ in range(48):
                lines.append(
                    "".join(
                        rnd.choice("abcdefghijklmnopqrstuvwxyz ABCDEF 0123456789 .,;")
                        for _ in range(76)
                    )
                )
            blocks.append("\n".join(lines))
        t0 = time.time()
        for s in range(SMALL_PER_NODE):
            name = f"n{node_id:02d}_s{s:06d}.txt"
            with open(DATA_DIR + "/" + name, "w") as f:
                f.write(f"CS550-PA2 dataset file {name} (node {node_id})\n")
                f.write(blocks[rnd.randrange(len(blocks))])
                f.write(f"\n{rnd.getrandbits(64):016x}\n")

                rem = SMALL_BYTES - f.tell()
                if rem > 1:
                    f.write("z" * (rem - 1) + "\n")
        print(f"small files created in {time.time()-t0:.1f}s", flush=True)
        t0 = time.time()
        with open("/dev/urandom", "rb") as u:
            for s in range(LARGE_PER_NODE):
                name = f"n{node_id:02d}_b{s}.bin"
                with open(DATA_DIR + "/" + name, "wb") as f:
                    rem = LARGE_BYTES
                    while rem > 0:
                        chunk = u.read(min(rem, 1 << 20))
                        f.write(chunk)
                        rem -= len(chunk)
        print(f"large files created in {time.time()-t0:.1f}s", flush=True)
    elif phase == "verify":

        have = os.listdir(DATA_DIR)
        own = {f"n{node_id:02d}_s{s:06d}.txt" for s in range(SMALL_PER_NODE)}
        own |= {f"n{node_id:02d}_b{s}.bin" for s in range(LARGE_PER_NODE)}
        replicas = [f for f in have if f not in own]
        print(f"node {node_id}: own files expected "
              f"{SMALL_PER_NODE + LARGE_PER_NODE}, replicas present {len(replicas)}")

if __name__ == "__main__":
    main()
