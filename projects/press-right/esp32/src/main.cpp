// ============================================================
// CrashTech VLSI-2026 — Challenge 4: Press Right (ESP32 side)
// Receives 4-digit counter value from FPGA over UART.
// If within ±10 of 1000: play victory buzzer.
// OLED: shows value + WIN/MISS result.
// ============================================================
#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// FPGA UART: GPIO16=TX (FPGA→ESP32 on ARDUINO_IO[1]), GPIO17=RX (unused here)
// Actually FPGA sends on ARDUINO_IO[1] → ESP32 GPIO17 RX
// Wait: per pin_config: PIN_FPGA_RX=17 means ESP32 receives from FPGA on GPIO17
//                       PIN_FPGA_TX=16 means ESP32 transmits to FPGA on GPIO16
// FPGA ARDUINO_IO[1] → ESP32 GPIO17
#define PIN_FPGA_TX   16  // ESP32 TX to FPGA (unused in this challenge)
#define PIN_FPGA_RX   17  // ESP32 RX from FPGA
#define FPGA_BAUD     9600

#define PIN_BUZZER    19
#define OLED_SDA      21
#define OLED_SCL      22
#define OLED_ADDR     0x3C
#define OLED_W        128
#define OLED_H        64

Adafruit_SSD1306 display(OLED_W, OLED_H, &Wire, -1);
HardwareSerial FpgaSerial(2);

String rxLine = "";
int    lastValue  = -1;
bool   lastIsWin  = false;
bool   hasResult  = false;

// Victory buzzer: 3 ascending tones
void playVictory() {
    tone(PIN_BUZZER, 523, 150);   // C5
    delay(180);
    tone(PIN_BUZZER, 659, 150);   // E5
    delay(180);
    tone(PIN_BUZZER, 784, 300);   // G5
    delay(350);
    noTone(PIN_BUZZER);
}

// Miss buzzer: low descending tones
void playMiss() {
    tone(PIN_BUZZER, 300, 200);
    delay(250);
    tone(PIN_BUZZER, 200, 300);
    delay(350);
    noTone(PIN_BUZZER);
}

void updateDisplay(int val, bool win) {
    display.clearDisplay();

    display.setTextSize(1);
    display.setCursor(22, 2);
    display.print("PRESS  RIGHT");
    display.drawFastHLine(0, 13, 128, SSD1306_WHITE);

    // Large value
    char buf[8];
    snprintf(buf, sizeof(buf), "%d", val);
    display.setTextSize(3);
    int xpos = (128 - (int)(strlen(buf) * 18)) / 2;
    if (xpos < 0) xpos = 0;
    display.setCursor(xpos, 18);
    display.print(buf);

    // Win/Miss
    display.setTextSize(2);
    if (win) {
        display.setCursor(28, 46);
        display.print("  WIN!");
    } else {
        int err = abs(val - 1000);
        display.setCursor(10, 46);
        display.printf("MISS +/-%d", err);
    }

    display.display();
}

void setup() {
    Serial.begin(115200);
    delay(300);

    pinMode(PIN_BUZZER, OUTPUT);
    noTone(PIN_BUZZER);

    Wire.begin(OLED_SDA, OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
        Serial.println("[!] OLED init failed");
    }
    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);
    display.setTextSize(1);
    display.setCursor(16, 28);
    display.print("Waiting for FPGA");
    display.display();

    FpgaSerial.begin(FPGA_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);

    Serial.println("Challenge 4: Press Right ready");
}

void loop() {
    // Read UART from FPGA: accumulate until '\n'
    while (FpgaSerial.available()) {
        char c = (char)FpgaSerial.read();
        if (c == '\n' || c == '\r') {
            if (rxLine.length() == 4) {
                int val = rxLine.toInt();
                Serial.printf("Received: %d\n", val);
                bool win = (val >= 990 && val <= 1010);
                lastValue = val;
                lastIsWin = win;
                hasResult = true;
                updateDisplay(val, win);
                if (win)
                    playVictory();
            }
            rxLine = "";
        } else if (rxLine.length() < 8) {
            rxLine += c;
        }
    }
}
