#include "index_client.hpp"

#include <sys/stat.h>

namespace p2p {

void IndexClient::start(const std::string& indexIp, uint16_t indexPort,
                        uint64_t nodeId, const std::string& myIp,
                        uint16_t downloadPort, const LocalIndex* files) {
  indexIp_ = indexIp;
  indexPort_ = indexPort;
  nodeId_ = nodeId;
  myIp_ = myIp;
  downloadPort_ = downloadPort;
  files_ = files;
  th_ = std::thread([this]() { loop(); });
}

void IndexClient::stop() {
  stop_.store(true);
  if (th_.joinable()) {
    th_.join();
  }
}

bool IndexClient::doRegister(int fd, const std::vector<std::string>& names) {

  Writer w;
  w.u64(nodeId_);
  w.str(myIp_);
  w.u16(downloadPort_);
  w.u32(static_cast<uint32_t>(names.size()));
  if (!writeFrame(fd, I_REGISTER, w.buf.data(), w.buf.size())) return false;
  Frame ack;
  if (!readFrame(fd, ack, 64) || ack.type != I_REGISTER_OK) return false;
  return sendFiles(fd, names);
}

bool IndexClient::sendFiles(int fd, const std::vector<std::string>& names) {
  for (const Writer& b : encFileBatches(names)) {
    if (!writeFrame(fd, I_FILES, b.buf.data(), b.buf.size())) return false;
    Frame ack;
    if (!readFrame(fd, ack, 64) || ack.type != I_FILES_OK) return false;
  }
  LOGI("registered %zu files with index server (ip %s dport %u)", names.size(),
       myIp_.c_str(), downloadPort_);
  return true;
}

bool IndexClient::sendAddFiles(int fd, const std::vector<std::string>& names) {
  Writer w;
  w.u64(nodeId_);
  if (!writeFrame(fd, I_ADDFILES, w.buf.data(), w.buf.size())) return false;
  Frame ack;
  if (!readFrame(fd, ack, 64) || ack.type != I_REGISTER_OK) return false;
  return sendFiles(fd, names);
}

void IndexClient::registerExtra(std::vector<std::string> names) {
  if (names.empty()) return;
  std::lock_guard<std::mutex> g(extraMu_);
  for (auto& n : names) extra_.push_back(std::move(n));
}

void IndexClient::resyncNow() {
  if (indexIp_.empty()) return;
  std::vector<std::string> names;
  if (files_) files_->dumpNames(&names);

  registerExtra(std::move(names));
}

void IndexClient::loop() {
  int64_t lastBeat = steadyMs();
  while (!stop_.load()) {

    std::vector<std::string> names;
    if (files_) files_->dumpNames(&names);
    int fd = tcpConnect(indexIp_, indexPort_, 2000);
    if (fd < 0) {
      LOGW("cannot connect to index server, retrying");
      std::this_thread::sleep_for(std::chrono::seconds(2));
      continue;
    }

    setRecvTimeout(fd, 60000);
    setSendTimeout(fd, 60000);
    if (!doRegister(fd, names)) {
      LOGW("register with index failed, retrying");
      closeFd(fd);
      std::this_thread::sleep_for(std::chrono::seconds(2));
      continue;
    }
    lastBeat = steadyMs();

    while (!stop_.load()) {
      std::vector<std::string> pending;
      {
        std::lock_guard<std::mutex> g(extraMu_);
        pending.swap(extra_);
      }
      if (!pending.empty() && !sendAddFiles(fd, pending)) break;
      if (steadyMs() - lastBeat >= 15000) {
        Writer w;
        w.u64(nodeId_);
        if (!writeFrame(fd, I_HEARTBEAT, w.buf.data(), w.buf.size())) break;

        Frame pong;
        if (!readFrame(fd, pong, 64) || pong.type != I_REGISTER_OK) break;
        uint8_t known = pong.payload.empty() ? 0 : pong.payload[0];
        if (known == 0) {
          LOGW("index lost our registration; re-registering");
          break;
        }
        lastBeat = steadyMs();
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }
    closeFd(fd);
    LOGW("index connection lost; re-registering");
  }
}

bool centralLookup(const std::string& indexIp, uint16_t indexPort,
                   const std::string& name, std::vector<HitEntry>* hits,
                   int timeoutMs) {
  int fd = tcpConnect(indexIp, indexPort, timeoutMs);
  if (fd < 0) return false;

  setRstOnClose(fd);
  setRecvTimeout(fd, timeoutMs > 0 ? timeoutMs : 2000);
  Writer w;
  w.str(name);
  bool good = writeFrame(fd, I_LOOKUP, w.buf.data(), w.buf.size());
  Frame f;
  good = good && readFrame(fd, f, 1 << 20) && f.type == I_LOOKUP_RESULT;
  closeFd(fd);
  if (!good) return false;
  bool ok = false;
  if (!decHits(f, &ok, hits)) return false;
  if (!ok) hits->clear();
  return true;
}

}
