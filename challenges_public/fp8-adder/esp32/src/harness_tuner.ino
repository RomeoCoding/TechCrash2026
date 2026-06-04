// FP8 Adder HIL Harness + Sweep Logger
// Board: ESP32 DevKit, Arduino framework via PlatformIO.
// Serial CSV output: Frequency_MHz,Microseconds,Status

#include <Arduino.h>
#include "../../../../projects/common/esp32/pin_config.h"

static constexpr uint32_t USB_BAUD = 115200;
static constexpr uint32_t WATCHDOG_US = 5000;
static constexpr uint32_t UART_GRACE_US = 20000;
static constexpr uint32_t START_PULSE_US = 50;

static constexpr int PIN_HIL_UART_RX = PIN_FPGA_RX;  // ESP32 GPIO17 <- FPGA ARDUINO_IO[1]
static constexpr int PIN_HIL_UART_TX = PIN_FPGA_TX;  // ESP32 GPIO16 -> FPGA ARDUINO_IO[0] reserved
static constexpr int PIN_HIL_DONE    = 32;           // ESP32 GPIO32 <- FPGA ARDUINO_IO[2]
static constexpr int PIN_HIL_BUSY    = 33;           // ESP32 GPIO33 <- FPGA ARDUINO_IO[3]
static constexpr int PIN_HIL_ERROR   = 25;           // ESP32 GPIO25 <- FPGA ARDUINO_IO[4]
static constexpr int PIN_HIL_START   = 26;           // ESP32 GPIO26 -> FPGA ARDUINO_IO[5]

HardwareSerial FpgaSerial(2);

portMUX_TYPE g_isrMux = portMUX_INITIALIZER_UNLOCKED;
volatile bool g_busyHigh = false;
volatile bool g_doneSeen = false;
volatile bool g_errorSeen = false;
volatile uint32_t g_busyRiseUs = 0;
volatile uint32_t g_busyFallUs = 0;
volatile uint32_t g_doneRiseUs = 0;
volatile uint32_t g_errorRiseUs = 0;

struct OfficialTelemetry {
    bool fresh;
    uint32_t microseconds;
    char status[8];
};

OfficialTelemetry g_official = {false, 0, "NA"};
char g_fpgaLine[48];
size_t g_fpgaLineLen = 0;
char g_usbLine[48];
size_t g_usbLineLen = 0;

float g_frequencyMHz = 210.04f;
bool g_runActive = false;
bool g_donePending = false;
bool g_reported = false;
uint32_t g_runStartUs = 0;
uint32_t g_donePendingSinceUs = 0;

void IRAM_ATTR onBusyChange()
{
    const bool high = digitalRead(PIN_HIL_BUSY);
    const uint32_t now = micros();

    portENTER_CRITICAL_ISR(&g_isrMux);
    g_busyHigh = high;
    if (high) {
        g_busyRiseUs = now;
        g_doneSeen = false;
        g_errorSeen = false;
    } else {
        g_busyFallUs = now;
    }
    portEXIT_CRITICAL_ISR(&g_isrMux);
}

void IRAM_ATTR onDoneRise()
{
    const uint32_t now = micros();

    portENTER_CRITICAL_ISR(&g_isrMux);
    g_doneSeen = true;
    g_doneRiseUs = now;
    portEXIT_CRITICAL_ISR(&g_isrMux);
}

void IRAM_ATTR onErrorRise()
{
    const uint32_t now = micros();

    portENTER_CRITICAL_ISR(&g_isrMux);
    g_errorSeen = true;
    g_errorRiseUs = now;
    portEXIT_CRITICAL_ISR(&g_isrMux);
}

static void clearOfficialTelemetry()
{
    g_official.fresh = false;
    g_official.microseconds = 0;
    strncpy(g_official.status, "NA", sizeof(g_official.status));
    g_official.status[sizeof(g_official.status) - 1] = '\0';
}

static bool parseOfficialLine(const char *line)
{
    if (strncmp(line, "US,", 3) != 0) {
        return false;
    }

    char *endPtr = nullptr;
    const uint32_t microseconds = strtoul(line + 3, &endPtr, 10);
    if (endPtr == nullptr || *endPtr != ',') {
        return false;
    }

    g_official.microseconds = microseconds;
    strncpy(g_official.status, endPtr + 1, sizeof(g_official.status));
    g_official.status[sizeof(g_official.status) - 1] = '\0';
    g_official.fresh = true;
    return true;
}

static void readFpgaTelemetry()
{
    while (FpgaSerial.available() > 0) {
        const char c = static_cast<char>(FpgaSerial.read());
        if (c == '\r') {
            continue;
        }
        if (c == '\n') {
            g_fpgaLine[g_fpgaLineLen] = '\0';
            parseOfficialLine(g_fpgaLine);
            g_fpgaLineLen = 0;
        } else if (g_fpgaLineLen < sizeof(g_fpgaLine) - 1) {
            g_fpgaLine[g_fpgaLineLen++] = c;
        } else {
            g_fpgaLineLen = 0;
        }
    }
}

static void pulseStart()
{
    clearOfficialTelemetry();
    g_runActive = false;
    g_donePending = false;
    g_reported = false;

    portENTER_CRITICAL(&g_isrMux);
    g_doneSeen = false;
    g_errorSeen = false;
    portEXIT_CRITICAL(&g_isrMux);

    digitalWrite(PIN_HIL_START, HIGH);
    delayMicroseconds(START_PULSE_US);
    digitalWrite(PIN_HIL_START, LOW);
}

static void printCsv(uint32_t microseconds, const char *status)
{
    Serial.printf("%.2f,%u,%s\n", g_frequencyMHz, microseconds, status);
}

static void reportAndReset(uint32_t microseconds, const char *status)
{
    if (!g_reported) {
        printCsv(microseconds, status);
    }
    g_runActive = false;
    g_donePending = false;
    g_reported = true;
}

static void handleCommand(const char *line)
{
    if (line[0] == 'f' || line[0] == 'F') {
        const char *value = line + 1;
        while (*value == ' ' || *value == ',') {
            value++;
        }
        const float parsed = static_cast<float>(atof(value));
        if (parsed > 0.0f) {
            g_frequencyMHz = parsed;
            Serial.printf("# Frequency label set to %.2f MHz\n", g_frequencyMHz);
        }
    } else if (line[0] == 'r' || line[0] == 'R') {
        pulseStart();
    } else if (line[0] == 'h' || line[0] == 'H' || line[0] == '?') {
        Serial.println("# Commands: F <MHz> set label, R run once. Enable SW[0] on FPGA for ESP starts.");
    }
}

static void readUsbCommands()
{
    while (Serial.available() > 0) {
        const char c = static_cast<char>(Serial.read());
        if (c == '\r') {
            continue;
        }
        if (c == '\n') {
            g_usbLine[g_usbLineLen] = '\0';
            handleCommand(g_usbLine);
            g_usbLineLen = 0;
        } else if (g_usbLineLen < sizeof(g_usbLine) - 1) {
            g_usbLine[g_usbLineLen++] = c;
        } else {
            g_usbLineLen = 0;
        }
    }
}

static uint32_t elapsedUs(uint32_t startUs, uint32_t endUs)
{
    return endUs - startUs;
}

void setup()
{
    Serial.begin(USB_BAUD);
    FpgaSerial.begin(FPGA_BAUD, SERIAL_8N1, PIN_HIL_UART_RX, PIN_HIL_UART_TX);

    pinMode(PIN_HIL_BUSY, INPUT);
    pinMode(PIN_HIL_DONE, INPUT);
    pinMode(PIN_HIL_ERROR, INPUT);
    pinMode(PIN_HIL_START, OUTPUT);
    digitalWrite(PIN_HIL_START, LOW);

    attachInterrupt(digitalPinToInterrupt(PIN_HIL_BUSY), onBusyChange, CHANGE);
    attachInterrupt(digitalPinToInterrupt(PIN_HIL_DONE), onDoneRise, RISING);
    attachInterrupt(digitalPinToInterrupt(PIN_HIL_ERROR), onErrorRise, RISING);

    Serial.println("# FP8 adder HIL harness ready");
    Serial.println("# Commands: F <MHz> set label, R run once. FPGA SW[0] must be ON for ESP starts.");
    Serial.println("Frequency_MHz,Microseconds,Status");
}

void loop()
{
    readUsbCommands();
    readFpgaTelemetry();

    bool busyHigh;
    bool doneSeen;
    bool errorSeen;
    uint32_t busyRiseUs;
    uint32_t busyFallUs;
    uint32_t doneRiseUs;
    uint32_t errorRiseUs;

    portENTER_CRITICAL(&g_isrMux);
    busyHigh = g_busyHigh;
    doneSeen = g_doneSeen;
    errorSeen = g_errorSeen;
    busyRiseUs = g_busyRiseUs;
    busyFallUs = g_busyFallUs;
    doneRiseUs = g_doneRiseUs;
    errorRiseUs = g_errorRiseUs;
    portEXIT_CRITICAL(&g_isrMux);

    const uint32_t nowUs = micros();

    if (busyHigh && !g_runActive) {
        g_runActive = true;
        g_donePending = false;
        g_reported = false;
        g_runStartUs = busyRiseUs;
        clearOfficialTelemetry();
    }

    if (!g_runActive || g_reported) {
        return;
    }

    if (errorSeen) {
        const uint32_t measured = elapsedUs(g_runStartUs, errorRiseUs);
        const uint32_t microseconds = g_official.fresh ? g_official.microseconds : measured;
        reportAndReset(microseconds, "FAIL_ERROR");
        return;
    }

    if (busyHigh && elapsedUs(g_runStartUs, nowUs) > WATCHDOG_US) {
        reportAndReset(elapsedUs(g_runStartUs, nowUs), "FAIL_WATCHDOG");
        return;
    }

    if (doneSeen && !g_donePending) {
        g_donePending = true;
        g_donePendingSinceUs = nowUs;
    }

    if (g_donePending && (g_official.fresh || elapsedUs(g_donePendingSinceUs, nowUs) > UART_GRACE_US)) {
        const uint32_t measured = busyFallUs > g_runStartUs
            ? elapsedUs(g_runStartUs, busyFallUs)
            : elapsedUs(g_runStartUs, doneRiseUs);
        const uint32_t microseconds = g_official.fresh ? g_official.microseconds : measured;

        if (g_official.fresh && strcmp(g_official.status, "FAIL") == 0) {
            reportAndReset(microseconds, "FAIL_FPGA");
        } else if (g_official.fresh) {
            reportAndReset(microseconds, "OK");
        } else {
            reportAndReset(microseconds, "OK_HIL_TIMER");
        }
    }
}