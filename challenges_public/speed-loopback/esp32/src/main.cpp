// Speed Loopback — ESP32 Single UART @ 115200 baud
// Minimal solution that clears the 4x bar (target < 2,600 ms; measured ~870 ms).
//
// Protocol:
//   FPGA sends 4-byte header: N as 32-bit little-endian (always 10,000)
//   FPGA sends N data bytes (LFSR pseudo-random)
//   ESP32 computes checksum = (sum of all N bytes) & 0xFF
//   ESP32 sends back 1 byte: the checksum
//   FPGA stops its timer and compares.
//
// Wiring (standard kit pinout — UART2):
//   FPGA ARDUINO_IO[1] (TX) -> ESP32 GPIO17 (RX)
//   FPGA ARDUINO_IO[0] (RX) <- ESP32 GPIO16 (TX)
//   GND <-> GND
//
// We read header + data as a single 10,004-byte stream, then reply.

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../projects/common/esp32/pin_config.h"

#define LOOP_BAUD   115200
#define N_DATA      10000

Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

// Blocking read of exactly one byte from UART2.
static inline uint8_t read_byte()
{
    while (!Serial2.available()) { /* spin */ }
    return (uint8_t)Serial2.read();
}

void setup()
{
    Serial.begin(115200);
    Serial.println("\n--- Speed Loopback: Single UART 115200 ---");

    // UART2 to FPGA at the loopback baud.
    Serial2.begin(LOOP_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println("OLED init failed");
    }
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback");
    display.println("UART 115200");
    display.println("Waiting for FPGA...");
    display.display();
}

void loop()
{
    // --- Read 4-byte little-endian header (N) ---
    uint32_t N = 0;
    N |= (uint32_t)read_byte();
    N |= (uint32_t)read_byte() << 8;
    N |= (uint32_t)read_byte() << 16;
    N |= (uint32_t)read_byte() << 24;

    if (N == 0 || N > 65535) {
        // Out of sync / garbage header — discard and resync on next byte.
        Serial.printf("Bad header N=%u, resyncing\n", N);
        return;
    }

    // --- Read N data bytes, accumulating checksum ---
    uint32_t sum = 0;
    for (uint32_t i = 0; i < N; i++) {
        sum += read_byte();
    }
    uint8_t checksum = (uint8_t)(sum & 0xFF);

    // --- Reply with 1 checksum byte ---
    Serial2.write(checksum);
    Serial2.flush();

    Serial.printf("N=%u checksum=0x%02X\n", N, checksum);

    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback");
    display.printf("N = %u\n", N);
    display.printf("checksum = 0x%02X\n", checksum);
    display.display();
}
