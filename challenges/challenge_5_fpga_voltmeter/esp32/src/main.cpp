// ============================================================
// CrashTech VLSI-2026 — Challenge 5: FPGA Volt-Meter (ESP32)
// ============================================================
// Receives ASCII voltage strings from the FPGA over UART2,
// parses them, and displays the reading on the OLED in large
// readable text.
//
// Expected UART message format (sent by FPGA):
//   "V=X.XX\n"   e.g. "V=1.23\n" or "V=3.30\n"
//
// OLED layout (128x64, SSD1306):
//   Line 1 (small):   "  Voltage"
//   Line 2 (large):   " 1.23 V"
//   Line 3 (small):   bar graph of ----------
//
// Wiring:
//   FPGA ARDUINO_IO[1]  →  ESP32 GPIO16  (UART2 RX)
//   FPGA GND            ↔  ESP32 GND
//   OLED SDA            →  ESP32 GPIO21
//   OLED SCL            →  ESP32 GPIO22
// ============================================================

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../projects/common/esp32/pin_config.h"

// ---- OLED ----
Adafruit_SSD1306 oled(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);
bool oledOk = false;

// ---- UART to FPGA ----
HardwareSerial FpgaSerial(2);   // UART2: RX=GPIO16, TX=GPIO17

// ---- UART receive buffer ----
String fpgaLine    = "";        // accumulates characters until '\n'
String voltageStr  = "-.--";   // last parsed voltage, e.g. "1.23"
float  voltageVal  = 0.0f;     // parsed float, 0.0 .. 3.3

// ---- Display throttle ----
unsigned long displayTimer = 0;
const unsigned long DISPLAY_INTERVAL = 100;  // ms (~10 FPS)

// ---- Timeout: show "No signal" if FPGA silent for 3 s ----
unsigned long lastRxTime = 0;
const unsigned long RX_TIMEOUT_MS = 3000;

// ============================================================
//  Parse a line like "V=1.23" and update voltageStr / voltageVal
// ============================================================
void parseFpgaLine(const String &line) {
    // Expect format: V=X.XX  (e.g. "V=1.23")
    if (line.length() >= 6 && line.startsWith("V=")) {
        String valPart = line.substring(2);   // "1.23"
        float v = valPart.toFloat();
        if (v >= 0.0f && v <= 3.30f) {
            voltageVal = v;
            voltageStr = valPart;
            // Normalise to always show exactly 4 chars ("X.XX")
            if (voltageStr.length() < 4) {
                while (voltageStr.length() < 4) voltageStr += '0';
            }
            voltageStr = voltageStr.substring(0, 4);
            lastRxTime = millis();
            Serial.printf("[FPGA] V=%s\n", voltageStr.c_str());
        }
    }
}

// ============================================================
//  Draw the OLED screen
// ============================================================
void updateOled() {
    oled.clearDisplay();
    oled.setTextColor(SSD1306_WHITE);

    bool hasSignal = (millis() - lastRxTime < RX_TIMEOUT_MS);

    // ---- Title bar ----
    oled.setTextSize(1);
    oled.setCursor(28, 0);
    oled.print("FPGA Voltmeter");
    oled.drawFastHLine(0, 10, 128, SSD1306_WHITE);

    if (!hasSignal) {
        // No UART data received yet
        oled.setTextSize(1);
        oled.setCursor(22, 28);
        oled.print("Waiting for FPGA...");
        oled.display();
        return;
    }

    // ---- Large voltage reading  e.g.  "1.23 V" ----
    oled.setTextSize(3);          // each char ~18x24 px
    oled.setCursor(4, 16);
    oled.print(voltageStr);
    oled.setTextSize(2);
    oled.print(" V");

    // ---- Bar graph (proportional to voltage 0..3.3 V) ----
    // Full bar = 126 px wide
    int barWidth = (int)(voltageVal / 3.30f * 126.0f);
    if (barWidth < 0)   barWidth = 0;
    if (barWidth > 126) barWidth = 126;

    oled.setTextSize(1);
    oled.setCursor(0, 53);
    oled.print("0V");
    oled.setCursor(107, 53);
    oled.print("3.3V");

    oled.drawRect(0, 44, 128, 8, SSD1306_WHITE);
    if (barWidth > 0)
        oled.fillRect(1, 45, barWidth, 6, SSD1306_WHITE);

    oled.display();
}

// ============================================================
//  Setup
// ============================================================
void setup() {
    Serial.begin(115200);
    delay(300);
    Serial.println();
    Serial.println("========================================");
    Serial.println(" CrashTech VLSI-2026 — Challenge 5");
    Serial.println(" FPGA Volt-Meter (ESP32 display)");
    Serial.println("========================================");
    Serial.printf(" UART2 RX: GPIO%d  (← FPGA ARDUINO_IO[1])\n", PIN_FPGA_RX);
    Serial.printf(" OLED SDA: GPIO%d   SCL: GPIO%d\n", PIN_OLED_SDA, PIN_OLED_SCL);
    Serial.println("========================================");

    // OLED init
    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    oledOk = oled.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR);
    if (!oledOk) {
        Serial.println("[!] OLED init failed — check SDA/SCL wiring");
    } else {
        oled.clearDisplay();
        oled.setTextSize(1);
        oled.setTextColor(SSD1306_WHITE);
        oled.setCursor(16, 24);
        oled.print("Waiting for FPGA");
        oled.display();
    }

    // FPGA UART init — receive only (9600 8N1)
    // PIN_FPGA_RX = GPIO16, PIN_FPGA_TX = GPIO17 (from pin_config.h)
    FpgaSerial.begin(FPGA_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);

    lastRxTime = millis();
}

// ============================================================
//  Loop
// ============================================================
void loop() {
    unsigned long now = millis();

    // ---- Receive UART from FPGA ----
    while (FpgaSerial.available()) {
        char c = (char)FpgaSerial.read();

        if (c == '\n' || c == '\r') {
            if (fpgaLine.length() > 0) {
                parseFpgaLine(fpgaLine);
                fpgaLine = "";
            }
        } else if (fpgaLine.length() < 32) {
            fpgaLine += c;
        }
    }

    // ---- Refresh OLED at ~10 FPS ----
    if (oledOk && (now - displayTimer >= DISPLAY_INTERVAL)) {
        displayTimer = now;
        updateOled();
    }
}
