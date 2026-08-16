#include <Arduino.h>
#include "Adafruit_TLC59711.h"
#include "DmxInput.h"

#define MIN_CURRENT 1
#define MAX_CURRENT 24
#define INTENSITY_SCALE_EXPONENT 1.832
#define MAX_PWM_GAIN_BEFORE_CURRENT_GAIN 64
#define PCB_RGB12 0
#define PCB_MONO20 1
#define PCB_MONO10 2

#define PCB_MODEL PCB_MONO20
#define BLACKOUT_IF_NO_DMX false

#define DEBUG_LED_PIN 6
#define DEBUG_SERIAL_LOG true
#define DEBUG_PRINT_INTERVAL_MILLIS 500
#define DMX_TIMEOUT_MILLIS 1000

#define DMX_OK 0
#define DMX_FAULT_NO_PACKET 1
#define DMX_FAULT_START_CODE 2
#define DMX_FAULT_ALL_FF 3

#define NUM_TLC59711 3
Adafruit_TLC59711 tlc = Adafruit_TLC59711(NUM_TLC59711, 18, 19);
DmxInput dmxInput;

volatile uint8_t buffer[DMXINPUT_BUFFER_SIZE(1, 512)];

uint8_t ledPatch[12] = {11, 10, 8, 9, 7, 6, 4, 5, 3, 2, 0, 1};
uint8_t slowClockValue = 0;
int loops = 0;

void applyBrightness();
void monochromeFrame();
void indexTestFrame();
void soloRGBTestFrame();
void allRGBTestFrame();
void whiteTestFrame();
void blackoutFrame();
void dmxDataRecevied(DmxInput* instance);

void regularRGBFrame();
void regularMonoFrame();

int updateDMXHealthLED();
void printLEDBrightnesses();

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
  dmxInput.read_async(buffer, dmxDataRecevied);

  for (int i = 0; i < 3; i++){
    digitalWrite(DEBUG_LED_PIN, HIGH);
    delay(100);
    digitalWrite(DEBUG_LED_PIN, LOW);
    delay(200);
  }
}

int dropIndex = 0;
int dipDial1 = 0;
int dipDial2 = 0;
int addressOffset = 0;
float brightnessGain = 0;
int redScale = 255;
int greenScale = 255;
int blueScale = 255;
int controlValue = 0;
int previousControlValue = 0;
volatile unsigned long lastDMXFrameMillis = 0;

void loop(){

  if(PCB_MODEL == PCB_RGB12){
    uint8_t b1 = digitalRead(10);
    uint8_t b2 = digitalRead(8);
    uint8_t b4 = digitalRead(11);
    uint8_t b8 = digitalRead(9);
    dropIndex = b1 + b2 * 2 + b4 * 4 + b8 * 8; // 0-15
    addressOffset = 11 * dropIndex;

  }else if(PCB_MODEL == PCB_MONO20){
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
    addressOffset = 20 * dropIndex;
  }

  if(updateDMXHealthLED() == DMX_OK){
    printLEDBrightnesses();
  }

  controlValue = buffer[511];

  if(false){
    allRGBTestFrame();

  }else if (PCB_MODEL == PCB_RGB12 && dropIndex == 15){
    soloRGBTestFrame();

  }else if (PCB_MODEL == PCB_MONO20 && dipDial1 == 15){
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

  }else if(BLACKOUT_IF_NO_DMX && millis() - lastDMXFrameMillis > 3000){
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


    }
  }
  tlc.write();

  loops++;
  if(loops>10){
    slowClockValue++;
    if(slowClockValue>11){
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

void soloRGBTestFrame(){
  if((previousControlValue < 40 || previousControlValue > 54) && controlValue>=40 && controlValue<=54){
    slowClockValue = 0;
    loops = 0;
  }

  tlc.setBrightness(50, 50, 50);

  int val = 40000;
  tlc.setLED(ledPatch[slowClockValue], val, 0, 0);
  tlc.write();
  delay(500);
  tlc.setLED(ledPatch[slowClockValue], 0, val, 0);
  tlc.write();
  delay(500);
  tlc.setLED(ledPatch[slowClockValue], 0, 0, val);
  tlc.write();
  delay(500);
  tlc.setLED(ledPatch[slowClockValue], 0, 0, 0);
  loops+=10;
}

void allRGBTestFrame(){
  tlc.setBrightness(50, 50, 50);

  int val = 40000;
  for (int i = 0; i < 12; i++){
    tlc.setLED(ledPatch[i], val, 0, 0);
  }
  tlc.write();
  delay(500);
  for (int i = 0; i < 12; i++){
    tlc.setLED(ledPatch[i], 0, val, 0);
  }
  tlc.write();
  delay(500);
  for (int i = 0; i < 12; i++){
    tlc.setLED(ledPatch[i], 0, 0, val);
  }
  tlc.write();
  delay(500);
}

void whiteTestFrame(){
  tlc.setBrightness(20, 20, 20);

  int val = 65535;
  for (int i = 0; i < 12; i++){
    tlc.setLED(ledPatch[i], val, val, val);
  }
}

void indexTestFrame(){
  tlc.setBrightness(127, 127, 127);

  for (int i = 0; i < 12; i++){
    tlc.setLED(ledPatch[i], 0, 0, 0);
  }

  int val = 20000;
  if(dropIndex < 11){
    tlc.setLED(ledPatch[dropIndex], 0, val, val);
  }else{
    tlc.setLED(ledPatch[dropIndex-11], val, 0, val);
  } 
}

void monochromeFrame(){
  applyBrightness();

  for (int i = 0; i < 12; i++){
    int val = pow(buffer[i + addressOffset + 1], INTENSITY_SCALE_EXPONENT);
    tlc.setLED(ledPatch[i], val, val, val);
  }
}

void blackoutFrame(){
  for (int i = 0; i < 12; i++){
    tlc.setLED(ledPatch[i], 0, 0, 0);
  }
}

void applyBrightness(){
  int brightnessScale = constrain(map(buffer[512], MAX_PWM_GAIN_BEFORE_CURRENT_GAIN, 255, 0, MAX_CURRENT), 0, MAX_CURRENT);
  // blue, green, red
  tlc.setBrightness(brightnessScale + MIN_CURRENT, brightnessScale + MIN_CURRENT, brightnessScale + MIN_CURRENT);
}

// Lights DEBUG_LED_PIN solid whenever the DMX input looks unhealthy:
// nothing received recently, a non-zero start code, or an all-0xFF universe
// (which is what a floating receiver input reads as).
int updateDMXHealthLED(){
  int fault = DMX_OK;

  if(millis() - lastDMXFrameMillis > DMX_TIMEOUT_MILLIS){
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

  digitalWrite(DEBUG_LED_PIN, fault == DMX_OK ? LOW : HIGH);

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
    }
  }
  previousFault = fault;
  return fault;
}

// Dumps the DMX value feeding each LED while the input is healthy: 20 single
// values on MONO20, 12 R,G,B triplets on RGB12. Rate limited to keep the log
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
  int span = (PCB_MODEL == PCB_RGB12) ? 36 : 20;

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
    for (int i = 0; i < 20; i++){
      Serial.print(" ");
      Serial.print(buffer[base + i + 1]);
    }
  }
  Serial.println();
}

void __isr dmxDataRecevied(DmxInput* instance) {
  // digitalWrite(6, !digitalRead(6));
  lastDMXFrameMillis = millis();
}