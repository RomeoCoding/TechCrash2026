// ============================================================================
// ESP32_P2 — Retro Pong score display (Player 2 side)
// ============================================================================
// No hardware inputs. Listens on USB Serial for 4-byte score packets from PC:
//   0xCC  p1_score  p2_score  0x55
// Updates the OLED when a valid packet arrives.
//
// OLED layout (128x64, SSD1306, I2C 0x3C):
//   Line 0: "P2  PONG"
//   Line 1: "Score: X - Y"
//   Line 2: "UP/DN: paddle"
//   Line 3: "SPC:Shot ENT:Shrink"
// ============================================================================

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#define OLED_SDA    21
#define OLED_SCL    22
#define OLED_ADDR   0x3C
#define OLED_W      128
#define OLED_H      64

#define SCORE_START 0xCC
#define PKT_END     0x55
#define SCORE_LEN   4

Adafruit_SSD1306 display(OLED_W, OLED_H, &Wire, -1);

uint8_t p1_score = 0;
uint8_t p2_score = 0;

void drawOLED() {
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);

    display.setCursor(0, 0);
    display.print(F("P2  PONG"));

    display.setCursor(0, 16);
    display.print(F("Score: "));
    display.print(p1_score);
    display.print(F(" - "));
    display.print(p2_score);

    display.setCursor(0, 32);
    display.print(F("UP/DN: paddle"));

    display.setCursor(0, 48);
    display.print(F("SPC:Shot ENT:Shrink"));

    display.display();
}

void setup() {
    Serial.begin(115200);

    Wire.begin(OLED_SDA, OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
        while (true) delay(1000);
    }
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.print(F("P2 Ready"));
    display.setCursor(0, 16);
    display.print(F("Waiting for game"));
    display.display();
}

void loop() {
    // Read score packets: 0xCC p1 p2 0x55
    if (Serial.available() >= SCORE_LEN) {
        uint8_t b = Serial.read();
        if (b != SCORE_START) return;  // discard, resync next loop

        uint32_t t0 = millis();
        while (Serial.available() < 3 && millis() - t0 < 20) {}
        if (Serial.available() < 3) return;

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
