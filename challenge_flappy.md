Read [](file:///c%3A/Users/matro/TechCrash2026/neural_flappy_bird_prompt.md#1-1), lines 1 to 80

There are **3 milestones** inside Challenge 9, not 3 separate challenges. Here's exactly how to flash, run, and validate each one:

---

## Hardware Wiring (all milestones)

```
DE10-Lite JP1 (GPIO_0)        ESP32
  Pin 1 = GPIO_0[0] (V10) ──► GPIO 16 (RX)   [FPGA TX → ESP32 RX]
  Pin 3 = GPIO_0[1] (W10) ◄── GPIO 17 (TX)   [ESP32 TX → FPGA RX]
  GND  ────────────────────── GND

ESP32 I²C:
  GPIO 21 (SDA) ──► SSD1306 SDA
  GPIO 22 (SCL) ──► SSD1306 SCL
  3.3V / GND as usual
```

---

## Flash Both Boards (one time, all milestones use the same binaries)

**ESP32:**
```powershell
cd challenges\neural-flappy-bird\esp32
$pio = "$env:USERPROFILE\.platformio\penv\Scripts\pio.exe"
& $pio run -t upload
```

**FPGA:**
```powershell
cd challenges\neural-flappy-bird\fpga
& "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_pgm.exe" -c "USB-Blaster [USB-0]" -m JTAG -o "P;output_files/neural_flappy_bird.sof"
```

---

## Milestone 1 — Manual Play

**Setup:** `SW[9]=0`, `SW[3:0]=0101` (difficulty 5), all others off.

**How to run:**
1. Power both boards. OLED shows `NEURAL / FLAPPY` splash for 1.2 s, then `MANUAL MODE` banner.
2. Game appears on OLED. Bird falls.
3. Press `KEY[0]` on the DE10-Lite → bird flaps.
4. Move `SW[3:0]` → `HEX0` updates instantly with the new hex digit.

**What to validate:**
| Observable | Expected |
|---|---|
| OLED splash on boot | `NEURAL` / `FLAPPY` in large text for ~1.2 s |
| OLED after splash | Flappy Bird game, bird alive, pipes scrolling |
| `KEY[0]` press | Bird flaps upward |
| `SW[3:0]` change | `HEX0` shows matching hex digit (0–F) live |
| `HEX1` | Updates as score increases (upper nibble) |
| `LEDR[0]`, `LEDR[1]` | Both OFF in manual mode |
| Bird dies | Screen shows `PRESS KEY[0]`, press restarts |

---

## Milestone 2 — GA Training

**Setup:** Same wiring. SW[9]=0.

**How to trigger:** From OLED/FPGA perspective, the mode is set by the FPGA sending `MODE=training (0x01)`. In the current implementation the FPGA sets mode based on its own SW[9] and passes MODE packets — but **training mode is initiated by the ESP32 receiving a MODE=training packet from the FPGA**. Since the FPGA only sends manual(0x00) or inference(0x02), training mode must be triggered by modifying `loopManual()` to let it auto-start, OR by temporarily sending mode 0x01 from a serial test.

> **Practical shortcut for demo:** In main.cpp, change `uart.sendMode(MODE_MANUAL)` in `setup()` to `uart.sendMode(MODE_TRAINING)` and re-flash. This makes the ESP32 immediately enter training on boot.

**What to validate:**
| Observable | Expected |
|---|---|
| OLED | `TRAINING...` banner, then game with header: `G:00 A:32/32 B:00000` |
| Generations 0–4 | Every frame rendered — smooth, visible animation |
| Generation 5+ | Render throttles to every 10 frames — visibly faster |
| `LEDR[0]` on FPGA | HIGH (training mode active) |
| After gen 200 or plateau escape | OLED shows `Uploading...` progress bar |
| After upload | OLED shows `WEIGHTS SENT`, then `FPGA INFERENCE` |
| `HEX1` | Increments as best bird's score grows |

---

## Milestone 3 — FPGA Inference

**Setup:** Flip `SW[9]=1` on DE10-Lite **after** training has uploaded weights (Milestone 2 completed first).

**How to trigger:** Flip `SW[9]` to 1. FPGA sends `MODE=inference (0x02)`. ESP32 auto-transitions.

**What to validate:**
| Observable | Expected |
|---|---|
| `LEDR[1]` on FPGA | HIGH when SW[9]=1 |
| OLED | `FPGA INFERENCE` banner, then game |
| `FPGA` badge on OLED | Small inverted white-on-black `FPGA` badge top-right corner every frame |
| Bird behavior | Plays autonomously — FPGA decides every flap |
| `HEX1` on FPGA | Live score from the autonomous bird |
| Flip SW[9] back to 0 | `MANUAL MODE` banner, returns to human control |

---

## Quick Serial Monitor Validation (without OLED)

If the OLED isn't connected yet, you can still verify UART comms:
```powershell
& $pio device monitor --port COMx --baud 115200
```
Add a temporary `Serial.printf` in `uart_comm.cpp`'s `update()` dispatch to print received packets. The FPGA should send `[7E 03 01 00 02]` (MODE=manual) within a second of power-on.