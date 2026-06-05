// ============================================================================
// Speed Loopback v2 — ESP32 SPI Slave with DMA (Challenge 3)
// ============================================================================
// Goal  : Receive 10,000 pseudo-random bytes from an FPGA SPI master as fast
//         as possible, compute an 8-bit checksum, return it on MISO.
//
// Framework : Arduino-ESP32 (ESP-IDF v4.x underlying)
// Core pin  : SPI task pinned to Core 1 ("APP_CPU") at high FreeRTOS priority.
//             Core 0 ("PRO_CPU") runs the Arduino loop() / OLED updates.
//
// ---- FPGA-side protocol (spi_loopback_io.sv, Mode 0, 8.33 MHz) ----------------
//   TX phase  : FPGA drives CS_N LOW, streams 4-byte LE header (N=10000)
//               + 10 000 LFSR data bytes via MOSI, then CS_N HIGH.
//   Handshake : ESP32 computes checksum, queues TX trans, then asserts READY_RX.
//               FPGA unblocks when it sees READY_RX (or after 1 ms fallback).
//   RX phase  : FPGA drives CS_N LOW again, clocks 8 dummy bits while ESP32
//               drives the 1-byte checksum on MISO. CS_N HIGH → done.
//
// ---- Pin wiring (FPGA DE10-Lite Arduino header ↔ ESP32 DevKit) ---------------
//   ARDUINO_IO[13]  SCK      → ESP32 GPIO18   VSPI CLK  (input  to ESP32)
//   ARDUINO_IO[11]  MOSI     → ESP32 GPIO23   VSPI MOSI (input  to ESP32)
//   ARDUINO_IO[12]  MISO     ← ESP32 GPIO19   VSPI MISO (output from ESP32)
//   ARDUINO_IO[10]  CS_N     → ESP32 GPIO5    VSPI CS   (input  to ESP32)
//   ARDUINO_IO[2]   READY_RX ← ESP32 GPIO4    Handshake (output from ESP32)
//   GND             GND      ↔ GND (common reference — mandatory)
//
// ---- FPGA-side change required -----------------------------------------------
//   In speed_loopback_top.sv, wire ARDUINO_IO[2] to spi_loopback_io.ready_for_rx.
//   (Add:  assign ready_for_rx = ARDUINO_IO[2];  and set IO[2] as inout/input.)
// ============================================================================

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// ESP-IDF low-level APIs — available in all Arduino-ESP32 builds
#include "driver/gpio.h"
#include "driver/spi_slave.h"
#include "esp_heap_caps.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "../../../common/esp32/pin_config.h"

// ============================================================================
// ---- SPI pin definitions (VSPI / SPI3 hardware peripheral) -----------------
// ============================================================================
// VSPI is preferred: it shares no silicon with the flash interface (SPI0/1)
// and its DMA channel (1 or 2) is independent of the boot ROM DMA.
// These are the hardware-native VSPI pins on ESP32; remapping is possible
// but adds one mux delay — avoid it for >10 MHz operation.
// ============================================================================
#define PIN_SPI_SCK      18   // VSPI CLK  — input from FPGA master
#define PIN_SPI_MOSI     23   // VSPI MOSI — input from FPGA master
#define PIN_SPI_MISO     19   // VSPI MISO — output to   FPGA master
#define PIN_SPI_CS        5   // VSPI CS_N — active-low, input from FPGA
#define PIN_READY_RX      4   // Handshake output → FPGA ready_for_rx input

// ============================================================================
// ---- Transfer geometry -----------------------------------------------------
// ============================================================================
#define HEADER_BYTES      4          // 32-bit LE "N" header prepended by FPGA
#define DATA_BYTES    10000          // Pseudo-random payload
#define TOTAL_BYTES   (HEADER_BYTES + DATA_BYTES)   // 10004

// DMA buffer size rules:
//   1. Must be a multiple of 4 bytes (32-bit DMA word alignment).
//   2. 10004 % 4 == 0  ✓  — no padding needed here.
//   3. If DATA_BYTES ever changes, round up: ((n+3) & ~3)
#define DMA_BUF_SIZE  TOTAL_BYTES   // 10004 bytes

// DMA channel: 1 or 2 are valid for ESP32 SPI slave.
// Channel 1 is used here; if another peripheral already claims it at runtime
// you will see ESP_ERR_INVALID_STATE from spi_slave_initialize — switch to 2.
#define SPI_DMA_CHAN     1

// ============================================================================
// ---- DMA buffers -----------------------------------------------------------
// ============================================================================
// rx_buf: allocated at runtime with MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL so
//   it lands in internal DRAM below 0x3FFE_0000 — the only region the DMA
//   engine can address. PSRAM (MALLOC_CAP_SPIRAM) is NOT DMA-accessible on
//   the plain ESP32 (it is on ESP32-S3, but not here).
//
// tx_buf: 4 bytes, statically declared with __attribute__((aligned(4))).
//   Static globals live in .data/.bss in internal DRAM — DMA-safe.
//   The extra 3 padding bytes satisfy the 32-bit alignment requirement.
// ============================================================================
static uint8_t *rx_buf = nullptr;
static uint8_t  tx_buf[4] __attribute__((aligned(4)));  // [0] = checksum byte

// ============================================================================
// ---- Shared display state (Core 0 reads, Core 1 writes atomically) ---------
// ============================================================================
static volatile uint32_t g_round    = 0;
static volatile uint8_t  g_checksum = 0;
static volatile uint32_t g_N        = 0;

static Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

// ============================================================================
// compute_checksum()
// ============================================================================
// IRAM_ATTR: places the function body in internal RAM (IRAM), bypassing the
//   instruction cache entirely. Flash-cached code has worst-case ~80 cycle
//   misses per cache line; IRAM is always 1-cycle fetch at 240 MHz.
//   For 10000 bytes with 4x unrolling: ~2500 iterations ≈ 40 µs at 240 MHz.
//
// Algorithm: accumulate into four independent uint32_t sums (acc0..acc3) to
//   allow the CPU's out-of-order pipeline to overlap four independent ADD
//   chains. A single accumulator creates a serial dependency chain limited
//   to one ADD per cycle; four sums saturate the two ALU units on Xtensa LX6.
// ============================================================================
static IRAM_ATTR uint8_t compute_checksum(const uint8_t * __restrict__ buf,
                                           uint32_t len)
{
    uint32_t acc0 = 0, acc1 = 0, acc2 = 0, acc3 = 0;
    const uint8_t *p   = buf;
    const uint8_t *end = buf + (len & ~3u);   // round down to 4-byte boundary

    // Main loop: 4 bytes per iteration, no cross-iteration dependency
    while (p < end) {
        acc0 += p[0];
        acc1 += p[1];
        acc2 += p[2];
        acc3 += p[3];
        p += 4;
    }
    // Tail: 0-3 remaining bytes
    switch (len & 3u) {
        case 3: acc2 += p[2]; /* fall through */
        case 2: acc1 += p[1]; /* fall through */
        case 1: acc0 += p[0]; /* fall through */
        default: break;
    }

    // Merge four 32-bit accumulators; only the low 8 bits matter
    return (uint8_t)((acc0 + acc1 + acc2 + acc3) & 0xFF);
}

// ============================================================================
// spi_slave_task() — Core 1
// ============================================================================
// All time-critical work lives here. Core 1 is otherwise idle (the Arduino
// scheduler does not use it by default), so we get deterministic latency.
// ============================================================================
static void spi_slave_task(void * /*arg*/)
{
    // ------------------------------------------------------------------
    // 1. Configure VSPI bus
    // ------------------------------------------------------------------
    // max_transfer_sz: hint to the driver for internal DMA descriptor
    //   allocation. Set it to our exact payload size.
    // quadwp / quadhd: not used in standard SPI; set to -1.
    // ------------------------------------------------------------------
    spi_bus_config_t buscfg = {};
    buscfg.mosi_io_num      = PIN_SPI_MOSI;
    buscfg.miso_io_num      = PIN_SPI_MISO;
    buscfg.sclk_io_num      = PIN_SPI_SCK;
    buscfg.quadwp_io_num    = -1;
    buscfg.quadhd_io_num    = -1;
    buscfg.max_transfer_sz  = DMA_BUF_SIZE;  // bytes

    // ------------------------------------------------------------------
    // 2. Configure SPI slave interface
    // ------------------------------------------------------------------
    // mode 0  : CPOL=0, CPHA=0 — data sampled on rising SCK edge,
    //           driven on falling. Matches spi_loopback_io.sv exactly.
    // queue_size 2: allows one pre-queued RX + one pre-queued TX to sit
    //   in the hardware queue simultaneously, eliminating re-arming delay.
    // ------------------------------------------------------------------
    spi_slave_interface_config_t slvcfg = {};
    slvcfg.mode         = 0;            // SPI Mode 0 (CPOL=0, CPHA=0)
    slvcfg.spics_io_num = PIN_SPI_CS;
    slvcfg.queue_size   = 2;
    slvcfg.flags        = 0;

    esp_err_t err = spi_slave_initialize(VSPI_HOST, &buscfg, &slvcfg, SPI_DMA_CHAN);
    if (err != ESP_OK) {
        Serial.printf("[SPI] init failed: %s\n", esp_err_to_name(err));
        vTaskDelete(nullptr);
        return;
    }
    Serial.printf("[SPI] VSPI slave ready. DMA ch%d, buf=%p (%u bytes)\n",
                  SPI_DMA_CHAN, rx_buf, DMA_BUF_SIZE);

    for (;;) {
        // ==============================================================
        // PHASE 1 — Receive: 4-byte header + 10 000 data bytes via DMA
        // ==============================================================
        // length is expressed in BITS. The hardware counts received SCK
        // edges; DMA stops when CS_N rises or length bits are consumed.
        // trans_len (written by the driver after completion) holds the
        // actual number of bits clocked — useful for sanity checking.
        // ==============================================================
        spi_slave_transaction_t rx_trans = {};
        rx_trans.length    = DMA_BUF_SIZE * 8;  // max bits to receive
        rx_trans.rx_buffer = rx_buf;
        rx_trans.tx_buffer = nullptr;            // slave is silent during RX phase

        // Queue the transaction, then block until it completes.
        // portMAX_DELAY: wait indefinitely for the FPGA to assert CS_N.
        spi_slave_queue_trans(VSPI_HOST, &rx_trans, portMAX_DELAY);

        spi_slave_transaction_t *ret_rx = nullptr;
        spi_slave_get_trans_result(VSPI_HOST, &ret_rx, portMAX_DELAY);
        // At this point CS_N has gone HIGH: all bytes are in rx_buf.

        // ==============================================================
        // PHASE 2 — Parse header and validate
        // ==============================================================
        uint32_t N = (uint32_t)rx_buf[0]
                   | ((uint32_t)rx_buf[1] <<  8)
                   | ((uint32_t)rx_buf[2] << 16)
                   | ((uint32_t)rx_buf[3] << 24);

        if (N == 0 || N > DATA_BYTES) {
            // Out-of-sync or partial transfer — log and retry.
            // Do NOT assert READY_RX; the FPGA will time out via GAP_CYCLES
            // and the next KEY[0] press will restart cleanly.
            Serial.printf("[SPI] bad header N=%u (trans_len=%u bits), resyncing\n",
                          N, ret_rx->trans_len);
            continue;
        }

        // ==============================================================
        // PHASE 3 — Compute checksum (IRAM-resident, 4x unrolled)
        // ==============================================================
        // Data starts at rx_buf[HEADER_BYTES]; the header itself is NOT
        // part of the checksum — the FPGA accumulates only data bytes.
        // ==============================================================
        uint32_t t0 = micros();
        uint8_t checksum = compute_checksum(rx_buf + HEADER_BYTES, N);
        uint32_t t1 = micros();

        // Store into the 4-byte aligned DMA TX buffer
        tx_buf[0] = checksum;

        // ==============================================================
        // PHASE 4 — Stage the TX transaction BEFORE signalling the FPGA
        // ==============================================================
        // Critical ordering: queue FIRST, then assert READY_RX.
        //
        // If we assert READY_RX first, the FPGA may assert CS_N and begin
        // clocking while the ESP32 hardware is still being configured for
        // the TX transaction — the byte would be lost (reads as 0x00).
        //
        // By queuing first, the SPI slave peripheral has the TX FIFO
        // loaded and is armed before the FPGA is even notified.
        // ==============================================================
        spi_slave_transaction_t tx_trans = {};
        tx_trans.length    = 8;          // 1 byte = 8 bits
        tx_trans.tx_buffer = tx_buf;     // checksum byte drives MISO
        tx_trans.rx_buffer = nullptr;    // MOSI is driven LOW (dummy) by FPGA

        spi_slave_queue_trans(VSPI_HOST, &tx_trans, portMAX_DELAY);

        // Signal FPGA: "checksum is ready on MISO, assert CS_N now"
        gpio_set_level((gpio_num_t)PIN_READY_RX, 1);

        // Wait for the FPGA to clock the checksum byte out
        spi_slave_transaction_t *ret_tx = nullptr;
        spi_slave_get_trans_result(VSPI_HOST, &ret_tx, portMAX_DELAY);

        // Deassert handshake line
        gpio_set_level((gpio_num_t)PIN_READY_RX, 0);

        // ==============================================================
        // Update shared display state (read by Core 0 loop)
        // ==============================================================
        // Writes to uint8_t/uint32_t are atomic on Xtensa; no mutex needed
        // for a read-stale-but-never-torn race.
        g_N        = N;
        g_checksum = checksum;
        g_round++;

        Serial.printf("[SPI] round=%u  N=%u  checksum=0x%02X  csum_us=%u\n",
                      (unsigned)g_round, N, checksum, (t1 - t0));
    }
    // Never reached
}

// ============================================================================
// setup() — Core 0
// ============================================================================
void setup()
{
    // Run the CPU at maximum frequency for both cores.
    // Default is 240 MHz on most Arduino-ESP32 builds; explicit call ensures it.
    setCpuFrequencyMhz(240);

    Serial.begin(115200);
    Serial.println("\n=== Speed Loopback v2: SPI Slave DMA ===");

    // ---- Configure READY_RX GPIO ------------------------------------------
    // Use ESP-IDF GPIO driver directly: faster than pinMode/digitalWrite and
    // avoids any Arduino HAL overhead in the hot path.
    gpio_config_t io_conf = {};
    io_conf.pin_bit_mask = (1ULL << PIN_READY_RX);
    io_conf.mode         = GPIO_MODE_OUTPUT;
    io_conf.pull_up_en   = GPIO_PULLUP_DISABLE;
    io_conf.pull_down_en = GPIO_PULLDOWN_DISABLE;
    io_conf.intr_type    = GPIO_INTR_DISABLE;
    gpio_config(&io_conf);
    gpio_set_level((gpio_num_t)PIN_READY_RX, 0);  // default LOW

    // ---- Allocate DMA receive buffer ----------------------------------------
    // MALLOC_CAP_DMA    : guarantees the region is accessible by the DMA engine.
    // MALLOC_CAP_INTERNAL: forces allocation in internal SRAM, not PSRAM.
    //   On ESP32 the DMA engine cannot reach PSRAM; omitting INTERNAL risks a
    //   silent heap_caps_malloc falling back to PSRAM in some configurations.
    // The returned pointer is guaranteed 32-bit aligned by the allocator when
    // MALLOC_CAP_DMA is specified.
    rx_buf = (uint8_t *)heap_caps_malloc(
        DMA_BUF_SIZE,
        MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL
    );
    if (!rx_buf) {
        Serial.println("[SPI] FATAL: DMA buffer allocation failed!");
        Serial.printf("  Requested: %u bytes\n", DMA_BUF_SIZE);
        Serial.printf("  Free DMA heap: %u bytes\n",
                      heap_caps_get_free_size(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL));
        while (1) { delay(1000); }
    }
    Serial.printf("[SPI] DMA rx_buf: %u bytes @ %p  (alignment: %s)\n",
                  DMA_BUF_SIZE, rx_buf,
                  ((uintptr_t)rx_buf % 4 == 0) ? "OK" : "FAIL");

    // ---- OLED ---------------------------------------------------------------
    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if (display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        display.clearDisplay();
        display.setTextSize(1);
        display.setTextColor(SSD1306_WHITE);
        display.setCursor(0, 0);
        display.println("Speed Loopback v2");
        display.println("SPI Slave @ 8 MHz");
        display.println("Waiting for FPGA...");
        display.display();
    } else {
        Serial.println("[OLED] init failed (non-fatal)");
    }

    // ---- Spawn SPI task on Core 1 ------------------------------------------
    // Stack: 4096 words × 4 bytes = 16 KB — ample for the SPI driver internals.
    // Priority 10: above the Arduino loop task (priority 1) and the idle task
    //   (priority 0), so it preempts everything except higher-priority ISRs.
    xTaskCreatePinnedToCore(
        spi_slave_task,   // task function
        "spi_slave",      // name (for uxTaskGetHandle / debug)
        4096,             // stack depth in 32-bit words
        nullptr,          // parameter
        10,               // priority (higher = more urgent)
        nullptr,          // task handle (not needed)
        1                 // Core 1 = APP_CPU
    );

    Serial.println("[Main] SPI task spawned on Core 1. loop() on Core 0.");
}

// ============================================================================
// loop() — Core 0
// ============================================================================
// Keep Core 0 free for display/debug. All SPI work is on Core 1.
// Reads of g_round/g_checksum/g_N are benign-racy: worst case we display
// a one-round-stale value, which is fine for a hackathon display.
// ============================================================================
void loop()
{
    static uint32_t last_round = 0;
    uint32_t r = g_round;

    if (r != last_round) {
        last_round = r;
        uint8_t  cs = g_checksum;
        uint32_t N  = g_N;

        display.clearDisplay();
        display.setTextSize(1);
        display.setTextColor(SSD1306_WHITE);
        display.setCursor(0, 0);
        display.println("Speed Loopback v2");
        display.printf("Round:    %u\n",   (unsigned)r);
        display.printf("N:        %u\n",   N);
        display.printf("Checksum: 0x%02X\n", cs);
        display.display();
    }

    delay(50);  // 20 Hz display refresh — does not affect Core 1 timing
}
