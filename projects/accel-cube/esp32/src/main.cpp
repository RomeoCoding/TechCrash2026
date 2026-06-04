// Accel Cube — ESP32 firmware
// Receives X/Y/Z raw accelerometer bytes from FPGA (7-byte packets at 115200 baud).
// Computes pitch/roll, rotates a wireframe unit cube, renders on SSD1306 OLED.

#include <Arduino.h>
#include <Wire.h>
#include <math.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "../../../../projects/common/esp32/pin_config.h"

#define ACCEL_BAUD 115200
#define HEADER     0xAA

Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);
HardwareSerial FpgaSerial(2);

// ---- 3D cube: 8 vertices at (±1, ±1, ±1) ----
static const float VERTS[8][3] = {
    { 1, 1, 1}, { 1, 1,-1}, { 1,-1, 1}, { 1,-1,-1},
    {-1, 1, 1}, {-1, 1,-1}, {-1,-1, 1}, {-1,-1,-1}
};

// 12 edges as index pairs
static const uint8_t EDGES[12][2] = {
    {0,1},{0,2},{0,4},{1,3},{1,5},{2,3},
    {2,6},{3,7},{4,5},{4,6},{5,7},{6,7}
};

// Project a 3D point to OLED screen coords
static void project(float x, float y, float z, int &sx, int &sy) {
    const float scale = 20.0f;
    const float cx = 64.0f, cy = 32.0f;
    sx = (int)(cx + scale * x);
    sy = (int)(cy - scale * y);   // OLED Y increases downward
}

// Rotate vertex by pitch (around Y) and roll (around X), then project
static void rotateProject(const float v[3], float cp, float sp,
                          float cr, float sr, int &sx, int &sy) {
    // Apply roll (Rx): rotate around X axis
    float x1 = v[0];
    float y1 = cr * v[1] - sr * v[2];
    float z1 = sr * v[1] + cr * v[2];
    // Apply pitch (Ry): rotate around Y axis
    float x2 =  cp * x1 + sp * z1;
    float y2 =  y1;
    float z2 = -sp * x1 + cp * z1;
    project(x2, y2, z2, sx, sy);
}

void drawCube(float pitch, float roll) {
    float cp = cosf(pitch), sp = sinf(pitch);
    float cr = cosf(roll),  sr = sinf(roll);

    int px[8], py[8];
    for (int i = 0; i < 8; i++) {
        rotateProject(VERTS[i], cp, sp, cr, sr, px[i], py[i]);
    }

    display.clearDisplay();
    for (int e = 0; e < 12; e++) {
        int a = EDGES[e][0], b = EDGES[e][1];
        // Clamp to display bounds before drawing
        if (px[a] >= 0 && px[a] < 128 && py[a] >= 0 && py[a] < 64 &&
            px[b] >= 0 && px[b] < 128 && py[b] >= 0 && py[b] < 64) {
            display.drawLine(px[a], py[a], px[b], py[b], SSD1306_WHITE);
        } else {
            // Draw unclamped — Adafruit GFX clips to display bounds
            display.drawLine(px[a], py[a], px[b], py[b], SSD1306_WHITE);
        }
    }
    display.display();
}

void setup() {
    Serial.begin(115200);
    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);

    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println("OLED init failed!");
    }
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Accel Cube");
    display.println("Waiting for FPGA...");
    display.display();

    FpgaSerial.setRxBufferSize(256);
    FpgaSerial.begin(ACCEL_BAUD, SERIAL_8N1, PIN_FPGA_RX, PIN_FPGA_TX);
    Serial.println("Accel Cube ready");
}

void loop() {
    // Sync to packet header (0xAA)
    while (FpgaSerial.available() < 1) { delayMicroseconds(100); }
    uint8_t h = FpgaSerial.read();
    if (h != HEADER) return;   // resync next iteration

    // Wait for 6 data bytes
    uint32_t t0 = millis();
    while (FpgaSerial.available() < 6 && millis() - t0 < 50) {}
    if (FpgaSerial.available() < 6) return;   // timeout

    uint8_t ax0 = FpgaSerial.read();
    uint8_t ax1 = FpgaSerial.read();
    uint8_t ay0 = FpgaSerial.read();
    uint8_t ay1 = FpgaSerial.read();
    uint8_t az0 = FpgaSerial.read();
    uint8_t az1 = FpgaSerial.read();

    // Reconstruct signed 16-bit values (ADXL345 little-endian 2's complement)
    int16_t ax = (int16_t)((ax1 << 8) | ax0);
    int16_t ay = (int16_t)((ay1 << 8) | ay0);
    int16_t az = (int16_t)((az1 << 8) | az0);

    // Compute pitch and roll in radians
    // pitch = tilt around Y (board left/right), roll = tilt around X (forward/back)
    float fax = (float)ax, fay = (float)ay, faz = (float)az;
    float pitch = atan2f(fax, faz);
    float roll  = atan2f(fay, faz);

    drawCube(pitch, roll);

    Serial.printf("ax=%d ay=%d az=%d  p=%.2f r=%.2f\n",
                  ax, ay, az, pitch * 57.296f, roll * 57.296f);
}
