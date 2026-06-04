// neural_net.cpp — Fixed-point neural network implementation
// CrashTech VLSI 2026 — Neural Flappy Bird

#include "neural_net.h"

// ── Randomize weights uniformly in [-1, 1] ───────────────────────────────────
void NeuralNet::randomize() {
    for (int j = 0; j < NN_HIDDEN; j++) {
        for (int i = 0; i < NN_INPUTS; i++) {
            // esp_random() returns uint32_t; map to [-1, 1]
            w1[j][i] = ((float)(esp_random() & 0xFFFF) / 32767.5f) - 1.0f;
        }
        b1[j] = ((float)(esp_random() & 0xFFFF) / 32767.5f) - 1.0f;
    }
    for (int j = 0; j < NN_OUTPUTS; j++) {
        for (int i = 0; i < NN_HIDDEN; i++) {
            w2[j][i] = ((float)(esp_random() & 0xFFFF) / 32767.5f) - 1.0f;
        }
        b2[j] = ((float)(esp_random() & 0xFFFF) / 32767.5f) - 1.0f;
    }
}

// ── Forward pass ─────────────────────────────────────────────────────────────
bool NeuralNet::forward(const float in[NN_INPUTS]) const {
    float h[NN_HIDDEN];
    for (int j = 0; j < NN_HIDDEN; j++) {
        float s = b1[j];
        for (int i = 0; i < NN_INPUTS; i++)
            s += w1[j][i] * in[i];
        h[j] = relu(s);
    }
    float out = b2[0];
    for (int j = 0; j < NN_HIDDEN; j++)
        out += w2[0][j] * h[j];
    return sigmoid(out) > 0.5f;
}

// ── Flatten to canonical array ───────────────────────────────────────────────
void NeuralNet::toArray(float* out) const {
    int idx = 0;
    for (int j = 0; j < NN_HIDDEN; j++)
        for (int i = 0; i < NN_INPUTS; i++)
            out[idx++] = w1[j][i];    // [0-15]
    for (int j = 0; j < NN_HIDDEN; j++)
        out[idx++] = b1[j];           // [16-19]
    for (int j = 0; j < NN_OUTPUTS; j++)
        for (int i = 0; i < NN_HIDDEN; i++)
            out[idx++] = w2[j][i];    // [20-23]
    out[idx++] = b2[0];               // [24]
}

// ── Unflatten from canonical array ───────────────────────────────────────────
void NeuralNet::fromArray(const float* in) {
    int idx = 0;
    for (int j = 0; j < NN_HIDDEN; j++)
        for (int i = 0; i < NN_INPUTS; i++)
            w1[j][i] = in[idx++];
    for (int j = 0; j < NN_HIDDEN; j++)
        b1[j] = in[idx++];
    for (int j = 0; j < NN_OUTPUTS; j++)
        for (int i = 0; i < NN_HIDDEN; i++)
            w2[j][i] = in[idx++];
    b2[0] = in[idx];
}

// ── Canonical Q8.8 array for FPGA transfer ───────────────────────────────────
void NeuralNet::toQ88Array(int16_t* out) const {
    float flat[NN_WEIGHTS];
    toArray(flat);
    for (int i = 0; i < NN_WEIGHTS; i++) {
        float v = flat[i];
        // Clamp to [-127, 127] then encode as Q8.8
        if (v >  127.0f) v =  127.0f;
        if (v < -127.0f) v = -127.0f;
        out[i] = (int16_t)(v * 256.0f);
    }
}
