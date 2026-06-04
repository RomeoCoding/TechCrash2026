// ============================================================================
// ESP32_P1 — Retro Pong bridge (Player 1 side)
// ============================================================================
// Receives 11-byte packets from FPGA over UART2 (GPIO16 RX).
// Validates framing (0xAA start, 0x55 end), forwards unchanged to PC
// via USB Serial.
//
// Also listens on USB Serial for 4-byte score packets from PC (0xCC p1 p2 0x55)
// and updates the OLED display.
//
// OLED layout (128x64, SSD1306, I2C 0x3C):
//   Line 0: "P1  PONG"
//   Line 1: "Score:  X"
//   Line 2: "Tilt: fwd/back"
//   Line 3: "K0:Shot K1:Shrink"
// ============================================================================

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// ---- Pin / bus constants ----
#define FPGA_RX_PIN   16
#define FPGA_TX_PIN   17    // unused but HardwareSerial requires both
#define FPGA_BAUD     115200
#define OLED_SDA      21
#define OLED_SCL      22
#define OLED_ADDR     0x3C
#define OLED_W        128
#define OLED_H        64

// ---- Packet constants ----
#define PKT_LEN       11
#define PKT_START     0xAA
#define PKT_END       0x55
#define SCORE_START   0xCC
#define SCORE_LEN     4

// ---- State ----
HardwareSerial FpgaSerial(2);
Adafruit_SSD1306 display(OLED_W, OLED_H, &Wire, -1);

uint8_t p1_score = 0;
uint8_t p2_score = 0;

// ---- OLED helpers ----
void drawOLED() {
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);

    display.setCursor(0, 0);
    display.print(F("P1  PONG"));

    display.setCursor(0, 16);
    display.print(F("Score: "));
    display.print(p1_score);
    display.print(F(" - "));
    display.print(p2_score);

    display.setCursor(0, 32);
    display.print(F("Tilt: fwd/back"));

    display.setCursor(0, 48);
    display.print(F("K0:Shot K1:Shrink"));

    display.display();
}

// ---- Score packet parser (from PC → us over USB Serial) ----
void checkScorePacket() {
    // Need at least 4 bytes in USB Serial buffer
    while (Serial.available() >= SCORE_LEN) {
        uint8_t b = Serial.read();
        if (b != SCORE_START) continue;
        // Wait briefly for remaining 3 bytes
        uint32_t t0 = millis();
        while (Serial.available() < 3 && millis() - t0 < 20) {}
        if (Serial.available() < 3) break;
        uint8_t s1  = Serial.read();
        uint8_t s2  = Serial.read();
        uint8_t end = Serial.read();
        if (end == PKT_END) {
            p1_score = s1;
            p2_score = s2;
            drawOLED();
        }
    }
}

// ---- FPGA packet reader ----
// Returns true and fills buf[11] if a valid packet was received.
bool readFpgaPacket(uint8_t* buf) {
    if (FpgaSerial.available() < 1) return false;

    uint8_t h = FpgaSerial.read();
    if (h != PKT_START) return false;  // resync next iteration

    // Wait for remaining 10 bytes (timeout 50 ms)
    uint32_t t0 = millis();
    while (FpgaSerial.available() < PKT_LEN - 1 && millis() - t0 < 50) {}
    if (FpgaSerial.available() < PKT_LEN - 1) return false;

    buf[0] = h;
    for (int i = 1; i < PKT_LEN; i++) buf[i] = FpgaSerial.read();

    return buf[PKT_LEN - 1] == PKT_END;
}

// ============================================================================
void setup() {
    Serial.begin(115200);

    Wire.begin(OLED_SDA, OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
        // OLED failed — continue anyway, just won't show anything
        Serial.println("[WARN] OLED init failed — continuing without display");
    }
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.print(F("P1 Ready"));
    display.setCursor(0, 16);
    display.print(F("Waiting for FPGA"));
    display.display();

    FpgaSerial.setRxBufferSize(256);
    FpgaSerial.begin(FPGA_BAUD, SERIAL_8N1, FPGA_RX_PIN, FPGA_TX_PIN);
}

void loop() {
    static uint8_t pkt[PKT_LEN];
    static bool oled_ready = false;

    // 1. Read FPGA packet and forward to PC
    if (readFpgaPacket(pkt)) {
        Serial.write(pkt, PKT_LEN);

        // Show full OLED on first good packet
        if (!oled_ready) {
            oled_ready = true;
            drawOLED();
        }
    }

    // 2. Check for score packets from PC
    checkScorePacket();
}
