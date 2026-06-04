# Challenge 5 — FPGA Volt-Meter

> **Safety first — never apply more than 3.3 V to Arduino A0.  
> Higher voltages will permanently damage the FPGA.**

---

## What this challenge does

A working digital voltmeter built from two chips:

| Part | Job |
|------|-----|
| **MAX 10 FPGA** | Reads the analog voltage on Arduino header pin A0 using the on-chip 12-bit ADC, converts the raw count to millivolts, shows the voltage on the 7-segment displays (`X.XX`), drives a 10-LED bar graph, and streams `V=X.XX\n` to the ESP32 over UART at 9600 baud. |
| **ESP32** | Receives the UART string, parses it, and shows the voltage in large text on the OLED display. |

Turn the potentiometer and watch the 7-segment display, LEDs, and OLED all update live.

---

## Folder structure

```
challenge_5_fpga_voltmeter/
├── fpga/
│   ├── fpga_voltmeter.qsf          Quartus project + pin assignments
│   └── src/
│       ├── fpga_voltmeter_top.sv   Top-level module
│       ├── adc_wrapper.sv          ADC IP wrapper (read me first!)
│       └── uart_tx.sv              UART transmitter (9600 8N1)
└── esp32/
    ├── platformio.ini
    └── src/
        └── main.cpp                UART receive + OLED display
```

---

## Required hardware

- DE10-Lite FPGA board
- ESP32 dev board
- SSD1306 OLED (128 × 64, I2C)
- 10 kΩ potentiometer (any value 1 kΩ–100 kΩ works)
- Breadboard + jumper wires

---

## Wiring

### Potentiometer → FPGA

| Pot pin | Connect to |
|---------|-----------|
| Left leg | FPGA 3.3 V rail (Arduino header **3V3** pin) |
| Right leg | GND |
| Wiper (middle) | FPGA Arduino header **A0** |

### FPGA → ESP32

| FPGA pin | ESP32 pin | Purpose |
|----------|-----------|---------|
| Arduino IO1 (TX) | GPIO 16 (RX2) | UART data |
| GND | GND | Common ground (required!) |

### ESP32 → OLED

| OLED pin | ESP32 pin |
|----------|-----------|
| SDA | GPIO 21 |
| SCL | GPIO 22 |
| VCC | 3.3 V |
| GND | GND |

---

## Compiling and uploading the FPGA bitstream

### Step 1 — Generate the MAX 10 ADC IP

> This is a one-time step. The ADC inside the MAX 10 requires a
> Quartus-generated IP core; it cannot be instantiated by hand.

1. Open Quartus Prime Lite (≥ 17.1).
2. Open the project: **File → Open Project** → select `fpga/fpga_voltmeter.qsf`.
3. Go to **Tools → Platform Designer** (formerly Qsys).
4. In the IP Catalog, search for **MAX 10 ADC** and double-click it.
5. Configure:
   - Prescaler: `10` (gives 5 MHz ADC clock from 50 MHz)
   - Channels: `1`, Channel 0 = `SINGLE_ENDED`
   - Resolution: `12 bit`
6. Click **Generate HDL…**, save files into `fpga/ip/max10_adc/`.
7. Back in Quartus, add the generated `.qip` file:
   **Project → Add/Remove Files** → browse to `fpga/ip/max10_adc/max10_adc.qip`.
8. Open `fpga/src/adc_wrapper.sv` and replace the `// TODO` placeholder
   with the generated instantiation (copy from `max10_adc_inst.v`).
9. Update `fpga_voltmeter.qsf`: uncomment the `QIP_FILE` line and set
   the correct path.

### Step 2 — Compile

Press **Ctrl + L** (Start Compilation) or click the blue ▶ button.  
Compilation takes ~2 minutes. Fix any errors shown in the Messages pane.

### Step 3 — Upload

1. Connect the DE10-Lite via USB-Blaster cable.
2. Go to **Tools → Programmer**.
3. Click **Auto Detect**, select the MAX 10 device.
4. Check the `.sof` file in `output_files/` is listed.
5. Click **Start**.

The FPGA now runs the voltmeter. The 7-segment displays should show
`0.00` if nothing is connected to A0.

---

## Uploading the ESP32 firmware

1. Open the `esp32/` folder in VS Code with PlatformIO installed.
2. Connect the ESP32 via USB.
3. Click **Upload** (→ button in the PlatformIO toolbar) or run:
   ```
   pio run --target upload
   ```
4. Open the Serial Monitor at 115200 baud to see debug output.

---

## Testing with a potentiometer

1. Wire the potentiometer as shown in the wiring table above.
2. Power both boards.
3. Rotate the potentiometer:
   - **Turned to GND end** → display shows `0.00`, no LEDs lit.
   - **Turned to middle** → display shows `~1.65`, ~5 LEDs lit, OLED shows ~1.65 V.
   - **Turned to 3.3 V end** → display shows `3.30`, all 10 LEDs lit, OLED shows 3.30 V.
4. The OLED and 7-segment should track each other in real time.

### Expected UART messages (Serial Monitor)

```
[FPGA] V=0.00
[FPGA] V=0.81
[FPGA] V=1.65
[FPGA] V=2.47
[FPGA] V=3.30
```

---

## How the voltage conversion works

The MAX 10 ADC produces a 12-bit number (0 – 4095):

```
millivolts = adc_raw × 3300 / 4095
```

Digit extraction:

| Digit | Formula |
|-------|---------|
| Ones | `millivolts / 1000` |
| Tenths | `(millivolts / 100) % 10` |
| Hundredths | `(millivolts / 10) % 10` |

The 7-segment display format is `X.XX` — the decimal point on HEX1
(the tenths position) is always lit.

The LED bar graph:
- LED `i` (0-based) lights when `millivolts ≥ (i+1) × 330`
- So at 3.30 V all 10 LEDs are on; at 0 V none are on.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Display stuck at `0.00` | ADC IP not generated / instantiated | Follow Step 1 above |
| OLED shows "Waiting for FPGA" | UART wiring wrong | Check IO1 → GPIO16, shared GND |
| Display shows garbage | Baud rate mismatch | Both sides must be 9600 |
| All LEDs always on | A0 voltage too high | Use a 3.3 V source, not 5 V |
| OLED not found | I2C address wrong | Try 0x3D if 0x3C fails |

---

## Safety warning

> **NEVER apply more than 3.3 V to the FPGA Arduino A0 pin.**
>
> The MAX 10 analog inputs are rated for 0 V – VCCIO (3.3 V on the
> DE10-Lite).  Applying 5 V or higher will damage the FPGA
> permanently and void the kit warranty.
>
> Always power the potentiometer from the **3.3 V** rail on the
> Arduino header, not from 5 V or VIN.
