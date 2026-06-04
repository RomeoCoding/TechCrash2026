// trainer.cpp — Genetic algorithm trainer
// CrashTech VLSI 2026 — Neural Flappy Bird

#include "trainer.h"
#include <math.h>

// ── Init ─────────────────────────────────────────────────────────────────────
void Trainer::init() {
    generation      = 0;
    bestEverFitness = 0;
    plateauCount    = 0;
    _boostActive    = false;
    _boostGensLeft  = 0;

    // Randomize initial population
    for (int i = 0; i < POP_SIZE; i++) {
        pop[i].net.randomize();
        pop[i].fitness = 0;
        pop[i].alive   = true;
    }
    // Initialize bestEver with first random net
    bestEver = pop[0].net;
}

// ── Box-Muller Gaussian noise ─────────────────────────────────────────────────
float Trainer::gaussianNoise(float std) {
    // Box-Muller transform using ESP32 hardware RNG
    float u1, u2;
    do {
        u1 = (float)(esp_random() & 0xFFFF) / 65535.0f;
    } while (u1 == 0.0f);
    u2 = (float)(esp_random() & 0xFFFF) / 65535.0f;
    float z = sqrtf(-2.0f * logf(u1)) * cosf(2.0f * M_PI * u2);
    return z * std;
}

// ── Mutate a single network ───────────────────────────────────────────────────
void Trainer::mutateNet(NeuralNet& net, float stdOverride) {
    float base_std = (stdOverride > 0.0f) ? stdOverride :
                     (_boostActive ? MUTATE_STD * 1.5f : MUTATE_STD);
    float flat[NN_WEIGHTS];
    net.toArray(flat);
    for (int i = 0; i < NN_WEIGHTS; i++) {
        float r = (float)(esp_random() & 0xFFFF) / 65535.0f;
        if (r < MUTATE_RATE)
            flat[i] += gaussianNoise(base_std);
        float r2 = (float)(esp_random() & 0xFFFF) / 65535.0f;
        if (r2 < BIG_MUT_PROB)
            flat[i] += gaussianNoise(BIG_MUT_STD);
    }
    net.fromArray(flat);
}

// ── Run one full generation ───────────────────────────────────────────────────
void Trainer::runGeneration(Game& game, Adafruit_SSD1306& display,
                             uint8_t difficulty, volatile uint8_t& currentMode,
                             UartComm& uart) {
    game.reset(difficulty, (uint32_t)generation * 0xABCD1234UL, POP_SIZE);

    // Reset per-gen alive state
    for (int i = 0; i < POP_SIZE; i++) {
        pop[i].fitness = 0;
        pop[i].alive   = true;
    }

    int frameCount = 0;

    while (game.getAliveCount() > 0 && currentMode == MODE_TRAINING) {
        // Poll UART every 10 frames so FPGA MODE-change packets are processed
        // mid-generation and can interrupt via currentMode.
        if (frameCount % 10 == 0) uart.update();

        // Build flap decisions for all alive birds
        bool flapDecisions[POP_SIZE];
        for (int i = 0; i < POP_SIZE; i++) {
            if (!game.isAlive(i)) {
                flapDecisions[i] = false;
                continue;
            }
            float bird_y  = game.getBirdY(i);
            float bird_vy = game.getBirdVy(i);
            float inputs[NN_INPUTS] = {
                bird_y  / FLOOR_Y,
                (bird_vy - MIN_VY) / (MAX_VY - MIN_VY),
                game.getPipeDistNorm(),
                game.getGapCenterNorm()
            };
            flapDecisions[i] = pop[i].net.forward(inputs);
        }

        // Step all birds
        game.updatePopulation(flapDecisions);

        // Record fitness of newly-dead birds
        for (int i = 0; i < POP_SIZE; i++) {
            if (pop[i].alive && !game.isAlive(i)) {
                pop[i].alive   = false;
                pop[i].fitness = game.getScore(i);
            }
        }

        // Render
        bool renderFrame = (generation < 5) || (frameCount % TRAIN_RENDER_SKIP == 0);
        if (renderFrame) {
            int alive = game.getAliveCount();
            uint32_t bestScore = 0;
            for (int i = 0; i < POP_SIZE; i++)
                if (game.getScore(i) > bestScore) bestScore = game.getScore(i);
            game.drawTraining(display, (uint8_t)generation, alive,
                              bestScore, bestEverFitness);
            display.display();
        }
        frameCount++;
    }

    // Capture final scores for any still-alive birds at end
    for (int i = 0; i < POP_SIZE; i++) {
        if (pop[i].alive) {
            pop[i].fitness = game.getScore(i);
            pop[i].alive   = false;
        }
    }
}

// ── Evolve: sort, select elites, breed next generation ───────────────────────
void Trainer::evolve() {
    // Bubble-sort by fitness descending (POP_SIZE=32, acceptable cost)
    for (int i = 0; i < POP_SIZE - 1; i++) {
        for (int j = 0; j < POP_SIZE - 1 - i; j++) {
            if (pop[j].fitness < pop[j + 1].fitness) {
                Individual tmp = pop[j];
                pop[j]     = pop[j + 1];
                pop[j + 1] = tmp;
            }
        }
    }

    // Hall-of-fame: update bestEver
    if (pop[0].fitness > bestEverFitness) {
        bestEverFitness = pop[0].fitness;
        bestEver        = pop[0].net;
        plateauCount    = 0;
        _boostActive    = false;
        _boostGensLeft  = 0;
    } else {
        plateauCount++;
        if (plateauCount >= PLATEAU_GENS) {
            _boostActive   = true;
            _boostGensLeft = 5;
            plateauCount   = 0;
        }
    }

    // Decrement boost counter
    if (_boostActive) {
        if (_boostGensLeft > 0) _boostGensLeft--;
        else _boostActive = false;
    }

    // pop[0] = bestEver (hall-of-fame injection)
    pop[0].net     = bestEver;
    pop[0].fitness = bestEverFitness;

    // pop[1..ELITE_COUNT-1] = top performers (already sorted, unchanged)

    // pop[ELITE_COUNT..POP_SIZE-1] = mutated offspring from elites
    for (int i = ELITE_COUNT; i < POP_SIZE; i++) {
        int parentIdx = (int)(esp_random() % ELITE_COUNT);
        pop[i].net = pop[parentIdx].net;
        mutateNet(pop[i].net);
        pop[i].fitness = 0;
    }
}
