#include "peer.hpp"

#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <iostream>
#include <random>
#include <set>

namespace p2p {

static std::string pathJoin(const std::string& a, const std::string& b) {
  if (a.empty()) return b;
  if (b.empty()) return a;
  return (a.back() == '/') ? a + b : a + "/" + b;
}
static uint32_t parseIpNum(const std::string& s) {
  struct in_addr a;
  if (inet_pton(AF_INET, s.c_str(), &a) != 1) return 0;
  return ntohl(a.s_addr);
}

static bool namePrefixParsed(const std::string& name, uint64_t* out) {
  if (name.empty() || name[0] != 'n') return false;
  size_t i = 1;
  long long v = 0;
  while (i < name.size() && isdigit((unsigned char)name[i])) {
    v = v * 10 + (name[i] - '0');
    if (v > 999999) return false;
    i++;
  }
  if (i == 1 || i >= name.size() || name[i] != '_') return false;
  *out = static_cast<uint64_t>(v);
  return true;
}
uint64_t Peer::prefixOwnerOf(const std::string& name) {
  uint64_t v = 0;
  return namePrefixParsed(name, &v) ? v : 0;
}
uint64_t Peer::ownerOf(const std::string& name) const {
  uint64_t v = 0;
  if (namePrefixParsed(name, &v)) return v;
  return journalLookup(name);
}

uint64_t Peer::journalLookup(const std::string& name) const {
  std::lock_guard<std::mutex> g(journalMu_);
  auto it = journal_.find(name);
  return it == journal_.end() ? 0 : it->second;
}

void Peer::journalRecord(const std::string& name, uint64_t owner) {
  if (name.empty() || owner == 0) return;
  if (prefixOwnerOf(name)) return;
  {
    std::lock_guard<std::mutex> g(journalMu_);
    auto it = journal_.find(name);
    if (it != journal_.end() && it->second == owner) return;
    journal_[name] = owner;
  }

  FILE* fp = std::fopen(opt_.journalPath.c_str(), "a");
  if (!fp) {
    LOGW("journal: cannot append to %s: %s", opt_.journalPath.c_str(),
         strerror(errno));
    return;
  }
  fprintf(fp, "%s\t%llu\n", name.c_str(), (unsigned long long)owner);
  fclose(fp);
}

void Peer::journalLoad() {
  std::unordered_map<std::string, uint64_t> fresh;
  FILE* fp = std::fopen(opt_.journalPath.c_str(), "r");
  size_t lines = 0;
  if (fp) {
    char line[4096];
    while (std::fgets(line, sizeof(line), fp)) {
      char* tab = std::strchr(line, '\t');
      if (!tab) continue;
      *tab = 0;
      uint64_t owner = std::strtoull(tab + 1, nullptr, 10);
      if (owner && line[0]) fresh[line] = owner;
      lines++;
    }
    fclose(fp);
  }
  {
    std::lock_guard<std::mutex> g(journalMu_);
    journal_ = std::move(fresh);
  }
  if (lines)
    LOGI("journal loaded: %zu lines from %s", lines, opt_.journalPath.c_str());
}

size_t Peer::journalAdoptOrphans() {
  std::vector<std::string> names;
  index_.dumpNames(&names);
  size_t adopted = 0;
  for (const auto& n : names) {
    if (prefixOwnerOf(n)) continue;
    if (journalLookup(n)) continue;
    journalRecord(n, opt_.nodeId);
    adopted++;
  }
  return adopted;
}

void Peer::journalCompact() {
  std::string tmp = opt_.journalPath + ".tmp";
  FILE* fp = std::fopen(tmp.c_str(), "w");
  if (!fp) {
    LOGW("journal compact: cannot write %s", tmp.c_str());
    return;
  }
  size_t kept = 0;
  {
    std::lock_guard<std::mutex> g(journalMu_);
    for (const auto& kv : journal_) {
      if (!index_.contains(kv.first)) continue;
      fprintf(fp, "%s\t%llu\n", kv.first.c_str(),
              (unsigned long long)kv.second);
      kept++;
    }
  }
  fclose(fp);
  if (std::rename(tmp.c_str(), opt_.journalPath.c_str()) != 0) {
    std::remove(tmp.c_str());
    LOGW("journal compact: rename failed");
    return;
  }
  LOGI("journal compacted: kept=%zu", kept);
}

std::vector<uint64_t> Peer::ringHolders(const std::string& name) const {
  std::vector<uint64_t> out;
  if (ring_.size() < 2) return out;
  uint64_t owner = ownerOf(name);
  uint64_t h = fnv1a64(name);
  size_t start = static_cast<size_t>(h % ring_.size());
  int want = opt_.replicationFactor - 1;
  std::set<uint64_t> chosen;
  for (size_t k = 0; k < ring_.size() && static_cast<int>(out.size()) < want;
       k++) {
    uint64_t cand = ring_[(start + k) % ring_.size()].id;
    if (cand == owner || chosen.count(cand)) continue;
    chosen.insert(cand);
    out.push_back(cand);
  }
  return out;
}

const Peer::RingNode* Peer::ringById(uint64_t id) const {
  for (const auto& rn : ring_)
    if (rn.id == id) return &rn;
  return nullptr;
}

bool Peer::replAlive(uint64_t id) {
  if (id == opt_.nodeId) return true;
  std::lock_guard<std::mutex> g(replMu_);
  auto it = replFail_.find(id);
  return it == replFail_.end() || it->second < 2;
}

bool Peer::replProbe(uint64_t id) {
  const RingNode* rn = ringById(id);
  if (!rn || rn->id == opt_.nodeId) return true;
  int fd = tcpConnect(rn->ip, rn->dport, 500, opt_.myIp);
  if (fd < 0) return false;
  setRstOnClose(fd);
  closeFd(fd);
  return true;
}

Peer::Peer(const Config& cfg, bool enableCli) {
  opt_.nodeId = static_cast<uint64_t>(cfg.num("node_id", 0));
  opt_.myIp = cfg.str("my_ip", "");
  opt_.msgPort = static_cast<uint16_t>(cfg.num("msg_port", 51000));
  opt_.controlPort = static_cast<uint16_t>(cfg.num("control_port", 51001));
  opt_.downloadPort = static_cast<uint16_t>(cfg.num("download_port", 51002));
  std::string topo = cfg.str("topology", "mesh");
  opt_.central = (topo == "central");
  opt_.dataDir = cfg.str("data_dir", "/data/shared");
  opt_.downloadsDir = cfg.str("downloads_dir", "/data/downloads");
  opt_.defaultTtl = static_cast<int>(cfg.num("ttl", 8));
  opt_.keepDownloads = cfg.num("keep_downloads", 0) != 0;
  opt_.queryTimeoutMs = cfg.num("query_timeout_ms", 8000);
  opt_.indexIp = cfg.str("index_ip", "");
  opt_.indexPort = static_cast<uint16_t>(cfg.num("index_port", 51000));
  opt_.enableCli = enableCli;
  opt_.replicationFactor = static_cast<int>(cfg.num("replication_factor", 3));
  opt_.hitCollectMs = cfg.num("hit_collect_ms", 250);
  opt_.ringFallback = cfg.num("ring_fallback", 1) != 0;
  myIpNum_ = parseIpNum(opt_.myIp);
  if (opt_.nodeId == 0 || opt_.myIp.empty()) {
    LOGE("peer config needs node_id and my_ip");
    std::exit(2);
  }

  if (cfg.has("journal_path")) {
    opt_.journalPath = cfg.str("journal_path", "");
  } else {
    std::string d = opt_.dataDir;
    while (!d.empty() && d.back() == '/') d.pop_back();
    size_t slash = d.rfind('/');
    std::string parent = (slash == std::string::npos) ? std::string(".")
                                                      : d.substr(0, slash);
    opt_.journalPath = pathJoin(parent, ".p2p-repl.meta");
  }

  opt_.rescanMarker = cfg.str("rescan_marker", opt_.rescanMarker);
  opt_.gcDryMarker = cfg.str("gc_dry_marker", opt_.gcDryMarker);
  opt_.gcMarker = cfg.str("gc_marker", opt_.gcMarker);

  for (const auto& n : cfg.list("neighbors")) {
    std::string ip;
    uint16_t port = 0;
    parseAddr(n, &ip, &port);
    if (port == 0) port = 51000;
    neighbors_.emplace_back(ip, port);
  }
  std::sort(neighbors_.begin(), neighbors_.end());
  neighbors_.erase(std::unique(neighbors_.begin(), neighbors_.end()),
                   neighbors_.end());

  for (const auto& n : cfg.list("extra_peers")) {
    std::string ip;
    uint16_t port = 0;
    parseAddr(n, &ip, &port);
    if (port == 0) port = 51000;
    extraPeers_.emplace_back(ip, port);
  }
  std::sort(extraPeers_.begin(), extraPeers_.end());
  extraPeers_.erase(std::unique(extraPeers_.begin(), extraPeers_.end()),
                    extraPeers_.end());

  for (const auto& tok : cfg.list("ring")) {
    std::vector<std::string> parts = split(tok, ':');
    if (parts.size() < 2) {
      LOGW("bad ring entry '%s' (want id:ip[:dport])", tok.c_str());
      continue;
    }
    RingNode rn;
    rn.id = std::strtoull(parts[0].c_str(), nullptr, 10);
    rn.ip = parts[1];
    rn.dport = parts.size() > 2
                   ? static_cast<uint16_t>(std::atoi(parts[2].c_str()))
                   : opt_.downloadPort;
    ring_.push_back(rn);
  }
  std::sort(ring_.begin(), ring_.end(),
            [](const RingNode& a, const RingNode& b) { return a.id < b.id; });
  if (opt_.replicationFactor < 1) opt_.replicationFactor = 1;
  if (opt_.replicationFactor > static_cast<int>(ring_.size()))
    opt_.replicationFactor = static_cast<int>(ring_.size());

  {
    DIR* d = opendir(opt_.dataDir.c_str());
    if (d) {
      struct dirent* de;
      size_t cleaned = 0;
      while ((de = readdir(d)) != nullptr) {
        std::string n(de->d_name);
        if (n.size() > 5 && n.compare(n.size() - 5, 5, ".part") == 0) {
          std::string p = pathJoin(opt_.dataDir, n);
          ::unlink(p.c_str());
          cleaned++;
        }
      }
      closedir(d);
      if (cleaned) LOGW("removed %zu stale .part files from %s", cleaned,
                        opt_.dataDir.c_str());
    }
  }
  index_.loadDir(opt_.dataDir);
  ::mkdir(opt_.downloadsDir.c_str(), 0755);

  journalLoad();
  size_t adopted = journalAdoptOrphans();
  if (adopted)
    LOGI("journal: adopted %zu journal-less files as originally published "
         "by node %llu", adopted, (unsigned long long)opt_.nodeId);
  LOGI(
      "peer %llu initialised: ip=%s msg=%u control=%u dl=%u top=%s "
      "neighbours=%zu files=%zu ring=%zu rf=%d journal=%s ring_fallback=%d",
      (unsigned long long)opt_.nodeId, opt_.myIp.c_str(), opt_.msgPort,
      opt_.controlPort, opt_.downloadPort, topo.c_str(), neighbors_.size(),
      index_.size(), ring_.size(), opt_.replicationFactor,
      opt_.journalPath.c_str(), opt_.ringFallback ? 1 : 0);
}

Peer::~Peer() { requestStop(); }

void Peer::requestStop() { stop_.store(true); }

void Peer::linkWriterLoop(std::shared_ptr<Link> link) {
  while (!stop_.load()) {
    std::pair<uint8_t, std::vector<uint8_t>> item;
    {
      std::unique_lock<std::mutex> lk(link->qmu);
      link->qcv.wait(lk, [&] {
        return stop_.load() || !link->q.empty() || link->dead->load();
      });
      if (stop_.load() || link->q.empty()) break;
      item = std::move(link->q.front());
      link->q.pop_front();
    }
    if (!writeFrame(link->fd, item.first, item.second.data(),
                    item.second.size())) {
      LOGW("link to %s write failed, closing channel",
           sockaddrPretty(link->ip, link->port).c_str());
      closeFd(link->fd);
      return;
    }
  }
}

void Peer::linkReaderLoop(std::shared_ptr<Link> link) {
  Frame f;
  while (!stop_.load()) {
    if (!readFrame(link->fd, f)) break;
    switch (f.type) {
      case MSG_QUERY:
        handleQueryFrame(link, f);
        break;
      case MSG_HITQUERY:
        handleHitFrame(f);
        break;
      case MSG_LINK_GRANT:
      case MSG_LINK_DENY:
        break;
      default:
        LOGW("link %s unknown frame type %u",
             sockaddrPretty(link->ip, link->port).c_str(), f.type);
        break;
    }
  }
  closeFd(link->fd);

  std::lock_guard<std::mutex> g(linksMu_);
  uint64_t key = addrKey(link->ip, link->port);
  auto it = links_.find(key);
  if (it != links_.end() && it->second.get() == link.get()) {
    links_.erase(it);
    LOGW("neighbour %s lost (node %llu), redialing",
         sockaddrPretty(link->ip, link->port).c_str(),
         (unsigned long long)link->peerId);
  }
  link->dead->store(true);

  replCv_.notify_all();
}

std::shared_ptr<Peer::Link> Peer::findLinkByKey(uint64_t key) {
  std::lock_guard<std::mutex> g(linksMu_);
  auto it = links_.find(key);
  return it == links_.end() ? nullptr : it->second;
}

void Peer::neighborDialerLoop() {

  std::unordered_map<uint64_t, int64_t> denyUntil;
  while (!stop_.load()) {
    for (size_t ci = 0; ci < neighbors_.size(); ci++) {
      if (stop_.load()) break;
      const std::string& ipStr_ = neighbors_[ci].first;
      uint16_t port_ = neighbors_[ci].second;
      uint32_t ip = parseIpNum(ipStr_);
      uint64_t key = addrKey(ip, port_);
      if (findLinkByKey(key)) continue;
      auto dua = denyUntil.find(key);
      if (dua != denyUntil.end() && dua->second > steadyMs()) continue;
      int fd = tcpConnect(ipStr_, port_, 1500, opt_.myIp);
      if (fd < 0) continue;

      setRecvTimeout(fd, 3000);
      HelloMsg h{opt_.nodeId, opt_.msgPort};
      Writer w = encHello(h);
      if (!writeFrame(fd, MSG_HELLO, w.buf.data(), w.buf.size())) {
        close(fd);
        continue;
      }
      Frame f;
      if (!readFrame(fd, f, 64)) {
        close(fd);
        continue;
      }
      bool granted =
          (f.type == MSG_LINK_GRANT && !f.payload.empty() && f.payload[0] == 1);
      if (!granted) {

        close(fd);
        denyUntil[key] = steadyMs() + 5000;
        continue;
      }
      auto link = std::make_shared<Link>();
      link->fd = fd;
      link->ip = ip;
      link->port = port_;
      link->peerId = 0;
      link->dead = std::make_shared<std::atomic<bool>>(false);

      setRecvTimeout(fd, 0);
      bool ok = true;
      {
        std::lock_guard<std::mutex> g(linksMu_);
        uint64_t key = addrKey(ip, port_);
        auto it = links_.find(key);
        if (it == links_.end())
          links_[key] = link;
        else if (it->second->dead->load()) {

          closeFd(it->second->fd);
          it->second = link;
        } else {
          ok = false;
        }
      }
      if (!ok) {
        closeFd(fd);
        continue;
      }
      LOGI("neighbour %s:%u channel established (outbound dial)",
           ipStr_.c_str(), port_);
      std::thread([this, link]() { linkWriterLoop(link); }).detach();
      std::thread([this, link]() { linkReaderLoop(link); }).detach();
    }
    std::this_thread::sleep_for(std::chrono::seconds(2));
  }
}

void Peer::inboundIntroLoop(int fd, uint32_t ip) {
  Frame f;
  if (!(readFrame(fd, f, 4096) && f.type == MSG_HELLO)) {
    LOGW("unrecognised connection on message port, dropping");
    closeFd(fd);
    return;
  }
  HelloMsg h;
  if (!decHello(f, &h)) {
    closeFd(fd);
    return;
  }

  uint16_t theirPort = h.msgPort ? h.msgPort : 51000;
  bool known = false;
  for (const auto& n : neighbors_)
    if (parseIpNum(n.first) == ip && n.second == theirPort) {
      known = true;
      break;
    }

  bool extra = false;
  if (!known) {
    for (const auto& n : extraPeers_) {
      if (parseIpNum(n.first) == ip && n.second == theirPort) {
        extra = true;
        break;
      }
    }
  }
  if (!known && !extra) {
    LOGW("connection from %s (node %llu) is not a configured neighbour: deny",
         sockaddrPretty(ip, theirPort).c_str(), (unsigned long long)h.nodeId);
    uint8_t zero = 0;
    writeFrame(fd, MSG_LINK_DENY, &zero, 1);
    closeFd(fd);
    return;
  }
  uint64_t key = addrKey(ip, theirPort);
  bool adopt = false;
  {
    std::lock_guard<std::mutex> g(linksMu_);
    auto it = links_.find(key);
    if (extra) {

      if (it != links_.end()) {
        closeFd(it->second->fd);
        links_.erase(it);
      }
      adopt = true;
    } else if (h.nodeId != 0 && h.nodeId < opt_.nodeId) {

      if (it != links_.end()) {
        closeFd(it->second->fd);
        links_.erase(it);
      }
      adopt = true;
    } else if (it != links_.end() && it->second->dead->load()) {

      closeFd(it->second->fd);
      links_.erase(it);
      adopt = true;
    }

  }
  uint8_t one = 1;
  if (!adopt) {
    writeFrame(fd, MSG_LINK_DENY, &one, 1);
    closeFd(fd);
    LOGI("denied duplicate dial from %s (node %llu)", ipStr(ip).c_str(),
         (unsigned long long)h.nodeId);
    return;
  }
  writeFrame(fd, MSG_LINK_GRANT, &one, 1);
  auto link = std::make_shared<Link>();
  link->fd = fd;
  link->ip = ip;
  link->port = theirPort;
  link->peerId = h.nodeId;
  link->dead = std::make_shared<std::atomic<bool>>(false);

  {
    std::lock_guard<std::mutex> g(linksMu_);
    links_[key] = link;
  }
  LOGI("neighbour %s channel established (inbound, node %llu)",
       sockaddrPretty(ip, theirPort).c_str(), (unsigned long long)h.nodeId);
  std::thread([this, link]() { linkWriterLoop(link); }).detach();
  std::thread([this, link]() { linkReaderLoop(link); }).detach();
}

void Peer::handleQueryFrame(std::shared_ptr<Link> up, const Frame& f) {
  QueryMsg q;
  if (!decQuery(f, &q)) return;
  if (q.id.peer == 0 || q.name.empty()) return;
  uint64_t upKey = addrKey(up->ip, up->port);
  qRecv_.fetch_add(1);

  bool hit = index_.contains(q.name);
  if (!routes_.tryInsert(q.id, upKey)) {
    qDup_.fetch_add(1);
    return;
  }

  if (hit) {
    hitOrig_.fetch_add(1);
    sendHit(up, q.id, q.name, static_cast<uint8_t>(opt_.defaultTtl));
  }

  QueryMsg fwd = q;
  if (fwd.ttl > 1) {
    fwd.ttl = static_cast<uint8_t>(fwd.ttl - 1);
    forwardQuery(fwd, up);
  }

}

void Peer::forwardQuery(const QueryMsg& q, std::shared_ptr<Link> except) {
  Writer w = encQuery(q);
  uint64_t exceptKey = except ? addrKey(except->ip, except->port) : 0;
  std::lock_guard<std::mutex> g(linksMu_);
  for (auto& kv : links_) {
    if (kv.first == exceptKey) continue;

    if (kv.second->sendFrame(MSG_QUERY, w)) qFwd_.fetch_add(1);
  }
}

void Peer::sendHit(std::shared_ptr<Link> up, const MsgId& id,
                   const std::string& name, uint8_t replyTtl) {
  HitMsg h;
  h.id = id;
  h.ttl = replyTtl;
  h.name = name;
  h.ip = static_cast<uint32_t>(myIpNum_);
  h.dport = opt_.downloadPort;
  Writer w = encHit(h);
  up->sendFrame(MSG_HITQUERY, w);
}

void Peer::handleHitFrame(const Frame& f) {
  HitMsg h;
  if (!decHit(f, &h)) return;
  HitEntry e{h.ip, h.dport, 0 };
  MsgId id = h.id;
  if (pends_.addHit(id, e)) return;

  uint8_t ttl = h.ttl;
  if (ttl <= 1) {
    hitsDropped_.fetch_add(1);
    return;
  }
  uint64_t upKey = 0;
  if (!routes_.find(id, &upKey)) {

    if (routes_.isLocal(id))
      hitsDropped_.fetch_add(1);
    else
      routeMisses_.fetch_add(1);
    return;
  }
  auto up = findLinkByKey(upKey);
  if (!up) {
    hitsDropped_.fetch_add(1);
    return;
  }
  HitMsg out = h;
  out.ttl = static_cast<uint8_t>(ttl - 1);
  Writer w = encHit(out);
  if (up->sendFrame(MSG_HITQUERY, w))
    hitRelay_.fetch_add(1);
  else
    hitsDropped_.fetch_add(1);
}

QueryResult Peer::userQuery(const std::string& name, int64_t timeoutMs,
                            uint8_t ttlOverride, int64_t collectMs) {
  QueryResult r;
  const int64_t t0 = steadyMs();
  int64_t timeout = timeoutMs > 0 ? timeoutMs : opt_.queryTimeoutMs;
  if (opt_.central) {

    std::vector<HitEntry> hits;
    bool found = centralLookup(opt_.indexIp, opt_.indexPort, name, &hits);
    r.timedOut = !found;
    r.hits = std::move(hits);

    if (opt_.ringFallback && (r.timedOut || r.hits.empty()) &&
        ring_.size() > 1) {
      size_t probed = 0;
      std::vector<HitEntry> fb = ringFallbackProbe(name, &probed);
      if (!fb.empty()) {
        printf("[client] lookup failed for '%s'; ring fallback probed %zu, "
               "found %zu\n",
               name.c_str(), probed, fb.size());
        fflush(stdout);
        r.hits = std::move(fb);
        r.timedOut = false;
      }
    }
    r.ms = steadyMs() - t0;
    return r;
  }

  MsgId id = nextMsgId();
  auto pending = pends_.open(id, steadyMs() + timeout);
  if (!pending) return r;
  routes_.insertLocal(id);

  QueryMsg q;
  q.id = id;
  q.ttl = ttlOverride ? ttlOverride
                      : static_cast<uint8_t>(opt_.defaultTtl);
  q.name = name;
  {
    Writer w = encQuery(q);
    std::lock_guard<std::mutex> g(linksMu_);
    for (auto& kv : links_) kv.second->sendFrame(MSG_QUERY, w);
  }

  if (index_.contains(name)) {
    pends_.addHit(id, HitEntry{static_cast<uint32_t>(myIpNum_),
                               opt_.downloadPort, opt_.nodeId});
  }

  PendingTable::waitForHit(pending);

  if (collectMs > 0) {
    bool gotAny = false;
    {
      std::lock_guard<std::mutex> g(pending->mu);
      gotAny = !pending->hits.empty();
    }
    if (gotAny) PendingTable::waitForWindow(pending, collectMs);
  }
  bool gotFirst = false;
  {
    std::lock_guard<std::mutex> g(pending->mu);
    gotFirst = !pending->hits.empty() || pending->expired;
  }
  if (auto p = pends_.take(id, gotFirst)) {
    std::lock_guard<std::mutex> g(p->mu);
    if (!p->hits.empty()) {
      for (auto& h : p->hits) r.hits.push_back(h.e);
      r.timedOut = false;
    }
  }

  if (opt_.ringFallback && r.hits.empty() && ring_.size() > 1) {
    size_t probed = 0;
    std::vector<HitEntry> fb = ringFallbackProbe(name, &probed);
    if (!fb.empty()) {
      printf("[client] lookup failed for '%s'; ring fallback probed %zu, "
             "found %zu\n",
             name.c_str(), probed, fb.size());
      fflush(stdout);
      r.hits = std::move(fb);
      r.timedOut = false;
    }
  }
  r.ms = steadyMs() - t0;
  return r;
}

std::vector<HitEntry> Peer::ringFallbackProbe(const std::string& name,
                                              size_t* probedOut) {
  std::vector<HitEntry> out;
  *probedOut = 0;
  if (ring_.size() < 2) return out;
  uint64_t owner = ownerOf(name);
  std::vector<uint64_t> cand;
  auto addCand = [&](uint64_t id) {
    if (!id || id == opt_.nodeId) return;
    for (uint64_t c : cand)
      if (c == id) return;
    cand.push_back(id);
  };
  if (owner) {
    addCand(owner);

    for (uint64_t h : ringHolders(name)) addCand(h);
  } else {
    for (const auto& rn : ring_) addCand(rn.id);
  }

  if (cand.size() > ring_.size()) cand.resize(ring_.size());

  std::mt19937_64 rng(fnv1a64(name) ^ ((uint64_t)opt_.nodeId * 0x9E3779B9u));
  std::shuffle(cand.begin(), cand.end(), rng);
  struct ProbeRes {
    bool ok = false;
    HitEntry e;
  };
  std::vector<ProbeRes> res(cand.size());
  std::vector<std::thread> probes;
  for (size_t i = 0; i < cand.size(); i++) {
    const RingNode* rn = ringById(cand[i]);
    if (!rn) continue;
    probes.emplace_back([this, rn, name, &res, i] {
      int fd = tcpConnect(rn->ip, rn->dport, 1500, opt_.myIp);
      if (fd < 0) return;
      setRstOnClose(fd);
      Writer w;
      w.str(name);
      if (!writeFrame(fd, D_OBTAIN, w.buf.data(), w.buf.size())) {
        closeFd(fd);
        return;
      }
      Frame h;
      bool okHdr = readFrame(fd, h, 32) && h.type == D_HEAD;
      uint8_t ok = 0;
      uint64_t size = 0;
      if (okHdr) {
        Reader hr(h.payload.data(), h.payload.size());
        okHdr = hr.u8(ok) && hr.u64(size);
      }
      closeFd(fd);

      if (okHdr && ok && size > 0) {
        res[i].ok = true;
        res[i].e = HitEntry{parseIpNum(rn->ip), rn->dport, rn->id};
      }
    });
  }
  *probedOut = cand.size();
  for (auto& t : probes) t.join();
  for (const auto& p : res)
    if (p.ok) out.push_back(p.e);
  if (!out.empty())
    LOGI("ring fallback: '%s' located at %zu probed holder(s)", name.c_str(),
         out.size());
  return out;
}

DownloadStat Peer::userObtain(const std::string& name, int64_t timeoutMs) {
  DownloadStat s;

  const int64_t tq0 = steadyUs();
  QueryResult r = userQuery(name, timeoutMs);
  const int64_t tq1 = steadyUs();
  s.queryUs = tq1 - tq0;
  s.queryMs = r.ms;
  s.nHits = static_cast<uint8_t>(r.hits.size() > 255 ? 255 : r.hits.size());
  if (r.timedOut || r.hits.empty()) {
    LOGW("obtain '%s' failed: no holders found", name.c_str());
    return s;
  }

  for (size_t i = 0; i < r.hits.size() && i < 2; i++) {
    const HitEntry& e = r.hits[i];
    s.attempts = static_cast<int>(i + 1);
    s.via = sockaddrPretty(e.ip, e.dport);
    s.holderIp = e.ip;
    int64_t t0 = steadyMs();
    int64_t d0 = steadyUs();
    uint64_t bytes = 0;
    if (downloadTo(e.ip, e.dport, name,
                   pathJoin(opt_.downloadsDir, name), &bytes, opt_.myIp)) {
      s.ok = true;
      s.bytes = bytes;
      s.dlMs = steadyMs() - t0;
      s.dlUs = steadyUs() - d0;

      printObtainLine(name, s);
      if (!opt_.keepDownloads)
        std::remove(pathJoin(opt_.downloadsDir, name).c_str());
      return s;
    }
    LOGW("download attempt %zu from %s failed for '%s'", i + 1,
         s.via.c_str(), name.c_str());
  }

  QueryResult r2 = userQuery(name, timeoutMs, 0, opt_.hitCollectMs);
  s.nHits = static_cast<uint8_t>(r2.hits.size() > 255 ? 255
                                                      : r2.hits.size());
  for (size_t i = 0; i < r2.hits.size(); i++) {
    const HitEntry& e = r2.hits[i];
    s.attempts = static_cast<int>(i + 1);
    s.via = sockaddrPretty(e.ip, e.dport);
    s.holderIp = e.ip;
    int64_t t0 = steadyMs();
    int64_t d0 = steadyUs();
    uint64_t bytes = 0;
    if (downloadTo(e.ip, e.dport, name,
                   pathJoin(opt_.downloadsDir, name), &bytes, opt_.myIp)) {
      s.ok = true;
      s.bytes = bytes;
      s.dlMs = steadyMs() - t0;
      s.dlUs = steadyUs() - d0;
      printObtainLine(name, s);
      if (!opt_.keepDownloads)
        std::remove(pathJoin(opt_.downloadsDir, name).c_str());
      return s;
    }
    LOGW("recovery download attempt %zu from %s failed for '%s'", i + 1,
         s.via.c_str(), name.c_str());
  }
  return s;
}

void Peer::msgAcceptLoop(int lfd) {
  while (!stop_.load()) {
    uint32_t ip = 0;
    uint16_t port = 0;
    int fd = pollAccept(lfd, 250, &ip, &port);
    if (fd == -2) continue;
    if (fd < 0) {
      if (stop_.load()) break;
      continue;
    }
    std::thread([this, fd, ip]() { inboundIntroLoop(fd, ip); }).detach();
  }
  closeFd(lfd);
}

void Peer::controlAcceptLoop(int lfd) {
  while (!stop_.load()) {
    int fd = pollAccept(lfd, 250, nullptr, nullptr);
    if (fd == -2) continue;
    if (fd < 0) {
      if (stop_.load()) break;
      continue;
    }
    std::thread([this, fd]() { controlConnLoop(fd); }).detach();
  }
  closeFd(lfd);
}

void Peer::controlConnLoop(int fd) {
  Frame f;
  while (!stop_.load()) {
    if (!readFrame(fd, f, 1 << 20)) break;
    switch (f.type) {
      case C_PING: {
        Writer w;
        w.u64(opt_.nodeId);
        w.u8(opt_.central ? 1 : 0);
        uint32_t neigh = 0;
        {
          std::lock_guard<std::mutex> g(linksMu_);
          neigh = static_cast<uint32_t>(links_.size());
        }
        w.u32(neigh);
        w.u64(index_.size());
        writeFrame(fd, C_PONG, w.buf.data(), w.buf.size());
        break;
      }
      case C_QUERY: {
        Reader r(f.payload.data(), f.payload.size());
        std::string name;
        if (!r.str(name)) break;
        uint8_t ttl = 0;
        r.u8(ttl);
        uint64_t cm = 0;
        r.u64(cm);
        QueryResult qr = userQuery(name, opt_.queryTimeoutMs, ttl,
                                   static_cast<int64_t>(cm));
        printQueryResults(name, qr);
        Writer w = encHits(!qr.timedOut, qr.hits);
        writeFrame(fd, C_HITS, w.buf.data(), w.buf.size());
        break;
      }
      case C_OBTAIN: {
        Reader r(f.payload.data(), f.payload.size());
        std::string name;
        if (!r.str(name)) break;
        DownloadStat st = userObtain(name, opt_.queryTimeoutMs);
        Writer w;
        w.u8(st.ok ? 1 : 0);
        w.u64(st.bytes);
        w.u32(static_cast<uint32_t>(st.queryMs + st.dlMs));
        w.u16(static_cast<uint16_t>(st.attempts));

        w.u64(static_cast<uint64_t>(st.queryUs));
        w.u64(static_cast<uint64_t>(st.dlUs));
        w.u32(st.holderIp);
        w.u8(st.nHits);
        writeFrame(fd, C_DLRESULT, w.buf.data(), w.buf.size());
        break;
      }
      case C_STATS: {
        Writer w;
        w.u64(routes_.size());
        w.u64(pends_.size());
        uint32_t neigh = 0;
        {
          std::lock_guard<std::mutex> g(linksMu_);
          neigh = static_cast<uint32_t>(links_.size());
        }
        w.u32(neigh);
        w.u64(index_.size());

        w.u64(replPushed_.load());
        w.u64(replSkipped_.load());
        w.u64(replRecv_.load());
        w.u8(replInitialDone_.load() ? 1 : 0);
        w.u64(routeMisses_.load());
        w.u64(hitsDropped_.load());

        w.u64(qRecv_.load());
        w.u64(qFwd_.load());
        w.u64(qDup_.load());
        w.u64(hitOrig_.load());
        w.u64(hitRelay_.load());
        writeFrame(fd, C_STATS2, w.buf.data(), w.buf.size());
        break;
      }
      case C_SHUTDOWN:
        LOGW("shutdown requested over control channel");
        requestStop();
        break;
      default:
        break;
    }
  }
  closeFd(fd);
}

void Peer::downloadAcceptLoop(int lfd) {
  while (!stop_.load()) {
    int fd = pollAccept(lfd, 250, nullptr, nullptr);
    if (fd == -2) continue;
    if (fd < 0) {
      if (stop_.load()) break;
      continue;
    }
    std::thread([this, fd]() { downloadConnLoop(fd); }).detach();
  }
  closeFd(lfd);
}

void Peer::downloadConnLoop(int fd) {
  setRecvTimeout(fd, 60000);
  setSendTimeout(fd, 60000);
  Frame f;
  while (!stop_.load()) {
    if (!readFrame(fd, f, 1 << 16)) break;
    if (f.type == D_OBTAIN) {
      if (!serveObtain(fd, f)) break;
    } else if (f.type == D_HAVEREQ) {
      if (!serveHaveReq(fd, f)) break;
    } else if (f.type == D_PUTREQ) {
      if (!servePutReq(fd, f)) break;
    } else {
      break;
    }
  }
  closeFd(fd);
}

bool Peer::serveObtain(int fd, const Frame& f) {
  Reader r(f.payload.data(), f.payload.size());
  std::string name;
  if (!r.str(name) || name.empty() ||
      name.find("..") != std::string::npos) {
    return false;
  }
  std::string path = pathJoin(opt_.dataDir, name);
  FILE* fp = std::fopen(path.c_str(), "rb");
  if (!fp) {
    uint8_t zero = 0;
    writeFrame(fd, D_HEAD, &zero, 1);
    return true;
  }
  struct stat st;
  ::stat(path.c_str(), &st);
  Writer w;
  w.u8(1);
  w.u64(static_cast<uint64_t>(st.st_size));
  if (!writeFrame(fd, D_HEAD, w.buf.data(), w.buf.size())) {
    std::fclose(fp);
    return false;
  }
  std::vector<char> buf(1 << 20);
  uint64_t sent = 0;
  while (!stop_.load()) {
    size_t n = std::fread(buf.data(), 1, buf.size(), fp);
    if (n == 0) break;
    if (!sendAll(fd, buf.data(), n)) break;
    sent += n;
  }
  std::fclose(fp);
  LOGI("served '%s' (%s) to a peer over direct download", name.c_str(),
       humanBytes(sent).c_str());
  return true;
}

bool Peer::serveHaveReq(int fd, const Frame& f) {
  Reader r(f.payload.data(), f.payload.size());
  uint32_t n = 0;
  if (!r.u32(n) || n == 0 || n > 1024) return false;
  Writer w;
  w.u32(n);
  for (uint32_t i = 0; i < n; i++) {
    std::string name;
    uint64_t size = 0;
    if (!r.str(name) || !r.u64(size)) return false;
    uint8_t have = 0;
    if (!name.empty() && name.find("..") == std::string::npos &&
        name.find('/') == std::string::npos && index_.contains(name)) {
      struct stat st;
      std::string path = pathJoin(opt_.dataDir, name);
      have = (::stat(path.c_str(), &st) == 0 &&
              static_cast<uint64_t>(st.st_size) == size) ? 1 : 0;
    }
    w.u8(have);
  }
  return writeFrame(fd, D_HAVEACK, w.buf.data(), w.buf.size());
}

bool Peer::servePutReq(int fd, const Frame& f) {
  Reader r(f.payload.data(), f.payload.size());
  std::string name;
  uint64_t size = 0;
  uint64_t pushedOwner = 0;
  if (!r.str(name) || !r.u64(size)) return false;
  if (!r.u64(pushedOwner)) pushedOwner = 0;
  if (name.empty() || size == 0 ||
      name.find("..") != std::string::npos ||
      name.find('/') != std::string::npos) {
    return false;
  }
  std::string path = pathJoin(opt_.dataDir, name);
  struct stat st;
  bool dup = ::stat(path.c_str(), &st) == 0 &&
             static_cast<uint64_t>(st.st_size) == size;
  std::string tmp = path + ".part";
  FILE* fp = dup ? nullptr : std::fopen(tmp.c_str(), "wb");
  if (!fp && !dup) {

    std::vector<char> bucket(1 << 16);
    uint64_t off = 0;
    while (off < size) {
      size_t want = bucket.size();
      if (want > size - off) want = static_cast<size_t>(size - off);
      if (!recvAll(fd, bucket.data(), want)) return false;
      off += want;
    }
    uint8_t zero = 0;
    writeFrame(fd, D_PUTACK, &zero, 1);
    return true;
  }
  std::vector<char> buf(dup ? (1 << 16) : (1 << 20));
  uint64_t got = 0;
  bool good = true;
  while (got < size) {
    size_t want = buf.size();
    if (want > size - got) want = static_cast<size_t>(size - got);
    if (!recvAll(fd, buf.data(), want)) { good = false; break; }
    if (fp && std::fwrite(buf.data(), 1, want, fp) != want) {
      good = false;
      break;
    }
    got += want;
  }
  if (fp) std::fclose(fp);
  if (!good || got != size) {
    if (!dup) std::remove(tmp.c_str());
    return false;
  }
  if (dup) {
    uint8_t two = 2;
    writeFrame(fd, D_PUTACK, &two, 1);
    return true;
  }

  if (::rename(tmp.c_str(), path.c_str()) != 0) {
    std::remove(tmp.c_str());
    uint8_t zero = 0;
    writeFrame(fd, D_PUTACK, &zero, 1);
    return true;
  }
  index_.add(name);
  replRecv_.fetch_add(1);

  if (!prefixOwnerOf(name)) journalRecord(name, pushedOwner);
  if (opt_.central) idxClient_.registerExtra({name});
  LOGI("replica stored: '%s' (%s) indexed; files=%zu", name.c_str(),
       humanBytes(size).c_str(), index_.size());
  uint8_t okb = 1;
  writeFrame(fd, D_PUTACK, &okb, 1);
  return true;
}

bool downloadTo(uint32_t ip, uint16_t port, const std::string& name,
                const std::string& dstPath, uint64_t* bytesOut,
                const std::string& bindIp) {
  int fd = tcpConnect(ipStr(ip), port, 2000, bindIp);
  if (fd < 0) return false;
  setRstOnClose(fd);
  Writer w;
  w.str(name);
  if (!writeFrame(fd, D_OBTAIN, w.buf.data(), w.buf.size())) {
    closeFd(fd);
    return false;
  }
  Frame h;
  if (!readFrame(fd, h, 32) || h.type != D_HEAD) {
    closeFd(fd);
    return false;
  }
  Reader hr(h.payload.data(), h.payload.size());
  uint8_t ok;
  uint64_t size;
  if (!hr.u8(ok) || !hr.u64(size) || !ok) {
    closeFd(fd);
    return false;
  }
  FILE* fp = std::fopen(dstPath.c_str(), "wb");
  if (!fp) {
    LOGE("cannot open %s for writing: %s", dstPath.c_str(), strerror(errno));
    closeFd(fd);
    return false;
  }
  std::vector<char> buf(1 << 20);
  uint64_t got = 0;
  bool good = true;
  while (got < size) {
    size_t want = buf.size();
    if (want > size - got) want = static_cast<size_t>(size - got);
    if (!recvAll(fd, buf.data(), want)) {
      good = false;
      break;
    }
    if (std::fwrite(buf.data(), 1, want, fp) != want) {
      good = false;
      break;
    }
    got += want;
  }
  std::fclose(fp);
  closeFd(fd);
  if (!good || got != size) {
    std::remove(dstPath.c_str());
    LOGE("download '%s' incomplete: %llu/%llu bytes", name.c_str(),
         (unsigned long long)got, (unsigned long long)size);
    return false;
  }
  if (bytesOut) *bytesOut = got;
  return true;
}

uint64_t Peer::replReplacement(
    const std::string& name, uint64_t deadId,
    const std::unordered_set<uint64_t>& extraSkip) {
  const RingNode* dead = ringById(deadId);
  if (!dead) return 0;
  size_t deadIdx = 0;
  for (size_t i = 0; i < ring_.size(); i++)
    if (ring_[i].id == deadId) deadIdx = i;
  uint64_t owner = ownerOf(name);
  std::vector<uint64_t> holders = ringHolders(name);
  std::set<uint64_t> taken(holders.begin(), holders.end());
  for (uint64_t s : extraSkip) taken.insert(s);
  taken.insert(deadId);
  for (size_t k = 1; k < ring_.size(); k++) {
    uint64_t cand = ring_[(deadIdx + k) % ring_.size()].id;
    if (cand == owner || cand == opt_.nodeId) continue;
    if (taken.count(cand)) continue;
    if (!replAlive(cand)) continue;
    return cand;
  }
  return 0;
}

void Peer::replEnqueue(const std::string& name, uint64_t target) {
  std::string key = name + "|" + std::to_string(target);
  std::lock_guard<std::mutex> g(replMu_);
  if (replQueued_.count(key) || replFlying_.count(key) ||
      replDone_.count(key))
    return;
  if (!target) return;
  replQueued_.insert(key);
  ++replPending_;
  std::deque<ReplJob>& q = replQ_[target];
  const bool wasEmpty = q.empty();
  q.push_back(ReplJob{name, target});
  if (wasEmpty) replTargets_.push_back(target);
  replCv_.notify_all();
}

void Peer::replEnsureAll() {
  std::vector<std::string> all;
  index_.dumpNames(&all);
  for (const auto& name : all) {
    uint64_t owner = ownerOf(name);
    std::vector<uint64_t> holders = ringHolders(name);
    if (owner == opt_.nodeId) {
      std::unordered_set<uint64_t> claimed;
      for (uint64_t h : holders) {
        if (h == opt_.nodeId) continue;
        if (!replAlive(h)) {
          uint64_t r = replReplacement(name, h, claimed);
          if (r) {
            claimed.insert(r);
            replEnqueue(name, r);
          }
          continue;
        }
        replEnqueue(name, h);
      }
    } else if (std::find(holders.begin(), holders.end(), opt_.nodeId) !=
                   holders.end() &&
               !replAlive(owner)) {

      std::unordered_set<uint64_t> claimed(holders.begin(), holders.end());
      uint64_t r = replReplacement(name, owner, claimed);
      if (r) replEnqueue(name, r);
    }
  }
}

void Peer::replWorkerLoop() {
  std::unordered_map<uint64_t, int> sess;
  constexpr size_t kBatchMax = 64;
  while (!stop_.load()) {
    std::vector<std::string> names;
    uint64_t target = 0;
    {
      std::unique_lock<std::mutex> lk(replMu_);
      replCv_.wait(lk, [&] { return stop_.load() || replPending_ > 0; });
      if (stop_.load()) break;
      while (!replTargets_.empty()) {
        target = replTargets_.front();
        replTargets_.pop_front();
        auto it = replQ_.find(target);
        if (it != replQ_.end() && !it->second.empty()) break;
        target = 0;
      }
      if (!target) continue;
      std::deque<ReplJob>& q = replQ_[target];
      names.reserve(kBatchMax);
      while (!q.empty() && names.size() < kBatchMax) {
        names.push_back(std::move(q.front().name));
        q.pop_front();
        --replPending_;

        replFlying_.insert(names.back() + "|" + std::to_string(target));
        replQueued_.erase(names.back() + "|" + std::to_string(target));
      }
      if (!q.empty()) replTargets_.push_back(target);
      replInFlight_.fetch_add(names.size());
    }
    int& sfd = sess.try_emplace(target, -1).first->second;
    std::vector<int> rc(names.size(), -1);
    const bool deadTarget = !replAlive(target);
    int live = -1;
    if (!deadTarget) live = replPushBatch(&sfd, target, names, &rc);

    std::unordered_set<uint64_t> claimed;
    for (size_t i = 0; i < names.size(); i++) {
      const std::string key = names[i] + "|" + std::to_string(target);

      {
        std::lock_guard<std::mutex> g(replMu_);
        replFlying_.erase(key);
        if (rc[i] == 1 || rc[i] == 2) replDone_.insert(key);
      }
      if (rc[i] == 1) {
        replPushed_.fetch_add(1);
      } else if (rc[i] == 2) {
        replSkipped_.fetch_add(1);
      } else if (rc[i] == 3) {

      } else if (rc[i] == 0 || deadTarget) {

        uint64_t r = replReplacement(names[i], target, claimed);
        if (r) {
          claimed.insert(r);
          replEnqueue(names[i], r);
        } else {
          replFailed_.fetch_add(1);
        }
      } else {

        const long long nowMs =
          std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        bool retry = false;
        {
          std::lock_guard<std::mutex> lk(replMu_);
          auto it = replRetry_.find(key);
          if (it == replRetry_.end()) {
            replRetry_.emplace(key, nowMs + 20000);
            retry = true;
          } else if (nowMs < it->second) {
            retry = true;
          } else {
            replRetry_.erase(it);
          }
        }
        if (retry) {
          replEnqueue(names[i], target);
        } else {
          uint64_t r = replReplacement(names[i], target, claimed);
          if (r) {
            claimed.insert(r);
            replEnqueue(names[i], r);
          } else {
            replFailed_.fetch_add(1);
          }
        }
      }
    }
    if (live != static_cast<int>(names.size()))
      std::this_thread::sleep_for(std::chrono::milliseconds(300));

    replInFlight_.fetch_sub(names.size());
    replCv_.notify_all();
  }
  for (auto& kv : sess) closeFd(kv.second);
}

int Peer::replPushBatch(int* sessionFd, uint64_t target,
                        const std::vector<std::string>& names,
                        std::vector<int>* rc) {
  const RingNode* t = ringById(target);
  if (!t) return 0;
  if (*sessionFd < 0) {
    *sessionFd = tcpConnect(t->ip, t->dport, 2000, opt_.myIp);
    if (*sessionFd < 0) return 0;
    setSendTimeout(*sessionFd, 60000);
    setRecvTimeout(*sessionFd, 60000);
  }
  const int fd = *sessionFd;

  std::vector<size_t> cand;
  std::vector<uint64_t> sizes(names.size(), 0);
  std::vector<uint64_t> owners(names.size(), 0);
  for (size_t i = 0; i < names.size(); i++) {
    struct stat st;
    const std::string path = pathJoin(opt_.dataDir, names[i]);
    if (::stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
      (*rc)[i] = 3;
      continue;
    }
    sizes[i] = static_cast<uint64_t>(st.st_size);
    owners[i] = ownerOf(names[i]);
    cand.push_back(i);
  }
  std::vector<size_t> todo;
  if (!cand.empty()) {
    Writer q;
    q.u32(static_cast<uint32_t>(cand.size()));
    for (size_t i : cand) { q.str(names[i]); q.u64(sizes[i]); }
    Frame hf;
    bool ok = writeFrame(fd, D_HAVEREQ, q.buf.data(), q.buf.size()) &&
              readFrame(fd, hf, 1 << 16) && hf.type == D_HAVEACK;
    std::vector<uint8_t> have(cand.size(), 0);
    if (ok) {
      Reader r(hf.payload.data(), hf.payload.size());
      uint32_t n = 0;
      ok = r.u32(n) && n == cand.size();
      for (size_t k = 0; ok && k < cand.size(); k++) ok = r.u8(have[k]);
    }
    if (!ok) {
      closeFd(*sessionFd);
      *sessionFd = -1;
      return 0;
    }
    for (size_t k = 0; k < cand.size(); k++) {
      if (have[k]) (*rc)[cand[k]] = 2;
      else todo.push_back(cand[k]);
    }
  }

  std::vector<char> buf(1 << 20);
  std::vector<size_t> wire;
  wire.reserve(todo.size());
  bool broke = false;
  for (size_t idx : todo) {
    const std::string path = pathJoin(opt_.dataDir, names[idx]);
    FILE* fp = std::fopen(path.c_str(), "rb");
    if (!fp) { (*rc)[idx] = 3; continue; }
    struct stat st;
    if (fstat(fileno(fp), &st) != 0 || !S_ISREG(st.st_mode)) {
      std::fclose(fp);
      (*rc)[idx] = 3;
      continue;
    }
    Writer w;
    w.str(names[idx]);
    w.u64(static_cast<uint64_t>(st.st_size));
    w.u64(owners[idx]);
    if (!writeFrame(fd, D_PUTREQ, w.buf.data(), w.buf.size())) {
      std::fclose(fp);
      broke = true;
      break;
    }
    wire.push_back(idx);
    uint64_t total = static_cast<uint64_t>(st.st_size), sent = 0;
    bool good = true;
    while (sent < total) {
      size_t want = buf.size();
      if (want > total - sent) want = static_cast<size_t>(total - sent);
      size_t n = std::fread(buf.data(), 1, want, fp);
      if (n == 0) { good = false; break; }
      if (!sendAll(fd, buf.data(), n)) { good = false; break; }
      sent += n;
    }
    std::fclose(fp);
    if (!good) { broke = true; break; }
  }

  size_t acked = 0;
  for (size_t j = 0; j < wire.size(); j++) {
    Frame f;
    if (!readFrame(fd, f, 60000) || f.type != D_PUTACK || f.payload.empty())
      break;
    (*rc)[wire[j]] = f.payload[0];
    acked++;
  }
  const bool complete = !broke && acked == wire.size();
  if (!complete) {
    closeFd(*sessionFd);
    *sessionFd = -1;
  }
  return complete ? static_cast<int>(names.size()) : static_cast<int>(acked);
}

void Peer::replicationLoop() {

  ::unlink("/tmp/peer.repl.done");
  const auto replT0 = std::chrono::steady_clock::now();
  if (opt_.replicationFactor > 1 && ring_.size() > 1) {
    replEnsureAll();

    {
      std::unique_lock<std::mutex> lk(replMu_);
      replCv_.wait(lk, [&] {
        return stop_.load() ||
               (replPending_ == 0 && replInFlight_.load() == 0);
      });
    }
    if (stop_.load()) return;
    replInitialDone_.store(true);
    const long long replMs =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - replT0)
            .count();
    FILE* mk = std::fopen("/tmp/peer.repl.done", "w");
    if (mk) {
      std::fprintf(mk, "pushed=%llu skipped=%llu elapsed_ms=%lld\n",
                   (unsigned long long)replPushed_.load(),
                   (unsigned long long)replSkipped_.load(), replMs);
      std::fclose(mk);
    }
    LOGI("REPLICATION-DONE pushed=%llu skipped=%llu elapsed_ms=%lld "
         "(factor=%d, index=%zu)",
         (unsigned long long)replPushed_.load(),
         (unsigned long long)replSkipped_.load(), replMs,
         opt_.replicationFactor, index_.size());
  } else {
    replInitialDone_.store(true);
    FILE* mk = std::fopen("/tmp/peer.repl.done", "w");
    if (mk) {
      std::fprintf(mk, "pushed=0 skipped=0 single-node\n");
      std::fclose(mk);
    }
  }

  size_t lastIndexSize = index_.size();
  while (!stop_.load()) {
    {
      std::unique_lock<std::mutex> lk(replMu_);
      replCv_.wait_for(lk, std::chrono::seconds(10), [&] {
        return stop_.load();
      });
    }
    if (stop_.load()) break;

    bool anyDead = false;
    for (const auto& rn : ring_) {
      if (rn.id == opt_.nodeId) continue;
      bool ok = replProbe(rn.id);
      std::lock_guard<std::mutex> g(replMu_);
      if (ok)
        replFail_[rn.id] = 0;
      else {
        int& s = replFail_[rn.id];
        s = s < 2 ? s + 1 : 2;
        if (s >= 2) anyDead = true;
      }
    }
    size_t nowSize = index_.size();
    if (anyDead || nowSize != lastIndexSize) {

      replEnsureAll();
      lastIndexSize = nowSize;
    }
  }
}

void Peer::gcScan(bool dryRun) {

  for (const auto& rn : ring_) {
    if (rn.id == opt_.nodeId) continue;
    if (!replProbe(rn.id)) {
      LOGW("gc%s: roster node %llu not live, refusing to run",
           dryRun ? "-dry" : "", (unsigned long long)rn.id);
      return;
    }
  }
  std::vector<std::string> names;
  index_.dumpNames(&names);
  std::sort(names.begin(), names.end());
  std::string logPath = dryRun ? opt_.gcDryMarker + ".log"
                               : opt_.gcMarker + ".log";
  FILE* log = std::fopen(logPath.c_str(), "w");
  size_t keep = 0, wouldDel = 0, deleted = 0, unknown = 0, gone = 0;
  for (const auto& n : names) {
    std::string path = pathJoin(opt_.dataDir, n);
    struct stat st;
    if (::stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
      if (log) fprintf(log, "GONE\t%s\n", n.c_str());
      index_.remove(n);
      gone++;
      continue;
    }
    uint64_t owner = ownerOf(n);
    if (!owner) {
      if (log) fprintf(log, "UNKNOWN-OWNER\t%s\n", n.c_str());
      unknown++;
      continue;
    }
    bool ours = (owner == opt_.nodeId);
    bool designed = ours;
    if (!designed) {
      for (uint64_t h : ringHolders(n))
        if (h == opt_.nodeId) { designed = true; break; }
    }
    if (designed) {
      if (log) fprintf(log, "KEEP\t%s\towner=%llu\n", n.c_str(),
                       (unsigned long long)owner);
      keep++;
      continue;
    }
    if (log) fprintf(log, "DELETE%s\t%s\towner=%llu\n",
                     dryRun ? "-DRY" : "", n.c_str(),
                     (unsigned long long)owner);
    wouldDel++;
    if (!dryRun) {
      if (std::remove(path.c_str()) == 0) deleted++;
      index_.remove(n);
    }
  }
  if (log) {
    fprintf(log, "SUMMARY\tchecked=%zu keep=%zu %s=%zu unknown=%zu gone=%zu\n",
            names.size(), keep, dryRun ? "would_delete" : "deleted", wouldDel,
            unknown, gone);
    fclose(log);
  }
  if (!dryRun && deleted) {
    journalCompact();
    idxClient_.resyncNow();
  }
  LOGI("gc%s: checked=%zu keep=%zu %s=%zu unknown=%zu gone=%zu log=%s",
       dryRun ? "-dry" : "", names.size(), keep,
       dryRun ? "would-delete" : "deleted", wouldDel, unknown, gone,
       logPath.c_str());
}

void Peer::janitorLoop() {
  int64_t lastPrint = steadyMs();
  while (!stop_.load()) {

    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    if (stop_.load()) break;
    routes_.prune(opt_.routingMaxAgeMs, opt_.routingCap);
    pends_.sweepExpired();

    if (fileExists(opt_.rescanMarker)) {
      ::unlink(opt_.rescanMarker.c_str());
      size_t n = index_.rescan();

      size_t adopted = journalAdoptOrphans();
      LOGI("index rescanned on rescan marker: files=%zu adopted=%zu", n,
           adopted);

      idxClient_.resyncNow();
    }

    if (fileExists(opt_.gcDryMarker)) {
      gcScan(true);
      ::unlink(opt_.gcDryMarker.c_str());
    }
    if (fileExists(opt_.gcMarker)) {
      gcScan(false);
      ::unlink(opt_.gcMarker.c_str());
    }
    int64_t now = steadyMs();
    if (now - lastPrint > 30000) {
      uint32_t n = 0;
      {
        std::lock_guard<std::mutex> g(linksMu_);
        n = static_cast<uint32_t>(links_.size());
      }
      LOGI("status: neighbours_conn=%u files=%zu routes=%zu pending=%zu", n,
           index_.size(), routes_.size(), pends_.size());
      lastPrint = now;
    }
  }
}

void Peer::printQueryResults(const std::string& name, const QueryResult& r) {
  if (r.timedOut) {
    fprintf(stdout,
            "[client] query '%s' -> no results (timed out after %lld ms)\n",
            name.c_str(), (long long)r.ms);
    fflush(stdout);
    return;
  }
  std::string s;
  for (size_t i = 0; i < r.hits.size() && i < 4; i++) {
    if (i) s += ", ";
    s += sockaddrPretty(r.hits[i].ip, r.hits[i].dport);
  }
  if (r.hits.size() > 4) s += ", ...";
  fprintf(stdout, "[client] query '%s' -> %zu hit(s): %s [%lld ms]\n",
          name.c_str(), r.hits.size(), s.c_str(), (long long)r.ms);
  fflush(stdout);
}

void Peer::printObtainLine(const std::string& name, const DownloadStat& s) {
  if (s.ok) {
    fprintf(stdout,
            "display file '%s' (%s from %s: download %lld ms, search %lld "
            "ms)\n",
            name.c_str(), humanBytes(s.bytes).c_str(), s.via.c_str(),
            (long long)s.dlMs, (long long)s.queryMs);
  } else {
    fprintf(stdout, "display file '%s' ... FAILED\n", name.c_str());
  }
  fflush(stdout);
}

void Peer::cliLoop() {

  if (!neighbors_.empty()) {
    for (int i = 0; i < 60; i++) {
      size_t up = 0;
      {
        std::lock_guard<std::mutex> g(linksMu_);
        up = links_.size();
      }
      if (up >= neighbors_.size()) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
  }
  std::string line;
  fprintf(stderr,
          "CLI ready: 'query <file>', 'obtain <file>', 'rescan', 'stat', "
          "'quit'\n");
  while (!stop_.load() && std::getline(std::cin, line)) {
    while (!line.empty() && (line.back() == '\r' || line.back() == ' '))
      line.pop_back();
    if (line.size() >= 5 && line.compare(0, 5, "query") == 0) {
      std::string name = line.substr(5);
      while (!name.empty() && name.front() == ' ') name.erase(name.begin());

      QueryResult r = userQuery(name, opt_.queryTimeoutMs, 0,
                                opt_.hitCollectMs);
      printQueryResults(name, r);
      if (!r.timedOut) {
        printf("  holders for '%s':\n", name.c_str());
        for (size_t i = 0; i < r.hits.size(); i++)
          printf("   #%zu %s\n", i + 1,
                 sockaddrPretty(r.hits[i].ip, r.hits[i].dport).c_str());
        fflush(stdout);
      }
    } else if (line.size() >= 6 && line.compare(0, 6, "obtain") == 0) {
      std::string name = line.substr(6);
      while (!name.empty() && name.front() == ' ') name.erase(name.begin());
      DownloadStat s = userObtain(name, opt_.queryTimeoutMs);
      if (!s.ok) fprintf(stderr, "obtain '%s' FAILED\n", name.c_str());
    } else if (line.compare(0, 6, "rescan") == 0) {

      size_t n = index_.rescan();

      idxClient_.resyncNow();
      printf("peer %llu: index rescanned, files=%zu\n",
             (unsigned long long)opt_.nodeId, n);
      fflush(stdout);
    } else if (line.compare(0, 4, "stat") == 0) {
      uint32_t n = 0;
      {
        std::lock_guard<std::mutex> g(linksMu_);
        n = static_cast<uint32_t>(links_.size());
      }
      printf(
          "peer %llu: files=%zu neighbours_conn=%u routes=%zu pending=%zu\n",
          (unsigned long long)opt_.nodeId, index_.size(), n, routes_.size(),
          pends_.size());
      fflush(stdout);
    } else if (line.compare(0, 4, "quit") == 0) {
      requestStop();
      break;
    } else if (!line.empty()) {
      fprintf(stderr, "unknown command\n");
    }
  }
}

void Peer::run() {
  int msgLfd = tcpListen(opt_.msgPort);
  int ctlLfd = tcpListen(opt_.controlPort);
  int dlLfd = tcpListen(opt_.downloadPort);
  if (msgLfd < 0 || ctlLfd < 0 || dlLfd < 0) {
    LOGE("listening sockets failed, aborting");
    return;
  }
  std::thread msgAccept([this, msgLfd]() { msgAcceptLoop(msgLfd); });
  std::thread ctlAccept([this, ctlLfd]() { controlAcceptLoop(ctlLfd); });
  std::thread dlAccept([this, dlLfd]() { downloadAcceptLoop(dlLfd); });
  std::thread dialer([this]() { neighborDialerLoop(); });
  std::thread janitor([this]() { janitorLoop(); });

  std::thread replCoord;
  std::vector<std::thread> replWorkers;
  if (opt_.replicationFactor > 1 && ring_.size() > 1) {
    replCoord = std::thread([this]() { replicationLoop(); });
    const int kWorkers = 8;
    for (int w = 0; w < kWorkers; w++)
      replWorkers.emplace_back([this]() { replWorkerLoop(); });
  } else {
    replInitialDone_.store(true);
  }
  if (opt_.central) {
    idxClient_.start(opt_.indexIp, opt_.indexPort, opt_.nodeId, opt_.myIp,
                     opt_.downloadPort, &index_);
  }
  if (opt_.enableCli) cliLoop();

  while (!stop_.load()) std::this_thread::sleep_for(std::chrono::seconds(1));
  LOGW("peer shutting down");
  if (opt_.central) idxClient_.stop();
  std::this_thread::sleep_for(std::chrono::milliseconds(300));

  msgAccept.join();
  ctlAccept.join();
  dlAccept.join();
  dialer.join();
  janitor.join();
  replCv_.notify_all();
  if (replCoord.joinable()) replCoord.join();
  for (auto& t : replWorkers) t.join();
}

void Peer::getPeerInfo(uint64_t* nodeId, uint32_t* connectedNeighbours,
                       uint64_t* files, uint32_t* controlPort) const {
  if (nodeId) *nodeId = opt_.nodeId;
  if (files) *files = index_.size();
  if (controlPort) *controlPort = opt_.controlPort;
  if (connectedNeighbours) {
    std::lock_guard<std::mutex> g(linksMu_);
    *connectedNeighbours = static_cast<uint32_t>(links_.size());
  }
}

void Peer::getDetailedStats(uint64_t* routeSize, uint64_t* pendingSize) const {
  if (routeSize) *routeSize = routes_.size();
  if (pendingSize) *pendingSize = pends_.size();
}

}
