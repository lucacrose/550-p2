#include "bench.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <dirent.h>
#include <fstream>
#include <mutex>
#include <random>
#include <thread>
#include <unordered_set>

#include <sys/socket.h>

namespace p2p {

static LatencySummary summarize(const std::vector<double>& vals) {
  LatencySummary s;
  s.n = vals.size();
  if (vals.empty()) return s;
  std::vector<double> sorted = vals;
  std::sort(sorted.begin(), sorted.end());
  double sum = 0;
  for (double x : vals) sum += x;
  s.avg = sum / vals.size();
  double var = 0;
  for (double x : vals) var += (x - s.avg) * (x - s.avg);
  s.stdev = std::sqrt(var / std::max<size_t>(1, vals.size() - 1));
  auto q = [&](double p) {
    size_t idx =
        std::min(sorted.size() - 1, (size_t)std::llround(p * (sorted.size() - 1)));
    return sorted[idx];
  };
  s.p50 = q(0.50);
  s.p95 = q(0.95);
  s.p99 = q(0.99);
  s.maxv = sorted.back();
  return s;
}

int runBench(const BenchArgs& a) {
  std::string ipPart;
  uint16_t port = 0;
  parseAddr(a.target, &ipPart, &port);
  if (port == 0) port = 51001;
  uint32_t targetIp = 0;
  {
    struct in_addr sa;
    if (inet_pton(AF_INET, ipPart.c_str(), &sa) != 1) {
      fprintf(stderr, "bad target address %s\n", a.target.c_str());
      return 2;
    }
    targetIp = ntohl(sa.s_addr);
  }
  std::vector<std::string> names;
  {
    std::ifstream in(a.manifest);
    if (!in) {
      fprintf(stderr, "cannot read manifest %s\n", a.manifest.c_str());
      return 2;
    }
    std::string line;
    while (std::getline(in, line)) {
      while (!line.empty() && (line.back() == '\r' || line.back() == '\n'))
        line.pop_back();
      if (!line.empty()) names.push_back(line);
    }
    if (names.empty()) {
      fprintf(stderr, "manifest %s is empty\n", a.manifest.c_str());
      return 2;
    }
  }

  if (!a.excludeDir.empty()) {
    std::unordered_set<std::string> local;
    if (DIR* d = opendir(a.excludeDir.c_str())) {
      struct dirent* de;
      while ((de = readdir(d)) != nullptr) {
        std::string n(de->d_name);
        if (n != "." && n != "..") local.insert(n);
      }
      closedir(d);
      std::vector<std::string> kept;
      kept.reserve(names.size());
      size_t removed = 0;
      for (auto& n : names) {
        if (local.count(n)) {
          removed++;
          continue;
        }
        kept.push_back(std::move(n));
      }
      fprintf(stderr,
              "workload: manifest %zu names, %zu present in %s (excluded), "
              "%zu remote names used\n",
              names.size(), removed, a.excludeDir.c_str(), kept.size());
      names = std::move(kept);
      if (names.empty()) {
        fprintf(stderr, "no remote names left after exclusion\n");
        return 2;
      }
    } else {
      fprintf(stderr, "warn: cannot open exclude-dir %s (no exclusions)\n",
              a.excludeDir.c_str());
    }
  }

  uint64_t baseSeed =
      a.seed ? a.seed
             : ((uint64_t)steadyUs() ^ ((uint64_t)getpid() << 32) ^
                0xA5A5A5A5A5A5A5A5ull);
  fprintf(stderr,
          "bench start: target=%s clients=%d count=%d op=%s manifest=%s "
          "(%zu names), out=%s, seed=%llu, start-at=%lld\n",
          a.target.c_str(), a.clients, a.count,
          a.obtain ? "query+obtain" : "query", a.manifest.c_str(),
          names.size(), a.out.c_str(), (unsigned long long)baseSeed,
          (long long)a.startAtMs);

  std::atomic<int64_t> completed{0};
  std::atomic<int64_t> okCount{0};
  std::atomic<int64_t> bytesTotal{0};
  std::mutex outMu;
  FILE* out = std::fopen(a.out.c_str(), "w");
  if (!out) {
    fprintf(stderr, "cannot open %s for writing\n", a.out.c_str());
    return 2;
  }

  std::fprintf(out, "tag,ts_us,client,seq,name,op,ok,duration_us,bytes,"
                    "query_us,dl_us,holder_ip,n_hits\n");
  std::fflush(out);

  std::atomic<uint64_t> globalSeq{0};
  const int64_t benchStart = wallMs();

  std::mutex aggMu;
  std::vector<double> aggLats;

  auto clientLoop = [&](int clientId) {
    std::vector<double> lats;
    size_t localOk = 0;
    int reconnects = 0;
    lats.reserve(static_cast<size_t>(a.count));

    uint64_t seed =
        baseSeed ^ ((uint64_t)(clientId + 1) * 0x9E3779B97F4A7C15ull);
    fprintf(stderr, "  client %d seed=%llu\n", clientId,
            (unsigned long long)seed);
    std::mt19937_64 rng(seed);
    std::vector<size_t> perm(names.size());
    for (size_t k = 0; k < perm.size(); k++) perm[k] = k;
    std::shuffle(perm.begin(), perm.end(), rng);
    size_t pos = rng() % names.size();

    if (a.startAtMs > 0) {
      while (wallMs() < a.startAtMs)
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }

    int fd = tcpConnect(ipStr(targetIp), port, 2000);
    for (int i = 0; i < a.count; i++) {
      std::string name = names[perm[pos]];
      pos = (pos + 1) % perm.size();
      uint64_t seq = globalSeq.fetch_add(1);
      int64_t t0 = steadyUs();
      bool ok = false;
      uint64_t bytes = 0;

      uint64_t qUs = 0, dUs = 0;
      uint32_t hIp = 0;
      uint8_t nh = 0;
      if (fd < 0) {
        fd = tcpConnect(ipStr(targetIp), port, 2000);
        reconnects++;
      }
      if (fd >= 0) {
        Writer w;
        w.str(name);
        bool good = writeFrame(fd, a.obtain ? C_OBTAIN : C_QUERY, w.buf.data(),
                               w.buf.size());
        Frame f;
        good = good && readFrame(fd, f, 1 << 22);
        if (!good) {

          closeFd(fd);
          fd = -1;
          reconnects++;
        } else if (a.obtain && f.type == C_DLRESULT) {
          Reader r(f.payload.data(), f.payload.size());
          uint8_t okb = 0;
          if (r.u8(okb) && r.u64(bytes)) {
            ok = okb != 0;

            r.u64(qUs);
            r.u64(dUs);
            r.u32(hIp);
            r.u8(nh);
          }
        } else if (!a.obtain && f.type == C_HITS) {
          bool okb = false;
          std::vector<HitEntry> hits;

          if (decHits(f, &okb, &hits) && okb && !hits.empty()) {
            ok = true;
            bytes = 0;

            hIp = hits.front().ip;
            nh = static_cast<uint8_t>(hits.size() > 255 ? 255 : hits.size());
          }
        }
      }
      int64_t took = steadyUs() - t0;

      if (!a.obtain) qUs = static_cast<uint64_t>(took);
      lats.push_back((double)took);
      if (ok) {
        localOk++;
        okCount.fetch_add(1);
      }
      if (a.obtain) bytesTotal.fetch_add(bytes);
      if (!ok) {

        fprintf(stderr, "FAIL %s %s seq=%llu took=%lldus\n",
                a.obtain ? "obtain" : "query", name.c_str(),
                (unsigned long long)seq, (long long)took);
      }
      {
        std::lock_guard<std::mutex> g(outMu);
        std::fprintf(out, "%s,%lld,%d,%llu,%s,%s,%d,%lld,%llu,%llu,%llu,%u,%u\n",
                     a.label.c_str(), (long long)wallUs(), clientId,
                     (unsigned long long)seq, name.c_str(),
                     a.obtain ? "obtain" : "query", ok ? 1 : 0,
                     (long long)took, (unsigned long long)bytes,
                     (unsigned long long)qUs, (unsigned long long)dUs,
                     (unsigned)hIp, (unsigned)nh);
      }
      int64_t done = completed.fetch_add(1);
      if (done % (2000 * a.clients) == 0) {
        fprintf(stderr, "  ... %lld ops done, %lld ms elapsed\n",
                (long long)(done + 1), (long long)(wallMs() - benchStart));
      }
    }
    closeFd(fd);
    LatencySummary s = summarize(lats);
    fprintf(stderr,
            "client %d: ops=%zu ok=%zu reconnects=%d avg=%.2fus stdev=%.2f "
            "p50=%.2f p95=%.2f p99=%.2f max=%.2f (us)\n",
            clientId, lats.size(), localOk, reconnects, s.avg, s.stdev, s.p50,
            s.p95, s.p99, s.maxv);
    {
      std::lock_guard<std::mutex> g(aggMu);
      aggLats.insert(aggLats.end(), lats.begin(), lats.end());
    }
  };

  std::vector<std::thread> threads;
  for (int c = 0; c < a.clients; c++)
    threads.emplace_back([&, c]() { clientLoop(c); });
  for (auto& t : threads) t.join();
  std::fclose(out);

  int64_t wall = wallMs() - benchStart;
  double wallSec = std::max<int64_t>(1, wall) / 1000.0;
  fprintf(stderr,
          "bench done: ops=%lld ok=%lld wall=%.2fs throughput=%.1f ops/s "
          "bytes=%lld (%.2f MiB/s)\n",
          (long long)completed.load(), (long long)okCount.load(), wallSec,
          completed.load() / wallSec, (long long)bytesTotal.load(),
          bytesTotal.load() / wallSec / (1024.0 * 1024.0));

  {
    LatencySummary s = summarize(aggLats);
    long long fail = completed.load() - okCount.load();
    fprintf(stderr,
            "BENCH-SUMMARY ops=%lld ok=%lld fail=%lld wall_s=%.2f "
            "throughput=%.1f avg_us=%.2f stdev_us=%.2f p50_us=%.2f "
            "p95_us=%.2f p99_us=%.2f max_us=%.2f bytes=%lld mibs=%.2f "
            "seed=%llu start_at=%lld\n",
            (long long)completed.load(), (long long)okCount.load(), fail,
            wallSec, completed.load() / wallSec, s.avg, s.stdev, s.p50, s.p95,
            s.p99, s.maxv, (long long)bytesTotal.load(),
            bytesTotal.load() / wallSec / (1024.0 * 1024.0),
            (unsigned long long)baseSeed, (long long)a.startAtMs);
  }
  return 0;
}

}
