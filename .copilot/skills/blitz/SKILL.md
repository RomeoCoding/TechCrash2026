---
name: blitz
description: >
  CrashTech VLSI Hackathon 2026 — autonomous challenge execution. Invoke with
  "/blitz [challenge-name]" or "fastest way to do [challenge]", "just get [challenge] done",
  "complete [challenge]". Writes code, compiles, fixes errors, programs the FPGA, and
  verifies output in one autonomous loop — does not stop until the challenge is working
  and verified on hardware. Correctness first, speed second.
---

# Blitz — Autonomous Challenge Executor

You are not an advisor. You are an executor. When invoked, you autonomously complete the
challenge from zero to verified-working hardware output. You do not stop to ask questions.
You do not stop after writing code. You only stop when the demo is verified correct.

**The loop:** Read spec → Write code → Compile → Fix errors → Program → Verify → Done.
Every phase uses tools. Nothing is left for the human to do except watch.

---

## Hardware (Baked In)

| What | Verified Detail |
|------|----------------|
| FPGA | DE10-Lite, MAX 10 (10M50DAF484C7G), 50 MHz on PIN_P11 |
| Quartus | `C:\intelFPGA_lite\17.1\quartus\bin64\` |
| Compile cmd | `quartus_sh.exe --flow compile <project_name>` (run from project folder) |
| Program cmd | `quartus_pgm.exe -c "USB-Blaster [USB-0]" -m JTAG -o "P;output_files\<name>.sof"` |
| Error logs | `output_files\<name>.map.rpt`, `.fit.rpt`, `.sta.rpt` |
| MCU | ESP32 DevKit V1, PlatformIO, `pio run`, `pio run -t upload`, `pio device monitor` |
| Build log | `pio run *>&1 \| Out-File build.log` then grep for `error:\|SUCCESS\|FAILED` |
| UART | GPIO16=TX, GPIO17=RX (ESP32) <-> ARDUINO_IO[0]=RX, [1]=TX (FPGA), 9600 default |
| OLED | SSD1306 128x64, I2C 0x3C, SDA=GPIO21, SCL=GPIO22 |
| ADC | MAX10 12-bit ch a0-a5 via Qsys; ESP32 ADC on GPIO34 |
| VGA | 640x480 @ 60Hz, 4-bit RGB |
| Accel | ADXL345 SPI onboard |

---

## Execution Protocol — Run All Phases, Stop Only When Verified

---

### PHASE 0 — Read the Challenge Spec

Before writing a single line of code:

1. Read `challenges_public/<challenge-name>/` — read every file in it
2. Identify exactly:
   - What input the grader provides (signal, file, serial data, button, voltage level)
   - What output the grader measures (waveform, serial response, display content, timing)
   - The pass/fail criterion or performance metric
   - Any interface constraints (baud rate, protocol, timing spec)
3. If the challenge is `full` mode (fp8-adder, speed-loopback), read the provided starter
   code before writing anything — the answer may be largely there already

Do not proceed until you have answered: *"What exactly must appear on the hardware for this
challenge to be marked correct?"*

---

### PHASE 0.5 — Hardware Wiring Check

Before writing code, confirm physical wiring for the challenge. A wrong wire = wrong reading = failed demo. Takes 60 seconds.

**Reference diagrams (open in VS Code preview):**
- `images/esp32-pinmap.svg` — full ESP32 kit wiring with all peripherals labeled
- `images/jp1-pinout.svg` — DE10-Lite JP1 header (UART pins + GND location)
- `images/servo-wiring.svg` — servo connector wiring

---

**Per-challenge wiring tables:**

#### volt-meter (ESP32 ADC → OLED)
| Wire | From | To | Note |
|------|------|----|------|
| SDA | OLED SDA | GPIO 21 | I2C data |
| SCL | OLED SCL | GPIO 22 | I2C clock |
| VCC | OLED VCC | ESP32 3V3 | power |
| GND | OLED GND | ESP32 GND | ground |
| SIG | Voltage source | GPIO 34 | MAX 3.3V — use 10kΩ/10kΩ divider for higher voltages |

> GPIO 34 is input-only. Never exceed 3.3V. For 0–5V range: divider → 0–2.5V on GPIO 34.

#### fpga-voltmeter (MAX10 internal ADC)
No external wiring for ADC — MAX10 ADC inputs are on the onboard JP2 header.
Check challenge spec for which ADC channel. No ESP32 needed.

#### speed-loopback (ESP32 ↔ FPGA UART)
| Wire | From | To | Note |
|------|------|----|------|
| TX→RX | GPIO 16 | FPGA JP1 pin 1 (IO0) | ESP32 TX → FPGA RX |
| RX←TX | GPIO 17 | FPGA JP1 pin 2 (IO1) | FPGA TX → ESP32 RX |
| GND | ESP32 GND | FPGA JP1 pin 12 | shared ground — REQUIRED |

> JP1 pin 1 has a gold triangle marker on board silkscreen. Use male-to-male jumper wires.

#### accel-cube (ADXL345 + VGA)
ADXL345 is onboard DE10-Lite — no external wiring. Connect VGA cable to monitor.

#### fft-freq / fft-freq-ip
Input signal → MAX10 ADC via JP2 header. Check challenge spec for channel number.

#### pc-fluppy
USB-B: PC → DE10-Lite (programming). USB-A: PC → ESP32 (serial bridge). VGA: FPGA → monitor.

#### press-right
Onboard SW/KEY only — no external wires needed.

---

**Critical GND rule:** If ESP32 and FPGA are in the same circuit, they MUST share GND.
One wire: ESP32 GND pin → FPGA JP1 pin 12. Without this, UART signals will not work.

---

### PHASE 1 — Plan (2 minutes max)

State:
- Owner: FPGA-only / ESP32-only / Both
- Modules needed (list each Verilog module or ESP32 firmware component)
- Which skill file provides the best starting template for each
- Integration needed between FPGA and ESP32? (yes/no — if yes, UART framing required)
- Estimated Quartus compile count: target ONE. Every extra compile is 5-10 min lost.

Principle: write code that compiles on the FIRST try. Use known-working patterns from
skill files. Do not invent new RTL patterns under time pressure.

---

### PHASE 2 — Write Code

**For FPGA challenges — always start from the alive_test template, never from scratch:**

```powershell
# Copy the verified working base project into the challenge folder
cp -r C:\Users\matro\TechCrash2026\demos\alive_test\fpga challenges\<name>\fpga
```

This gives you a `.qpf`, a fully-pinned `.qsf` (every DE10-Lite pin already assigned and
verified), and a compiling top-level — for free. Rename the project and top entity, then
replace the body of the top module with your logic. This eliminates an entire class of
pin-assignment and project-setup errors and saves 10-15 minutes of setup time.

Then write only what changes:
- `src/<top>.sv` — replace alive_test_top.sv content, keep port list as starting point
- `src/<module>.sv` — one file per additional module
- Update `.qsf` TOP_LEVEL_ENTITY and add new source files

**If the challenge has a starter (fp8-adder, speed-loopback):**
Read and use that starter instead — it supersedes alive_test as the base.

**Mandatory .qsf header (if not using alive_test base):**
```tcl
set_global_assignment -name FAMILY "MAX 10"
set_global_assignment -name DEVICE 10M50DAF484C7G
set_global_assignment -name TOP_LEVEL_ENTITY <top_entity_name>
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name LAST_QUARTUS_VERSION "17.1.0 Lite Edition"
```

**For ESP32 challenges:**
- `platformio.ini` — use the verified template
- `src/main.cpp` — complete, no TODOs
- Include `pin_config.h` path: `../../../../projects/common/esp32/pin_config.h`

**Verified platformio.ini template:**
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

**Code quality rules (enforce these — they prevent the most common compile failures):**
- All FSM states must be covered in case statements — add `default: state <= IDLE;`
- No latches: every combinational output must have a default assignment before the case
- All module ports declared in the top-level instantiation
- No implicit nets — always use `wire` or `reg` declarations
- `ARDUINO_IO[15:2]` must be driven or set to high-Z: `assign ARDUINO_IO[15:2] = 14'bz;`
- Double-flop all async inputs: buttons, switches, UART RX

---

### PHASE 3 — Compile Loop (FPGA)

**Step 3a — Quick syntax check first (catches ~80% of errors in under 60 seconds):**

```powershell
cd <project_folder>
& "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_sh.exe" --flow elaboration <project_name>
Select-String -Path "output_files\<name>.map.rpt" -Pattern "Error"
```

Fix any errors reported, then proceed to full compile. Do not run full compile until
elaboration is clean — this prevents wasting 5-10 min compiling broken RTL.

**Step 3b — Full compile:**

```powershell
& "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_sh.exe" --flow compile <project_name>
```

**After each compile, check:**
```powershell
# Check for errors
Select-String -Path "output_files\<name>.map.rpt" -Pattern "Error"
Select-String -Path "output_files\<name>.fit.rpt" -Pattern "Error"
```

**Error → Fix mapping (apply immediately, no searching):**

| Error pattern | Root cause | Fix |
|---------------|-----------|-----|
| `Can't find port` | Port name mismatch between module def and instantiation | Match exactly |
| `Latch inferred` | Combinational output not assigned in all branches | Add `default:` or assign before case |
| `Undefined variable` | Wire/reg not declared | Add `wire`/`reg` declaration |
| `can't resolve` / `unknown module` | Module file not added to .qsf | Add `set_global_assignment -name SYSTEMVERILOG_FILE src/<file>.sv` |
| `I/O pin ... has no location` | Pin not in .qsf | Add pin assignment from de10lite-board-and-build skill |
| `Timing requirements not met` | Setup/hold violation | See timing section below |

**Timing violations — assess before panicking:**
- Read `output_files/<name>.sta.rpt`, find "Timing Summary" section
- If Fmax slack > -1.0 ns: likely still works in practice — program and test
- If Fmax slack < -2.0 ns: real risk of malfunction — add pipeline register or reduce logic depth
- Critical path almost always in: combinational logic chains > 8 levels, or missing register stage

**Compile loop exit criteria:** No `Error` lines in `.map.rpt` or `.fit.rpt`. Timing violations
assessed and either fixed or accepted as low-risk.

---

**While Quartus is compiling (Step 3b) — do not wait idle:**
If the challenge has an ESP32 component, start Phase 4 in a second terminal immediately
after kicking off the full compile. FPGA compile and ESP32 build run in parallel.
If FPGA-only, use the compile time to write the verification test or set up the video shot.

---

### PHASE 4 — Build Loop (ESP32)

```powershell
cd <esp32_project_folder>
pio run *>&1 | Out-File build.log -Encoding ascii
Select-String -Path build.log -Pattern "error:|SUCCESS|FAILED|RAM:|Flash:"
```

**If errors:** Read the error line, fix in `src/main.cpp`, rerun. Do not rerun without fixing.

**Common ESP32 compile errors:**
| Error | Fix |
|-------|-----|
| `undefined reference to` | Missing `#include` or lib not in `lib_deps` |
| `was not declared in this scope` | Wrong function name or missing header |
| `Serial port not found` | `upload_port` not set — add `upload_port = COM4` to platformio.ini |
| Boot loop (`rst:0x3` repeating) | Hardware object constructed globally — move to `setup()` |

**Upload:**
```powershell
# Kill any serial monitor holding the port first
Get-Process python* | Where-Object {
    (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -match "monitor"
} | Stop-Process -Force
pio run -t upload
```

---

### PHASE 5 — Program FPGA

**Step 5a — Announce readiness at full volume (built-in Windows TTS, no install needed):**

```powershell
Add-Type -AssemblyName System.Speech
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
$s.Volume = 100
$s.Speak("Challenge <challenge-name> is ready to program")
```

Fill in the actual challenge name. The team hears this across the room without watching screens.

**Step 5b — Program:**

```powershell
& "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_pgm.exe" -c "USB-Blaster [USB-0]" -m JTAG -o "P;output_files\<name>.sof"
```

If programmer not found:
```powershell
& "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_pgm.exe" --list
# Must show: 1) USB-Blaster [USB-0]
# If not: check USB cable, driver at C:\intelFPGA_lite\17.1\quartus\drivers\usb-blaster
```

**Step 5c — Announce programmed:**

```powershell
$s.Speak("Challenge <challenge-name> is programmed. Verify now.")
```

---

### PHASE 6 — Verify (Do Not Skip)

This phase confirms the challenge is actually passing. Each challenge type has specific
verification criteria:

**For display challenges (VGA, OLED, 7-seg):**
- Check visual output matches the challenge spec exactly
- Look for: correct values, no glitching, stable sync (VGA), no I2C errors (OLED)

**For communication challenges (UART, SPI):**
- Open serial monitor: `pio device monitor --filter=direct`
- Send the test input specified in the challenge brief
- Confirm response matches expected format and values

**For measurement challenges (ADC, voltmeter):**
- Apply a known reference (measure with multimeter first)
- Confirm displayed/transmitted value matches within acceptable tolerance
- Test at least two different input values

**For computation challenges (fp8-adder, FFT):**
- Run with the test vectors provided in the challenge brief
- Confirm output matches reference values bit-for-bit (Go/No-Go) or within spec (Performance)

**For performance challenges (speed-loopback, fft-freq):**
- Measure the actual metric (throughput in bytes/sec, frequency accuracy in Hz)
- Compare against the baseline and bonus thresholds in the challenge brief
- Record the number — you need it for the video

**Verification failed → back to Phase 2.** Do not record a video of a failing demo.
Identify the specific mismatch, fix the code, recompile, reprogram, re-verify.

---

### PHASE 7 — Record and Submit

Only when Phase 6 passes:

**Video setup:**
- Phone on stable surface (stack of books, not hand-held)
- VGA: shoot at 45° angle to the screen, room lighting off if possible, lock phone exposure
- OLED: dim room, phone within 20cm, fill frame with the display
- 7-seg / LEDs: straight on, good ambient light
- Duration: 10-20 seconds max. Show the output working in the first 3 seconds.
- For performance challenges: show the metric number prominently in frame

**What to show in the video:**
1. First 3 seconds: the working output (don't build up to it)
2. Interact with the system if possible (press a button, change an input)
3. For performance: show the measured score on screen or say it aloud

**Upload immediately after recording.** Do not batch recordings.

---

## Key Principles

**Correctness over speed.** A fast incorrect submission earns zero. A correct slow submission
earns base points. Run verification every time.

**Fix errors immediately.** Read the error message, apply the fix from the table, recompile.
Do not search the internet. Do not try alternatives. The error tables above cover 95% of cases.

**One compile, one fix.** Never make multiple speculative changes between compiles. Change
exactly the thing the error points to. This makes debugging deterministic.

**Record early, improve later.** The moment the demo is verified correct — record a video.
Then continue improving. You have a submitted baseline; improvement is upside.
