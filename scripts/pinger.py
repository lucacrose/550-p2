#!/usr/bin/env python3
import socket
import struct
import sys
import time

C_QUERY = 12
C_HITS = 13

def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise ConnectionError("peer closed connection")
        buf += c
    return buf

def probe(ip, port, name, ttl, timeout_s):

    t0 = time.time()
    s = socket.create_connection((ip, port), timeout=timeout_s)
    try:
        pl = struct.pack("<H", len(name)) + name.encode() + struct.pack("<B", ttl)
        s.sendall(struct.pack("<BI", C_QUERY, len(pl)) + pl)
        hdr = recv_exact(s, 5)
        typ = hdr[0]
        ln = struct.unpack("<I", hdr[1:5])[0]
        pl2 = recv_exact(s, ln) if ln else b""
        dt = (time.time() - t0) * 1000.0
        if typ != C_HITS or len(pl2) < 5:
            raise ConnectionError("unexpected reply type %d len %d" % (typ, ln))
        ok = pl2[0]
        nhits = struct.unpack("<I", pl2[1:5])[0]
        return dt, ok, nhits
    finally:
        s.close()

def main():
    args = sys.argv[1:]
    if len(args) < 4:
        print(__doc__)
        sys.exit(2)
    ip, port, rounds = args[0], int(args[1]), int(args[2])
    names, ttl = [], 0
    i = 3
    while i < len(args):
        if args[i] == "--ttl":
            ttl = int(args[i + 1])
            i += 2
        else:
            names.append(args[i])
            i += 1

    lat = {}
    hitavg = {}
    okc = {}
    for _ in range(rounds):
        for name in names:
            try:

                dt, ok, nh = probe(ip, port, name, ttl, 30)
            except Exception as e:
                print("probe error for %s: %s" % (name, e))
                dt, ok, nh = float("nan"), 0, 0
            lat.setdefault(name, []).append(dt)
            hitavg.setdefault(name, []).append(nh)
            okc[name] = okc.get(name, 0) + (1 if ok else 0)

    print("# pinger %s:%d rounds=%d ttl=%s" % (ip, port, rounds,
                                               ttl if ttl else "peer-default"))
    for name in names:
        ls = [x for x in lat[name] if x == x]
        if ls:
            print("%-12s lat_ms mean=%.1f min=%.1f max=%.1f hits_avg=%.1f"
                  % (name, sum(ls) / len(ls), min(ls), max(ls),
                     sum(hitavg[name]) / len(hitavg[name])))
        print("RESULT %s ttl=%s ok=%d/%d" % (name, ttl, okc.get(name, 0), rounds))

if __name__ == "__main__":
    main()
