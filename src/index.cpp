#include "index.hpp"

#include <sys/stat.h>

namespace p2p {

IndexServer::IndexServer(const Config& cfg) {
  port_ = static_cast<uint16_t>(cfg.num("msg_port", 51000));
  LOGI("index server starting: port=%u", port_);
}

void IndexServer::run() {
  int lfd = tcpListen(port_);
  if (lfd < 0) {
    LOGE("index server: cannot listen on %u", port_);
    return;
  }
  gStartMs_ = wallMs();
  std::thread janitor([this]() { janitorLoop(); });
  acceptLoop(lfd);
  janitor.join();
}

void IndexServer::acceptLoop(int lfd) {
  while (!stop_.load()) {
    uint32_t ip = 0;
    uint16_t port = 0;
    int fd = pollAccept(lfd, 250, &ip, &port);
    if (fd == -2) continue;
    if (fd < 0) {
      if (stop_.load()) break;
      continue;
    }

    setRecvTimeout(fd, 90000);
    std::thread([this, fd, ip]() { connLoop(fd, ip); }).detach();
  }
  closeFd(lfd);
}

void IndexServer::removePeerLocked(uint64_t nodeId) {
  auto it = byNodeId_.find(nodeId);
  if (it == byNodeId_.end()) return;
  PeerRecord* rec = it->second.get();

  for (const std::string& name : rec->files) {
    auto fit = byFile_.find(name);
    if (fit == byFile_.end()) continue;
    auto& holders = fit->second;
    for (size_t i = 0; i < holders.size(); i++) {
      if (holders[i] == rec) {
        holders[i] = holders.back();
        holders.pop_back();
        break;
      }
    }
    if (holders.empty()) byFile_.erase(fit);
  }

  LOGI("node %llu de-registered (%zu files)", (unsigned long long)nodeId,
       rec->files.size());
  byNodeId_.erase(it);
}

void IndexServer::connLoop(int fd, uint32_t remoteIp) {
  Frame f;
  uint64_t selfNodeId = 0;
  bool dead = false;
  const std::string remoteStr = ipStr(remoteIp);
  while (!stop_.load() && !dead) {
    if (!readFrame(fd, f, 4 << 20)) break;
    Reader r(f.payload.data(), f.payload.size());
    switch (f.type) {
      case I_REGISTER: {
        uint64_t nodeId = 0;
        std::string theirIp;
        uint16_t dport = 0;
        uint32_t fileCount = 0;
        if (!r.u64(nodeId) || !r.str(theirIp) || !r.u16(dport) ||
            !r.u32(fileCount)) {
          LOGW("malformed REGISTER from %s", remoteStr.c_str());
          dead = true;
          break;
        }
        {
          std::unique_lock<std::shared_mutex> g(mu_);
          removePeerLocked(nodeId);
          auto rec = std::make_unique<PeerRecord>();
          rec->nodeId = nodeId;
          rec->ip = remoteIp;
          rec->dport = dport;
          rec->lastSeen = steadyMs();
          selfNodeId = nodeId;
          byNodeId_[nodeId] = std::move(rec);
        }
        uint8_t one = 1;
        writeFrame(fd, I_REGISTER_OK, &one, 1);
        LOGI("node %llu registering (%s, %u files)...",
             (unsigned long long)nodeId, sockaddrPretty(remoteIp, dport).c_str(),
             fileCount);
        break;
      }
      case I_ADDFILES: {

        uint64_t nodeId = 0;
        if (!r.u64(nodeId) || nodeId != selfNodeId || selfNodeId == 0) {
          LOGW("ADDFILES from %s without an owned registration",
               remoteStr.c_str());
          dead = true;
          break;
        }
        {
          std::unique_lock<std::shared_mutex> g(mu_);
          auto it = byNodeId_.find(selfNodeId);
          if (it != byNodeId_.end()) it->second->lastSeen = steadyMs();
        }
        uint8_t one = 1;
        writeFrame(fd, I_REGISTER_OK, &one, 1);
        break;
      }
      case I_FILES: {
        uint16_t batchCount = 0;
        if (!r.u16(batchCount)) {
          dead = true;
          break;
        }
        {
          std::unique_lock<std::shared_mutex> g(mu_);
          auto it = byNodeId_.find(selfNodeId);
          if (it == byNodeId_.end()) {

            LOGW("I_FILES for node %llu without a registration record; "
                 "closing connection",
                 (unsigned long long)selfNodeId);
            dead = true;
            break;
          }
          PeerRecord* rec = it->second.get();
          rec->lastSeen = steadyMs();
          for (uint16_t i = 0; i < batchCount; i++) {
            std::string name;
            if (!r.str(name)) {
              dead = true;
              break;
            }

            if (rec->files.insert(name).second)
              byFile_[name].push_back(rec);
          }
          if (dead) break;
        }
        uint8_t one = 1;
        writeFrame(fd, I_FILES_OK, &one, 1);
        break;
      }
      case I_LOOKUP: {
        std::string name;
        if (!r.str(name)) {
          dead = true;
          break;
        }
        std::vector<HitEntry> hits;
        {
          std::shared_lock<std::shared_mutex> g(mu_);
          auto it = byFile_.find(name);
          if (it != byFile_.end()) {
            for (PeerRecord* rec : it->second) {
              hits.push_back(HitEntry{rec->ip, rec->dport, rec->nodeId});
            }
          }
        }
        Writer w = encHits(true, hits);
        writeFrame(fd, I_LOOKUP_RESULT, w.buf.data(), w.buf.size());
        LOGI("lookup '%s' from %s -> %zu holder(s)", name.c_str(),
             remoteStr.c_str(), hits.size());
        break;
      }
      case I_HEARTBEAT: {
        uint64_t nodeId = 0;
        if (!r.u64(nodeId)) {
          dead = true;
          break;
        }
        uint8_t known = 0;
        {
          std::unique_lock<std::shared_mutex> g(mu_);
          auto it = byNodeId_.find(nodeId);
          if (it != byNodeId_.end()) {
            it->second->lastSeen = steadyMs();
            known = 1;
          }
        }

        writeFrame(fd, I_REGISTER_OK, &known, 1);
        break;
      }
      case I_GOODBYE: {
        uint64_t nodeId = 0;
        if (!r.u64(nodeId)) {
          dead = true;
          break;
        }
        {
          std::unique_lock<std::shared_mutex> g(mu_);
          removePeerLocked(nodeId);
        }
        selfNodeId = 0;
        break;
      }
      default:
        LOGW("index server: unexpected frame type %u", f.type);
        dead = true;
        break;
    }
  }

  if (selfNodeId != 0) {
    std::unique_lock<std::shared_mutex> g(mu_);
    removePeerLocked(selfNodeId);
    LOGW("node %llu disconnected from index", (unsigned long long)selfNodeId);
  }
  closeFd(fd);
}

void IndexServer::janitorLoop() {

  while (!stop_.load()) {
    std::this_thread::sleep_for(std::chrono::seconds(10));
    if (stop_.load()) break;
    std::vector<uint64_t> dead;
    {
      std::shared_lock<std::shared_mutex> g(mu_);
      const int64_t cutoff = steadyMs() - 300000;
      for (auto& kv : byNodeId_)
        if (kv.second->lastSeen < cutoff) dead.push_back(kv.first);
    }
    if (!dead.empty()) {
      std::unique_lock<std::shared_mutex> g(mu_);
      for (uint64_t n : dead) removePeerLocked(n);
      LOGW("index janitor removed %zu silent node(s)", dead.size());
    }
  }
}

}
