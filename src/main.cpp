#include <signal.h>

#include <cstdio>
#include <cstring>

#include "bench.hpp"
#include "index.hpp"
#include "peer.hpp"

namespace p2p {
static Peer* g_peer = nullptr;
static IndexServer* g_index = nullptr;
static void onSignal(int) {
  if (g_peer) g_peer->requestStop();
  if (g_index) {  }
}
}

static void usage() {
  fprintf(stderr,
          "usage:\n"
          "  p2p index  -c <cfg>              run centralized index server\n"
          "  p2p peer   -c <cfg> [--cli]      run a servent peer (--cli keeps\n"
          "                                   the interactive console on stdin)\n"
          "  p2p ping   --target ip:controlPort   one-shot health/status probe\n"
          "  p2p bench  --target ip:controlPort [--clients N] [--count N]\n"
          "             [--op query|obtain] --manifest <file> [--out csv]\n"
          "             [--label tag] [--seed N] [--start-at epoch_ms]\n"
          "             [--exclude-dir <dir>]  experiment driver\n"
          );
}

int main(int argc, char** argv) {
  signal(SIGPIPE, SIG_IGN);
  if (argc < 2) {
    usage();
    return 2;
  }
  std::string role = argv[1];
  if (role == "index") {
    std::string cfgPath;
    for (int i = 2; i < argc; i++) {
      if (!strcmp(argv[i], "-c") && i + 1 < argc) cfgPath = argv[++i];
    }
    if (cfgPath.empty()) {
      usage();
      return 2;
    }
    p2p::Config cfg(cfgPath);
    p2p::IndexServer srv(cfg);
    p2p::g_index = &srv;
    signal(SIGINT, p2p::onSignal);
    signal(SIGTERM, p2p::onSignal);
    srv.run();
    return 0;
  }
  if (role == "peer") {
    std::string cfgPath;
    bool cli = false;
    for (int i = 2; i < argc; i++) {
      if (!strcmp(argv[i], "-c") && i + 1 < argc)
        cfgPath = argv[++i];
      else if (!strcmp(argv[i], "--cli")) cli = true;
    }
    if (cfgPath.empty()) {
      usage();
      return 2;
    }
    p2p::Config cfg(cfgPath);
    p2p::Peer peer(cfg, cli);
    p2p::g_peer = &peer;
    signal(SIGINT, p2p::onSignal);
    signal(SIGTERM, p2p::onSignal);
    peer.run();
    return 0;
  }
  if (role == "ping") {

    std::string target;
    for (int i = 2; i < argc; i++) {
      if (!strcmp(argv[i], "--target") && i + 1 < argc) target = argv[++i];
    }
    if (target.empty()) {
      usage();
      return 2;
    }
    std::string ipPart;
    uint16_t port = 0;
    p2p::parseAddr(target, &ipPart, &port);
    if (port == 0) port = 51001;
    int fd = p2p::tcpConnect(ipPart, port, 2000);
    if (fd < 0) {
      printf("ping %s: FAIL connect\n", target.c_str());
      return 1;
    }
    p2p::Writer w;
    p2p::writeFrame(fd, p2p::C_STATS, w.buf.data(), w.buf.size());
    p2p::Frame f;
    bool ok = p2p::readFrame(fd, f, 1 << 20);
    p2p::closeFd(fd);
    if (!ok || f.type != p2p::C_STATS2) {
      printf("ping %s: FAIL protocol\n", target.c_str());
      return 1;
    }
    p2p::Reader r(f.payload.data(), f.payload.size());
    uint64_t route = 0, pend = 0, files = 0;
    uint32_t neigh = 0;
    if (!r.u64(route) || !r.u64(pend) || !r.u32(neigh) || !r.u64(files))
      return 1;
    printf("ping %s: OK routes=%llu pending=%llu neighbours=%llu files=%llu",
           target.c_str(), (unsigned long long)route,
           (unsigned long long)pend, (unsigned long long)neigh,
           (unsigned long long)files);

    uint64_t pushed = 0, skipped = 0, recv = 0, rmiss = 0, hdrop = 0;
    uint8_t done = 0;
    if (r.u64(pushed) && r.u64(skipped) && r.u64(recv) && r.u8(done) &&
        r.u64(rmiss) && r.u64(hdrop)) {
      printf(" repl(push=%llu skip=%llu recv=%llu%s) drops(route=%llu hit=%llu)",
             (unsigned long long)pushed, (unsigned long long)skipped,
             (unsigned long long)recv, done ? ",done" : "",
             (unsigned long long)rmiss, (unsigned long long)hdrop);

      uint64_t qrecv = 0, qfwd = 0, qdup = 0, horig = 0, hrelay = 0;
      if (r.u64(qrecv) && r.u64(qfwd) && r.u64(qdup) && r.u64(horig) &&
          r.u64(hrelay)) {
        printf(" queries(recv=%llu fwd=%llu dup=%llu) hits(orig=%llu relay=%llu)",
               (unsigned long long)qrecv, (unsigned long long)qfwd,
               (unsigned long long)qdup, (unsigned long long)horig,
               (unsigned long long)hrelay);
      }
    }
    printf("\n");
    return 0;
  }
  if (role == "bench") {
    p2p::BenchArgs a;
    for (int i = 2; i < argc; i++) {
      std::string arg = argv[i];
      auto next = [&]() -> const char* {
        return (i + 1 < argc) ? argv[++i] : "";
      };
      if (arg == "--target") a.target = next();
      else if (arg == "--manifest") a.manifest = next();
      else if (arg == "--out") a.out = next();
      else if (arg == "--label") a.label = next();
      else if (arg == "--clients") a.clients = atoi(next());
      else if (arg == "--count") a.count = atoi(next());
      else if (arg == "--seed") a.seed = strtoull(next(), nullptr, 10);
      else if (arg == "--exclude-dir") a.excludeDir = next();
      else if (arg == "--start-at") a.startAtMs = atoll(next());
      else if (arg == "--op") {
        std::string v = next();
        if (v == "obtain") a.obtain = true;
      }
    }
    return p2p::runBench(a);
  }
  usage();
  return 2;
}
