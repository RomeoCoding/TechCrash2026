# Neural Flappy Bird — Milestone 1 (Manual FPGA-Controlled Game)

Minimal, from-scratch implementation of **Challenge 9, Milestone 1 (80 pts)**.

The **ESP32** renders a playable Flappy Bird on the OLED. The **FPGA** is the
controller: `KEY[0]` is the flap button and `SW[3:0]` sets the difficulty,
both sent to the ESP32 over a one-way UART link.

## Requirement → implementation map

| Requirement | Where |
|---|---|
| ESP32 renders playable Flappy Bird on OLED | `esp32/src/main.cpp` (`draw`, `updateGame`) |
| FPGA reads `KEY[0]` as flap button | `fpga/src/flappy_m1_top.v` (debounce + edge → `flap_pulse`) |
| On each valid press, FPGA sends flap over UART | sends byte `0x46` (`'F'`) |
| ESP32 moves bird up on flap | `doFlap()` sets `birdVy = FLAP_FORCE` |
| Bird hits floor/ceiling/obstacle → game ends | `updateGame()` collision → `GAMEOVER` |
| `KEY[0]` after game over restarts | flap in `GAMEOVER` calls `resetGame()` |
| FPGA reads `SW[3:0]` as difficulty 0–15 | `diff_val = SW[3:0]` |
| FPGA shows difficulty on 7-seg | `HEX0` via `seg7` module |
| FPGA sends difficulty over UART | byte `0xD0..0xDF` (low nibble = value) |
| Higher difficulty → faster obstacles | `pipeSpeedFor()` 1.0→4.0 px/frame |
| Higher difficulty → smaller gap | `pipeGapFor()` 40→18 px |

## UART protocol (FPGA → ESP32, 115200 8-N-1)

Single bytes, no framing:

- `0x46` (`'F'`) — **FLAP** (also restarts the game when in GAME OVER)
- `0xD0 .. 0xDF` — **difficulty**: high nibble `0xD`, low nibble = value 0–15.
  Sent once at startup and again on every switch change.

Milestone 1 is **TX-only on the FPGA side** — the ESP32 never talks back yet.

---

## Wiring (ESP32 ↔ FPGA ↔ OLED)

```
   DE10-Lite FPGA                         ESP32 DevKit
 ┌────────────────┐                     ┌────────────────┐
 │ GPIO_0[0]      │ ──── data ────────► │ GPIO16 (RX2)   │
 │  = PIN_V10  TX │                     │                │
 │                │                     │                │
 │ GND  ──────────┼───── common GND ───►│ GND            │
 └────────────────┘                     └──────┬─────────┘
                                                │  I2C
                                          ┌─────┴───────────┐
                                          │ SSD1306 OLED     │
                                          │  SDA = GPIO21    │
                                          │  SCL = GPIO22    │
                                          │  VCC = 3V3       │
                                          │  GND = GND       │
                                          │  addr 0x3C       │
                                          └──────────────────┘
```

### Connection table

| Signal            | FPGA pin            | ESP32 pin | Notes                          |
|-------------------|---------------------|-----------|--------------------------------|
| UART data FPGA→ESP| `GPIO_0[0]` PIN_V10 | GPIO16    | FPGA TX → ESP32 RX2            |
| Ground            | any GND on GPIO_0   | GND       | **must share ground**          |
| OLED SDA          | —                   | GPIO21    | I2C data                       |
| OLED SCL          | —                   | GPIO22    | I2C clock                      |
| OLED VCC / GND    | —                   | 3V3 / GND | 0x3C address                   |

**Only one wire + ground** is needed between the boards for Milestone 1
(FPGA transmit only). Both run at **3.3 V logic**, so no level shifter is needed.

> `GPIO_0[0]` is pin 1 of the 40-pin JP1 header on the DE10-Lite.
> If you prefer a different GPIO_0 pin, change the `set_location_assignment` for
> `GPIO_0_TX` in `fpga/flappy_m1.qsf`. On the ESP32 side, avoid the
> strapping/flash pins (GPIO6–11); GPIO16 is safe.

---

## Build & flash

### FPGA (Quartus 17.1 Lite)
```powershell
$env:PATH += ";C:\intelFPGA_lite\17.1\quartus\bin64"
cd projects\flappy-m1\fpga
quartus_sh --flow compile flappy_m1
# program (volatile, lost on power-cycle):
quartus_pgm -c "USB-Blaster" -m JTAG -o "p;output_files/flappy_m1.sof"
```

### ESP32 (PlatformIO)
```powershell
& "$env:USERPROFILE\.platformio\penv\Scripts\pio.exe" run -t upload `
    -d projects\flappy-m1\esp32 --upload-port COM3
```
Close any open serial monitor first or COM3 will be busy.

## How to demo
1. Program FPGA, flash ESP32, wire the single UART line + shared GND.
2. OLED shows the bird falling. Press **KEY[0]** to flap — bird jumps up.
3. Flip **SW[3:0]** — `HEX0` shows the value, pipes speed up and the gap shrinks.
4. Crash into a pipe/floor/ceiling → "GAME OVER". Press **KEY[0]** to restart.

`KEY[1]` = FPGA reset. `LEDR[3:0]` mirror the difficulty; `LEDR[9]` blinks on
each UART byte sent (handy to confirm the link is alive).
