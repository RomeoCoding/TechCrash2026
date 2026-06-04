#pragma once
// uart_comm.h — UART framed packet communication
// CrashTech VLSI 2026 — Neural Flappy Bird
//
// Frame: [0x7E][CMD:1][LEN:1][PAYLOAD:LEN][CHK:1]
// CHK = XOR of CMD, LEN, and all payload bytes.
// 50 ms timeout resets RX parser on incomplete packet.

#include <Arduino.h>
#include "config.h"

class UartComm {
public:
    void begin();
    void update();   // call every loop; drains RX FIFO

    // ── TX ───────────────────────────────────────────────────────────────
    void sendFlap();
    void sendDifficulty(uint8_t diff);
    void sendMode(uint8_t mode);
    void sendInferResult(uint8_t flap);
    void sendGameState(float bird_y_n, float bird_vy_n,
                       float pipe_dist_n, float gap_cy_n);
    void sendWeights(const float* weights, uint8_t count);  // count = NN_WEIGHTS
    void sendScoreUpdate(uint16_t score);

    // ── Callbacks (set in setup()) ───────────────────────────────────────
    void (*onFlap)()               = nullptr;
    void (*onDifficulty)(uint8_t)  = nullptr;
    void (*onMode)(uint8_t)        = nullptr;
    void (*onInferResult)(uint8_t) = nullptr;

private:
    void    buildAndSend(uint8_t cmd, const uint8_t* payload, uint8_t len);
    uint8_t checksum(uint8_t cmd, uint8_t len, const uint8_t* payload);

    int16_t toQ88(float v) {
        float clamped = v < -127.0f ? -127.0f : (v > 127.0f ? 127.0f : v);
        return (int16_t)(clamped * 256.0f);
    }

    enum class RxState { WAIT_START, WAIT_CMD, WAIT_LEN, READ_PAYLOAD, VALIDATE };
    RxState _rx       = RxState::WAIT_START;
    uint8_t _rxCmd    = 0;
    uint8_t _rxLen    = 0;
    uint8_t _rxIdx    = 0;
    uint8_t _rxBuf[52];
    uint32_t _rxStartMs = 0;   // for 50 ms timeout
};
