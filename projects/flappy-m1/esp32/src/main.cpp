// main.cpp — Neural Flappy Bird, Milestone 1 (minimal)
// CrashTech VLSI 2026
//
// ESP32 renders a playable Flappy Bird on a 128x64 SSD1306 OLED.
// The FPGA is the controller: it sends single-byte commands over UART.
//
//   FPGA -> ESP32 protocol (UART2, 115200 8-N-1):
//     0x46 ('F')   = FLAP        -> bird flaps up
//     0xD0..0xDF   = difficulty  -> low nibble 0..15 sets speed + gap
//
//   A flap also restarts the game when it is in the GAME OVER state.
//
// Wiring:
//   FPGA GPIO_0[0] (PIN_V10) ── ESP32 GPIO16 (UART2 RX)
//   FPGA GND        ───────────  ESP32 GND
//   OLED: SDA=GPIO21, SCL=GPIO22, VCC=3V3, GND=GND  (I2C addr 0x3C)

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// ── Display ──────────────────────────────────────────────────────────────────
#define SCREEN_W   128
#define SCREEN_H   64
#define OLED_ADDR  0x3C
#define OLED_SDA   21
#define OLED_SCL   22
Adafruit_SSD1306 display(SCREEN_W, SCREEN_H, &Wire, -1);

// ── UART from FPGA ───────────────────────────────────────────────────────────
#define FPGA_RX_PIN 16     // ESP32 RX  <- FPGA TX (PIN_V10)
#define FPGA_TX_PIN 17     // ESP32 TX  -> FPGA RX (unused in M1)
#define UART_BAUD   115200
HardwareSerial FpgaSerial(2);

#define BYTE_FLAP   0x46   // 'F'
#define DIFF_TAG    0xD0   // 0xD0..0xDF

// ── Game constants ───────────────────────────────────────────────────────────
static const float GRAVITY    = 0.18f;
static const float FLAP_FORCE = -2.6f;
static const int   BIRD_X     = 28;
static const int   BIRD_R     = 3;
static const int   PIPE_W     = 12;

// difficulty mapping ---------------------------------------------------------
//   speed: 1.0 .. 4.0 px/frame   gap: 40 .. 18 px
static float pipeSpeedFor(uint8_t d) { return 1.0f + d * (3.0f / 15.0f); }
static int   pipeGapFor  (uint8_t d) { return 40   - d * (22  / 15);     }

// ── Game state ───────────────────────────────────────────────────────────────
enum GameState { PLAYING, GAMEOVER };
GameState state = PLAYING;

float   birdY, birdVy;
int     pipeX, gapY;          // gapY = top of the gap
uint8_t difficulty = 5;
uint16_t score = 0;
bool    passedPipe = false;
uint32_t lastFrame = 0;
const uint32_t FRAME_MS = 33;  // ~30 FPS

uint32_t rngState = 0x1234abcd;
static uint16_t prng() { rngState ^= rngState << 13; rngState ^= rngState >> 17; rngState ^= rngState << 5; return rngState & 0xFFFF; }

static void spawnPipe() {
    int gap = pipeGapFor(difficulty);
    int margin = 8;
    int maxTop = SCREEN_H - gap - margin;
    if (maxTop < margin) maxTop = margin;
    gapY  = margin + (prng() % (maxTop - margin + 1));
    pipeX = SCREEN_W;
    passedPipe = false;
}

static void resetGame() {
    birdY  = SCREEN_H / 2;
    birdVy = 0;
    score  = 0;
    state  = PLAYING;
    spawnPipe();
}

static void doFlap() {
    if (state == GAMEOVER) { resetGame(); return; }
    birdVy = FLAP_FORCE;
}

// ── UART receive ─────────────────────────────────────────────────────────────
static void pollFpga() {
    while (FpgaSerial.available()) {
        uint8_t b = FpgaSerial.read();
        if (b == BYTE_FLAP) {
            doFlap();
        } else if ((b & 0xF0) == DIFF_TAG) {
            difficulty = b & 0x0F;
        }
    }
}

// ── Physics + collision ──────────────────────────────────────────────────────
static void updateGame() {
    birdVy += GRAVITY;
    birdY  += birdVy;

    pipeX -= (int)(pipeSpeedFor(difficulty) + 0.5f);
    if (pipeX + PIPE_W < 0) spawnPipe();

    // score when bird passes the pipe
    if (!passedPipe && pipeX + PIPE_W < BIRD_X - BIRD_R) {
        passedPipe = true;
        score++;
    }

    int gap = pipeGapFor(difficulty);

    // floor / ceiling
    if (birdY - BIRD_R <= 0 || birdY + BIRD_R >= SCREEN_H) {
        state = GAMEOVER;
        return;
    }
    // pipe collision (bird overlaps pipe column and is outside the gap)
    bool xOverlap = (BIRD_X + BIRD_R >= pipeX) && (BIRD_X - BIRD_R <= pipeX + PIPE_W);
    if (xOverlap) {
        if (birdY - BIRD_R < gapY || birdY + BIRD_R > gapY + gap) {
            state = GAMEOVER;
        }
    }
}

// ── Rendering ────────────────────────────────────────────────────────────────
static void draw() {
    display.clearDisplay();
    int gap = pipeGapFor(difficulty);

    // pipes (top + bottom)
    display.fillRect(pipeX, 0, PIPE_W, gapY, SSD1306_WHITE);
    display.fillRect(pipeX, gapY + gap, PIPE_W, SCREEN_H - (gapY + gap), SSD1306_WHITE);

    // bird
    display.fillCircle(BIRD_X, (int)birdY, BIRD_R, SSD1306_WHITE);

    // HUD
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.print("S:"); display.print(score);
    display.setCursor(90, 0);
    display.print("D:"); display.print(difficulty);

    if (state == GAMEOVER) {
        display.setCursor(28, 26);
        display.print("GAME OVER");
        display.setCursor(10, 40);
        display.print("KEY[0] to restart");
    }
    display.display();
}

// ── Arduino entry points ─────────────────────────────────────────────────────
void setup() {
    Serial.begin(115200);
    delay(150);
    Serial.println("\n[FLAPPY-M1] boot");

    Wire.begin(OLED_SDA, OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
        Serial.println("[FLAPPY-M1] OLED init FAILED");
    }
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(8, 24);
    display.print("Flappy M1 - ready");
    display.display();
    delay(700);

    FpgaSerial.begin(UART_BAUD, SERIAL_8N1, FPGA_RX_PIN, FPGA_TX_PIN);

    resetGame();
    lastFrame = millis();
}

void loop() {
    pollFpga();

    uint32_t now = millis();
    if (now - lastFrame >= FRAME_MS) {
        lastFrame = now;
        if (state == PLAYING) updateGame();
        draw();
    }
}
