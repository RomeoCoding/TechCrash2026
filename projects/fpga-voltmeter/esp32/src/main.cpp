#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../projects/common/esp32/pin_config.h"

Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

HardwareSerial FpgaSerial(2);

void setup() {
    Serial.begin(115200);
    FpgaSerial.begin(FPGA_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println("OLED init failed");
        while (true);
    }
    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);
    display.display();
    Serial.println("FPGA volt-meter ready");
}

void loop() {
    if (!FpgaSerial.available()) return;

    String rxLine = FpgaSerial.readStringUntil('\n');
    rxLine.trim();

    // Expect "X.XXX" (4 or 5 chars with decimal point)
    if (rxLine.length() < 3) return;

    float v = rxLine.toFloat();
    if (v < 0.0f || v > 3.4f) return;  // sanity check

    Serial.printf("FPGA voltage: %s V\n", rxLine.c_str());

    display.clearDisplay();

    // Title
    display.setTextSize(1);
    display.setCursor(18, 2);
    display.print("FPGA VOLT-METER");
    display.drawFastHLine(0, 13, 128, SSD1306_WHITE);

    // Large voltage value
    display.setTextSize(3);
    char buf[12];
    snprintf(buf, sizeof(buf), "%.3f", v);
    int xpos = (128 - (strlen(buf) * 18)) / 2;
    display.setCursor(xpos, 20);
    display.print(buf);

    // Unit
    display.setTextSize(2);
    display.setCursor(100, 46);
    display.print("V");

    display.display();
}
