// oled_mgr.cpp — SSD1306 OLED display manager
// CrashTech VLSI 2026 — Neural Flappy Bird

#include "oled_mgr.h"

Adafruit_SSD1306& OledMgr::display() {
    return _display;
}

void OledMgr::begin() {
    Wire.begin(21, 22);  // SDA=21, SCL=22

    if (!_display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
        // OLED init failed — blink built-in LED forever as error indicator
        pinMode(2, OUTPUT);
        while (true) {
            digitalWrite(2, HIGH); delay(200);
            digitalWrite(2, LOW);  delay(200);
        }
    }

    // ── Splash screen: "NEURAL" / "FLAPPY" in 2× font, centered, 1200 ms ──
    _display.clearDisplay();
    _display.setTextColor(SSD1306_WHITE);
    _display.setTextSize(2);

    // Center "NEURAL" — each char is 12px wide × 16px tall at size 2
    // "NEURAL" = 6 chars × 12 = 72px wide
    _display.setCursor((128 - 72) / 2, 12);
    _display.print("NEURAL");

    // Center "FLAPPY" — 6 chars × 12 = 72px
    _display.setCursor((128 - 72) / 2, 32);
    _display.print("FLAPPY");

    _display.display();
    delay(1200);

    // Transition: brief invert flash
    _display.invertDisplay(true);
    delay(40);
    _display.invertDisplay(false);
    _display.clearDisplay();
    _display.display();
}

// ── Mode transition screen ────────────────────────────────────────────────────
void OledMgr::showModeTransition(const char* label) {
    _display.clearDisplay();
    _display.invertDisplay(true);
    delay(40);
    _display.invertDisplay(false);

    // Draw label centered
    _display.setTextSize(1);
    _display.setTextColor(SSD1306_WHITE);

    // Estimate text width: ~6px per character at size 1
    int textW = strlen(label) * 6;
    int x     = (128 - textW) / 2;
    if (x < 0) x = 0;

    _display.setCursor(x, 28);
    _display.print(label);
    _display.display();
    delay(800);
}

// ── Weight transfer progress bar ─────────────────────────────────────────────
void OledMgr::showWeightTransfer(uint8_t percent) {
    _display.clearDisplay();
    _display.setTextSize(1);
    _display.setTextColor(SSD1306_WHITE);

    // "Uploading..." centered
    _display.setCursor((128 - 72) / 2, 20);
    _display.print("Uploading...");

    // Empty bar: rect [10, 48, 118, 58] — (x, y, w, h)
    _display.drawRect(10, 48, 108, 10, SSD1306_WHITE);

    // Filled portion
    int fillW = (int)(108 * percent / 100.0f);
    if (fillW > 0)
        _display.fillRect(10, 48, fillW, 10, SSD1306_WHITE);

    _display.display();
}
