# Speed Loopback — Wiring & Run Notes

Minimal solution: single UART at **115,200 baud 8N1**. Expected ~870 ms
(~12x over the 9,600-baud baseline), which clears the **50-point bar**
(must complete < 2,600 ms with a correct checksum).

## Wiring (3 wires)

DE10-Lite Arduino header  <->  ESP32 DevKit

| Signal              | FPGA (Arduino header) | ESP32        | Direction      |
|---------------------|-----------------------|--------------|----------------|
| FPGA TX -> ESP32 RX | ARDUINO_IO[1]         | GPIO17 (RX2) | FPGA -> ESP32  |
| ESP32 TX -> FPGA RX | ARDUINO_IO[0]         | GPIO16 (TX2) | ESP32 -> FPGA  |
| GND                 | any GND on header     | GND          | common ground  |

Pin numbers match `projects/common/esp32/pin_config.h`
(`PIN_FPGA_TX = 16`, `PIN_FPGA_RX = 17`).

## Protocol

1. FPGA sends 4-byte header: `N = 10000` as 32-bit little-endian (`0x00002710`).
2. FPGA sends `N` LFSR-16 pseudo-random data bytes.
3. ESP32 sums all `N` bytes, takes `& 0xFF`.
4. ESP32 sends back 1 checksum byte.
5. FPGA stops its ms timer and compares against its own `sum[7:0]`.

## Run

1. Build/flash FPGA: open `fpga/speed_loopback.qpf` in Quartus, compile,
   program the `.sof`.
2. Build/flash ESP32: `pio run -t upload` in `esp32/`.
3. On the board press **KEY[0]** to start.
   - During the run: HEX shows byte count, LEDR[9] on.
   - On completion: HEX shows elapsed time in ms, **LEDR[0] = green = PASS**.
   - Hold **SW[9]** in DONE to show `{rx_checksum, sum[7:0]}` for debugging.
   - **KEY[1]** is reset.

## Going faster (optional)

Single UART at higher baud (e.g. 921,600 -> ~110 ms, or 2 Mbaud -> ~50 ms)
just changes the `BAUD` parameter in `fpga/src/speed_loopback_top.sv` and the
`LOOP_BAUD` define in `esp32/src/main.cpp`. Dual UARTs / SPI go further but are
not needed to pass.
