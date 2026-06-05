// main.cpp — Neural Flappy Bird, Milestone 2 (ESP32 NN training)
// CrashTech VLSI 2026
//
// The ESP32 trains a population of small neural networks to play Flappy Bird
// using a genetic algorithm, entirely on-device. The OLED shows the live
// population, generation number, alive count, and best score, and the birds
// visibly improve over generations.
//
//   Network:    4 inputs -> 4 hidden (tanh) -> 1 output (sigmoid > 0.5 = flap)
//   Inputs:     bird height, bird velocity, distance to next pipe, distance to gap
//   Population: 40 birds, each with its own network
//   Selection:  keep top performers, breed next gen from them + mutation
//   Course:     deterministic per generation (same seed -> same pipes)
//
//   OLED: SDA=GPIO21, SCL=GPIO22, VCC=3V3, GND=GND  (I2C addr 0x3C)
//
// No FPGA is required for Milestone 2 (it is not in the M2 control path).

#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <math.h>

// ── Display ──────────────────────────────────────────────────────────────────
#define SCREEN_W   128
#define SCREEN_H   64
#define OLED_ADDR  0x3C
#define OLED_SDA   21
#define OLED_SCL   22
Adafruit_SSD1306 display(SCREEN_W, SCREEN_H, &Wire, -1);

// ── Neural network: 4 -> 4 -> 1 ──────────────────────────────────────────────
#define NN_IN      4
#define NN_HID     4
#define NN_W      (NN_IN*NN_HID + NN_HID + NN_HID + 1)   // 16+4+4+1 = 25

struct Net {
    float w1[NN_HID][NN_IN];   // hidden weights
    float b1[NN_HID];          // hidden bias
    float w2[NN_HID];          // output weights
    float b2;                  // output bias

    bool forward(const float in[NN_IN]) const {
        float h[NN_HID];
        for (int j = 0; j < NN_HID; j++) {
            float s = b1[j];
            for (int i = 0; i < NN_IN; i++) s += w1[j][i] * in[i];
            h[j] = tanhf(s);
        }
        float o = b2;
        for (int j = 0; j < NN_HID; j++) o += w2[j] * h[j];
        return (1.0f / (1.0f + expf(-o))) > 0.5f;   // sigmoid > 0.5 -> flap
    }
};

// ── Genetic algorithm parameters ─────────────────────────────────────────────
#define POP_SIZE   40       // >= 30 required
#define ELITE      6        // top performers kept as parents
#define MUT_RATE   0.15f    // per-weight chance of a small mutation
#define MUT_STD    0.40f    // small mutation magnitude
#define BIGMUT_P   0.03f    // chance a mutation is a large one (exploration)
#define BIGMUT_STD 1.50f

// ── Game / simulation constants (match the M1 rendered game) ─────────────────
static const float GRAVITY    = 0.18f;
static const float FLAP_FORCE = -2.6f;
static const int   BIRD_X     = 28;
static const int   PIPE_W     = 12;
static const int   PIPE_GAP   = 30;     // fixed gap for training
static const float PIPE_SPEED = 1.8f;
static const int   PIPE_SPACING = 60;   // horizontal px between pipe centers

// ── Deterministic RNG (xorshift) ─────────────────────────────────────────────
static uint32_t rng;
static inline uint32_t xs() { rng ^= rng<<13; rng ^= rng>>17; rng ^= rng<<5; return rng; }
static inline float frand()  { return (xs() & 0xFFFF) / 65535.0f; }          // 0..1
static inline float frandn() { return (frand() - 0.5f) * 2.0f; }             // -1..1
// approx gaussian via sum of uniforms
static inline float gauss()  { float s=0; for(int i=0;i<4;i++) s+=frand(); return (s-2.0f); }

// ── Population ───────────────────────────────────────────────────────────────
struct Bird {
    float    y, vy;
    bool     alive;
    uint16_t score;
    uint32_t fitness;
    Net      net;
};
static Bird pop[POP_SIZE];

// Deterministic pipe course: pipe k has gap-top gapY[k].
// Generated fresh each generation from a fixed seed so all birds share it.
static const int MAX_PIPES = 256;
static int16_t courseGapY[MAX_PIPES];

static uint16_t generation = 0;
static uint16_t bestScoreEver = 0;
static uint16_t lastGenBest = 0;

// ── Network init / breeding ──────────────────────────────────────────────────
static void randomizeNet(Net &n) {
    for (int j=0;j<NN_HID;j++){
        for (int i=0;i<NN_IN;i++) n.w1[j][i] = frandn();
        n.b1[j] = frandn();
        n.w2[j] = frandn();
    }
    n.b2 = frandn();
}

static float* asArr(Net &n){ return reinterpret_cast<float*>(&n); }  // 25 contiguous floats

static void mutate(Net &n) {
    float *a = asArr(n);
    for (int i=0;i<NN_W;i++){
        if (frand() < MUT_RATE) {
            if (frand() < BIGMUT_P) a[i] += gauss()*BIGMUT_STD;
            else                    a[i] += gauss()*MUT_STD;
        }
    }
}

static void copyNet(Net &dst, const Net &src){ memcpy(&dst, &src, sizeof(Net)); }

// ── Course generation (deterministic per generation) ─────────────────────────
static void buildCourse(uint32_t seed) {
    uint32_t save = rng;
    rng = seed;
    int margin = 8;
    int maxTop = SCREEN_H - PIPE_GAP - margin;
    for (int k=0;k<MAX_PIPES;k++)
        courseGapY[k] = margin + (xs() % (maxTop - margin + 1));
    rng = save;
}

// ── Reset population for a new generation ────────────────────────────────────
static void resetPopulation() {
    for (int b=0;b<POP_SIZE;b++){
        pop[b].y       = SCREEN_H/2;
        pop[b].vy      = 0;
        pop[b].alive   = true;
        pop[b].score   = 0;
        pop[b].fitness = 0;
    }
}

// Pipe geometry helpers given world-x scroll distance.
// Pipe k's left edge x = startX - scroll + k*PIPE_SPACING
static inline int pipeLeftX(int k, float scroll) {
    return (int)(SCREEN_W - scroll + k*PIPE_SPACING);
}

// ── One simulation step for all alive birds ──────────────────────────────────
static float scroll = 0;
static int   aliveCount = 0;

static void simStep() {
    scroll += PIPE_SPEED;
    aliveCount = 0;

    // which pipe is the "next" one in front of the bird
    // find smallest k whose right edge is still ahead of bird
    int nextK = 0;
    for (int k=0;k<MAX_PIPES;k++){
        int lx = pipeLeftX(k, scroll);
        if (lx + PIPE_W >= BIRD_X - 3) { nextK = k; break; }
    }
    int   npLx  = pipeLeftX(nextK, scroll);
    int   npGap = courseGapY[nextK % MAX_PIPES];

    for (int b=0;b<POP_SIZE;b++){
        Bird &bird = pop[b];
        if (!bird.alive) continue;

        // ── NN inputs (normalized) ──
        float in[NN_IN];
        in[0] = bird.y / (float)SCREEN_H;                  // height 0..1
        in[1] = bird.vy / 6.0f;                            // velocity
        in[2] = (npLx - BIRD_X) / (float)SCREEN_W;         // dist to next pipe
        in[3] = ((npGap + PIPE_GAP*0.5f) - bird.y) / (float)SCREEN_H; // dist to gap center

        if (bird.net.forward(in)) bird.vy = FLAP_FORCE;

        bird.vy += GRAVITY;
        bird.y  += bird.vy;
        bird.fitness++;   // survival time

        // collisions
        bool dead = false;
        if (bird.y <= 3 || bird.y >= SCREEN_H-3) dead = true;
        bool xOverlap = (BIRD_X+3 >= npLx) && (BIRD_X-3 <= npLx+PIPE_W);
        if (xOverlap && (bird.y-3 < npGap || bird.y+3 > npGap+PIPE_GAP)) dead = true;

        // score: passed the pipe
        if (npLx + PIPE_W < BIRD_X-3) {
            // counted when the next pipe advances; approximate by scroll progress
        }
        bird.score = (uint16_t)(scroll / PIPE_SPACING);

        if (dead) {
            bird.alive = false;
            bird.fitness += bird.score * 50;  // reward progress strongly
        } else {
            aliveCount++;
        }
    }
}

// ── Selection + next generation ──────────────────────────────────────────────
static int orderIdx[POP_SIZE];
static void nextGeneration() {
    // sort indices by fitness desc (simple insertion sort, small N)
    for (int i=0;i<POP_SIZE;i++) orderIdx[i]=i;
    for (int i=1;i<POP_SIZE;i++){
        int key=orderIdx[i], j=i-1;
        while (j>=0 && pop[orderIdx[j]].fitness < pop[key].fitness){ orderIdx[j+1]=orderIdx[j]; j--; }
        orderIdx[j+1]=key;
    }

    lastGenBest = pop[orderIdx[0]].score;
    if (lastGenBest > bestScoreEver) bestScoreEver = lastGenBest;

    // keep elite parents, breed the rest from them
    Net parents[ELITE];
    for (int e=0;e<ELITE;e++) copyNet(parents[e], pop[orderIdx[e]].net);

    Net newNets[POP_SIZE];
    for (int e=0;e<ELITE;e++) copyNet(newNets[e], parents[e]);   // elitism: carry over unchanged
    for (int b=ELITE;b<POP_SIZE;b++){
        int p = xs() % ELITE;             // pick a parent from the elite
        copyNet(newNets[b], parents[p]);
        mutate(newNets[b]);
    }
    for (int b=0;b<POP_SIZE;b++) copyNet(pop[b].net, newNets[b]);

    generation++;
    scroll = 0;
    buildCourse(0xC0FFEE ^ generation);   // deterministic, varies per gen
    resetPopulation();
}

// ── Rendering ────────────────────────────────────────────────────────────────
static void draw() {
    display.clearDisplay();

    // draw the next few pipes
    for (int k=0;k<MAX_PIPES;k++){
        int lx = pipeLeftX(k, scroll);
        if (lx > SCREEN_W) break;
        if (lx + PIPE_W < 0) continue;
        int g = courseGapY[k % MAX_PIPES];
        display.fillRect(lx, 12, PIPE_W, g-12 < 0 ? 0 : g-12, SSD1306_WHITE);
        display.fillRect(lx, g+PIPE_GAP, PIPE_W, SCREEN_H-(g+PIPE_GAP), SSD1306_WHITE);
    }

    // draw all alive birds as dots
    for (int b=0;b<POP_SIZE;b++)
        if (pop[b].alive) display.drawPixel(BIRD_X, (int)pop[b].y, SSD1306_WHITE);
    // emphasize one (the first alive) bird
    for (int b=0;b<POP_SIZE;b++)
        if (pop[b].alive){ display.fillCircle(BIRD_X,(int)pop[b].y,2,SSD1306_WHITE); break; }

    // HUD (top strip)
    display.fillRect(0,0,SCREEN_W,11,SSD1306_BLACK);
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0,0);
    display.printf("G%-3u A:%-2d", generation, aliveCount);
    display.setCursor(72,0);
    display.printf("B:%u/%u", lastGenBest, bestScoreEver);

    display.display();
}

// ── Arduino entry points ─────────────────────────────────────────────────────
void setup() {
    Serial.begin(115200);
    delay(150);
    Serial.println("\n[FLAPPY-M2] boot: ESP32 NN training");

    Wire.begin(OLED_SDA, OLED_SCL);
    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR))
        Serial.println("[FLAPPY-M2] OLED init FAILED");
    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(4,24);
    display.print("NN Training...");
    display.display();
    delay(600);

    rng = 0xDEADBEEF ^ esp_random();
    for (int b=0;b<POP_SIZE;b++) randomizeNet(pop[b].net);

    generation = 1;
    scroll = 0;
    buildCourse(0xC0FFEE ^ generation);
    resetPopulation();
}

void loop() {
    simStep();
    draw();

    if (aliveCount == 0) {
        Serial.printf("[GEN %u] best=%u everBest=%u\n", generation, lastGenBest, bestScoreEver);
        // brief pause so the generation summary is visible
        display.setCursor(30,28);
        display.printf("GEN %u DONE", generation);
        display.display();
        delay(400);
        nextGeneration();
    }
    delay(16);   // ~60 FPS sim
}
