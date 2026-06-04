// uart_comm.cpp — UART framed packet communication
// CrashTech VLSI 2026 — Neural Flappy Bird

#include "uart_comm.h"

void UartComm::begin() {
    Serial2.begin(UART_BAUD, SERIAL_8N1, UART_RX_PIN, UART_TX_PIN);
}

// ── RX polling ───────────────────────────────────────────────────────────────
void UartComm::update() {
    // Timeout: if in the middle of a packet and nothing received for 50 ms → reset
    if (_rx != RxState::WAIT_START && (millis() - _rxStartMs) > 50) {
        _rx = RxState::WAIT_START;
    }

    while (Serial2.available()) {
        uint8_t b = (uint8_t)Serial2.read();

        switch (_rx) {
            case RxState::WAIT_START:
                if (b == 0x7E) {
                    _rx        = RxState::WAIT_CMD;
                    _rxStartMs = millis();
                }
                break;

            case RxState::WAIT_CMD:
                _rxCmd = b;
                _rx    = RxState::WAIT_LEN;
                break;

            case RxState::WAIT_LEN:
                _rxLen = b;
                _rxIdx = 0;
                _rx    = (_rxLen == 0) ? RxState::VALIDATE : RxState::READ_PAYLOAD;
                break;

            case RxState::READ_PAYLOAD:
                if (_rxIdx < sizeof(_rxBuf))
                    _rxBuf[_rxIdx] = b;
                _rxIdx++;
                if (_rxIdx >= _rxLen)
                    _rx = RxState::VALIDATE;
                break;

            case RxState::VALIDATE: {
                // b is the received checksum; validate
                uint8_t expected = checksum(_rxCmd, _rxLen, _rxBuf);
                _rx = RxState::WAIT_START;
                if (b != expected) break;   // invalid: silently discard

                // Dispatch to callbacks
                switch (_rxCmd) {
                    case 0x01:
                        if (onFlap) onFlap();
                        break;
                    case 0x02:
                        if (onDifficulty) onDifficulty(_rxBuf[0]);
                        break;
                    case 0x03:
                        if (onMode) onMode(_rxBuf[0]);
                        break;
                    case 0x04:
                        if (onInferResult) onInferResult(_rxBuf[0]);
                        break;
                    default:
                        break;
                }
                break;
            }
        }
    }
}

// ── TX helpers ───────────────────────────────────────────────────────────────
uint8_t UartComm::checksum(uint8_t cmd, uint8_t len, const uint8_t* payload) {
    uint8_t chk = cmd ^ len;
    for (uint8_t i = 0; i < len; i++)
        chk ^= payload[i];
    return chk;
}

void UartComm::buildAndSend(uint8_t cmd, const uint8_t* payload, uint8_t len) {
    uint8_t chk = checksum(cmd, len, payload);
    Serial2.write(0x7E);
    Serial2.write(cmd);
    Serial2.write(len);
    if (len > 0)
        Serial2.write(payload, len);
    Serial2.write(chk);
}

void UartComm::sendFlap() {
    buildAndSend(0x01, nullptr, 0);
}

void UartComm::sendDifficulty(uint8_t diff) {
    uint8_t payload[1] = { diff };
    buildAndSend(0x02, payload, 1);
}

void UartComm::sendMode(uint8_t mode) {
    uint8_t payload[1] = { mode };
    buildAndSend(0x03, payload, 1);
}

void UartComm::sendInferResult(uint8_t flap) {
    uint8_t payload[1] = { flap };
    buildAndSend(0x04, payload, 1);
}

void UartComm::sendGameState(float bird_y_n, float bird_vy_n,
                              float pipe_dist_n, float gap_cy_n) {
    // 4 × int16_t Q8.8, big-endian
    int16_t vals[4] = {
        toQ88(bird_y_n),
        toQ88(bird_vy_n),
        toQ88(pipe_dist_n),
        toQ88(gap_cy_n)
    };
    uint8_t payload[8];
    for (int i = 0; i < 4; i++) {
        payload[i * 2]     = (uint8_t)(vals[i] >> 8);
        payload[i * 2 + 1] = (uint8_t)(vals[i] & 0xFF);
    }
    buildAndSend(0x11, payload, 8);
}

void UartComm::sendWeights(const float* weights, uint8_t count) {
    // 25 × int16_t Q8.8, big-endian  → 50 bytes
    uint8_t payload[50];
    for (uint8_t i = 0; i < count && i < 25; i++) {
        int16_t q = toQ88(weights[i]);
        payload[i * 2]     = (uint8_t)(q >> 8);
        payload[i * 2 + 1] = (uint8_t)(q & 0xFF);
    }
    buildAndSend(0x12, payload, count * 2);
}

void UartComm::sendScoreUpdate(uint16_t score) {
    uint8_t payload[2] = {
        (uint8_t)(score >> 8),
        (uint8_t)(score & 0xFF)
    };
    buildAndSend(0x13, payload, 2);
}
