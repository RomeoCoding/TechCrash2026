#pragma once
// trainer.h — Genetic algorithm trainer for neural network birds
// CrashTech VLSI 2026 — Neural Flappy Bird

#include <Arduino.h>
#include <Adafruit_SSD1306.h>
#include "config.h"
#include "neural_net.h"
#include "game.h"
#include "uart_comm.h"

struct Individual {
    NeuralNet net;
    uint32_t  fitness;
    bool      alive;
};

class Trainer {
public:
    void init();

    // Runs one full generation (blocks until all birds dead or mode changes).
    // Renders every TRAIN_RENDER_SKIP frames (every frame for gen < 5).
    // Polls uart every 10 sim frames so FPGA MODE-change packets interrupt mid-gen.
    void runGeneration(Game& game, Adafruit_SSD1306& display,
                       uint8_t difficulty, volatile uint8_t& currentMode,
                       UartComm& uart);

    // Sort by fitness, keep elites, breed next generation.
    void evolve();

    int       generation      = 0;
    uint32_t  bestEverFitness = 0;
    NeuralNet bestEver;
    int       plateauCount    = 0;
    Individual pop[POP_SIZE];

private:
    void  mutateNet(NeuralNet& net, float stdOverride = 0.0f);
    float gaussianNoise(float std);
    bool  _boostActive     = false;
    int   _boostGensLeft   = 0;
};
