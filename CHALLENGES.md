# CrashTech VLSI Hackathon 2026 — Team Challenge Planner

> **Branch for teamwork:** `team/hackathon-dev` — see bottom of this file.

---

## Challenge Overview

| # | Name | Pts | Bonus | Difficulty | Category | Starter? | Strategy | Est. Time |
|---|------|-----|-------|------------|----------|----------|----------|-----------|
| 1 | [Volt-Meter](#1-volt-meter) | 10 | — | Easy | ESP32 + FPGA | No | BLITZ | ~45 min |
| 4 | [Press Right](#4-press-right) | 20 | — | Easy | FPGA + ESP32 | No | BLITZ | ~45 min |
| 5 | [FPGA Volt-Meter](#5-fpga-volt-meter) | 20 | — | Medium | FPGA + ESP32 | No | BLITZ | ~60 min |
| 2 | [Accelerometer 3D Cube](#2-accelerometer-3d-cube) | 30 | — | Medium | FPGA + ESP32 | No | DOMINATE | ~2 hrs |
| 7 | [FP8 Adder Race](#7-fp8-adder-race) | 80 | +150/100/50 | Hard | FPGA only | YES | DOMINATE | ~3 hrs |
| 3 | [Speed Loopback](#3-speed-loopback) | 50 | +200/150/100 | Hard | FPGA + ESP32 | YES | DOMINATE | ~3 hrs |
| 6 | [Frequency Detector](#6-frequency-detector) | 100 | — | Med-Hard | FPGA + ESP32 | No | DOMINATE | ~3 hrs |
| 8 | [PC Retro Game](#8-pc-retro-game) | 100 | +250/200/150 | Medium | FPGA+ESP32+PC | No | DOMINATE | ~4 hrs |

**Total available:** 510 base + up to 600 bonus = **1110 pts**

---

## Recommended Execution Order

```
START HERE — grab easy points fast, build momentum
  [45min] Challenge 1  — Volt-Meter         /blitz volt-meter
  [45min] Challenge 4  — Press Right        /blitz press-right
  [60min] Challenge 5  — FPGA Volt-Meter    /blitz fpga-voltmeter

THEN — high point density with starters (dominator to plan, blitz to execute)
  [3hrs]  Challenge 7  — FP8 Adder Race     /challenge-dominator fp8-adder  then  /blitz fp8-adder
  [3hrs]  Challenge 3  — Speed Loopback     /challenge-dominator speed-loopback  then  /blitz speed-loopback

THEN — high base pts
  [3hrs]  Challenge 6  — Frequency Detector /challenge-dominator fft-freq  then  /blitz fft-freq
  [2hrs]  Challenge 2  — Accel Cube         /challenge-dominator accel-cube  then  /blitz accel-cube

LAST — open-ended creative, time-box hard
  [4hrs]  Challenge 8  — PC Retro Game      /challenge-dominator pc-fluppy  then  /blitz pc-fluppy
```

---

## BLITZ Challenges (Fast, Binary, Just Execute)

These are Go/No-Go with well-defined wiring and no ambiguous optimization.
Run `/blitz <name>` directly — no planning needed.

---

### 1. Volt-Meter
**10 pts | Easy | ESP32 + FPGA**

ESP32 reads potentiometer on GPIO34, shows voltage on OLED. Sends value over UART to FPGA.
FPGA shows X.XX on 7-seg with decimal point. LED bar graph LEDR[9:0] shows voltage proportionally.

- Wiring: OLED SDA->GPIO21, SCL->GPIO22. Pot->GPIO34 (max 3.3V). ESP32 GND->FPGA JP1 pin 12.
- Pass condition: All five requirements work. Go/No-Go, no partial credit.
- Command: `/blitz volt-meter`

---

### 4. Press Right
**20 pts | Easy | FPGA + ESP32**

FPGA counter increments every 10ms, shown on HEX3..0. KEY[0] starts/stops. Goal: stop exactly
at 1000 (+-10). Stopped value sent to ESP32 over UART. ESP32 plays buzzer if in range. OLED
shows result. LEDs show closeness.

- Wiring: ESP32 GND->FPGA JP1 pin 12. No extra wires — uses onboard KEY/SW only.
- Pass condition: Full chain works — counter, stop, UART, buzzer, OLED. Go/No-Go.
- Command: `/blitz press-right`

---

### 5. FPGA Volt-Meter
**20 pts | Medium | FPGA + ESP32**

FPGA reads analog voltage using MAX 10 internal ADC (Arduino header A0). Shows X.XX on 7-seg.
Sends value to ESP32, which displays on OLED in large text. Live update as voltage changes.

- Wiring: Voltage source -> Arduino header A0. ESP32 GND->FPGA JP1 pin 12.
- Pass condition: All six requirements work. Go/No-Go.
- Command: `/blitz fpga-voltmeter`

> Note: The `max10-adc-fpga` skill handles the Qsys ADC IP setup. Blitz knows this.

---

## DOMINATE Challenges (Strategy First, Then Execute)

These have performance bonuses or complex DSP. Running blitz without a strategy first
leaves the majority of available points on the table. Always run `/challenge-dominator`
first to get the tier 1-4 approach hierarchy, then execute with `/blitz`.

---

### 7. FP8 Adder Race
**80 pts base + 150/100/50 podium bonus | Hard | FPGA only | Starter provided**

Starter gives a correct but intentionally slow multi-cycle FP8 E4M3 adder. Harness tests
4096 operand pairs from ROM vs golden reference. Elapsed time shown on 7-seg.

- You may modify: `fp8_adder.v`, `challenge_pll.v`, add helper modules instantiated from fp8_adder.v
- You may NOT modify: harness, test controller, ROM, pin assignments, test vectors
- Pass condition: 2x speedup over baseline with all 4096 vectors passing (LEDR[0]=1)
- Commands: `/challenge-dominator fp8-adder` then `/blitz fp8-adder`

**Why dominate first:** The naive approach (just tune the PLL) gives ~2x. Pipelining the adder
stages can give 8-10x. The dominator will generate the exact pipeline architecture to target.

---

### 3. Speed Loopback
**50 pts base + 200/150/100 podium bonus | Hard | FPGA + ESP32 | Starter provided**

FPGA sends 10,000 pseudo-random bytes to ESP32. ESP32 receives all, computes checksum
(sum & 0xFF), sends it back. FPGA verifies and measures elapsed time.

- Baseline: 9600 baud single UART (~10.4 sec)
- Pass threshold: under 2,600ms (4x speedup required for base 50 pts)
- You may: replace UART TX/RX, change baud rates, add parallel channels, switch to SPI, rewrite ESP32 entirely
- You may NOT: modify LFSR, sum accumulator, timer, comparator, state machine, data count
- Commands: `/challenge-dominator speed-loopback` then `/blitz speed-loopback`

**Why dominate first:** 460800 baud gets you to ~200ms. Dual UART channels get you under 100ms.
SPI or parallel bus gets you under 20ms. The dominator maps which tier is worth the time investment.

---

### 6. Frequency Detector
**100 pts | Medium-Hard | FPGA + ESP32**

ESP32 reads potentiometer -> maps 0-4095 to 100-2000 Hz -> generates 256 sine wave samples
at 8kHz sample rate -> sends raw signed bytes over UART (115200 baud) to FPGA. FPGA detects
frequency, shows in Hz on HEX3..0. Accuracy must be within 35 Hz.

- SW[9] toggles debug mode (raw detection internals)
- LED bar shows frequency band (more LEDs = higher frequency)
- Commands: `/challenge-dominator fft-freq` then `/blitz fft-freq`

**Key decision:** Zero-crossing detection (simple, ~1 hr) vs Goertzel (accurate, ~2 hrs) vs FFT
(full power, ~3 hrs with Quartus IP). Dominator picks the right tier for the time budget.

---

### 2. Accelerometer 3D Cube
**30 pts | Medium | FPGA + ESP32**

FPGA reads ADXL345 via SPI -> sends raw X/Y/Z over UART to ESP32 -> ESP32 computes pitch/roll
-> draws wireframe 3D cube on OLED rotating in real time. FPGA LEDs show tilt direction.

- Wiring: ADXL345 is onboard DE10-Lite — no external wires. ESP32 GND->FPGA JP1 pin 12.
- Pass condition: All six requirements work. Go/No-Go.
- Commands: `/challenge-dominator accel-cube` then `/blitz accel-cube`

---

### 8. PC Retro Game
**100 pts base + 250/200/150 judge ranking bonus | Medium | FPGA + ESP32 + PC | No starter**

FPGA samples KEY[0], KEY[1], SW[9:0] -> sends live control packet to ESP32 -> ESP32 bridges
to PC over USB serial -> Python game receives packets as controls.

- KEY[0]: main in-game action (jump, flap, shoot)
- KEY[1]: secondary action (pause, restart)
- Switches must visibly affect gameplay, visuals, or difficulty
- No starter code provided — full creative freedom
- Commands: `/challenge-dominator pc-fluppy` then `/blitz pc-fluppy`

**Why dominate first:** The judge ranking bonus (up to +250) is for the most impressive game.
The dominator surfaces unexpected hardware combos (LCD dual display, servo feedback, BLE phone
controller) that make judges stop. A generic Flappy Bird clone will not win the ranking bonus.

---

## Teammate Branch Setup

To work on the same code together, both of you push/pull from a shared branch:

```bash
# One teammate runs this once to create and push the shared branch
git checkout -b team/hackathon-dev
git push -u origin team/hackathon-dev

# Second teammate: pull it down
git fetch origin
git checkout team/hackathon-dev
```

**Split ownership by challenge folder to avoid merge conflicts:**

```
challenges/volt-meter/         Teammate A
challenges/press-right/        Teammate B
challenges/fpga-voltmeter/     Teammate A
challenges/speed-loopback/     Teammate B
challenges/fp8-adder/          Both — coordinate before editing fp8_adder.v
challenges/fft-freq/           Teammate A
challenges/accel-cube/         Teammate B
challenges/pc-game/            Both — split FPGA side vs ESP32+Python side
projects/common/esp32/         Shared — coordinate before editing
```

**Commit after each verified challenge:**
```bash
git add challenges/<name>/
git commit -m "feat: complete <name> - verified on hardware"
git push origin team/hackathon-dev
```

**Before starting your next challenge, always pull first:**
```bash
git pull origin team/hackathon-dev
```

**If you have WIP that isn't ready to commit:**
```bash
git stash
git pull origin team/hackathon-dev
git stash pop
```

---

## Points Summary

| Priority | Challenge | Base | Max w/ Bonus | Time | How |
|----------|-----------|------|--------------|------|-----|
| 1 | Volt-Meter | 10 | 10 | 45min | /blitz |
| 2 | Press Right | 20 | 20 | 45min | /blitz |
| 3 | FPGA Volt-Meter | 20 | 20 | 60min | /blitz |
| 4 | FP8 Adder | 80 | 230 | 3hrs | dominate then blitz |
| 5 | Speed Loopback | 50 | 250 | 3hrs | dominate then blitz |
| 6 | Freq Detector | 100 | 100 | 3hrs | dominate then blitz |
| 7 | Accel Cube | 30 | 30 | 2hrs | dominate then blitz |
| 8 | PC Retro Game | 100 | 350 | 4hrs | dominate then blitz |

Minimum (first 3 only): **50 pts**
Strong run (challenges 1-6): **~360-560 pts depending on bonuses**
Full ceiling (all + podium on both performance): **~1110 pts**
