#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#define PIN_ADC       34
#define OLED_SDA      21
#define OLED_SCL      22
#define OLED_ADDR     0x3C
#define OLED_W        128
#define OLED_H        64
#define ADC_REF_MV    3300.0f
#define ADC_SAMPLES   64

Adafruit_SSD1306 display(OLED_W, OLED_H, &Wire, -1);

void setup() {
    Serial.begin(115200);
    Serial2.begin(9600, SERIAL_8N1, 17, 16);  // TX=GPIO16 -> FPGA ARDUINO_IO[0]
    delay(500);

    analogReadResolution(12);
    analogSetAttenuation(ADC_11db);

    Wire.begin(OLED_SDA, OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
        Serial.println("OLED init failed");
        while (true);
    }
    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);
    display.display();
    Serial.println("Volt-meter ready");
}

void loop() {
    uint32_t sum = 0;
    for (int i = 0; i < ADC_SAMPLES; i++) {
        sum += analogRead(PIN_ADC);
        delayMicroseconds(100);
    }
    uint32_t raw = sum / ADC_SAMPLES;

    float mv = (raw / 4095.0f) * ADC_REF_MV;
    float v  = mv / 1000.0f;

    // Send to FPGA over UART: "X.XX\n" e.g. "1.65\n"
    Serial2.printf("%.2f\n", v);

    Serial.printf("RAW: %4lu  |  %.4f V\n", raw, v);

    display.clearDisplay();
    display.setTextSize(1);
    display.setCursor(28, 2);
    display.print("VOLT-METER");
    display.drawFastHLine(0, 13, 128, SSD1306_WHITE);
    display.setTextSize(3);
    char buf[12];
    snprintf(buf, sizeof(buf), "%.3f", v);
    int xpos = (128 - (strlen(buf) * 18)) / 2;
    display.setCursor(xpos, 20);
    display.print(buf);
    display.setTextSize(2);
    display.setCursor(100, 46);
    display.print("V");
    display.setTextSize(1);
    display.setCursor(0, 56);
    display.printf("raw:%4lu", raw);
    display.display();

    delay(100);
}
