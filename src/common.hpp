#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace p2p {

using Clock = std::chrono::steady_clock;
inline int64_t steadyMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             Clock::now().time_since_epoch())
      .count();
}

inline int64_t steadyUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             Clock::now().time_since_epoch())
      .count();
}

inline int64_t wallMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

inline int64_t wallUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

inline std::string wallStamp() {
  char buf[40];
  auto now = std::chrono::system_clock::now();
  auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                now.time_since_epoch())
                .count() %
            1000000;
  auto t = std::chrono::system_clock::to_time_t(now);
  struct tm tmv;
  localtime_r(&t, &tmv);
  std::snprintf(buf, sizeof(buf), "%02d:%02d:%02d.%03d", tmv.tm_hour, tmv.tm_min,
                tmv.tm_sec, static_cast<int>(us / 1000));
  return std::string(buf);
}

void vlog(char level, const char* file, int line, const char* fmt, ...)
    __attribute__((format(printf, 4, 5)));
#define LOGI(...) ::p2p::vlog('I', __FILE__, __LINE__, __VA_ARGS__)
#define LOGW(...) ::p2p::vlog('W', __FILE__, __LINE__, __VA_ARGS__)
#define LOGE(...) ::p2p::vlog('E', __FILE__, __LINE__, __VA_ARGS__)

inline uint16_t rdU16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}
inline uint32_t rdU32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}
inline uint64_t rdU64(const uint8_t* p) {
  uint64_t lo = rdU32(p);
  uint64_t hi = rdU32(p + 4);
  return lo | (hi << 32);
}
inline void wrU16(uint8_t* p, uint16_t v) {
  p[0] = static_cast<uint8_t>(v & 0xff);
  p[1] = static_cast<uint8_t>(v >> 8);
}
inline void wrU32(uint8_t* p, uint32_t v) {
  wrU16(p, static_cast<uint16_t>(v & 0xffff));
  wrU16(p + 2, static_cast<uint16_t>(v >> 16));
}
inline void wrU64(uint8_t* p, uint64_t v) {
  wrU32(p, static_cast<uint32_t>(v & 0xffffffffllu));
  wrU32(p + 4, static_cast<uint32_t>(v >> 32));
}

class Writer {
 public:
  std::vector<uint8_t> buf;
  void u8(uint8_t v) { buf.push_back(v); }
  void u16(uint16_t v) {
    size_t s = buf.size();
    buf.resize(s + 2);
    wrU16(buf.data() + s, v);
  }
  void u32(uint32_t v) {
    size_t s = buf.size();
    buf.resize(s + 4);
    wrU32(buf.data() + s, v);
  }
  void u64(uint64_t v) {
    size_t s = buf.size();
    buf.resize(s + 8);
    wrU64(buf.data() + s, v);
  }
  void str(const std::string& s) {
    u16(static_cast<uint16_t>(s.size()));
    buf.insert(buf.end(), s.begin(), s.end());
  }
  void bytes(const void* p, size_t n) {
    const uint8_t* b = static_cast<const uint8_t*>(p);
    buf.insert(buf.end(), b, b + n);
  }
};

class Reader {
 public:
  Reader(const uint8_t* p, size_t n) : p_(p), n_(n), pos_(0) {}
  bool u8(uint8_t& v) { return take(&v, 1); }
  bool u16(uint16_t& v) {
    uint8_t t[2];
    if (!take(t, 2)) return false;
    v = rdU16(t);
    return true;
  }
  bool u32(uint32_t& v) {
    uint8_t t[4];
    if (!take(t, 4)) return false;
    v = rdU32(t);
    return true;
  }
  bool u64(uint64_t& v) {
    uint8_t t[8];
    if (!take(t, 8)) return false;
    v = rdU64(t);
    return true;
  }
  bool str(std::string& s) {
    uint16_t len;
    if (!u16(len)) return false;
    if (pos_ + len > n_) return false;
    s.assign(reinterpret_cast<const char*>(p_ + pos_), len);
    pos_ += len;
    return true;
  }
  bool bytes(void* dst, size_t k) { return take(dst, k); }
  bool eof() const { return pos_ == n_; }
  size_t pos() const { return pos_; }

 private:
  bool take(void* dst, size_t k) {
    if (pos_ + k > n_) return false;
    std::memcpy(dst, p_ + pos_, k);
    pos_ += k;
    return true;
  }
  const uint8_t* p_;
  size_t n_;
  size_t pos_;
};

inline std::string ipStr(uint32_t ip) {
  char buf[16];
  std::snprintf(buf, sizeof(buf), "%u.%u.%u.%u", (ip >> 24) & 0xff,
                (ip >> 16) & 0xff, (ip >> 8) & 0xff, ip & 0xff);
  return buf;
}
inline std::string sockaddrPretty(uint32_t ip, uint16_t port) {
  return ipStr(ip) + ":" + std::to_string(port);
}

inline uint64_t addrKey(uint32_t ip, uint16_t port) {
  return (static_cast<uint64_t>(ip) << 16) | port;
}
inline bool fileExists(const std::string& path) {
  struct stat st;
  return ::stat(path.c_str(), &st) == 0;
}

inline bool setNonBlock(int fd, bool enable) {
  int fl = fcntl(fd, F_GETFL, 0);
  if (fl < 0) return false;
  if (enable)
    fl |= O_NONBLOCK;
  else
    fl &= ~O_NONBLOCK;
  return fcntl(fd, F_SETFL, fl) == 0;
}
inline void setTcpNoDelay(int fd) {
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
}
inline void setReuseAddr(int fd) {
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
}

inline void setRstOnClose(int fd) {
  struct linger lg { 1, 0 };
  setsockopt(fd, SOL_SOCKET, SO_LINGER, &lg, sizeof(lg));
}

int tcpConnect(const std::string& ip, uint16_t port, int timeoutMs,
               const std::string& bindIp = "");

int tcpListen(uint16_t port);

bool setRecvTimeout(int fd, int ms);
bool setSendTimeout(int fd, int ms);

int tcpAccept(int listenFd, uint32_t* ip, uint16_t* port);

int pollAccept(int listenFd, int timeoutMs, uint32_t* ip, uint16_t* port);
inline void closeFd(int& fd) {
  if (fd >= 0) {
    ::close(fd);
    fd = -1;
  }
}
bool sendAll(int fd, const void* buf, size_t len);
bool recvAll(int fd, void* buf, size_t len);

struct Frame {
  uint8_t type = 0;
  std::vector<uint8_t> payload;
};
bool writeFrame(int fd, uint8_t type, const void* payload, size_t len);

bool readFrame(int fd, Frame& out, size_t maxPayload = 128u << 20);

inline uint64_t fnv1a64(const std::string& s) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (unsigned char c : s) {
    h ^= c;
    h *= 0x100000001b3ULL;
  }
  return h;
}

class Config {
 public:
  explicit Config(const std::string& path) { load(path); }
  void load(const std::string& path);
  bool has(const std::string& k) const {
    return kv_.count(k) != 0;
  }
  std::string str(const std::string& k, const std::string& dflt) const {
    auto it = kv_.find(k);
    return it == kv_.end() ? dflt : it->second;
  }
  long long num(const std::string& k, long long dflt) const {
    auto it = kv_.find(k);
    if (it == kv_.end()) return dflt;
    return std::atoll(it->second.c_str());
  }

  std::vector<std::string> list(const std::string& k) const;

 private:
  std::unordered_map<std::string, std::string> kv_;
};

void parseAddr(const std::string& s, std::string* ip, uint16_t* port);

inline std::vector<std::string> split(const std::string& s, char sep) {
  std::vector<std::string> out;
  std::string cur;
  for (char c : s) {
    if (c == sep) {
      if (!cur.empty()) out.push_back(cur);
      cur.clear();
    } else
      cur.push_back(c);
  }
  if (!cur.empty()) out.push_back(cur);
  return out;
}

std::string humanBytes(uint64_t n);

struct LatencySummary {
  double avg = 0, stdev = 0, p50 = 0, p95 = 0, p99 = 0, maxv = 0;
  size_t n = 0;
};

}
