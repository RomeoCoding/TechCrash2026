#pragma once
// game.h — Flappy Bird game engine (single-bird and population modes)
// CrashTech VLSI 2026 — Neural Flappy Bird

#include <Arduino.h>
#include <Adafruit_SSD1306.h>
#include "config.h"

struct Pipe {
    float x;
    int   gapTop;   // y-pixel of top of gap opening
    int   gapBot;   // y-pixel of bottom of gap opening
    bool  passed;
};

struct BirdState {
    float    y;
    float    vy;
    bool     alive;
    uint32_t score;
    uint32_t pipesPassed;
};

class Game {
public:
    // Reset with given difficulty and deterministic seed.
    // Seed formula for training: generation * 0xABCD1234UL
    void reset(uint8_t difficulty, uint32_t seed, int popSize = 1);

    // Single-bird update (manual or inference mode)
    void update(bool flap);

    // Multi-bird update (training mode). flapDecisions[POP_SIZE]
    void updatePopulation(const bool* flapDecisions);

    // ── Queries ─────────────────────────────────────────────────────────
    bool     isAlive(int idx = 0)      const;
    float    getBirdY(int idx = 0)     const;
    float    getBirdVy(int idx = 0)    const;
    float    getPipeDistNorm()          const;
    float    getGapCenterNorm()         const;
    uint32_t getScore(int idx = 0)     const;
    int      getAliveCount()            const;
    int      getBestAliveIdx()          const;

    // ── Rendering ───────────────────────────────────────────────────────
    void drawManual(Adafruit_SSD1306& d, uint8_t diff) const;
    void drawTraining(Adafruit_SSD1306& d, uint8_t gen, int alive,
                      uint32_t bestScore, uint32_t bestEver) const;
    void drawInference(Adafruit_SSD1306& d, uint32_t bestEver) const;

private:
    uint8_t    _diff;
    float      _speed;
    int        _gapSize;
    int        _popSize;
    Pipe       _pipes[3];
    BirdState  _birds[POP_SIZE];
    uint32_t   _rng;
    uint32_t   _frame;

    uint32_t nextRand();
    void     spawnPipe(Pipe& p, float startX);
    bool     birdHitsPipe(const BirdState& b, const Pipe& p) const;
    bool     birdHitsWall(const BirdState& b)                const;
    void     drawPipeAt(Adafruit_SSD1306& d, const Pipe& p)  const;
    void     drawBirdAt(Adafruit_SSD1306& d, float y, float vy) const;

    // 3-frame bird sprites (7×7 pixels, 1 byte per row)
    static const uint8_t BIRD_SPRITE_FLAT[7];
    static const uint8_t BIRD_SPRITE_UP[7];
    static const uint8_t BIRD_SPRITE_DOWN[7];
};
