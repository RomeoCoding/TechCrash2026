// Frequency Detector — ESP32 firmware
// Reads potentiometer on GPIO34 -> maps 0-4095 to 100-2000 Hz ->
// generates 256 int8 sine samples at 8kHz -> streams over UART to FPGA.
// FPGA detects frequency via zero-crossing count and displays on 7-seg.

#include <Arduino.h>
#include <Wire.h>
#include <math.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../projects/common/esp32/pin_config.h"

#define FREQ_BAUD    115200
#define SAMPLES      256
#define SAMPLE_RATE  8000   // Hz — must match FPGA ZC formula
#define POT_MIN      100    // Hz
#define POT_MAX      2000   // Hz
#define FRAME_US     32000  // 256 samples / 8000 Hz = 32 ms per frame

Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);
HardwareSerial FpgaSerial(2);

static int8_t samples[SAMPLES];

void buildSine(float freq_hz) {
    for (int i = 0; i < SAMPLES; i++) {
        float phase = 2.0f * M_PI * freq_hz * i / (float)SAMPLE_RATE;
        samples[i] = (int8_t)(127.0f * sinf(phase));
    }
}

void setup() {
    Serial.begin(115200);
    Serial.println("\n--- Freq Detector (115200 baud) ---");

    analogReadResolution(12);
    analogSetAttenuation(ADC_11db);  // 0-3.3V range

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println("OLED init failed!");
    }
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Freq Detector");
    display.println("115200 baud");
    display.println("Waiting...");
    display.display();

    FpgaSerial.begin(FREQ_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);
}

void loop() {
    uint32_t frame_start = micros();

    // Read potentiometer and map to frequency
    int raw = analogRead(PIN_ANALOG_IN);
    float freq = POT_MIN + (float)(raw) * (POT_MAX - POT_MIN) / 4095.0f;

    // Build 256-sample sine wave at the target frequency
    buildSine(freq);

    // Stream all 256 bytes to FPGA
    FpgaSerial.write((const uint8_t*)samples, SAMPLES);

    // Update OLED every frame (32ms is fast enough)
    display.clearDisplay();
    display.setTextSize(2);
    display.setCursor(0, 0);
    display.printf("%4d Hz", (int)freq);
    display.setTextSize(1);
    display.setCursor(0, 24);
    display.printf("ADC: %d", raw);
    display.setCursor(0, 34);
    display.printf("Samples: %d @ %d Hz", SAMPLES, SAMPLE_RATE);
    display.display();

    Serial.printf("freq=%.1f Hz  raw=%d\n", freq, raw);

    // Pace to 8kHz effective sample rate (32ms per 256-sample frame)
    uint32_t elapsed = micros() - frame_start;
    if (elapsed < FRAME_US) {
        delayMicroseconds(FRAME_US - elapsed);
    }
}
