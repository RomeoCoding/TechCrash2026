# SRS — Retro Pong (Challenge 8: PC Retro Game)
**CrashTech VLSI Hackathon 2026**
Last updated: 2026-06-04

---

## 1. Overview

Two-player Pong.

- **Player 1** tilts the DE10-Lite FPGA board forward/back to move their paddle. Uses ADXL345 accelerometer already onboard.
- **Player 2** uses the PC keyboard (UP/DOWN arrows).

No extra hardware needed. No WiFi. No breadboard. Just the FPGA board, two ESP32s with OLEDs, and two USB cables to the PC.

### Hardware you have

| Device | Role |
|--------|------|
| DE10-Lite FPGA | P1 controller — tilt + KEY/SW |
| ESP32_P1 + OLED | Bridge FPGA → PC. Shows P1 HUD on OLED. |
| ESP32_P2 + OLED | Score display only. Shows P2 HUD. Receives score from PC via USB. |
| PC | Runs Python game. P2 uses keyboard. |

### Scoring (Challenge 8)

- **100 pts baseline**: full chain works (board → ESP32 → PC game responds)
- **Judge bonus**: 1st=250, 2nd=200, 3rd/4th/5th=150

---

## 2. System Architecture

```
┌─────────────────────────────────────────────────────┐
│  DE10-Lite FPGA                                      │
│  ADXL345 ──SPI──► pong_top.sv                       │
│  KEY[1:0], SW[9:0] ──────────►                      │
│  LEDR[9:0] ◄── P1 tilt bar                          │
│  HEX5:4 = "P1"                                      │
└────────────┬────────────────────────────────────────┘
             │ UART TX 115200 8N1
             │ ARDUINO_IO[1] → ESP32_P1 GPIO16
             ▼
┌────────────────────────────────────────────────────┐
│  ESP32_P1                                           │
│  HardwareSerial(2) ← FPGA 11-byte packets          │
│  Serial (USB) → forward packets to PC              │
│  Serial (USB) ← receive score packet from PC       │
│  OLED: P1 score, tilt indicator, power shot status │
└────────────┬───────────────────────────────────────┘
             │ USB Serial (COM port A)
             ▼
┌────────────────────────────────────────────────────┐
│  PC — Python game.py (pygame)                       │
│  Left  paddle = P1 (ADXL345 ay tilt from FPGA)     │
│  Right paddle = P2 (keyboard UP / DOWN arrows)      │
│  P1 actions: KEY[0]=power shot, KEY[1]=shrink       │
│  P2 actions: Space=power shot, Enter=shrink         │
│  SW[9:0] = modifiers (speed, multi-ball, narrow)   │
│  Sends score packet → COM port B (ESP32_P2)        │
└────────────┬───────────────────────────────────────┘
             │ USB Serial (COM port B)
             ▼
┌────────────────────────────────────────────────────┐
│  ESP32_P2                                           │
│  Serial (USB) ← score packets from PC              │
│  OLED: P2 score, shrink cooldown, game status      │
└────────────────────────────────────────────────────┘
```

---

## 3. Wiring

### FPGA → ESP32_P1 (one wire + ground)

| FPGA Arduino header | ESP32_P1 GPIO | Signal |
|--------------------|---------------|--------|
| D1 (ARDUINO_IO[1]) | GPIO16 (RX2) | UART TX from FPGA |
| GND | GND | Common ground |

### ESP32_P1 OLED

| OLED pin | ESP32_P1 GPIO |
|----------|---------------|
| SDA | GPIO21 |
| SCL | GPIO22 |
| VCC | 3.3V |
| GND | GND |

### ESP32_P2 OLED

Same as above. ESP32_P2 connects to PC via its own USB cable. No other wiring.

---

## 4. Communication Protocols

### 4.1 P1 Packet: FPGA → ESP32_P1 (11 bytes, 115200 baud)

```
[0] 0xAA        start marker
[1] ax0         ADXL345 X low byte
[2] ax1         ADXL345 X high byte
[3] ay0         ADXL345 Y low byte   ← PRIMARY paddle axis
[4] ay1         ADXL345 Y high byte  ← PRIMARY paddle axis
[5] az0         ADXL345 Z low byte
[6] az1         ADXL345 Z high byte
[7] key_byte    bit0=KEY0 pressed, bit1=KEY1 pressed (active HIGH after inversion)
[8] sw_lo       SW[7:0]
[9] sw_hi       SW[9:8] in bits [1:0]
[10] 0x55       end marker
```

Sent every **16 ms** (62.5 Hz). `KEY[n]` is active-low on the DE10-Lite — invert before packing so `1 = pressed`.

### 4.2 ESP32_P1 → PC (same 11 bytes, forwarded over USB Serial)

ESP32_P1 validates the packet (checks `0xAA` start and `0x55` end), then writes it unchanged to `Serial` (USB). The PC Python game reads it directly.

### 4.3 Score Packet: PC → ESP32_P1 and PC → ESP32_P2 (4 bytes)

Sent over USB Serial after each point:

```
[0] 0xCC
[1] p1_score   (0–7)
[2] p2_score   (0–7)
[3] 0x55
```

PC sends this on **both** COM port A (ESP32_P1) and COM port B (ESP32_P2) simultaneously.
ESP32_P1 and ESP32_P2 each parse it and update their OLED.

---

## 5. FPGA Specification

### 5.1 Source files

```
projects/retro-pong/fpga/src/
  pong_top.sv     ← single file, based on accel_cube_top.sv
```

### 5.2 Starting point

**Copy `projects/accel-cube/fpga/src/accel_cube_top.sv` to `projects/retro-pong/fpga/src/pong_top.sv`.**
Rename the module to `pong_top`. The ADXL345 SPI driver, UART TX, and main FSM are kept verbatim. Only three things change:

### 5.3 Change 1 — Rename module and update header assigns

```systemverilog
module pong_top (   // was: accel_cube_top
    ...             // same port list
);
    assign ARDUINO_RESET_N  = 1'b1;
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_IO[0]    = 1'bz;
```

### 5.4 Change 2 — Poll interval: 10 ms → 16 ms

```systemverilog
// OLD:
if (main_cnt == 27'd500_000) begin   // 10 ms

// NEW:
if (main_cnt == 27'd800_000) begin   // 16 ms at 50 MHz
```

### 5.5 Change 3 — Expand TX packet: 7 bytes → 11 bytes

The original accel_cube sends: `0xAA ax0 ax1 ay0 ay1 az0 az1` (7 bytes, no end marker).
Pong_top sends: `0xAA ax0 ax1 ay0 ay1 az0 az1 key_byte sw_lo sw_hi 0x55` (11 bytes).

Add these signals before the FSM:

```systemverilog
// KEY is active low — invert
wire [7:0] key_byte = {6'b0, ~KEY[1], ~KEY[0]};
```

Add these states to the `state_t` enum (after the existing states):

```systemverilog
S_TX_KEY, S_TX_SWL, S_TX_SWH, S_TX_END, S_TX_END_WAIT
```

Replace `S_TX_Z1` and the `state <= S_POLL_WAIT` transition with:

```systemverilog
S_TX_Z1: if (uart_done) begin
    uart_tx_byte <= az1;     uart_start <= 1; state <= S_TX_KEY;
end
S_TX_KEY: if (uart_done) begin
    uart_tx_byte <= key_byte; uart_start <= 1; state <= S_TX_SWL;
end
S_TX_SWL: if (uart_done) begin
    uart_tx_byte <= SW[7:0]; uart_start <= 1; state <= S_TX_SWH;
end
S_TX_SWH: if (uart_done) begin
    uart_tx_byte <= {6'b0, SW[9:8]}; uart_start <= 1; state <= S_TX_END;
end
S_TX_END: if (uart_done) begin
    uart_tx_byte <= 8'h55;   uart_start <= 1; state <= S_TX_END_WAIT;
end
S_TX_END_WAIT: if (uart_done) begin
    state <= S_POLL_WAIT;
end
```

### 5.6 Change 4 — LEDR: tilt bar instead of sign bits

Remove the existing `assign LEDR[...]` lines. Replace with:

```systemverilog
// ay_signed: reconstruct signed 16-bit from ay1:ay0 (available after S_RD_Y1)
wire signed [15:0] ay_signed = {ay1, ay0};

// Map ay ∈ [-200, +200] → LEDR bar [0..9]
// Saturate, then: idx = (ay_signed + 200) * 10 / 400
wire [9:0] ledr_bar;
wire signed [15:0] ay_clamped =
    (ay_signed > 16'sd200)  ? 16'sd200  :
    (ay_signed < -16'sd200) ? -16'sd200 : ay_signed;
wire [3:0] bar_idx = ((ay_clamped + 16'sd200) * 10) >> 9; // approx /400 * 10

genvar gi;
generate
    for (gi = 0; gi < 10; gi++) begin : led_bar
        assign LEDR[gi] = (gi <= bar_idx);
    end
endgenerate
```

### 5.7 Change 5 — HEX display: show "P1" static

Replace the existing HEX assignments:

```systemverilog
// Active-low 7-segment encoding
assign HEX5 = 8'b1000_1110; // "P"
assign HEX4 = 8'b1111_1001; // "1"
assign HEX3 = 8'b1011_1111; // "-"
assign HEX2 = 8'b1011_1111; // "-"
assign HEX1 = 8'b1011_1111; // "-"
assign HEX0 = 8'b1011_1111; // "-"
```

### 5.8 QSF (use the alive_test base, update these fields)

```tcl
set_global_assignment -name TOP_LEVEL_ENTITY pong_top
set_global_assignment -name SYSTEMVERILOG_FILE src/pong_top.sv
```

All pin assignments are inherited from the alive_test .qsf — do not change them.
The GSENSOR pins and ARDUINO_IO pins are already in the alive_test base.
Verify these two are present (add if missing):

```tcl
set_location_assignment PIN_AB16 -to GSENSOR_CS_N
set_location_assignment PIN_AB15 -to GSENSOR_SCLK
set_location_assignment PIN_V11  -to GSENSOR_SDI
set_location_assignment PIN_V12  -to GSENSOR_SDO
set_location_assignment PIN_Y13  -to GSENSOR_INT[1]
set_location_assignment PIN_AA14 -to GSENSOR_INT[2]
```

### 5.9 Compile & program

```powershell
cd C:\Users\matro\TechCrash2026\projects\retro-pong\fpga
& "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_sh.exe" --flow compile retro_pong
Select-String -Path "output_files\retro_pong.map.rpt" -Pattern "Error"
Select-String -Path "output_files\retro_pong.fit.rpt" -Pattern "Error"
& "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_pgm.exe" `
    -c "USB-Blaster [USB-0]" -m JTAG -o "P;output_files\retro_pong.sof"
```

---

## 6. ESP32_P1 Specification

### 6.1 platformio.ini

```ini
[env:esp32dev]
platform = espressif32
board = esp32dev
framework = arduino
monitor_speed = 115200
lib_deps =
    adafruit/Adafruit SSD1306@^2.5.7
    adafruit/Adafruit GFX Library@^1.11.5
```

### 6.2 Behavior

```
Setup:
  - Init OLED (I2C, addr 0x3C, SDA=21, SCL=22)
  - Start HardwareSerial(2) at 115200 on GPIO16/17
  - Start USB Serial at 115200
  - Show "P1 Ready" on OLED

Loop:
  - Read from HardwareSerial(2): sync on 0xAA, collect 10 more bytes, check 0x55 tail
  - If valid: forward all 11 bytes unchanged to Serial (USB → PC)
  - Also check Serial for incoming score packet (0xCC p1 p2 0x55)
  - If score packet received: update OLED
```

### 6.3 OLED layout

```
┌──────────────────┐
│ P1  PONG         │
│ Score:  3        │
│ Tilt: fwd/back   │
│ KEY0: Powershot  │
└──────────────────┘
```

Update score line only when a score packet arrives. Everything else is static.

### 6.4 Key constants

```cpp
#define FPGA_RX_PIN   16
#define FPGA_TX_PIN   17
#define FPGA_BAUD     115200
#define P1_PKT_LEN    11
#define PKT_START     0xAA
#define PKT_END       0x55
#define SCORE_START   0xCC
```

---

## 7. ESP32_P2 Specification

### 7.1 platformio.ini

Same as ESP32_P1.

### 7.2 Behavior

ESP32_P2 has no hardware inputs. It is a display device only.

```
Setup:
  - Init OLED
  - Start USB Serial at 115200
  - Show "P2 Ready" on OLED

Loop:
  - Check USB Serial for score packet (0xCC p1 p2 0x55)
  - If received: update OLED score display
```

### 7.3 OLED layout

```
┌──────────────────┐
│ P2  PONG         │
│ Score:  2        │
│ UP/DN: paddle    │
│ SPC: Powershot   │
└──────────────────┘
```

### 7.4 Serial packet parsing

```cpp
void loop() {
    if (Serial.available() >= 4) {
        if (Serial.read() == 0xCC) {
            uint8_t p1 = Serial.read();
            uint8_t p2 = Serial.read();
            uint8_t end = Serial.read();
            if (end == 0x55) updateOLED(p1, p2);
        }
    }
}
```

---

## 8. Python Game Specification

### 8.1 Dependencies

```
# requirements.txt
pygame==2.5.2
pyserial==3.5
numpy==1.26.4
```

### 8.2 Launch

```bash
python game.py --p1port COM3 --p2port COM4
```

- `--p1port`: COM port for ESP32_P1 (receives FPGA packets, sends score back)
- `--p2port`: COM port for ESP32_P2 (sends score only)
- Both ports opened at 115200 baud.

### 8.3 Screen layout (800×600)

```
┌──────────────────────────────────────────────────────────────────┐
│         P1: 3                  PONG               P2: 5          │
│                                                                   │
│  ┌──┐          . . . . . . . . . . . . . . .            ┌──┐     │
│  │  │                                                    │  │     │
│  │  │   P1 paddle                          P2 paddle    │  │     │
│  │  │   x=30, w=12                         x=758, w=12 │  │     │
│  │  │   h=80px (normal)                                 │  │     │
│  │  │   h=48px (shrunk)          ●                     │  │     │
│  └──┘                           ball                    └──┘     │
│                                 12×12px                           │
│  [modifiers]                                       [FPS]          │
└──────────────────────────────────────────────────────────────────┘
```

### 8.4 Coordinate mapping

**P1 paddle Y** — ADXL345 ay (signed 16-bit, little-endian):

```python
ay = int.from_bytes(pkt[3:5], byteorder='little', signed=True)
ay_clamped = max(-180, min(180, ay))
# Map [-180, +180] → [PADDLE_H//2, SCREEN_H - PADDLE_H//2]
p1_y = int((ay_clamped + 180) / 360 * (SCREEN_H - PADDLE_H)) + PADDLE_H // 2
```

Board flat (ay≈0): paddle centred at y=300.
Tilted forward (positive ay): paddle moves down.
Tilted back (negative ay): paddle moves up.

**P2 paddle Y** — keyboard, updated in the pygame event loop:

```python
keys = pygame.key.get_pressed()
if keys[pygame.K_UP]:   p2_y -= PADDLE_SPEED
if keys[pygame.K_DOWN]: p2_y += PADDLE_SPEED
p2_y = max(PADDLE_H // 2, min(SCREEN_H - PADDLE_H // 2, p2_y))
PADDLE_SPEED = 6   # px per frame at 60fps
```

### 8.5 Ball physics

- Ball size: 12×12 px square.
- Initial speed: set by `SW[9:8]` at serve time (see §8.7). Never changes mid-rally.
- Launch angle on serve: random, constrained to 30°–60° or 120°–150° (never near-horizontal).
- On **paddle hit**:
  - Reflect `vx`.
  - New `vy = (ball_cy - paddle_cy) / (PADDLE_H / 2) * ball_speed * 0.75`
  - This makes centre hits return flat and edge hits return at a steep angle.
  - If power shot active: `vx *= 1.4`, cap at `MAX_VX = ball_speed * 1.4`.
  - Clamp `vy` to `[-ball_speed*0.9, ball_speed*0.9]` so ball never goes purely vertical.
- On **top/bottom wall hit**: reflect `vy`.
- Ball exits **left side** (x < 0): P2 scores.
- Ball exits **right side** (x > SCREEN_W): P1 scores.

```python
SCREEN_W, SCREEN_H = 800, 600
PADDLE_W, PADDLE_H = 12, 80
PADDLE_H_SHRUNK    = 48
BALL_SIZE          = 12
MAX_SCORE          = 7
```

### 8.6 Scoring

- First to **7 points** wins.
- On point:
  1. Flash scoring side: fill that half of the screen white for 120 ms.
  2. Send score packet to both serial ports:
     `ser_p1.write(bytes([0xCC, p1_score, p2_score, 0x55]))`
     `ser_p2.write(bytes([0xCC, p1_score, p2_score, 0x55]))`
  3. Reset ball to centre, pause 1.0 second, re-launch.
  4. Reset `power_shot_available` and `shrink_available` for both players.
- On match win (7 points reached):
  1. Show `"PLAYER X WINS!"` text for 3 seconds.
  2. Play win sound.
  3. Reset all scores to 0, return to serve.

### 8.7 Game mechanics

#### KEY[0] (FPGA) / Space (keyboard) — Power Shot

- Available once per point per player. Resets on each point.
- On press (rising edge):
  - If `power_shot_available[player]`:
    - Set `power_shot_pending[player] = True`.
    - Visual: that player's paddle turns **cyan** until the next hit.
  - If not available: no effect.
- On next ball hit while pending:
  - Apply 1.4× speed boost to ball's `vx`.
  - Clear `power_shot_pending[player]` and `power_shot_available[player]`.
  - Visual: brief white trail on ball for 0.3 seconds (last 6 ball positions drawn fading).

```python
power_shot_available = [True, True]  # reset each point
power_shot_pending   = [False, False]
```

#### KEY[1] (FPGA) / Enter (keyboard) — Shrink Debuff

- Available once per point per player. Resets on each point.
- On press:
  - If `shrink_available[player]`:
    - Set `shrink_active[opponent] = True` with a 3.0 second timer.
    - Opponent's `PADDLE_H` drops from 80 → 48 px immediately.
    - Opponent's paddle flashes **red** for the duration.
    - `shrink_available[player] = False`.

```python
shrink_available = [True, True]
shrink_active    = [False, False]
shrink_timer     = [0.0, 0.0]   # seconds remaining
```

#### SW[0] — Multi-ball

- When `SW[0]` high: 2 seconds after each serve, a second ball spawns from centre.
- Both balls travel independently.
- A point is scored whenever either ball exits the field — all balls reset.
- On-screen label: `"2-BALL"` in top-left when active.

#### SW[1] — Narrow Paddle Mode

- When `SW[1]` high: both paddles are 50 px tall instead of 80 px (baseline shrunk state).
- Takes effect immediately when switch is flipped.
- On-screen label: `"NARROW"` when active.
- Shrink debuff still applies on top (50 → 30 px).

#### SW[9:8] — Ball Speed Preset

Applied at next serve (not mid-rally).

| SW[9:8] | Ball speed (px/frame) | Label |
|---------|----------------------|-------|
| `00` | 5 | SLOW |
| `01` | 7 | NORMAL |
| `10` | 10 | FAST |
| `11` | 14 | INSANE |

Speed displayed in bottom-right of screen: `SPEED: FAST`.

### 8.8 Visual design

| Element | Colour | Notes |
|---------|--------|-------|
| Background | `#000000` black | |
| Paddles | `#FFFFFF` white | |
| Paddle (power shot ready) | `#00FFFF` cyan | |
| Paddle (shrunk + debuffed) | `#FF4444` red | |
| Ball | `#FFFFFF` white | |
| Ball trail | `#FFFFFF` fading | 6 past positions, alpha 200→20 |
| Centre line | `#222222` dashes | every 20px, 4px wide |
| Score text | `#FFFFFF` | `pygame.font.SysFont("monospace", 36, bold=True)` |
| Modifier labels | `#888888` | small font, bottom-left |
| Scanline overlay | semi-transparent black | horizontal line every 2 rows, alpha=25 |

CRT scanline implementation:

```python
scanline_surf = pygame.Surface((SCREEN_W, SCREEN_H), pygame.SRCALPHA)
for y in range(0, SCREEN_H, 2):
    pygame.draw.line(scanline_surf, (0, 0, 0, 25), (0, y), (SCREEN_W, y))
# Draw this surface last, every frame:
screen.blit(scanline_surf, (0, 0))
```

### 8.9 Sounds (procedural, no audio files)

```python
import numpy as np, pygame

def make_beep(freq_hz, duration_ms, sample_rate=44100):
    n = int(sample_rate * duration_ms / 1000)
    t = np.linspace(0, duration_ms / 1000, n, False)
    wave = np.sign(np.sin(2 * np.pi * freq_hz * t))  # square wave
    wave = (wave * 28000).astype(np.int16)
    stereo = np.column_stack([wave, wave])
    return pygame.sndarray.make_sound(stereo)

# Pre-generate at startup:
SND_PADDLE = make_beep(440, 40)
SND_WALL   = make_beep(220, 30)
SND_POINT  = make_beep(880, 180)
SND_POWER  = make_beep(660, 60)
SND_SHRINK = make_beep(300, 140)
SND_WIN    = make_beep(523, 800)   # close enough
```

Play sounds non-blocking: `SND_PADDLE.play()`.

### 8.10 Serial parsing

```python
import serial

def open_ports(p1_port, p2_port):
    s1 = serial.Serial(p1_port, 115200, timeout=0.02)
    s2 = serial.Serial(p2_port, 115200, timeout=0.02)
    return s1, s2

def read_p1_packet(ser):
    """Non-blocking. Returns 11-byte bytearray or None."""
    if ser.in_waiting < 1:
        return None
    b = ser.read(1)
    if b != b'\xAA':
        return None
    rest = ser.read(10)
    if len(rest) == 10 and rest[-1] == 0x55:
        return bytearray(b) + bytearray(rest)
    return None

def send_score(ser1, ser2, p1, p2):
    pkt = bytes([0xCC, p1, p2, 0x55])
    ser1.write(pkt)
    ser2.write(pkt)
```

### 8.11 Game loop

```python
TARGET_FPS = 60
clock = pygame.time.Clock()

while running:
    dt = clock.tick(TARGET_FPS) / 1000.0   # seconds

    # 1. pygame events: quit, keyboard state
    for event in pygame.event.get():
        if event.type == pygame.QUIT: running = False
        if event.type == pygame.KEYDOWN:
            if event.key == pygame.K_SPACE: trigger_power_shot(P2)
            if event.key == pygame.K_RETURN: trigger_shrink(P2)

    # 2. Read FPGA packet (non-blocking)
    pkt = read_p1_packet(ser1)
    if pkt:
        update_p1_paddle(pkt)
        check_p1_buttons(pkt)   # KEY[0], KEY[1] rising edge detection
        read_switches(pkt)      # SW[9:8], SW[0], SW[1]

    # 3. Update P2 paddle from keyboard (held keys)
    update_p2_paddle_keyboard()

    # 4. Update shrink timers
    for p in [P1, P2]:
        if shrink_active[p]:
            shrink_timer[p] -= dt
            if shrink_timer[p] <= 0:
                shrink_active[p] = False

    # 5. Move ball(s)
    # 6. Collision detection
    # 7. Score detection + flash + send score packets
    # 8. Draw background, paddles, ball(s), score, centre line, modifiers
    # 9. Blit scanline overlay
    # 10. pygame.display.flip()
```

---

## 9. File Structure

```
projects/retro-pong/
├── SRS.md
├── fpga/
│   ├── retro_pong.qpf
│   ├── retro_pong.qsf
│   └── src/
│       └── pong_top.sv
├── esp32_p1/
│   ├── platformio.ini
│   └── src/main.cpp
├── esp32_p2/
│   ├── platformio.ini
│   └── src/main.cpp
└── pc/
    ├── game.py
    └── requirements.txt
```

---

## 10. Build Sequence

### Step 1 — FPGA

```powershell
# 1. Copy alive_test base
cp -r C:\Users\matro\TechCrash2026\demos\alive_test\fpga `
      C:\Users\matro\TechCrash2026\projects\retro-pong\fpga

cd C:\Users\matro\TechCrash2026\projects\retro-pong\fpga

# 2. Copy accel_cube source as starting point
cp C:\Users\matro\TechCrash2026\projects\accel-cube\fpga\src\accel_cube_top.sv `
   src\pong_top.sv

# 3. Edit pong_top.sv (rename module, change poll rate, expand packet, update LEDR/HEX)
# 4. Edit .qsf: set TOP_LEVEL_ENTITY = pong_top, update SYSTEMVERILOG_FILE
# 5. Compile
& "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_sh.exe" --flow compile retro_pong
Select-String -Path "output_files\retro_pong.map.rpt" -Pattern "Error"

# 6. Program
& "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_pgm.exe" `
    -c "USB-Blaster [USB-0]" -m JTAG -o "P;output_files\retro_pong.sof"
```

### Step 2 — ESP32_P1

```powershell
cd C:\Users\matro\TechCrash2026\projects\retro-pong\esp32_p1
pio run -t upload
```

### Step 3 — ESP32_P2

```powershell
cd C:\Users\matro\TechCrash2026\projects\retro-pong\esp32_p2
pio run -t upload
```

### Step 4 — PC game

```powershell
cd C:\Users\matro\TechCrash2026\projects\retro-pong\pc
pip install -r requirements.txt
# Identify COM ports: ESP32_P1 = COM3, ESP32_P2 = COM4 (adjust as needed)
python game.py --p1port COM3 --p2port COM4
```

---

## 11. Verification Checklist

Run these in order. Do not skip steps.

- [ ] **FPGA compiles clean**: no errors in `.map.rpt` or `.fit.rpt`
- [ ] **FPGA programmed**: LEDR bar lights up when board is tilted
- [ ] **P1 packet arrives at ESP32_P1**: open `pio device monitor` on ESP32_P1, confirm hex output starts with `AA` and ends with `55`, length 11
- [ ] **ay bytes change with tilt**: bytes [3:4] change as you tilt board forward/back
- [ ] **KEY bytes work**: press KEY[0], confirm bit 0 of byte [7] goes to 1
- [ ] **SW bytes work**: set SW[0]=1, confirm byte [8] bit 0 = 1
- [ ] **ESP32_P1 forwards to PC**: run `python -c "import serial; s=serial.Serial('COM3',115200); [print(s.read(11).hex()) for _ in range(5)]"` — should see 11-byte packets
- [ ] **PC game launches**: `python game.py --p1port COM3 --p2port COM4` — window opens, no crash
- [ ] **P1 paddle tracks tilt**: tilt board, left paddle moves smoothly
- [ ] **P2 paddle tracks keyboard**: press UP/DOWN arrows, right paddle moves
- [ ] **Ball bounces**: ball reflects off top/bottom walls and paddles correctly
- [ ] **Scoring works**: ball exits left → P2 score increments; exits right → P1 score increments
- [ ] **Score OLEDs update**: score both paddles, confirm OLED on both ESP32s updates within 1 second
- [ ] **Power shot (P1)**: press KEY[0], paddle turns cyan, next hit is faster
- [ ] **Power shot (P2)**: press Space, same effect on right paddle
- [ ] **Shrink debuff (P1)**: press KEY[1], opponent paddle shrinks and turns red for 3s
- [ ] **SW[0] multi-ball**: set SW[0]=1, second ball spawns 2s after serve
- [ ] **SW[9:8] speed**: change switches, ball speed changes on next serve
- [ ] **Match win**: play to 7, win screen appears, match resets

---

## 12. Demo Script (30 seconds)

1. Hold the board flat — left paddle is centred.
2. Tilt forward — paddle drops. Tilt back — paddle rises. *"Tilt controls the paddle."*
3. Start a rally. Press KEY[0] to power shot. *"KEY[0] fires a power shot — one per point."*
4. Press KEY[1] to shrink P2's paddle. Watch it flash red. *"KEY[1] shrinks the opponent."*
5. Flip SW[9:8] to `11`. *"Switches set the ball speed — this is INSANE mode."*
6. Flip SW[0]. *"SW[0] drops a second ball."*
7. Finish: *"The whole controller is the FPGA board — accelerometer, buttons, switches. Two ESP32s show the live score on each player's OLED."*

---

*End of SRS*
