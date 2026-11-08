#pragma once

// Receives a firmware image broadcast as ordinary DMX frames.
//
// Update packets ride in normal start-code-0 frames, so they pass through any
// Art-Net / sACN node or USB-DMX interface untouched. Every packet is a full
// 512-slot frame laid out as below (offsets are slot offsets, i.e. slot 1 of
// the universe is offset 0; multi-byte fields are little endian):
//
//   0..7     magic "SBFW" A5 5A C3 3C
//   8        protocol version (DMX_UPDATE_PROTOCOL_VERSION)
//   9        packet type: 1 = header, 2 = data
//   10..13   CRC-32 of the whole image (also identifies the image)
//   header:
//     14..17 image size in bytes
//     18     board model (PCB_RGB12 / PCB_MONO20 / PCB_MONO12)
//     19..20 chunk size in bytes
//     21..24 build ID: CRC-32 of the image's FIRMWARE_ID string (see main.cpp)
//   data:
//     14..15 chunk index
//     16..17 payload length
//     18..   payload (at most DMX_UPDATE_MAX_CHUNK bytes)
//   508..511 CRC-32 of offsets 0..507
//
// The 64-bit magic plus a packet CRC-32 means show data can't be mistaken for
// an update. Nothing is written to flash here: the image is assembled in RAM
// and only handed back once every chunk has arrived and the whole-image CRC
// matches, the board model matches, and its build ID differs from the build
// that is running (so a board that has just installed an image, and reboots
// into a sender still playing it, doesn't install it again - while a board
// whose install failed still has the old build ID and simply takes it again).
//
// tools/dmx_update.py is the matching sender. Keep the two in step.
//
// Kept free of Arduino dependencies so it can be tested on a host machine
// (test/host/).

#include <stddef.h>
#include <stdint.h>

#define DMX_UPDATE_PROTOCOL_VERSION 1
#define DMX_UPDATE_SLOTS 512
#define DMX_UPDATE_MAGIC_LEN 8
#define DMX_UPDATE_PACKET_HEADER 1
#define DMX_UPDATE_PACKET_DATA 2
#define DMX_UPDATE_DATA_OFFSET 18
#define DMX_UPDATE_CRC_OFFSET 508
#define DMX_UPDATE_MAX_CHUNK (DMX_UPDATE_CRC_OFFSET - DMX_UPDATE_DATA_OFFSET)
#define DMX_UPDATE_MAX_CHUNKS 512

extern const uint8_t DMX_UPDATE_MAGIC[DMX_UPDATE_MAGIC_LEN];

uint32_t dmxUpdateCrc32(const uint8_t* data, size_t len, uint32_t crc = 0);

class DmxUpdateReceiver {
public:
  enum Result {
    NOT_UPDATE,   // ordinary show data
    BAD_PACKET,   // has the magic but failed CRC or sanity checks
    IGNORED,      // valid, but not for this board / already installed / no header yet
    PROGRESS,     // accepted, image not complete yet
    COMPLETE,     // image complete and verified; read it with image()/imageSize()
  };

  // imageBuffer must outlive the receiver. runningBuildId is the build ID of
  // the firmware currently running; images with the same ID are ignored.
  DmxUpdateReceiver(uint8_t* imageBuffer, size_t imageBufferSize,
                    uint8_t boardModel, uint32_t runningBuildId);

  // Cheap check on the magic only; safe to call from an interrupt.
  static bool isUpdateFrame(const uint8_t* slots);

  // slots points at the 512 slots of one frame (not the start code).
  Result handleFrame(const uint8_t* slots);

  const uint8_t* image() const { return _buf; }
  uint32_t imageSize() const { return _size; }
  uint32_t imageCrc() const { return _crc; }
  uint16_t chunksReceived() const { return _received; }
  uint16_t chunkCount() const { return _chunkCount; }
  bool active() const { return _active; }

  // Forget any partial image. Call after a failed install so it can retry.
  void reset();

private:
  Result handleHeader(const uint8_t* slots, uint32_t crc);
  Result handleData(const uint8_t* slots, uint32_t crc);

  uint8_t* _buf;
  size_t _bufSize;
  uint8_t _model;
  uint32_t _runningBuildId;

  bool _active;
  uint32_t _crc;
  uint32_t _size;
  uint16_t _chunkSize;
  uint16_t _chunkCount;
  uint16_t _received;
  uint8_t _have[DMX_UPDATE_MAX_CHUNKS / 8];
};
