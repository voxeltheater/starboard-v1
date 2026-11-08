Vendored copy of adafruit/Adafruit_TLC59711 1.3.4 (BSD, see license.txt).

One change, in Adafruit_TLC59711::write(): the 200 us latch delay inside
noInterrupts() busy-waits on micros() instead of calling delayMicroseconds().
On the arduino-pico core delayMicroseconds() sleeps until a timer interrupt,
which can never fire with interrupts disabled, so the stock library hangs the
board on its first write(). Drop this copy if upstream fixes it.

Also note: Adafruit BusIO's software SPI calls delayMicroseconds() between bits
(with interrupts off) when the SPI frequency is below ~1 MHz. Keep the
TLC59711 at 1 MHz or above, where that delay is zero.
