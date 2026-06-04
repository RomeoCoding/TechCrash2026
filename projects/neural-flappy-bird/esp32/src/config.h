#pragma once
// config.h — System-wide constants for Neural Flappy Bird
// CrashTech VLSI 2026

// ── Display ──────────────────────────────────────────────────────────────────
#define SCREEN_W        128
#define SCREEN_H         64
#define FLOOR_Y          57
#define BIRD_X           22
#define BIRD_W            7
#define BIRD_H            7

// ── Physics ──────────────────────────────────────────────────────────────────
#define GRAVITY         0.28f
#define FLAP_FORCE     -3.2f
#define MAX_VY          5.0f
#define MIN_VY         -5.0f

// ── Pipes ────────────────────────────────────────────────────────────────────
#define PIPE_W           14
#define PIPE_SPACING     60
#define MIN_GAP          13
#define MAX_GAP          26
#define BASE_SPEED       1.2f
#define SPEED_PER_DIFF   0.12f

// ── Neural Network ───────────────────────────────────────────────────────────
#define NN_INPUTS         4
#define NN_HIDDEN         4
#define NN_OUTPUTS        1
#define NN_WEIGHTS       25   // 4*4 + 4 + 4 + 1

// ── Genetic Algorithm ────────────────────────────────────────────────────────
#define POP_SIZE         32
#define ELITE_COUNT       6
#define MUTATE_RATE      0.12f
#define MUTATE_STD       0.35f
#define BIG_MUT_PROB     0.02f
#define BIG_MUT_STD      1.8f
#define MAX_GENS         200
#define PLATEAU_GENS      10

// ── UART ─────────────────────────────────────────────────────────────────────
#define UART_BAUD        115200
#define UART_RX_PIN       16
#define UART_TX_PIN       17

// ── Modes ────────────────────────────────────────────────────────────────────
#define MODE_MANUAL        0
#define MODE_TRAINING      1
#define MODE_INFERENCE     2

// ── Rendering ────────────────────────────────────────────────────────────────
#define FRAME_MS          17
#define TRAIN_RENDER_SKIP 10
