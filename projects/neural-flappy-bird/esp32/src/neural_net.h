#pragma once
// neural_net.h — Fixed-point neural network (4→4→1)
// CrashTech VLSI 2026 — Neural Flappy Bird
//
// Architecture: 4 inputs → 4 hidden (ReLU) → 1 output (sigmoid > 0.5 = flap)
// Weight canonical order (matches FPGA nn_inference.v w[0:24]):
//   [0-3]   W1[0][0..3]   [4-7]   W1[1][0..3]
//   [8-11]  W1[2][0..3]   [12-15] W1[3][0..3]
//   [16-19] B1[0..3]
//   [20-23] W2[0][0..3]   [24] B2[0]

#include <Arduino.h>
#include <math.h>
#include "config.h"

inline float relu(float x)    { return x > 0.0f ? x : 0.0f; }
inline float sigmoid(float x) { return 1.0f / (1.0f + expf(-x)); }

struct NeuralNet {
    float w1[NN_HIDDEN][NN_INPUTS];   // hidden layer weights
    float b1[NN_HIDDEN];
    float w2[NN_OUTPUTS][NN_HIDDEN];  // output layer weights
    float b2[NN_OUTPUTS];

    void  randomize();
    bool  forward(const float in[NN_INPUTS]) const;
    void  toArray(float* out) const;
    void  fromArray(const float* in);
    void  toQ88Array(int16_t* out) const;   // for FPGA weight transfer
};
