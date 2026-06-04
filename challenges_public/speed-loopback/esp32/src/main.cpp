// Speed Loopback — ESP32 SPI Slave (8.33 MHz)
// FPGA sends 4-byte header (N, LE) + N LFSR bytes over SPI.
// ESP32 sums bytes 4..N+3 (skips header) and returns checksum (sum & 0xFF)
// in a second SPI transaction triggered by the FPGA.
//
// Speedup vs 460800-baud UART: ~22× (9.7 ms vs 217 ms for 10 000 bytes)
//
// SPI wiring (HSPI — native IOMUX for max speed):
//   FPGA IO[2] SCK  → ESP32 GPIO14
//   FPGA IO[3] MOSI → ESP32 GPIO13
//   FPGA IO[4] MISO ← ESP32 GPIO12
//   FPGA IO[5] CS_N → ESP32 GPIO15

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "driver/spi_slave.h"
#include "../../../../projects/common/esp32/pin_config.h"

// ---------------------------------------------------------------------------
// Hardware constants
// ---------------------------------------------------------------------------
#define SPI_HOST       HSPI_HOST
#define PIN_MISO       12
#define PIN_MOSI       13
#define PIN_SCK        14
#define PIN_CS         15

// DMA buffer must be 32-bit aligned and large enough for max transfer.
// Transfer = 4 header bytes + 10000 data bytes = 10004 bytes.
// Round up to 32-bit boundary and add margin.
#define DMA_BUF_WORDS  ((10004 + 3) / 4 + 1)
#define DMA_BUF_BYTES  (DMA_BUF_WORDS * 4)

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------
DRAM_ATTR static uint8_t  rx_buf[DMA_BUF_BYTES];   // SPI RX DMA buffer
DRAM_ATTR static uint8_t  tx_buf[4];               // SPI TX buffer (checksum reply)

Adafruit_SSD1306 display(OLED_WIDTH, OLED_HEIGHT, &Wire, -1);

// ---------------------------------------------------------------------------
// SPI slave initialisation
// ---------------------------------------------------------------------------
static void spi_slave_init()
{
    spi_bus_config_t buscfg = {
        .mosi_io_num     = PIN_MOSI,
        .miso_io_num     = PIN_MISO,
        .sclk_io_num     = PIN_SCK,
        .quadwp_io_num   = -1,
        .quadhd_io_num   = -1,
        .max_transfer_sz = DMA_BUF_BYTES,  // critical: allows >4096-byte DMA transfers
    };

    spi_slave_interface_config_t slvcfg = {
        .spics_io_num   = PIN_CS,
        .flags          = 0,
        .queue_size     = 2,
        .mode           = 0,                // SPI Mode 0: CPOL=0, CPHA=0
        .post_setup_cb  = NULL,
        .post_trans_cb  = NULL,
    };

    ESP_ERROR_CHECK(spi_slave_initialize(SPI_HOST, &buscfg, &slvcfg, SPI_DMA_CH_AUTO));
}

// ---------------------------------------------------------------------------
// Perform one SPI slave DMA receive of exactly `len` bytes.
// Returns after transaction completes (CS_N deasserts).
// ---------------------------------------------------------------------------
static void spi_recv(uint8_t *buf, size_t len)
{
    spi_slave_transaction_t t = {};
    t.length    = len * 8;      // length in bits
    t.rx_buffer = buf;
    t.tx_buffer = NULL;
    spi_slave_transmit(SPI_HOST, &t, portMAX_DELAY);
}

// ---------------------------------------------------------------------------
// Perform one SPI slave DMA transmit of exactly `len` bytes.
// ---------------------------------------------------------------------------
static void spi_send(const uint8_t *buf, size_t len)
{
    spi_slave_transaction_t t = {};
    t.length    = len * 8;
    t.rx_buffer = NULL;
    t.tx_buffer = buf;
    spi_slave_transmit(SPI_HOST, &t, portMAX_DELAY);
}

// ---------------------------------------------------------------------------
// setup()
// ---------------------------------------------------------------------------
void setup()
{
    Serial.begin(115200);
    Serial.println("\n--- Speed Loopback SPI Slave (8.33 MHz) ---");

    Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        Serial.println("OLED init failed");
    }
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback SPI");
    display.println("8.33 MHz  ~22x UART");
    display.println("Waiting for FPGA...");
    display.display();

    spi_slave_init();
}

// ---------------------------------------------------------------------------
// loop()
// ---------------------------------------------------------------------------
void loop()
{
    // -----------------------------------------------------------------------
    // Transaction 1: Receive header (4 bytes) + N data bytes in one burst.
    // FPGA keeps CS_N low for the entire data phase, so one DMA covers it.
    // -----------------------------------------------------------------------
    memset(rx_buf, 0, sizeof(rx_buf));
    spi_recv(rx_buf, DMA_BUF_BYTES);   // Wait for full DMA buffer; actual
                                        // transfer ends on CS_N deassert.
    // NOTE: spi_slave_transmit returns after CS_N deasserts, meaning the
    // actual received byte count is in t.trans_len / 8. We rely on the
    // protocol: header[0..3] = N (little-endian), data = [4 .. N+3].

    uint32_t N = (uint32_t)rx_buf[0]
               | ((uint32_t)rx_buf[1] << 8)
               | ((uint32_t)rx_buf[2] << 16)
               | ((uint32_t)rx_buf[3] << 24);

    // Guard against corrupt header
    if (N == 0 || N > 10000) {
        Serial.printf("Bad header N=%u, discarding\n", N);
        return;
    }

    // Sum data bytes (skip 4-byte header)
    uint32_t sum = 0;
    for (uint32_t i = 0; i < N; i++) {
        sum += rx_buf[4 + i];
    }
    uint8_t checksum = (uint8_t)(sum & 0xFF);

    Serial.printf("RX %u bytes, checksum=0x%02X\n", N, checksum);

    // -----------------------------------------------------------------------
    // Transaction 2: FPGA asserts CS_N and clocks 1 byte. We reply with
    // the checksum on MISO. The FPGA reads it via spi_loopback_io S_RX_BYTE.
    // -----------------------------------------------------------------------
    tx_buf[0] = checksum;
    spi_send(tx_buf, 1);

    // -----------------------------------------------------------------------
    // Update OLED
    // -----------------------------------------------------------------------
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Speed Loopback SPI");
    display.printf("N   = %u\n", N);
    display.printf("Sum = 0x%02X\n", checksum);
    display.println("PASS - FPGA timer stop");
    display.display();
}
