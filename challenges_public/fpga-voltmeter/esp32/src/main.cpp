// Challenge 5: FPGA Volt-Meter — ESP32 side
//
// Reads "X.XX\n" from FPGA over UART (GPIO17 = RX from FPGA ARDUINO_IO[1])
// Displays voltage in large text on SSD1306 128x64 OLED.
//
// WIRING:
//   FPGA ARDUINO_IO[1] (TX)  -> ESP32 GPIO17 (Serial2 RX)
//   FPGA GND                 -> ESP32 GND
//   OLED SDA                 -> ESP32 GPIO21
//   OLED SCL                 -> ESP32 GPIO22
//   OLED VCC                 -> ESP32 3.3V
//   OLED GND                 -> ESP32 GND

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#define OLED_WIDTH  128
#define OLED_HEIGHT  64
#define OLED_RESET   -1
#define OLED_ADDR  0x3C

// Serial2: RX=GPIO17, TX=GPIO16 (TX not used here)
#define FPGA_UART_RX 17
#define FPGA_UART_TX 16
#define FPGA_BAUD    9600

Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, OLED_RESET);

String lastVoltage = "-.--";

void showVoltage(const String& v) {
    display.clearDisplay();

    // Top label — small
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(20, 0);
    display.print("FPGA VOLTMETER");

    // Horizontal divider
    display.drawFastHLine(0, 10, OLED_WIDTH, SSD1306_WHITE);

    // Large voltage value
    display.setTextSize(4);
    display.setCursor(4, 16);
    display.print(v);

    // Unit label
    display.setTextSize(2);
    display.setCursor(96, 48);
    display.print("V");

    display.display();
}

void setup() {
    Serial.begin(115200);
    Serial2.begin(FPGA_BAUD, SERIAL_8N1, FPGA_UART_RX, FPGA_UART_TX);

    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
        Serial.println("SSD1306 init failed");
        while (true);
    }

    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);
    display.setTextSize(1);
    display.setCursor(10, 28);
    display.print("Waiting for FPGA...");
    display.display();
}

void loop() {
    // Read one line ending in '\n' from FPGA
    if (Serial2.available()) {
        String line = Serial2.readStringUntil('\n');
        line.trim();

        // Validate: should be exactly "X.XX" (4 chars, digit, dot, digit, digit)
        if (line.length() == 4 &&
            isDigit(line[0]) &&
            line[1] == '.' &&
            isDigit(line[2]) &&
            isDigit(line[3])) {

            lastVoltage = line;
            showVoltage(lastVoltage);
            Serial.print("Voltage: ");
            Serial.println(lastVoltage);
        }
    }
}
