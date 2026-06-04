// Speed Loopback — ESP32 Dual-Channel SPI Slave (25 MHz × 2)
// FPGA sends 5,000 bytes per channel simultaneously on two independent
// SPI buses. ESP32 receives both in parallel, computes a partial checksum
// for each channel, and returns each checksum on its respective channel.
// FPGA verifies: (cs0 + cs1)[7:0] == expected_sum[7:0].
//
// Speedup vs 9600-baud baseline: ~6,000× (~1.75 ms vs 10.4 sec)
//
// Channel 0 wiring (HSPI — IOMUX for max speed):
//   FPGA IO[2] SCK  → ESP32 GPIO14
//   FPGA IO[3] MOSI → ESP32 GPIO13
//   FPGA IO[4] MISO ← ESP32 GPIO12
//   FPGA IO[5] CS_N → ESP32 GPIO15
//
// Channel 1 wiring (VSPI — IOMUX for max speed):
//   FPGA IO[6] SCK  → ESP32 GPIO18
//   FPGA IO[7] MOSI → ESP32 GPIO23
//   FPGA IO[8] MISO ← ESP32 GPIO19
//   FPGA IO[9] CS_N → ESP32 GPIO5

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "driver/spi_slave.h"
#include "../../../../projects/common/esp32/pin_config.h"

// ---------------------------------------------------------------------------
// Hardware constants — Channel 0 (HSPI)
// ---------------------------------------------------------------------------
#define CH0_HOST     HSPI_HOST
#define CH0_MISO     12
#define CH0_MOSI     13
#define CH0_SCK      14
#define CH0_CS       15

// ---------------------------------------------------------------------------
// Hardware constants — Channel 1 (VSPI)
// ---------------------------------------------------------------------------
#define CH1_HOST     VSPI_HOST
#define CH1_MISO     19
#define CH1_MOSI     23
#define CH1_SCK      18
#define CH1_CS        5

// ---------------------------------------------------------------------------
// Buffer sizing
// 4-byte header + 5000 data bytes = 5004 bytes per channel.
// DMA buffer must be 32-bit aligned; round up.
// ---------------------------------------------------------------------------
#define PER_CH_BYTES 5000
#define BUF_BYTES    (((4 + PER_CH_BYTES + 3) / 4) * 4)   // 5004 rounded to 5004

// ---------------------------------------------------------------------------
// DMA buffers — DRAM_ATTR forces them into DRAM (required for DMA access)
// ---------------------------------------------------------------------------
DRAM_ATTR static uint8_t rx0_buf[BUF_BYTES];
DRAM_ATTR static uint8_t rx1_buf[BUF_BYTES];
DRAM_ATTR static uint8_t tx0_buf[4];   // checksum reply ch0
DRAM_ATTR static uint8_t tx1_buf[4];   // checksum reply ch1

Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

// ---------------------------------------------------------------------------
// Initialise one SPI slave host
// ---------------------------------------------------------------------------
static void init_spi_slave(spi_host_device_t host,
                            int mosi, int miso, int sck, int cs)
{
    spi_bus_config_t buscfg = {
        .mosi_io_num     = mosi,
        .miso_io_num     = miso,
        .sclk_io_num     = sck,
        .quadwp_io_num   = -1,
        .quadhd_io_num   = -1,
        .max_transfer_sz = BUF_BYTES,
    };
    spi_slave_interface_config_t slvcfg = {
        .spics_io_num   = cs,
        .flags          = 0,
        .queue_size     = 2,    // need at least 1 queued per phase (RX + TX)
        .mode           = 0,    // SPI Mode 0: CPOL=0, CPHA=0
        .post_setup_cb  = NULL,
        .post_trans_cb  = NULL,
    };
    ESP_ERROR_CHECK(spi_slave_initialize(host, &buscfg, &slvcfg, SPI_DMA_CH_AUTO));
}

// ---------------------------------------------------------------------------
// setup()
// ---------------------------------------------------------------------------
void setup()
{
    Serial.begin(115200);
    Serial.println("\n--- Speed Loopback Dual-Channel SPI Slave (25 MHz x2) ---");

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println("OLED init failed");
    }
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback");
    display.println("2x SPI 25MHz ~6000x");
    display.println("Waiting for FPGA...");
    display.display();

    init_spi_slave(CH0_HOST, CH0_MOSI, CH0_MISO, CH0_SCK, CH0_CS);
    init_spi_slave(CH1_HOST, CH1_MOSI, CH1_MISO, CH1_SCK, CH1_CS);
}

// ---------------------------------------------------------------------------
// loop()
// ---------------------------------------------------------------------------
void loop()
{
    // -----------------------------------------------------------------------
    // Phase 1 — Receive: queue BOTH channels before waiting on either.
    // Both SPI DMA engines run in parallel while we block on get_trans_result.
    // -----------------------------------------------------------------------
    memset(rx0_buf, 0, sizeof(rx0_buf));
    memset(rx1_buf, 0, sizeof(rx1_buf));

    spi_slave_transaction_t t0_rx = {};
    t0_rx.length    = BUF_BYTES * 8;
    t0_rx.rx_buffer = rx0_buf;
    t0_rx.tx_buffer = NULL;

    spi_slave_transaction_t t1_rx = {};
    t1_rx.length    = BUF_BYTES * 8;
    t1_rx.rx_buffer = rx1_buf;
    t1_rx.tx_buffer = NULL;

    // Queue both — non-blocking
    ESP_ERROR_CHECK(spi_slave_queue_trans(CH0_HOST, &t0_rx, portMAX_DELAY));
    ESP_ERROR_CHECK(spi_slave_queue_trans(CH1_HOST, &t1_rx, portMAX_DELAY));

    // Wait for both to complete
    spi_slave_transaction_t *rx0_done, *rx1_done;
    ESP_ERROR_CHECK(spi_slave_get_trans_result(CH0_HOST, &rx0_done, portMAX_DELAY));
    ESP_ERROR_CHECK(spi_slave_get_trans_result(CH1_HOST, &rx1_done, portMAX_DELAY));

    // -----------------------------------------------------------------------
    // Parse headers and validate N
    // -----------------------------------------------------------------------
    uint32_t N0 = (uint32_t)rx0_buf[0]
                | ((uint32_t)rx0_buf[1] << 8)
                | ((uint32_t)rx0_buf[2] << 16)
                | ((uint32_t)rx0_buf[3] << 24);

    uint32_t N1 = (uint32_t)rx1_buf[0]
                | ((uint32_t)rx1_buf[1] << 8)
                | ((uint32_t)rx1_buf[2] << 16)
                | ((uint32_t)rx1_buf[3] << 24);

    if (N0 == 0 || N0 > PER_CH_BYTES || N1 == 0 || N1 > PER_CH_BYTES) {
        Serial.printf("Bad headers N0=%u N1=%u, discarding\n", N0, N1);
        return;
    }

    // -----------------------------------------------------------------------
    // Compute partial checksums (skip 4-byte header in each buffer)
    // -----------------------------------------------------------------------
    uint32_t sum0 = 0;
    for (uint32_t i = 0; i < N0; i++) sum0 += rx0_buf[4 + i];
    uint8_t cs0 = (uint8_t)(sum0 & 0xFF);

    uint32_t sum1 = 0;
    for (uint32_t i = 0; i < N1; i++) sum1 += rx1_buf[4 + i];
    uint8_t cs1 = (uint8_t)(sum1 & 0xFF);

    Serial.printf("CH0: N=%u cs=0x%02X  |  CH1: N=%u cs=0x%02X  |  combined=0x%02X\n",
                  N0, cs0, N1, cs1, (uint8_t)(cs0 + cs1));

    // -----------------------------------------------------------------------
    // Phase 2 — Send: queue BOTH checksum replies simultaneously.
    // The FPGA waits GAP_CYCLES (300 µs) then clocks 1 byte per channel.
    // -----------------------------------------------------------------------
    tx0_buf[0] = cs0;
    tx1_buf[0] = cs1;

    spi_slave_transaction_t t0_tx = {};
    t0_tx.length    = 8;            // 1 byte = 8 bits
    t0_tx.tx_buffer = tx0_buf;
    t0_tx.rx_buffer = NULL;

    spi_slave_transaction_t t1_tx = {};
    t1_tx.length    = 8;
    t1_tx.tx_buffer = tx1_buf;
    t1_tx.rx_buffer = NULL;

    // Queue both — non-blocking
    ESP_ERROR_CHECK(spi_slave_queue_trans(CH0_HOST, &t0_tx, portMAX_DELAY));
    ESP_ERROR_CHECK(spi_slave_queue_trans(CH1_HOST, &t1_tx, portMAX_DELAY));

    // Wait for both sends to complete
    spi_slave_transaction_t *tx0_done, *tx1_done;
    ESP_ERROR_CHECK(spi_slave_get_trans_result(CH0_HOST, &tx0_done, portMAX_DELAY));
    ESP_ERROR_CHECK(spi_slave_get_trans_result(CH1_HOST, &tx1_done, portMAX_DELAY));

    // -----------------------------------------------------------------------
    // Update OLED
    // -----------------------------------------------------------------------
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback 2xSPI");
    display.printf("CH0 N=%-5u cs=0x%02X\n", N0, cs0);
    display.printf("CH1 N=%-5u cs=0x%02X\n", N1, cs1);
    display.printf("Combined:     0x%02X\n", (uint8_t)(cs0 + cs1));
    display.display();
}
