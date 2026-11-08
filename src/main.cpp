#include <Arduino.h>
#include "Adafruit_TLC59711.h"
#include "DmxInput.h"
#include <Updater.h>
#include "dmx_update.h"

#define MIN_CURRENT 1
#define MAX_CURRENT 24
#define INTENSITY_SCALE_EXPONENT 1.832
#define MAX_PWM_GAIN_BEFORE_CURRENT_GAIN 64
#define PCB_RGB12 0
#define PCB_MONO20 1
#define PCB_MONO12 2

#define PCB_MODEL PCB_RGB12
#define BLACKOUT_IF_NO_DMX false

// Identifies this build. tools/dmx_update.py reads it out of firmware.bin to
// learn which board type the image is for (and refuses files without one),
// and boards compare its CRC against their own to skip an image they're
// already running. FIRMWARE_BUILD_TIME is set fresh on every build by
// platformio.ini, so every build gets a distinct ID.
#define SB_STR2(x) #x
#define SB_STR(x) SB_STR2(x)
#ifndef FIRMWARE_BUILD_TIME
#define FIRMWARE_BUILD_TIME __DATE__ " " __TIME__
#define FIRMWARE_BUILD_TIME_STR FIRMWARE_BUILD_TIME
#else
#define FIRMWARE_BUILD_TIME_STR SB_STR(FIRMWARE_BUILD_TIME)
#endif
__attribute__((used)) const char FIRMWARE_ID[] = "SBFWID:" SB_STR(PCB_MODEL) ":" FIRMWARE_BUILD_TIME_STR;

#define DEBUG_LED_PIN 6
#define DEBUG_SERIAL_LOG true
#define DEBUG_PRINT_INTERVAL_MILLIS 500
// DMX512 allows up to 1 s between breaks, so time out with some margin past it.
#define DMX_TIMEOUT_MILLIS 1500
// The debug LED is visible to the audience, so it only signals two events per
// boot: a double flash at power-up, and a double flash the first time valid DMX
// arrives. After that it stays dark; faults are reported over serial only.
#define DEBUG_LED_FLASH_COUNT 2
#define DEBUG_LED_ON_MILLIS 100
#define DEBUG_LED_OFF_MILLIS 200

#define DMX_OK 0
#define DMX_FAULT_NO_PACKET 1
#define DMX_FAULT_START_CODE 2
#define DMX_FAULT_ALL_FF 3
#define DMX_FAULT_BAD_ADDRESS 4

// Highest drop whose channels still fit inside the 512-channel universe.
// MONO20 reads 20*index + 20; a dial setting above this would index past
// the end of buffer[]. (RGB12 needs no limit: its 4-bit dial tops out at
// 15, which is the test mode, and 14 reads at most 33*14 + 36 = 498.)
#define MONO20_MAX_DROP_INDEX 24

// Count of 224-bit packets clocked out per write, which is not the same as the
// number of drivers stuffed. RGB12 really does have three. MONO20 carries two
// but still declares three: the first packet sent shifts clear off the end of
// the chain, which is what lands the groups regularMonoFrame() uses (4-11) in
// the two real drivers. Lowering this to 2 shrinks pwmbuffer and setPWM() then
// rejects groups 8-11, so leave it alone. MONO12 has a single driver and needs
// no such offset - one packet, one chip.
#define NUM_TLC59711 (PCB_MODEL == PCB_MONO12 ? 1 : 3)
// LED groups those packets cover, 4 per packet. Bounds the test frames.
#define NUM_LED_GROUPS (NUM_TLC59711 * 4)
// DMX footprint of the mono boards.
#define MONO_CHANNELS (PCB_MODEL == PCB_MONO12 ? 12 : 20)

Adafruit_TLC59711 tlc = Adafruit_TLC59711(NUM_TLC59711, 18, 19);
DmxInput dmxInput;

// The current show frame. The DMX interrupt copies in each complete frame in
// one go (a few microseconds), instead of the DMA trickling bytes in while the
// frame functions read it.
volatile uint8_t buffer[DMXINPUT_BUFFER_SIZE(1, 512)];

// --- Firmware update over DMX (src/dmx_update.h, tools/dmx_update.py) ---
// The DMA receives every frame into dmaBuffer. The DMX interrupt then routes
// it: update packets into updateQueue, everything else into buffer[]. Update
// data never reaches the LEDs, so the rig holds its last look while it plays.
#define DMX_UPDATE_MAX_IMAGE (160 * 1024) // keep in step with MAX_IMAGE in tools/dmx_update.py
#define DMX_UPDATE_QUEUE 8
// No update packet for this long and the download LED goes dark again.
#define DMX_UPDATE_IDLE_MILLIS 2000
#define DMX_UPDATE_PROGRESS_INTERVAL_MILLIS 1000

volatile uint8_t dmaBuffer[DMXINPUT_BUFFER_SIZE(1, 512)];
uint8_t updateQueue[DMX_UPDATE_QUEUE][DMX_UPDATE_SLOTS];
volatile uint8_t updateQueueHead = 0; // advanced only by the interrupt
volatile uint8_t updateQueueTail = 0; // advanced only by loop()
uint8_t updateImage[DMX_UPDATE_MAX_IMAGE];
DmxUpdateReceiver* updateRx = nullptr;
unsigned long lastUpdatePacketMillis = 0;

uint8_t ledPatch[12] = {11, 10, 8, 9, 7, 6, 4, 5, 3, 2, 0, 1};

// RGB12 and MONO20 patch their 12 LED groups into physical drop order. MONO12's
// lone driver is wired straight through, so its groups need no remapping - and
// only 4 of them exist, which is what NUM_LED_GROUPS bounds the test frames to.
int testLED(int i){
  return (PCB_MODEL == PCB_MONO12) ? i : ledPatch[i];
}

uint8_t slowClockValue = 0;
int loops = 0;

void applyBrightness();
void monochromeFrame();
void indexTestFrame();
void soloRGBTestFrame();
void allRGBTestFrame();
void whiteTestFrame();
void solidColorTestFrame(bool red, bool green, bool blue);
void blackoutFrame();
void dmxDataRecevied(DmxInput* instance);

void regularRGBFrame();
void regularMonoFrame();
void regularMono12Frame();

int checkDMXHealth();
void updateDebugLED(int fault);
void printLEDBrightnesses();
unsigned long millisSinceLastDMXFrame();
void serviceFirmwareUpdate();
void installFirmwareUpdate();
bool downloadingFirmware();

void setup(){
  Serial.begin(9600);
  pinMode(DEBUG_LED_PIN, OUTPUT);
  pinMode(23, OUTPUT);
  pinMode(24, INPUT_PULLUP);

  pinMode(10, INPUT_PULLDOWN);
  pinMode(4, INPUT_PULLDOWN);
  pinMode(2, INPUT_PULLDOWN);
  pinMode(0, INPUT_PULLDOWN);
  pinMode(11, INPUT_PULLDOWN);
  pinMode(5, INPUT_PULLDOWN);
  pinMode(3, INPUT_PULLDOWN);
  pinMode(1, INPUT_PULLDOWN);

  delay(300);

  tlc.begin();
  tlc.setBrightness(2, 2, 2);

  digitalWrite(23, LOW);
  dmxInput.begin(24, 1, 512);
  uint32_t buildId = dmxUpdateCrc32((const uint8_t*)FIRMWARE_ID, strlen(FIRMWARE_ID));
  static DmxUpdateReceiver receiver(updateImage, sizeof(updateImage), PCB_MODEL, buildId);
  updateRx = &receiver;
  if(DEBUG_SERIAL_LOG){
    Serial.printf("%s (build ID %08lX)\n", FIRMWARE_ID, (unsigned long)buildId);
  }

  dmxInput.read_async(dmaBuffer, dmxDataRecevied);

  for (int i = 0; i < DEBUG_LED_FLASH_COUNT; i++){
    digitalWrite(DEBUG_LED_PIN, HIGH);
    delay(DEBUG_LED_ON_MILLIS);
    digitalWrite(DEBUG_LED_PIN, LOW);
    delay(DEBUG_LED_OFF_MILLIS);
  }
}

int dropIndex = 0;
int dipDial1 = 0;
int dipDial2 = 0;
int addressOffset = 0;
bool addressValid = true;
float brightnessGain = 0;
int redScale = 255;
int greenScale = 255;
int blueScale = 255;
int controlValue = 0;
int previousControlValue = 0;
volatile unsigned long lastDMXFrameMillis = 0;

void loop(){
  serviceFirmwareUpdate();

  // Mid-download, skip rendering entirely: the TLC59711s latch their last
  // values so the rig holds its look, and the blocking test frames (up to
  // 1.5 s per loop) would otherwise overflow the update queue.
  if(downloadingFirmware()){
    updateDebugLED(DMX_OK);
    return;
  }

  if(PCB_MODEL == PCB_RGB12){
    uint8_t b1 = digitalRead(10);
    uint8_t b2 = digitalRead(8);
    uint8_t b4 = digitalRead(11);
    uint8_t b8 = digitalRead(9);
    dropIndex = b1 + b2 * 2 + b4 * 4 + b8 * 8; // 0-15
    addressOffset = 11 * dropIndex;

  }else if(PCB_MODEL == PCB_MONO20 || PCB_MODEL == PCB_MONO12){
    uint8_t b1a = digitalRead(10);
    uint8_t b2a = digitalRead(4);
    uint8_t b4a = digitalRead(2);
    uint8_t b8a = digitalRead(0);
    dipDial1 = b1a + b2a * 2 + b4a * 4 + b8a * 8; // 0-15

    uint8_t b1b = digitalRead(11);
    uint8_t b2b = digitalRead(5);
    uint8_t b4b = digitalRead(3);
    uint8_t b8b = digitalRead(1);
    dipDial2 = b1b + b2b * 2 + b4b * 4 + b8b * 8; // 0-15

    dropIndex = dipDial1 * 10 + dipDial2;

    // dipDial2 accepts 10-15 and dipDial1 multiplies by 10, so the dials can
    // ask for a drop far beyond the universe. Clamp so the frame functions
    // never index past buffer[], and flag it so the debug LED reports it.
    // dipDial1 == 15 is the intentional test mode, not a misconfiguration.
    addressValid = (dipDial1 == 15) || (dropIndex <= MONO20_MAX_DROP_INDEX);
    if(dropIndex > MONO20_MAX_DROP_INDEX){
      dropIndex = MONO20_MAX_DROP_INDEX;
    }

    addressOffset = MONO_CHANNELS * dropIndex;
  }

  int dmxFault = checkDMXHealth();
  updateDebugLED(dmxFault);
  if(dmxFault == DMX_OK){
    printLEDBrightnesses();
  }

  controlValue = buffer[511];

  if(false){
    allRGBTestFrame();

  }else if (PCB_MODEL == PCB_RGB12 && dropIndex == 15){
    soloRGBTestFrame();

  }else if ((PCB_MODEL == PCB_MONO20 || PCB_MODEL == PCB_MONO12) && dipDial1 == 15){
    whiteTestFrame();
    
  }else if(controlValue == 10){
    monochromeFrame();

  }else if(controlValue >= 20 && controlValue <= 34){
    indexTestFrame();

  }else if(controlValue >= 40 && controlValue <= 54){
    soloRGBTestFrame();

  }else if(controlValue >= 60 && controlValue <= 74){
    allRGBTestFrame();

  }else if(controlValue >= 80 && controlValue <= 94){
    whiteTestFrame();

  }else if(PCB_MODEL == PCB_RGB12 && controlValue >= 100 && controlValue <= 114){
    solidColorTestFrame(1, 0, 0); // all red

  }else if(PCB_MODEL == PCB_RGB12 && controlValue >= 120 && controlValue <= 134){
    solidColorTestFrame(0, 1, 0); // all green

  }else if(PCB_MODEL == PCB_RGB12 && controlValue >= 140 && controlValue <= 154){
    solidColorTestFrame(0, 0, 1); // all blue

  }else if(BLACKOUT_IF_NO_DMX && millisSinceLastDMXFrame() > 3000){
    blackoutFrame();

  }else{
    applyBrightness();
    brightnessGain = map(buffer[512], 0, MAX_PWM_GAIN_BEFORE_CURRENT_GAIN, 100, 65535/pow(255, INTENSITY_SCALE_EXPONENT)*100)/100.0;
    redScale = buffer[508];
    greenScale = buffer[509];
    blueScale = buffer[510];

    if(PCB_MODEL == PCB_RGB12){
      regularRGBFrame();

    }else if(PCB_MODEL == PCB_MONO20){
      regularMonoFrame();

    }else if(PCB_MODEL == PCB_MONO12){
      regularMono12Frame();

    }
  }
  tlc.write();

  loops++;
  if(loops>10){
    slowClockValue++;
    if(slowClockValue > NUM_LED_GROUPS - 1){
      slowClockValue = 0;
    }
    loops = 0;
  }

  previousControlValue = buffer[511];

  delay(3);
}

void regularRGBFrame(){
  addressOffset *= 3;

  for (int i = 0; i < 12; i++){
    int ledOffset = i * 3;
    int redVal = constrain(pow(buffer[ledOffset + addressOffset + 1], INTENSITY_SCALE_EXPONENT) * (redScale/255.0) * brightnessGain, 0, 65535);
    int greenVal = constrain(pow(buffer[ledOffset + addressOffset + 2], INTENSITY_SCALE_EXPONENT)* (greenScale/255.0) * brightnessGain, 0, 65535);
    int blueVal = constrain(pow(buffer[ledOffset + addressOffset + 3], INTENSITY_SCALE_EXPONENT)* (blueScale/255.0) * brightnessGain, 0, 65535);

    tlc.setLED(ledPatch[i], redVal, greenVal, blueVal);
  }
}

void regularMonoFrame(){
  int processedValues[20];
  for (int i = 0; i < 20; i++){
    processedValues[i] = constrain(buffer[addressOffset+i+1]*255, 0, 65535);
  }


  tlc.setLED(4, processedValues[12], processedValues[14], processedValues[16]); // 12/14/16
  tlc.setLED(5, processedValues[18], 0, 0); // 18/_/_
  tlc.setLED(6, 0, 0, processedValues[19]); // _/_/19
  tlc.setLED(7, processedValues[17], processedValues[15], processedValues[13]); // 17/15/13
  tlc.setLED(8, processedValues[0], processedValues[2], processedValues[4]); // 0/2/4
  tlc.setLED(9, processedValues[6], processedValues[8], processedValues[10]); // 6/8/10
  tlc.setLED(10, processedValues[11], processedValues[9], processedValues[7]); // 11/9/7
  tlc.setLED(11, processedValues[5], processedValues[3], processedValues[1]); // 5/3/1
  
}

// MONO12 wires board outputs 1-12 to the driver's PWM channels 0-11 in order:
// pins 3-8 are OUTR0/G0/B0/R1/G1/B1 (GS fields 0-5) and pins 13-18 are
// OUTR2/G2/B2/R3/G3/B3 (GS fields 6-11), so DMX channel N drives output N with
// no patching. Scaling matches regularMonoFrame().
void regularMono12Frame(){
  for (int i = 0; i < 12; i++){
    tlc.setPWM(i, constrain(buffer[addressOffset + i + 1] * 255, 0, 65535));
  }
}

void soloRGBTestFrame(){
  if((previousControlValue < 40 || previousControlValue > 54) && controlValue>=40 && controlValue<=54){
    slowClockValue = 0;
    loops = 0;
  }

  tlc.setBrightness(50, 50, 50);

  int val = 40000;
  tlc.setLED(testLED(slowClockValue), val, 0, 0);
  tlc.write();
  delay(500);
  tlc.setLED(testLED(slowClockValue), 0, val, 0);
  tlc.write();
  delay(500);
  tlc.setLED(testLED(slowClockValue), 0, 0, val);
  tlc.write();
  delay(500);
  tlc.setLED(testLED(slowClockValue), 0, 0, 0);
  loops+=10;
}

void allRGBTestFrame(){
  tlc.setBrightness(50, 50, 50);

  int val = 40000;
  for (int i = 0; i < NUM_LED_GROUPS; i++){
    tlc.setLED(testLED(i), val, 0, 0);
  }
  tlc.write();
  delay(500);
  for (int i = 0; i < NUM_LED_GROUPS; i++){
    tlc.setLED(testLED(i), 0, val, 0);
  }
  tlc.write();
  delay(500);
  for (int i = 0; i < NUM_LED_GROUPS; i++){
    tlc.setLED(testLED(i), 0, 0, val);
  }
  tlc.write();
  delay(500);
}

void whiteTestFrame(){
  tlc.setBrightness(20, 20, 20);

  int val = 65535;
  for (int i = 0; i < NUM_LED_GROUPS; i++){
    tlc.setLED(testLED(i), val, val, val);
  }
}

// Holds every LED group on a single colour. Same level as each step of
// allRGBTestFrame(), but static, so one colour can be checked across the rig.
void solidColorTestFrame(bool red, bool green, bool blue){
  tlc.setBrightness(50, 50, 50);

  int val = 40000;
  for (int i = 0; i < NUM_LED_GROUPS; i++){
    tlc.setLED(testLED(i), red ? val : 0, green ? val : 0, blue ? val : 0);
  }
}

void indexTestFrame(){
  tlc.setBrightness(127, 127, 127);

  for (int i = 0; i < NUM_LED_GROUPS; i++){
    tlc.setLED(testLED(i), 0, 0, 0);
  }

  // ledPatch only has 12 entries; MONO20 drop indices run well past that, so
  // anything it can't display is left dark rather than read out of bounds.
  int val = 20000;
  if(PCB_MODEL == PCB_MONO12){
    // One output per index here, and only 12 of them.
    if(dropIndex < 12){
      tlc.setPWM(dropIndex, val);
    }
  }else if(dropIndex < 11){
    tlc.setLED(ledPatch[dropIndex], 0, val, val);
  }else if(dropIndex - 11 < 12){
    tlc.setLED(ledPatch[dropIndex-11], val, 0, val);
  }
}

void monochromeFrame(){
  applyBrightness();

  if(PCB_MODEL == PCB_MONO12){
    // Every output is its own pixel on this board, so monochrome mode is just
    // the regular map with the gamma curve applied.
    for (int i = 0; i < 12; i++){
      tlc.setPWM(i, pow(buffer[i + addressOffset + 1], INTENSITY_SCALE_EXPONENT));
    }
    return;
  }

  for (int i = 0; i < 12; i++){
    int val = pow(buffer[i + addressOffset + 1], INTENSITY_SCALE_EXPONENT);
    tlc.setLED(ledPatch[i], val, val, val);
  }
}

void blackoutFrame(){
  for (int i = 0; i < NUM_LED_GROUPS; i++){
    tlc.setLED(testLED(i), 0, 0, 0);
  }
}

void applyBrightness(){
  int brightnessScale = constrain(map(buffer[512], MAX_PWM_GAIN_BEFORE_CURRENT_GAIN, 255, 0, MAX_CURRENT), 0, MAX_CURRENT);
  // blue, green, red
  tlc.setBrightness(brightnessScale + MIN_CURRENT, brightnessScale + MIN_CURRENT, brightnessScale + MIN_CURRENT);
}

// Classifies the DMX input: no frame recently, a non-zero start code, an
// all-0xFF universe (which is what a floating receiver input reads as), or an
// out-of-range address. Logs each change over serial.
int checkDMXHealth(){
  int fault = DMX_OK;

  if(!addressValid){
    fault = DMX_FAULT_BAD_ADDRESS;

  }else if(millisSinceLastDMXFrame() > DMX_TIMEOUT_MILLIS){
    fault = DMX_FAULT_NO_PACKET;

  }else if(buffer[0] != 0x00){
    fault = DMX_FAULT_START_CODE;

  }else{
    fault = DMX_FAULT_ALL_FF;
    for (int i = 1; i <= 512; i++){
      if(buffer[i] != 0xFF){
        fault = DMX_OK;
        break;
      }
    }
  }

  static int previousFault = DMX_OK;
  if(DEBUG_SERIAL_LOG && fault != previousFault && Serial){
    switch(fault){
      case DMX_OK:              Serial.println("DMX ok"); break;
      case DMX_FAULT_NO_PACKET: Serial.println("DMX fault: no packet"); break;
      case DMX_FAULT_START_CODE:
        Serial.print("DMX fault: start code 0x");
        Serial.println(buffer[0], HEX);
        break;
      case DMX_FAULT_ALL_FF:    Serial.println("DMX fault: all-0xFF universe"); break;
      case DMX_FAULT_BAD_ADDRESS:
        Serial.print("DMX fault: drop index out of range, clamped to ");
        Serial.println(MONO20_MAX_DROP_INDEX);
        break;
    }
  }
  previousFault = fault;
  return fault;
}

// Double flashes the first time valid DMX arrives, then keeps the LED dark for
// the rest of the boot. Non-blocking, so the outputs keep updating meanwhile.
// The one exception is a firmware download: the LED stays lit while update
// packets are arriving, since the boards have no other way to show it.
void updateDebugLED(int fault){
  static bool dmxSeen = false;
  static unsigned long dmxSeenMillis = 0;

  if(downloadingFirmware()){
    digitalWrite(DEBUG_LED_PIN, HIGH);
    return;
  }

  if(!dmxSeen){
    if(fault != DMX_OK){
      return;
    }
    dmxSeen = true;
    dmxSeenMillis = millis();
  }

  unsigned long elapsed = millis() - dmxSeenMillis;
  unsigned long period = DEBUG_LED_ON_MILLIS + DEBUG_LED_OFF_MILLIS;
  bool on = elapsed < period * DEBUG_LED_FLASH_COUNT && elapsed % period < DEBUG_LED_ON_MILLIS;
  digitalWrite(DEBUG_LED_PIN, on ? HIGH : LOW);
}

// Dumps the DMX value feeding each LED while the input is healthy: 20 single
// values on MONO20, 12 on MONO12, 12 R,G,B triplets on RGB12. Rate limited to keep the log
// readable and to stay well clear of saturating the link.
void printLEDBrightnesses(){
  if(!DEBUG_SERIAL_LOG || !Serial){
    return;
  }

  static unsigned long lastPrintMillis = 0;
  if(millis() - lastPrintMillis < DEBUG_PRINT_INTERVAL_MILLIS){
    return;
  }
  lastPrintMillis = millis();

  // Mirrors the indexing in regularMonoFrame()/regularRGBFrame() without
  // touching the global addressOffset, which regularRGBFrame() rescales.
  int base = (PCB_MODEL == PCB_RGB12) ? addressOffset * 3 : addressOffset;
  int span = (PCB_MODEL == PCB_RGB12) ? 36 : MONO_CHANNELS;

  Serial.print("LEDs @");
  Serial.print(base + 1);
  Serial.print(":");

  if(base + span > 512){
    Serial.println(" address out of range");
    return;
  }

  if(PCB_MODEL == PCB_RGB12){
    for (int i = 0; i < 12; i++){
      int ledOffset = base + i * 3;
      Serial.print(" ");
      Serial.print(buffer[ledOffset + 1]);
      Serial.print(",");
      Serial.print(buffer[ledOffset + 2]);
      Serial.print(",");
      Serial.print(buffer[ledOffset + 3]);
    }
  }else{
    for (int i = 0; i < MONO_CHANNELS; i++){
      Serial.print(" ");
      Serial.print(buffer[base + i + 1]);
    }
  }
  Serial.println();
}

// Read the timestamp before millis(). The other order races the DMX interrupt:
// a frame landing between the two reads makes lastDMXFrameMillis newer than
// "now", the unsigned subtraction wraps to ~4 billion, and the board briefly
// reports a DMX timeout. Read this way, an interrupt can only make the copy
// older, which is harmless.
unsigned long millisSinceLastDMXFrame(){
  unsigned long last = lastDMXFrameMillis;
  return millis() - last;
}

bool downloadingFirmware(){
  return updateRx != nullptr && updateRx->active()
      && millis() - lastUpdatePacketMillis < DMX_UPDATE_IDLE_MILLIS;
}

// Feeds queued update packets to the receiver, and installs the image once it
// is complete and verified.
void serviceFirmwareUpdate(){
  while(updateQueueTail != updateQueueHead){
    uint8_t tail = updateQueueTail;
    DmxUpdateReceiver::Result result = updateRx->handleFrame(updateQueue[tail]);
    updateQueueTail = (tail + 1) % DMX_UPDATE_QUEUE;

    if(result == DmxUpdateReceiver::PROGRESS || result == DmxUpdateReceiver::COMPLETE){
      lastUpdatePacketMillis = millis();
    }
    if(result == DmxUpdateReceiver::COMPLETE){
      installFirmwareUpdate();
    }
  }

  static unsigned long lastProgressMillis = 0;
  if(DEBUG_SERIAL_LOG && Serial && downloadingFirmware()
     && millis() - lastProgressMillis >= DMX_UPDATE_PROGRESS_INTERVAL_MILLIS){
    lastProgressMillis = millis();
    Serial.printf("Firmware update %08lX: %u/%u chunks\n", (unsigned long)updateRx->imageCrc(),
                  updateRx->chunksReceived(), updateRx->chunkCount());
  }
}

// Stages the verified image in LittleFS and reboots; the arduino-pico OTA
// bootloader then copies it over the running firmware (unpacking gzip).
void installFirmwareUpdate(){
  uint32_t size = updateRx->imageSize();
  uint32_t crc = updateRx->imageCrc();
  if(DEBUG_SERIAL_LOG){
    Serial.printf("Firmware update %08lX complete (%lu bytes), installing\n",
                  (unsigned long)crc, (unsigned long)size);
  }

  bool ok = Update.begin(size) && Update.write(updateImage, size) == size && Update.end();
  if(!ok){
    if(DEBUG_SERIAL_LOG){
      Serial.print("Firmware update failed: ");
      Update.printError(Serial);
    }
    updateRx->reset(); // drop it; the next pass from the sender starts over
    return;
  }

  digitalWrite(DEBUG_LED_PIN, LOW);
  delay(100);
  rp2040.reboot();
}

void __isr dmxDataRecevied(DmxInput* instance) {
  lastDMXFrameMillis = millis();

  // The DMA has already restarted at dmaBuffer[0], but the next frame's first
  // byte is at least a break + MAB + start code (>100 us) away, far longer
  // than these copies take.
  const uint8_t* frame = (const uint8_t*)dmaBuffer;
  if(frame[0] == 0x00 && DmxUpdateReceiver::isUpdateFrame(frame + 1)){
    uint8_t head = updateQueueHead;
    uint8_t next = (head + 1) % DMX_UPDATE_QUEUE;
    if(next != updateQueueTail){ // when full, drop it: the sender repeats everything
      memcpy(updateQueue[head], frame + 1, DMX_UPDATE_SLOTS);
      updateQueueHead = next;
    }
    return;
  }
  memcpy((void*)buffer, frame, sizeof(buffer));
}