#pragma once

#include "common.hpp"
#include "index_client.hpp"
#include "local_index.hpp"
#include "proto.hpp"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <unordered_map>
#include <unordered_set>

namespace p2p {

struct QueryResult {
  bool timedOut = true;
  int64_t ms = 0;
  std::vector<HitEntry> hits;
};

struct DownloadStat {
  bool ok = false;
  uint64_t bytes = 0;
  int64_t queryMs = 0;
  int64_t dlMs = 0;
  int attempts = 0;
  std::string via;

  int64_t queryUs = 0;
  int64_t dlUs = 0;
  uint32_t holderIp = 0;
  uint8_t nHits = 0;
};

class Peer {
 public:
  Peer(const Config& cfg, bool enableCli);
  ~Peer();
  void run();
  void requestStop();

  QueryResult userQuery(const std::string& name, int64_t timeoutMs,
                        uint8_t ttlOverride = 0, int64_t collectMs = 0);
  DownloadStat userObtain(const std::string& name, int64_t timeoutMs);

  void getPeerInfo(uint64_t* nodeId, uint32_t* connectedNeighbours,
                   uint64_t* files, uint32_t* controlPort) const;
  void getDetailedStats(uint64_t* routeSize, uint64_t* pendingSize) const;

 private:
  struct Options {
    uint64_t nodeId = 0;
    std::string myIp;
    uint16_t msgPort = 51000;
    uint16_t controlPort = 51001;
    uint16_t downloadPort = 51002;
    bool central = false;
    std::string indexIp;
    uint16_t indexPort = 51000;
    std::string dataDir;
    std::string downloadsDir;
    int defaultTtl = 8;
    bool keepDownloads = false;
    bool enableCli = false;
    size_t routingCap = 262144;
    int64_t routingMaxAgeMs = 30000;
    int64_t queryTimeoutMs = 8000;
    int replicationFactor = 3;
    int64_t hitCollectMs = 250;

    std::string journalPath;

    bool ringFallback = true;

    std::string rescanMarker = "/tmp/peer.rescan";
    std::string gcDryMarker = "/tmp/peer.gc-dry";
    std::string gcMarker = "/tmp/peer.gc";
  };

  Options opt_;
  std::atomic<bool> stop_{false};

  LocalIndex index_;
  RouteTable routes_;
  PendingTable pends_;
  uint64_t myIpNum_ = 0;

  struct Link {
    int fd = -1;
    uint32_t ip = 0;
    uint16_t port = 0;
    uint64_t peerId = 0;
    std::shared_ptr<std::atomic<bool>> dead;
    std::mutex qmu;
    std::condition_variable qcv;
    std::deque<std::pair<uint8_t, std::vector<uint8_t>>> q;
    static constexpr size_t QMAX = 8192;
    bool send(uint8_t type, const void* payload, size_t n) {
      std::lock_guard<std::mutex> g(qmu);
      if (dead->load()) return false;
      if (q.size() >= QMAX) return false;
      std::vector<uint8_t> pl(static_cast<const uint8_t*>(payload),
                              static_cast<const uint8_t*>(payload) + n);
      q.emplace_back(type, std::move(pl));
      qcv.notify_one();
      return true;
    }
    bool sendFrame(uint8_t type, const Writer& w) {
      return send(type, w.buf.data(), w.buf.size());
    }
  };
  mutable std::mutex linksMu_;
  std::unordered_map<uint64_t, std::shared_ptr<Link>> links_;

  std::vector<std::pair<std::string, uint16_t>> neighbors_;

  std::vector<std::pair<std::string, uint16_t>> extraPeers_;

  void linkWriterLoop(std::shared_ptr<Link> link);
  void linkReaderLoop(std::shared_ptr<Link> link);
  void neighborDialerLoop();

  void handleQueryFrame(std::shared_ptr<Link> up, const Frame& f);
  void handleHitFrame(const Frame& f);
  void sendHit(std::shared_ptr<Link> up, const MsgId& id,
               const std::string& name, uint8_t replyTtl);
  void forwardQuery(const QueryMsg& q, std::shared_ptr<Link> except);
  std::shared_ptr<Link> findLinkByKey(uint64_t key);

  void msgAcceptLoop(int lfd);
  void controlAcceptLoop(int lfd);
  void downloadAcceptLoop(int lfd);
  void controlConnLoop(int fd);
  void downloadConnLoop(int fd);
  void inboundIntroLoop(int fd, uint32_t ip);

  bool serveObtain(int fd, const Frame& f);
  bool servePutReq(int fd, const Frame& f);
  bool serveHaveReq(int fd, const Frame& f);

  void janitorLoop();

  IndexClient idxClient_;

  void cliLoop();

  void printQueryResults(const std::string& name, const QueryResult& r);
  void printObtainLine(const std::string& name, const DownloadStat& s);

  MsgId nextMsgId() { return MsgId{opt_.nodeId, seqCounter_++}; }
  std::atomic<uint64_t> seqCounter_{1};

  struct RingNode {
    uint64_t id = 0;
    std::string ip;
    uint16_t dport = 0;
  };
  std::vector<RingNode> ring_;

  struct ReplJob {
    std::string name;
    uint64_t target = 0;
  };
  std::mutex replMu_;
  std::condition_variable replCv_;

  std::unordered_map<uint64_t, std::deque<ReplJob>> replQ_;
  std::deque<uint64_t> replTargets_;
  size_t replPending_ = 0;
  std::unordered_set<std::string> replQueued_;
  std::unordered_set<std::string> replFlying_;

  std::unordered_set<std::string> replDone_;

  std::unordered_map<uint64_t, int> replFail_;
  std::unordered_map<std::string, long long> replRetry_;
  std::atomic<size_t> replInFlight_{0};
  std::atomic<uint64_t> replPushed_{0};
  std::atomic<uint64_t> replSkipped_{0};
  std::atomic<uint64_t> replFailed_{0};
  std::atomic<uint64_t> replRecv_{0};
  std::atomic<bool> replInitialDone_{false};

  void replicationLoop();
  void replWorkerLoop();
  void replEnqueue(const std::string& name, uint64_t target);
  void replEnsureAll();
  uint64_t ownerOf(const std::string& name) const;
  std::vector<uint64_t> ringHolders(const std::string& name) const;
  const RingNode* ringById(uint64_t id) const;

  static uint64_t prefixOwnerOf(const std::string& name);
  uint64_t journalLookup(const std::string& name) const;
  void journalRecord(const std::string& name, uint64_t owner);
  void journalLoad();
  size_t journalAdoptOrphans();

  void journalCompact();
  mutable std::mutex journalMu_;
  std::unordered_map<std::string, uint64_t> journal_;

  void gcScan(bool dryRun);

  std::vector<HitEntry> ringFallbackProbe(const std::string& name,
                                          size_t* probedOut);

  bool replAlive(uint64_t id);
  bool replProbe(uint64_t id);
  uint64_t replReplacement(const std::string& name, uint64_t deadId,
                           const std::unordered_set<uint64_t>& extraSkip);

  int replPushBatch(int* sessionFd, uint64_t target,
                    const std::vector<std::string>& names,
                    std::vector<int>* rc);

  std::atomic<uint64_t> routeMisses_{0};
  std::atomic<uint64_t> hitsDropped_{0};

  std::atomic<uint64_t> qRecv_{0};
  std::atomic<uint64_t> qFwd_{0};
  std::atomic<uint64_t> qDup_{0};
  std::atomic<uint64_t> hitOrig_{0};
  std::atomic<uint64_t> hitRelay_{0};
};

bool downloadTo(uint32_t ip, uint16_t port, const std::string& name,
                const std::string& dstPath, uint64_t* bytesOut,
                const std::string& bindIp = "");

}
