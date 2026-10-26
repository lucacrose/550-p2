#include "proto.hpp"

namespace p2p {

std::vector<Writer> encFileBatches(const std::vector<std::string>& names) {
  std::vector<Writer> batches;
  static const size_t MAX_BATCH_BYTES = 1u << 20;
  size_t i = 0;
  while (i < names.size()) {
    Writer w;
    size_t used = 2;
    size_t count = 0;
    size_t j = i;
    for (; j < names.size(); j++) {
      size_t need = 2 + names[j].size();
      if (used + need > MAX_BATCH_BYTES && count > 0) break;
      used += need;
      count++;
    }
    w.u16(static_cast<uint16_t>(count));
    for (size_t k = i; k < j; k++) w.str(names[k]);
    batches.push_back(std::move(w));
    i = j;
  }
  return batches;
}

}
