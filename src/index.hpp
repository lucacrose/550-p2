#pragma once

#include "common.hpp"
#include "proto.hpp"

#include <atomic>
#include <memory>
#include <shared_mutex>
#include <unordered_set>

namespace p2p {

struct PeerRecord {
  uint64_t nodeId = 0;
  uint32_t ip = 0;
  uint16_t dport = 51002;
  int64_t lastSeen = 0;
  std::unordered_set<std::string> files;
};

class IndexServer {
 public:
  explicit IndexServer(const Config& cfg);
  void run();

 private:
  void acceptLoop(int lfd);
  void connLoop(int fd, uint32_t remoteIp);
  void janitorLoop();

  void removePeerLocked(uint64_t nodeId);

  uint16_t port_ = 51000;
  mutable std::shared_mutex mu_;
  std::unordered_map<std::string, std::vector<PeerRecord*>> byFile_;
  std::unordered_map<uint64_t, std::unique_ptr<PeerRecord>> byNodeId_;
  std::atomic<bool> stop_{false};
  int64_t gStartMs_ = wallMs();
};

}
