#pragma once

#include "common.hpp"
#include "proto.hpp"

#include <algorithm>
#include <dirent.h>
#include <sys/stat.h>
#include <unordered_set>

namespace p2p {

class LocalIndex {
 public:
  void loadDir(const std::string& dir) {
    dir_ = dir;
    std::lock_guard<std::shared_mutex> g(m_);
    files_.clear();
    scanDirLocked();
  }

  size_t rescan() {
    std::lock_guard<std::shared_mutex> g(m_);
    files_.clear();
    scanDirLocked();
    return files_.size();
  }

  bool contains(const std::string& name) const {
    std::shared_lock<std::shared_mutex> g(m_);
    return files_.count(name) != 0;
  }

  void add(const std::string& name) {
    std::lock_guard<std::shared_mutex> g(m_);
    files_.insert(name);
  }

  void remove(const std::string& name) {
    std::lock_guard<std::shared_mutex> g(m_);
    files_.erase(name);
  }
  size_t size() const {
    std::shared_lock<std::shared_mutex> g(m_);
    return files_.size();
  }
  std::string dir() const { return dir_; }

  void dumpNames(std::vector<std::string>* out) const {
    std::shared_lock<std::shared_mutex> g(m_);
    out->assign(files_.begin(), files_.end());
  }

 private:

  void scanDirLocked() {
    DIR* d = opendir(dir_.c_str());
    if (!d) {
      LOGE("cannot open shared dir %s: %s", dir_.c_str(), strerror(errno));
      return;
    }
    struct dirent* de;
    while ((de = readdir(d)) != nullptr) {
      if (de->d_type == DT_DIR) continue;
      std::string n(de->d_name);
      if (n == "." || n == "..") continue;
      files_.insert(n);
    }
    closedir(d);
    LOGI("local index loaded %zu files from %s", files_.size(), dir_.c_str());
  }
  std::string dir_;
  mutable std::shared_mutex m_;
  std::unordered_set<std::string> files_;
};

class RouteTable {
 public:
  enum class Upstream : uint8_t { Link = 0, Local = 1 };

  bool tryInsert(const MsgId& id, uint64_t linkKey) {
    std::lock_guard<std::shared_mutex> g(m_);
    auto it = map_.find(id);
    if (it != map_.end()) return false;
    map_[id] = Entry{steadyMs(), linkKey, Upstream::Link};
    return true;
  }
  void insertLocal(const MsgId& id) {
    std::lock_guard<std::shared_mutex> g(m_);
    map_[id] = Entry{steadyMs(), 0, Upstream::Local};
  }

  bool find(const MsgId& id, uint64_t* linkKey) const {
    std::shared_lock<std::shared_mutex> g(m_);
    auto it = map_.find(id);
    if (it == map_.end()) return false;
    if (it->second.up == Upstream::Local) return false;
    *linkKey = it->second.link;
    return true;
  }
  bool isLocal(const MsgId& id) const {
    std::shared_lock<std::shared_mutex> g(m_);
    auto it = map_.find(id);
    return it != map_.end() && it->second.up == Upstream::Local;
  }
  bool seen(const MsgId& id) const {
    std::shared_lock<std::shared_mutex> g(m_);
    return map_.count(id) != 0;
  }

  void prune(int64_t maxAgeMs, size_t cap) {
    std::lock_guard<std::shared_mutex> g(m_);
    const int64_t cutoff = steadyMs() - maxAgeMs;
    for (auto it = map_.begin(); it != map_.end();) {
      if (it->second.ts < cutoff)
        it = map_.erase(it);
      else
        ++it;
    }
    if (map_.size() > cap) {
      std::vector<uint64_t> times;
      times.reserve(map_.size());
      for (auto& kv : map_) times.push_back(kv.second.ts);
      std::nth_element(times.begin(), times.begin() + map_.size() - cap,
                       times.end(), std::greater<uint64_t>());
      uint64_t cutoffTs = times[map_.size() - cap];
      for (auto it = map_.begin(); it != map_.end();) {
        if (static_cast<uint64_t>(it->second.ts) < cutoffTs)
          it = map_.erase(it);
        else
          ++it;
      }
    }
  }
  size_t size() const {
    std::shared_lock<std::shared_mutex> g(m_);
    return map_.size();
  }

 private:
  struct Entry {
    int64_t ts;
    uint64_t link;
    Upstream up;
  };
  mutable std::shared_mutex m_;
  std::unordered_map<MsgId, Entry, MsgIdHash> map_;
};

class PendingTable {
 public:
  static constexpr int64_t PENDING_EXPIRE_MS = 8000;

  struct Hit {
    HitEntry e;
    int64_t atMs;
  };
  struct Entry;

  std::shared_ptr<Entry> open(const MsgId& id, int64_t deadlineMs) {
    std::lock_guard<std::mutex> g(m_);
    auto now = std::make_shared<Entry>();
    now->deadline = deadlineMs;
    pend_[id] = now;
    return now;
  }

  bool addHit(const MsgId& id, const HitEntry& e) {
    std::shared_ptr<Entry> en;
    {
      std::lock_guard<std::mutex> g(m_);
      auto it = pend_.find(id);
      if (it == pend_.end()) return false;
      en = it->second;
    }
    std::lock_guard<std::mutex> g(en->mu);
    if (en->hits.empty()) en->firstHitMs = wallMs();
    en->hits.emplace_back(Hit{e, wallMs()});
    en->cv.notify_all();
    return true;
  }

  std::shared_ptr<Entry> take(const MsgId& id, bool eraseIt) {
    std::lock_guard<std::mutex> g(m_);
    auto it = pend_.find(id);
    if (it == pend_.end()) return nullptr;
    std::shared_ptr<Entry> en = it->second;
    if (eraseIt) pend_.erase(it);
    return en;
  }
  static void waitForHit(const std::shared_ptr<Entry>& en) {
    std::unique_lock<std::mutex> lk(en->mu);
    en->cv.wait(lk, [&] {
      return !en->hits.empty() || en->expired;
    });
  }

  static void waitForWindow(const std::shared_ptr<Entry>& en,
                            int64_t windowMs) {
    std::unique_lock<std::mutex> lk(en->mu);
    auto windowOver = [&] {
      if (en->expired || en->hits.empty()) return true;
      return en->firstHitMs + windowMs <= wallMs() ||
             en->deadline <= steadyMs();
    };
    en->cv.wait_for(lk, std::chrono::milliseconds(windowMs + 50), windowOver);
  }
  void sweepExpired() {
    std::vector<std::shared_ptr<Entry>> old;
    {
      std::lock_guard<std::mutex> g(m_);
      for (auto it = pend_.begin(); it != pend_.end();) {
        if (it->second->deadline < steadyMs()) {
          old.push_back(it->second);
          it = pend_.erase(it);
        } else
          ++it;
      }
    }
    for (auto& en : old) {
      std::lock_guard<std::mutex> g(en->mu);
      en->expired = true;
      en->cv.notify_all();
    }
  }
  size_t size() const {
    std::lock_guard<std::mutex> g(m_);
    return pend_.size();
  }

  struct Entry {
    std::vector<Hit> hits;
    int64_t deadline = 0;
    int64_t firstHitMs = 0;
    bool expired = false;
    std::mutex mu;
    std::condition_variable cv;
  };

 private:
  mutable std::mutex m_;

  std::unordered_map<MsgId, std::shared_ptr<Entry>, MsgIdHash> pend_;
};

}
