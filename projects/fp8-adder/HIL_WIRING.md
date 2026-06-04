# FP8 Adder HIL Wiring

All signals are 3.3 V logic. Do not connect either board's 5 V pin to an FPGA GPIO or ESP32 GPIO. Connect at least one DE10-Lite Arduino-header GND pin to ESP32 GND before connecting signal wires.

| Purpose | DE10-Lite signal | MAX 10 pin | Direction | ESP32 DevKit pin |
| --- | --- | --- | --- | --- |
| UART telemetry, reserved RX | `ARDUINO_IO[0]` | `PIN_AB5` | ESP32 -> FPGA, unused/high-Z in this build | GPIO16 / `PIN_FPGA_TX` |
| UART telemetry TX, 9600 8N1 | `ARDUINO_IO[1]` | `PIN_AB6` | FPGA -> ESP32 | GPIO17 / `PIN_FPGA_RX` |
| `done` | `ARDUINO_IO[2]` | `PIN_AB7` | FPGA -> ESP32 | GPIO32 |
| `busy` | `ARDUINO_IO[3]` | `PIN_AB8` | FPGA -> ESP32 | GPIO33 |
| `error_flag` | `ARDUINO_IO[4]` | `PIN_AB9` | FPGA -> ESP32 | GPIO25 |
| Optional start pulse | `ARDUINO_IO[5]` | `PIN_Y10` | ESP32 -> FPGA | GPIO26 |
| Ground reference | Arduino header `GND` | board ground | shared | ESP32 `GND` |

`error_flag` asserts only after the run has finished and at least one vector failed. This is the useful HIL form of `!LEDR[0]`; it does not assert during idle/running just because the pass LED is off.

To let the ESP32 launch a run, set `SW[0]` on the DE10-Lite to ON and send `R` in the ESP32 USB serial monitor. With `SW[0]` OFF, `KEY[0]` remains the only start source.

The FPGA also sends the official fixed-measurement timer result over UART as:

```text
US,000123,OK
US,000123,FAIL
```

The ESP32 serial monitor prints CSV rows:

```text
Frequency_MHz,Microseconds,Status
210.04,123,OK
```

The current `challenge_pll.v` has no ALTPLL reconfiguration port. Use Quartus compilation sweeps for frequency tuning, then update the ESP32 frequency label with `F <MHz>` before each run.