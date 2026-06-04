#pragma once
// oled_mgr.h — SSD1306 OLED display manager
// CrashTech VLSI 2026 — Neural Flappy Bird

#include <Arduino.h>
#include <Adafruit_SSD1306.h>

class OledMgr {
public:
    void begin();
    void showModeTransition(const char* label);
    void showWeightTransfer(uint8_t percent);
    Adafruit_SSD1306& display();

private:
    Adafruit_SSD1306 _display{128, 64, &Wire, -1};
};
