// main.cpp — Neural Flappy Bird ESP32 main
// CrashTech VLSI 2026
//
// Three modes (set by FPGA or switching SW[9]):
//   MODE_MANUAL    (0): human plays via KEY[0] on FPGA
//   MODE_TRAINING  (1): 32-bird GA evolves NN; best weights sent to FPGA
//   MODE_INFERENCE (2): FPGA runs NN; ESP32 sends game state, applies result

#include <Arduino.h>
#include <Wire.h>
#include "config.h"
#include "uart_comm.h"
#include "game.h"
#include "neural_net.h"
#include "trainer.h"
#include "oled_mgr.h"

static UartComm  uart;
static Game      game;
static Trainer   trainer;
static OledMgr   oled;

static volatile uint8_t currentMode   = MODE_MANUAL;
static uint8_t  currentDiff           = 5;
static bool     needFlap              = false;
static bool     pendingInferFlap      = false;
static bool     waitingInfer          = false;
static uint32_t lastFrameMs           = 0;
static bool     trainingLoop          = false;

// Forward declarations
static void handleModeChange(uint8_t newMode);
static void loopManual();
static void loopTraining();
static void loopInference();

// ── setup ─────────────────────────────────────────────────────────────────────
void setup() {
    oled.begin();   // splash screen shown here
    uart.begin();

    uart.onFlap = []() {
        needFlap = true;
    };
    uart.onDifficulty = [](uint8_t d) {
        currentDiff = d;
        game.reset(d, (uint32_t)millis(), 1);
    };
    uart.onMode = [](uint8_t m) {
        handleModeChange(m);
    };
    uart.onInferResult = [](uint8_t f) {
        pendingInferFlap = f;
        waitingInfer     = false;
    };

    game.reset(currentDiff, 42UL, 1);
    uart.sendMode(MODE_MANUAL);
}

// ── loop ──────────────────────────────────────────────────────────────────────
void loop() {
    uart.update();

    uint32_t now = millis();
    if (now - lastFrameMs < FRAME_MS) return;
    lastFrameMs = now;

    switch (currentMode) {
        case MODE_MANUAL:    loopManual();    break;
        case MODE_TRAINING:  loopTraining();  break;
        case MODE_INFERENCE: loopInference(); break;
        default:             loopManual();    break;
    }
}

// ── Manual mode ───────────────────────────────────────────────────────────────
static void loopManual() {
    bool flap = needFlap;
    needFlap  = false;

    if (!game.isAlive(0)) {
        if (flap) game.reset(currentDiff, (uint32_t)millis(), 1);
        oled.display().clearDisplay();
        oled.display().setTextSize(1);
        oled.display().setTextColor(SSD1306_WHITE);
        oled.display().setCursor(28, 28);
        oled.display().print("PRESS KEY[0]");
        oled.display().display();
        return;
    }

    game.update(flap);
    game.drawManual(oled.display(), currentDiff);
    oled.display().display();
    uart.sendScoreUpdate((uint16_t)game.getScore(0));
}

// ── Training mode ─────────────────────────────────────────────────────────────
static void loopTraining() {
    if (!trainingLoop) {
        trainingLoop = true;
        trainer.init();
    }

    if (trainer.generation < MAX_GENS && currentMode == MODE_TRAINING) {
        uart.update();
        trainer.runGeneration(game, oled.display(), currentDiff, currentMode, uart);
        if (currentMode != MODE_TRAINING) {
            trainingLoop = false;
            return;
        }
        trainer.evolve();
        trainer.generation++;
        return;  // next loop() call continues the next generation
    }

    // Training complete — send best weights to FPGA
    trainingLoop = false;
    int16_t q88w[NN_WEIGHTS];
    trainer.bestEver.toQ88Array(q88w);
    float fw[NN_WEIGHTS];
    for (int i = 0; i < NN_WEIGHTS; i++)
        fw[i] = q88w[i] / 256.0f;

    oled.showWeightTransfer(0);
    uart.sendWeights(fw, NN_WEIGHTS);
    oled.showWeightTransfer(100);
    delay(400);
    oled.showModeTransition("WEIGHTS SENT");
}

// ── Inference mode ────────────────────────────────────────────────────────────
static void loopInference() {
    if (waitingInfer) {
        uart.update();
        return;   // waiting for FPGA INFER_RESULT
    }

    if (!game.isAlive(0)) {
        game.reset(currentDiff, (uint32_t)millis(), 1);
        return;
    }

    // Apply last inference result, then step physics
    game.update(pendingInferFlap);
    pendingInferFlap = false;

    // Send game state to FPGA for next decision
    float bird_y_n  = game.getBirdY(0) / FLOOR_Y;
    float bird_vy_n = (game.getBirdVy(0) - MIN_VY) / (MAX_VY - MIN_VY);

    uart.sendGameState(bird_y_n, bird_vy_n,
                       game.getPipeDistNorm(), game.getGapCenterNorm());
    waitingInfer = true;

    game.drawInference(oled.display(), trainer.bestEverFitness);
    oled.display().display();
    uart.sendScoreUpdate((uint16_t)game.getScore(0));
}

// ── Mode change handler ───────────────────────────────────────────────────────
static void handleModeChange(uint8_t newMode) {
    if (newMode == currentMode) return;

    const char* labels[] = { "MANUAL MODE", "TRAINING...", "FPGA INFERENCE" };
    oled.showModeTransition(labels[newMode < 3 ? newMode : 0]);

    if (currentMode == MODE_TRAINING) trainingLoop = false;

    currentMode      = newMode;
    waitingInfer     = false;
    pendingInferFlap = false;

    if (newMode != MODE_TRAINING)
        game.reset(currentDiff, (uint32_t)millis(), 1);

    uart.sendMode(newMode);
}
