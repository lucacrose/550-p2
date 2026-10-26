#include "common.hpp"

#include <chrono>
#include <cinttypes>
#include <cmath>
#include <poll.h>
#include <sys/select.h>
#include <thread>

namespace p2p {

static std::mutex gLogMu;

void vlog(char level, const char* file, int line, const char* fmt, ...) {
  char msg[1024];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(msg, sizeof(msg), fmt, ap);
  va_end(ap);
  const char* slash = strrchr(file, '/');
  file = slash ? slash + 1 : file;
  std::lock_guard<std::mutex> g(gLogMu);
  std::fprintf(stderr, "[%s %c] %s:%d: %s\n", wallStamp().c_str(), level, file,
               line, msg);
  std::fflush(stderr);
}

int tcpConnect(const std::string& ip, uint16_t port, int timeoutMs,
               const std::string& bindIp) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;

  setReuseAddr(fd);
  setNonBlock(fd, true);
  struct sockaddr_in sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_port = htons(port);
  if (inet_pton(AF_INET, ip.c_str(), &sa.sin_addr) != 1) {
    close(fd);
    return -1;
  }
  if (!bindIp.empty()) {

    struct sockaddr_in local;
    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_port = 0;
    if (inet_pton(AF_INET, bindIp.c_str(), &local.sin_addr) != 1 ||
        bind(fd, reinterpret_cast<struct sockaddr*>(&local), sizeof(local)) != 0) {
      close(fd);
      return -1;
    }
  }
  int rc = connect(fd, reinterpret_cast<struct sockaddr*>(&sa), sizeof(sa));
  if (rc != 0) {
    fd_set wfds, rfds;
    FD_ZERO(&wfds);
    FD_ZERO(&rfds);
    FD_SET(fd, &wfds);
    FD_SET(fd, &rfds);
    struct timeval tv;
    tv.tv_sec = timeoutMs / 1000;
    tv.tv_usec = (timeoutMs % 1000) * 1000;
    int sel = select(fd + 1, &rfds, &wfds, nullptr, &tv);
    if (sel <= 0) {
      close(fd);
      return -1;
    }
    int err = 0;
    socklen_t len = sizeof(err);
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
    if (err != 0) {
      close(fd);
      return -1;
    }
  }
  setNonBlock(fd, false);
  setTcpNoDelay(fd);
  return fd;
}

int tcpListen(uint16_t port) {
  struct sockaddr_in sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_addr.s_addr = INADDR_ANY;
  sa.sin_port = htons(port);

  for (int attempt = 0; attempt < 12; attempt++) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    setReuseAddr(fd);
    if (bind(fd, reinterpret_cast<struct sockaddr*>(&sa), sizeof(sa)) == 0 &&
        listen(fd, 512) == 0)
      return fd;
    int saved = errno;
    close(fd);
    if (saved != EADDRINUSE) {
      errno = saved;
      break;
    }
    LOGW("port %u busy, retrying bind (%d/12)", port, attempt + 1);
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
  }
  LOGE("listen on port %u failed: %s", port, strerror(errno));
  return -1;
}

bool setRecvTimeout(int fd, int ms) {
  struct timeval tv;
  tv.tv_sec = ms / 1000;
  tv.tv_usec = (ms % 1000) * 1000;
  return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) == 0;
}
bool setSendTimeout(int fd, int ms) {
  struct timeval tv;
  tv.tv_sec = ms / 1000;
  tv.tv_usec = (ms % 1000) * 1000;
  return setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) == 0;
}

int tcpAccept(int listenFd, uint32_t* ip, uint16_t* port) {
  struct sockaddr_in sa;
  socklen_t len = sizeof(sa);
  int fd = accept(listenFd, reinterpret_cast<struct sockaddr*>(&sa), &len);
  if (fd < 0) return -1;
  setTcpNoDelay(fd);
  if (ip) *ip = ntohl(sa.sin_addr.s_addr);
  if (port) *port = ntohs(sa.sin_port);
  return fd;
}

int pollAccept(int listenFd, int timeoutMs, uint32_t* ip, uint16_t* port) {
  struct pollfd pfd;
  pfd.fd = listenFd;
  pfd.events = POLLIN;
  int rc = poll(&pfd, 1, timeoutMs);
  if (rc == 0) return -2;
  if (rc < 0) return -1;
  return tcpAccept(listenFd, ip, port);
}

bool sendAll(int fd, const void* buf, size_t len) {
  const char* p = static_cast<const char*>(buf);
  while (len > 0) {
    ssize_t n = ::send(fd, p, len, MSG_NOSIGNAL);
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    if (n == 0) return false;
    p += n;
    len -= static_cast<size_t>(n);
  }
  return true;
}

bool recvAll(int fd, void* buf, size_t len) {
  char* p = static_cast<char*>(buf);
  while (len > 0) {
    ssize_t n = ::recv(fd, p, len, 0);
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    if (n == 0) return false;
    p += n;
    len -= static_cast<size_t>(n);
  }
  return true;
}

bool writeFrame(int fd, uint8_t type, const void* payload, size_t len) {
  uint8_t hdr[5];
  hdr[0] = type;
  wrU32(hdr + 1, static_cast<uint32_t>(len));
  if (!sendAll(fd, hdr, sizeof(hdr))) return false;
  if (len > 0 && !sendAll(fd, payload, len)) return false;
  return true;
}

bool readFrame(int fd, Frame& out, size_t maxPayload) {
  uint8_t hdr[5];
  if (!recvAll(fd, hdr, sizeof(hdr))) return false;
  out.type = hdr[0];
  uint32_t len = rdU32(hdr + 1);
  if (len > maxPayload) {
    LOGE("frame of %u bytes exceeds cap, dropping connection", len);
    return false;
  }
  out.payload.resize(len);
  if (len > 0 && !recvAll(fd, out.payload.data(), len)) return false;
  return true;
}

void Config::load(const std::string& path) {
  FILE* f = std::fopen(path.c_str(), "r");
  if (!f) {
    LOGE("cannot open config file %s: %s", path.c_str(), strerror(errno));
    std::exit(2);
  }
  char line[4096];
  while (std::fgets(line, sizeof(line), f)) {
    std::string s(line);

    while (!s.empty() && (s.back() == '\n' || s.back() == '\r' ||
                          s.back() == ' ' || s.back() == '\t'))
      s.pop_back();
    size_t start = s.find_first_not_of(" \t");
    if (start == std::string::npos || s[start] == '#') continue;
    size_t eq = s.find('=');
    if (eq == std::string::npos) continue;
    std::string key = s.substr(start, eq - start);
    std::string val = s.substr(eq + 1);
    kv_[key] = val;
  }
  std::fclose(f);
}

std::vector<std::string> Config::list(const std::string& k) const {
  return split(str(k, ""), ',');
}

void parseAddr(const std::string& s, std::string* ip, uint16_t* port) {
  size_t c = s.find(':');
  if (c == std::string::npos) {
    *ip = s;
    *port = 0;
  } else {
    *ip = s.substr(0, c);
    *port = static_cast<uint16_t>(std::atoi(s.substr(c + 1).c_str()));
  }
}

std::string humanBytes(uint64_t n) {
  char buf[32];
  if (n >= (1ULL << 30))
    snprintf(buf, sizeof(buf), "%.2f GiB", double(n) / (1 << 30));
  else if (n >= (1ULL << 20))
    snprintf(buf, sizeof(buf), "%.2f MiB", double(n) / (1 << 20));
  else if (n >= (1 << 10))
    snprintf(buf, sizeof(buf), "%.2f KiB", double(n) / (1 << 10));
  else
    snprintf(buf, sizeof(buf), "%llu B", (unsigned long long)n);
  return buf;
}

}
