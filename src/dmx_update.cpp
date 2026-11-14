#include "dmx_update.h"

#include <string.h>

const uint8_t DMX_UPDATE_MAGIC[DMX_UPDATE_MAGIC_LEN] = {'S', 'B', 'F', 'W', 0xA5, 0x5A, 0xC3, 0x3C};

static uint32_t readLE32(const uint8_t* p){
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint16_t readLE16(const uint8_t* p){
  return (uint16_t)(p[0] | (p[1] << 8));
}

// Standard CRC-32 (IEEE, same as zlib / Python's zlib.crc32). Bitwise rather
// than table driven: it only runs on update frames, and it saves 1 KB of RAM.
uint32_t dmxUpdateCrc32(const uint8_t* data, size_t len, uint32_t crc){
  crc = ~crc;
  for (size_t i = 0; i < len; i++){
    crc ^= data[i];
    for (int b = 0; b < 8; b++){
      crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
  }
  return ~crc;
}

DmxUpdateReceiver::DmxUpdateReceiver(uint8_t* imageBuffer, size_t imageBufferSize,
                                     uint8_t boardModel, uint32_t runningBuildId)
  : _buf(imageBuffer), _bufSize(imageBufferSize), _model(boardModel), _runningBuildId(runningBuildId){
  reset();
}

void DmxUpdateReceiver::reset(){
  _active = false;
  _crc = 0;
  _size = 0;
  _chunkSize = 0;
  _chunkCount = 0;
  _received = 0;
  memset(_have, 0, sizeof(_have));
}

bool DmxUpdateReceiver::isUpdateFrame(const uint8_t* slots){
  return memcmp(slots, DMX_UPDATE_MAGIC, DMX_UPDATE_MAGIC_LEN) == 0;
}

DmxUpdateReceiver::Result DmxUpdateReceiver::handleFrame(const uint8_t* slots){
  if(!isUpdateFrame(slots)){
    return NOT_UPDATE;
  }
  if(dmxUpdateCrc32(slots, DMX_UPDATE_CRC_OFFSET) != readLE32(slots + DMX_UPDATE_CRC_OFFSET)){
    return BAD_PACKET;
  }
  if(slots[8] != DMX_UPDATE_PROTOCOL_VERSION){
    return IGNORED;
  }

  uint32_t crc = readLE32(slots + 10);
  switch(slots[9]){
    case DMX_UPDATE_PACKET_HEADER: return handleHeader(slots, crc);
    case DMX_UPDATE_PACKET_DATA:   return handleData(slots, crc);
    default:                       return BAD_PACKET;
  }
}

DmxUpdateReceiver::Result DmxUpdateReceiver::handleHeader(const uint8_t* slots, uint32_t crc){
  uint32_t size = readLE32(slots + 14);
  uint8_t model = slots[18];
  uint16_t chunkSize = readLE16(slots + 19);
  uint32_t buildId = readLE32(slots + 21);

  // A repeat of the header we're already following. The same image sent
  // with another chunk size (a rerun with different settings) has the same
  // CRC but different chunks, so it must start over below.
  if(_active && crc == _crc && size == _size && chunkSize == _chunkSize){
    return PROGRESS;
  }

  if(model != _model || buildId == _runningBuildId){
    return IGNORED;
  }
  if(size == 0 || size > _bufSize || chunkSize == 0 || chunkSize > DMX_UPDATE_MAX_CHUNK){
    return BAD_PACKET;
  }
  uint32_t chunkCount = (size + chunkSize - 1) / chunkSize;
  if(chunkCount > DMX_UPDATE_MAX_CHUNKS){
    return BAD_PACKET;
  }

  // A different image than the one in progress (or the first header seen):
  // start over and follow this one.
  reset();
  _active = true;
  _crc = crc;
  _size = size;
  _chunkSize = chunkSize;
  _chunkCount = (uint16_t)chunkCount;
  return PROGRESS;
}

DmxUpdateReceiver::Result DmxUpdateReceiver::handleData(const uint8_t* slots, uint32_t crc){
  if(!_active || crc != _crc){
    return IGNORED; // no header yet, or a chunk from some other image
  }

  uint16_t index = readLE16(slots + 14);
  uint16_t len = readLE16(slots + 16);
  if(index >= _chunkCount){
    return BAD_PACKET;
  }
  uint32_t offset = (uint32_t)index * _chunkSize;
  uint32_t expected = (index == _chunkCount - 1) ? _size - offset : _chunkSize;
  if(len != expected){
    return BAD_PACKET;
  }

  uint8_t bit = (uint8_t)(1u << (index & 7));
  if(!(_have[index >> 3] & bit)){
    memcpy(_buf + offset, slots + DMX_UPDATE_DATA_OFFSET, len);
    _have[index >> 3] |= bit;
    _received++;
  }

  if(_received < _chunkCount){
    return PROGRESS;
  }
  if(dmxUpdateCrc32(_buf, _size) != _crc){
    // Every packet checked out but the whole doesn't: start again from scratch.
    reset();
    return BAD_PACKET;
  }
  return COMPLETE;
}
