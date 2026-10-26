#pragma once

#include "common.hpp"

namespace p2p {

enum : uint8_t {
  MSG_HELLO = 1,
  MSG_QUERY = 2,
  MSG_HITQUERY = 3,
  MSG_LINK_GRANT = 4,
  MSG_LINK_DENY = 5
};

struct MsgId {
  uint64_t peer = 0;
  uint64_t seq = 0;
  uint64_t pairKey() const { return peer ^ (seq * 0x9e3779b97f4a7c15ULL); }
  bool operator==(const MsgId& o) const { return peer == o.peer && seq == o.seq; }
  std::string str() const {
    return "[peer " + std::to_string(peer) + " #" + std::to_string(seq) + "]";
  }
};
struct MsgIdHash {
  size_t operator()(const MsgId& id) const { return std::hash<uint64_t>()(id.pairKey()); }
};

inline void encMsgId(Writer& w, const MsgId& id) {
  w.u64(id.peer);
  w.u64(id.seq);
}
inline bool decMsgId(Reader& r, MsgId* id) { return r.u64(id->peer) && r.u64(id->seq); }

struct QueryMsg {
  MsgId id;
  uint8_t ttl = 0;
  std::string name;
};

inline Writer encQuery(const QueryMsg& q) {
  Writer w;
  encMsgId(w, q.id);
  w.u8(q.ttl);
  w.str(q.name);
  return w;
}
inline bool decQuery(const Frame& f, QueryMsg* q) {
  Reader r(f.payload.data(), f.payload.size());
  if (!decMsgId(r, &q->id)) return false;
  if (!r.u8(q->ttl)) return false;
  if (!r.str(q->name)) return false;
  return r.eof();
}

struct HitMsg {
  MsgId id;
  uint8_t ttl = 0;
  std::string name;
  uint32_t ip = 0;
  uint16_t dport = 0;
};

inline Writer encHit(const HitMsg& h) {
  Writer w;
  encMsgId(w, h.id);
  w.u8(h.ttl);
  w.str(h.name);
  w.u32(h.ip);
  w.u16(h.dport);
  return w;
}
inline bool decHit(const Frame& f, HitMsg* h) {
  Reader r(f.payload.data(), f.payload.size());
  if (!decMsgId(r, &h->id)) return false;
  if (!r.u8(h->ttl)) return false;
  if (!r.str(h->name)) return false;
  if (!r.u32(h->ip) || !r.u16(h->dport)) return false;
  return r.eof();
}

struct HelloMsg {
  uint64_t nodeId = 0;
  uint16_t msgPort = 0;
};
inline Writer encHello(const HelloMsg& h) {
  Writer w;
  w.u64(h.nodeId);
  w.u16(h.msgPort);
  return w;
}
inline bool decHello(const Frame& f, HelloMsg* h) {
  Reader r(f.payload.data(), f.payload.size());
  return r.u64(h->nodeId) && r.u16(h->msgPort) && r.eof();
}

enum : uint8_t {
  C_PING = 10,
  C_PONG = 11,
  C_QUERY = 12,
  C_HITS = 13,
  C_OBTAIN = 14,
  C_DLRESULT = 15,

  C_STATS = 16,
  C_STATS2 = 17,

  C_SHUTDOWN = 18,
};

struct HitEntry {
  uint32_t ip = 0;
  uint16_t dport = 0;
  uint64_t nodeId = 0;
  std::string pretty() const { return sockaddrPretty(ip, dport) + " (node " + std::to_string(nodeId) + ")"; }
};
inline Writer encHits(bool ok, const std::vector<HitEntry>& hits) {
  Writer w;
  w.u8(ok ? 1 : 0);
  w.u32(static_cast<uint32_t>(hits.size()));
  for (const auto& h : hits) {
    w.u32(h.ip);
    w.u16(h.dport);
    w.u64(h.nodeId);
  }
  return w;
}
inline bool decHits(const Frame& f, bool* ok, std::vector<HitEntry>* out) {
  Reader r(f.payload.data(), f.payload.size());
  uint8_t o;
  if (!r.u8(o)) return false;
  *ok = o != 0;
  uint32_t n;
  if (!r.u32(n)) return false;
  for (uint32_t i = 0; i < n; i++) {
    HitEntry e;
    if (!r.u32(e.ip) || !r.u16(e.dport) || !r.u64(e.nodeId)) return false;
    out->push_back(e);
  }
  return true;
}

enum : uint8_t { D_OBTAIN = 1, D_HEAD = 2, D_PUTREQ = 3, D_PUTACK = 4,
                 D_HAVEREQ = 5, D_HAVEACK = 6 };

enum : uint8_t {
  I_REGISTER = 1,
  I_REGISTER_OK = 2,
  I_FILES = 3,
  I_FILES_OK = 4,
  I_LOOKUP = 5,
  I_LOOKUP_RESULT = 6,
  I_HEARTBEAT = 7,
  I_GOODBYE = 8,
  I_ADDFILES = 9,

};

std::vector<Writer> encFileBatches(const std::vector<std::string>& names);

}
