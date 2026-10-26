#pragma once

#include "common.hpp"
#include "local_index.hpp"
#include "proto.hpp"

#include <atomic>
#include <mutex>
#include <thread>
#include <vector>

namespace p2p {

class Peer;

class IndexClient {
 public:

  void start(const std::string& indexIp, uint16_t indexPort, uint64_t nodeId,
             const std::string& myIp, uint16_t downloadPort,
             const LocalIndex* files);
  void stop();
  ~IndexClient() { stop(); }

  void registerExtra(std::vector<std::string> names);

  void resyncNow();

 private:
  void loop();
  bool doRegister(int fd, const std::vector<std::string>& names);

  bool sendFiles(int fd, const std::vector<std::string>& names);

  bool sendAddFiles(int fd, const std::vector<std::string>& names);

  std::string indexIp_;
  uint16_t indexPort_ = 51000;
  uint64_t nodeId_ = 0;
  std::string myIp_;
  uint16_t downloadPort_ = 51002;
  const LocalIndex* files_ = nullptr;
  std::mutex extraMu_;
  std::vector<std::string> extra_;
  std::thread th_;
  std::atomic<bool> stop_{false};
};

bool centralLookup(const std::string& indexIp, uint16_t indexPort,
                   const std::string& name, std::vector<HitEntry>* hits,
                   int timeoutMs = 3000);

}
