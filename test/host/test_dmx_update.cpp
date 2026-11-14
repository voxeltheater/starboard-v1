// Host-side test for src/dmx_update.cpp against frames produced by
// tools/dmx_update.py --dump. Run via test/host/run.sh.
//
//   test_dmx_update <frames file> <expected image> <model> [<frames, other chunk size>]

#include "../../src/dmx_update.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

static std::vector<uint8_t> readFile(const char* path){
  FILE* f = fopen(path, "rb");
  if(!f){ perror(path); exit(2); }
  std::vector<uint8_t> data;
  uint8_t buf[4096];
  size_t n;
  while((n = fread(buf, 1, sizeof(buf), f)) > 0) data.insert(data.end(), buf, buf + n);
  fclose(f);
  return data;
}

static int failures = 0;
#define CHECK(cond, ...) do { if(!(cond)){ printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); failures++; } } while(0)

static std::vector<uint8_t> imageBuf(160 * 1024);

// Feeds passes of the stream (each pass shuffled, with loss and corruption)
// until the receiver completes or maxPasses runs out. Returns passes used, or
// -1 if it never completed.
static int deliver(DmxUpdateReceiver& rx, const std::vector<std::vector<uint8_t>>& frames,
                   double loss, double corrupt, int maxPasses, unsigned seed, bool shuffle = true){
  std::mt19937 rng(seed);
  std::uniform_real_distribution<double> u(0, 1);
  for(int pass = 1; pass <= maxPasses; pass++){
    std::vector<size_t> order(frames.size());
    for(size_t i = 0; i < order.size(); i++) order[i] = i;
    if(shuffle) std::shuffle(order.begin(), order.end(), rng);
    for(size_t i : order){
      if(u(rng) < loss) continue;
      std::vector<uint8_t> f = frames[i];
      if(u(rng) < corrupt) f[rng() % f.size()] ^= (uint8_t)(1 + rng() % 255);
      DmxUpdateReceiver::Result r = rx.handleFrame(f.data());
      if(r == DmxUpdateReceiver::COMPLETE) return pass;
    }
  }
  return -1;
}

int main(int argc, char** argv){
  if(argc != 4 && argc != 5){
    fprintf(stderr, "usage: %s <frames> <image> <model> [<frames, other chunk size>]\n", argv[0]);
    return 2;
  }
  std::vector<uint8_t> raw = readFile(argv[1]);
  std::vector<uint8_t> expected = readFile(argv[2]);
  uint8_t model = (uint8_t)atoi(argv[3]);
  CHECK(raw.size() % DMX_UPDATE_SLOTS == 0, "frames file not a multiple of 512");

  std::vector<std::vector<uint8_t>> frames;
  for(size_t off = 0; off + DMX_UPDATE_SLOTS <= raw.size(); off += DMX_UPDATE_SLOTS){
    frames.emplace_back(raw.begin() + off, raw.begin() + off + DMX_UPDATE_SLOTS);
  }
  uint32_t crc = dmxUpdateCrc32(expected.data(), expected.size());

  // Build ID, computed the way main.cpp does: CRC of the FIRMWARE_ID string.
  const char* prefix = "SBFWID:";
  auto it = std::search(expected.begin(), expected.end(), prefix, prefix + strlen(prefix));
  CHECK(it != expected.end(), "test image has no FIRMWARE_ID");
  auto idEnd = std::find(it, expected.end(), 0);
  uint32_t buildId = dmxUpdateCrc32(&*it, idEnd - it);

  // Clean, in-order delivery completes in one pass with the exact image.
  {
    DmxUpdateReceiver rx(imageBuf.data(), imageBuf.size(), model, 0);
    int passes = deliver(rx, frames, 0, 0, 1, 1, false);
    CHECK(passes == 1, "clean delivery didn't complete in one pass");
    CHECK(rx.imageSize() == expected.size(), "size %u != %zu", rx.imageSize(), expected.size());
    CHECK(memcmp(rx.image(), expected.data(), expected.size()) == 0, "image mismatch");
    CHECK(rx.imageCrc() == crc, "crc mismatch");
  }

  // 30% loss, 5% corruption, shuffled: still completes, still exact.
  for(unsigned seed = 1; seed <= 20; seed++){
    DmxUpdateReceiver rx(imageBuf.data(), imageBuf.size(), model, 0);
    int passes = deliver(rx, frames, 0.30, 0.05, 20, seed);
    CHECK(passes > 0, "seed %u: lossy delivery never completed", seed);
    if(passes > 0){
      CHECK(memcmp(rx.image(), expected.data(), expected.size()) == 0, "seed %u: image mismatch", seed);
    }
  }

  // Wrong board model: never accepts anything.
  {
    DmxUpdateReceiver rx(imageBuf.data(), imageBuf.size(), (uint8_t)(model + 1), 0);
    CHECK(deliver(rx, frames, 0, 0, 3, 2) == -1, "accepted firmware for another board model");
    CHECK(!rx.active(), "started a download for another board model");
  }

  // Same build as the one running: ignored, so a board doesn't reinstall in a loop.
  {
    DmxUpdateReceiver rx(imageBuf.data(), imageBuf.size(), model, buildId);
    CHECK(deliver(rx, frames, 0, 0, 3, 3) == -1, "reinstalled the running build");
  }

  // Ordinary show data is passed through untouched.
  {
    DmxUpdateReceiver rx(imageBuf.data(), imageBuf.size(), model, 0);
    uint8_t show[DMX_UPDATE_SLOTS];
    std::mt19937 rng(4);
    for(int i = 0; i < 10000; i++){
      for(auto& b : show) b = (uint8_t)rng();
      CHECK(rx.handleFrame(show) == DmxUpdateReceiver::NOT_UPDATE, "show frame treated as update");
    }
    memset(show, 0xFF, sizeof(show));
    CHECK(rx.handleFrame(show) == DmxUpdateReceiver::NOT_UPDATE, "all-full frame treated as update");
  }

  // Data before any header is ignored, not buffered blindly.
  {
    DmxUpdateReceiver rx(imageBuf.data(), imageBuf.size(), model, 0);
    for(auto& f : frames){
      if(f[9] == DMX_UPDATE_PACKET_DATA){
        CHECK(rx.handleFrame(f.data()) == DmxUpdateReceiver::IGNORED, "data accepted without header");
        break;
      }
    }
  }

  // Too big for the board's buffer: rejected at the header.
  {
    std::vector<uint8_t> small(expected.size() - 1);
    DmxUpdateReceiver rx(small.data(), small.size(), model, 0);
    CHECK(rx.handleFrame(frames[0].data()) == DmxUpdateReceiver::BAD_PACKET, "oversize image accepted");
  }

  // A send stopped part-way, then rerun with another chunk size: same image
  // and CRC, different chunks. The board must start over and complete.
  if(argc == 5){
    std::vector<uint8_t> rawB = readFile(argv[4]);
    std::vector<std::vector<uint8_t>> framesB;
    for(size_t off = 0; off + DMX_UPDATE_SLOTS <= rawB.size(); off += DMX_UPDATE_SLOTS){
      framesB.emplace_back(rawB.begin() + off, rawB.begin() + off + DMX_UPDATE_SLOTS);
    }
    DmxUpdateReceiver rx(imageBuf.data(), imageBuf.size(), model, 0);
    std::vector<std::vector<uint8_t>> half(frames.begin(), frames.begin() + frames.size() / 2);
    CHECK(deliver(rx, half, 0, 0, 1, 5, false) == -1, "half a pass completed");
    CHECK(rx.active(), "half a pass didn't start a download");
    int passes = deliver(rx, framesB, 0, 0, 2, 6, false);
    CHECK(passes == 1, "rerun with another chunk size didn't complete in one pass");
    if(passes > 0){
      CHECK(memcmp(rx.image(), expected.data(), expected.size()) == 0, "chunk-size rerun: image mismatch");
    }
  }

  printf("%s (%zu frames, %zu-byte image)\n", failures ? "FAILED" : "ok", frames.size(), expected.size());
  return failures ? 1 : 0;
}
