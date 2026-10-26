CXX      := g++
CXXFLAGS := -std=c++17 -O2 -g -Wall -Wextra -pthread
LDFLAGS  := -pthread

SRCS := src/common.cpp src/proto.cpp src/index_client.cpp \
        src/peer.cpp src/index.cpp src/bench.cpp src/main.cpp
OBJS := $(SRCS:.cpp=.o)
DEPS := $(SRCS:.cpp=.d)

BIN := p2p

.PHONY: all clean indent

all: $(BIN)

$(BIN): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $(OBJS) $(LDFLAGS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -MMD -MP -c $< -o $@

-include $(DEPS)

clean:
	rm -f $(OBJS) $(DEPS) $(BIN)

indent:
	clang-format -i src/*.cpp src/*.hpp || true
