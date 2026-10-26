#pragma once

#include "common.hpp"
#include "proto.hpp"

namespace p2p {

struct BenchArgs {
  std::string target = "127.0.0.1:51001";
  std::string manifest;
  std::string out = "bench.csv";
  std::string label = "run";
  int clients = 1;
  int count = 10000;
  bool obtain = false;
  int startIdx = 0;
  bool jsonSummary = false;
  uint64_t seed = 0;
  std::string excludeDir;
  int64_t startAtMs = 0;
};

int runBench(const BenchArgs& a);

}
