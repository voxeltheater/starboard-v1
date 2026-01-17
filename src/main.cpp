#include <Arduino.h>
#include "Adafruit_TLC59711.h"
#include "DmxInput.h"

#define NUM_TLC59711 3
Adafruit_TLC59711 tlc = Adafruit_TLC59711(NUM_TLC59711, 18, 19);
DmxInput dmxInput;

#define START_CHANNEL 1
#define NUM_CHANNELS 512

volatile uint8_t buffer[DMXINPUT_BUFFER_SIZE(START_CHANNEL, NUM_CHANNELS)];

uint8_t ledPatch[12] = {11, 10, 8, 9, 7, 6, 4, 5, 3, 2, 0, 1};

void rgbLoop();

void setup()
{
  Serial.begin(9600);
  pinMode(22, OUTPUT);
  pinMode(23, OUTPUT);
  pinMode(24, INPUT_PULLUP);

  pinMode(10, INPUT_PULLDOWN);
  pinMode(8, INPUT_PULLDOWN);
  pinMode(11, INPUT_PULLDOWN);
  pinMode(9, INPUT_PULLDOWN);

  delay(300);

  tlc.begin();
  tlc.setBrightness(2, 2, 2);

  digitalWrite(23, LOW);
  dmxInput.begin(24, START_CHANNEL, NUM_CHANNELS);
  dmxInput.read_async(buffer);

  for (int i = 0; i < 3; i++)
  {
    digitalWrite(22, HIGH);
    delay(100);
    digitalWrite(22, LOW);
    delay(200);
  }
}

void loop()
{

  // read DIP dial
  uint8_t b1 = digitalRead(10);
  uint8_t b2 = digitalRead(8);
  uint8_t b4 = digitalRead(11);
  uint8_t b8 = digitalRead(9);

  int dipDial = b1 + b2 * 2 + b4 * 4 + b8 * 8; // 0-15
  int addressOffset = 11 * 3 * dipDial;

  if (dipDial == 15 || buffer[511] == 500)
  {
    rgbLoop();
  }
  else
  {
    int brightnessScale = buffer[512] + 1;
    // blue, green, red
    tlc.setBrightness(brightnessScale / 2 + 1, brightnessScale / 2 + 1, brightnessScale / 2 + 1);

    for (int i = 0; i < 12; i++)
    {
      int ledOffset = i * 3;
      int redVal = pow(buffer[ledOffset + addressOffset + 1], 1.832);
      int greenVal = pow(buffer[ledOffset + addressOffset + 2], 1.832);
      int blueVal = pow(buffer[ledOffset + addressOffset + 3], 1.832);

      tlc.setLED(ledPatch[i], redVal, greenVal, blueVal);
    }
  }
  tlc.write();

  delay(10);
}

void rgbLoop()
{
  int testBrightness = 1000;

  for (int i = 0; i < 12; i++)
  {
    tlc.setLED(ledPatch[i], testBrightness, testBrightness, testBrightness);
  }
  tlc.write();
  delay(1000);

  for (int i = 0; i < 12; i++)
  {
    tlc.setLED(ledPatch[i], testBrightness, 0, 0);
  }
  tlc.write();
  delay(1000);

  for (int i = 0; i < 12; i++)
  {
    tlc.setLED(ledPatch[i], 0, testBrightness, 0);
  }
  tlc.write();
  delay(1000);

  for (int i = 0; i < 12; i++)
  {
    tlc.setLED(ledPatch[i], 0, 0, testBrightness);
  }

  tlc.write();
  delay(1000);
}