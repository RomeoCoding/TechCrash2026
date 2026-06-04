// game.cpp — Flappy Bird game engine
// CrashTech VLSI 2026 — Neural Flappy Bird

#include "game.h"

// ── Bird sprites (7×7 px, 1 byte per row, MSB = leftmost pixel) ─────────────
// FLAT: level flight
const uint8_t Game::BIRD_SPRITE_FLAT[7] = {
    0b00111000,  //   ###
    0b01111110,  //  ######
    0b11111101,  // ####### (eye at bit 1)
    0b11111110,  // #######
    0b01111100,  //  #####
    0b00111000,  //   ###
    0b00010000   //    #
};

// UP: pitched up (vy < -1.5)
const uint8_t Game::BIRD_SPRITE_UP[7] = {
    0b00011100,  //    ###
    0b01111110,  //  ######
    0b11111101,  // ####### (eye)
    0b11111110,  // #######
    0b01111100,  //  #####
    0b00111000,  //   ###
    0b00001000   //      #
};

// DOWN: pitched down (vy > 1.5)
const uint8_t Game::BIRD_SPRITE_DOWN[7] = {
    0b00010000,  //    #
    0b00111000,  //   ###
    0b01111110,  //  ######
    0b11111101,  // ####### (eye)
    0b11111110,  // #######
    0b01111100,  //  #####
    0b00111000   //   ###
};

// ── XOR-shift32 RNG ──────────────────────────────────────────────────────────
uint32_t Game::nextRand() {
    _rng ^= _rng << 13;
    _rng ^= _rng >> 17;
    _rng ^= _rng << 5;
    return _rng;
}

// ── Pipe spawn ───────────────────────────────────────────────────────────────
void Game::spawnPipe(Pipe& p, float startX) {
    int range  = FLOOR_Y - _gapSize - 16;   // 8px margin top + 8px margin bottom
    int gapTop = 8 + (int)(nextRand() % (uint32_t)range);
    p.x       = startX;
    p.gapTop  = gapTop;
    p.gapBot  = gapTop + _gapSize;
    p.passed  = false;
}

// ── Reset ────────────────────────────────────────────────────────────────────
void Game::reset(uint8_t difficulty, uint32_t seed, int popSize) {
    _diff    = difficulty;
    _speed   = BASE_SPEED + difficulty * SPEED_PER_DIFF;
    _gapSize = MAX_GAP - (int)(difficulty * (MAX_GAP - MIN_GAP) / 15.0f);
    _popSize = (popSize < 1) ? 1 : (popSize > POP_SIZE ? POP_SIZE : popSize);
    _rng     = seed ? seed : 1;  // seed must not be 0 for xorshift
    _frame   = 0;

    // Spawn 3 pipes staggered
    spawnPipe(_pipes[0], SCREEN_W + 20.0f);
    spawnPipe(_pipes[1], SCREEN_W + 20.0f + PIPE_SPACING);
    spawnPipe(_pipes[2], SCREEN_W + 20.0f + PIPE_SPACING * 2);

    // Initialize birds
    for (int i = 0; i < _popSize; i++) {
        _birds[i].y          = FLOOR_Y / 2.0f;
        _birds[i].vy         = 0.0f;
        _birds[i].alive      = true;
        _birds[i].score      = 0;
        _birds[i].pipesPassed = 0;
    }
}

// ── Collision ────────────────────────────────────────────────────────────────
bool Game::birdHitsPipe(const BirdState& b, const Pipe& p) const {
    // Bird occupies [BIRD_X, BIRD_X+BIRD_W) horizontally, [(int)b.y, (int)b.y+BIRD_H) vertically
    int bx1 = BIRD_X, bx2 = BIRD_X + BIRD_W;
    int by1 = (int)b.y, by2 = (int)b.y + BIRD_H;
    int px1 = (int)p.x, px2 = (int)p.x + PIPE_W;

    if (bx2 <= px1 || bx1 >= px2) return false;  // no horizontal overlap
    // Vertical overlap means hitting pipe (gap is the safe zone)
    return (by1 < p.gapTop || by2 > p.gapBot);
}

bool Game::birdHitsWall(const BirdState& b) const {
    return (b.y < 0) || ((int)b.y + BIRD_H > FLOOR_Y);
}

// ── Single-bird update ───────────────────────────────────────────────────────
void Game::update(bool flap) {
    if (!_birds[0].alive) return;

    if (flap) _birds[0].vy = FLAP_FORCE;
    _birds[0].vy += GRAVITY;
    if (_birds[0].vy >  MAX_VY) _birds[0].vy =  MAX_VY;
    if (_birds[0].vy < -MAX_VY) _birds[0].vy = -MAX_VY;  // Note: MIN_VY is negative
    _birds[0].y += _birds[0].vy;

    // Move pipes and check collisions
    for (int p = 0; p < 3; p++) {
        _pipes[p].x -= _speed;
        if (_pipes[p].x + PIPE_W < 0)
            spawnPipe(_pipes[p], _pipes[(p + 2) % 3].x + PIPE_SPACING);

        if (birdHitsPipe(_birds[0], _pipes[p]) || birdHitsWall(_birds[0])) {
            _birds[0].alive = false;
            return;
        }

        if (!_pipes[p].passed && _pipes[p].x + PIPE_W < BIRD_X) {
            _pipes[p].passed = true;
            _birds[0].pipesPassed++;
            _birds[0].score += 200;
        }
    }
    _birds[0].score += 10;
    _frame++;
}

// ── Population update ────────────────────────────────────────────────────────
void Game::updatePopulation(const bool* flapDecisions) {
    // Move pipes first (shared)
    for (int p = 0; p < 3; p++) {
        _pipes[p].x -= _speed;
        if (_pipes[p].x + PIPE_W < 0) {
            // Find the pipe that's furthest right to chain from
            float maxX = _pipes[0].x;
            for (int k = 1; k < 3; k++) if (_pipes[k].x > maxX) maxX = _pipes[k].x;
            spawnPipe(_pipes[p], maxX + PIPE_SPACING);
        }
    }

    for (int i = 0; i < _popSize; i++) {
        if (!_birds[i].alive) continue;

        if (flapDecisions[i]) _birds[i].vy = FLAP_FORCE;
        _birds[i].vy += GRAVITY;
        if (_birds[i].vy >  MAX_VY) _birds[i].vy =  MAX_VY;
        if (_birds[i].vy < MIN_VY)  _birds[i].vy =  MIN_VY;
        _birds[i].y += _birds[i].vy;

        for (int p = 0; p < 3; p++) {
            if (birdHitsPipe(_birds[i], _pipes[p]) || birdHitsWall(_birds[i])) {
                _birds[i].alive = false;
                break;
            }
            if (!_pipes[p].passed && _pipes[p].x + PIPE_W < BIRD_X) {
                // Score is shared pipe-pass tracking — only mark once
                // (use bird 0 as reference; all birds share same pipes)
            }
        }
        if (_birds[i].alive) {
            // Per-bird pipe-pass scoring
            for (int p = 0; p < 3; p++) {
                // Each bird tracks its own passed state via score delta
            }
            _birds[i].score += 10;
        }
    }

    // Pipe-pass scoring: done once globally
    for (int p = 0; p < 3; p++) {
        bool anyAlive = false;
        for (int i = 0; i < _popSize; i++)
            if (_birds[i].alive) { anyAlive = true; break; }
        if (anyAlive && !_pipes[p].passed && _pipes[p].x + PIPE_W < BIRD_X) {
            _pipes[p].passed = true;
            for (int i = 0; i < _popSize; i++)
                if (_birds[i].alive) {
                    _birds[i].pipesPassed++;
                    _birds[i].score += 200;
                }
        }
    }
    _frame++;
}

// ── Queries ──────────────────────────────────────────────────────────────────
bool     Game::isAlive(int idx)   const { return (idx >= 0 && idx < _popSize) ? _birds[idx].alive   : false; }
float    Game::getBirdY(int idx)  const { return (idx >= 0 && idx < _popSize) ? _birds[idx].y        : 0.0f; }
float    Game::getBirdVy(int idx) const { return (idx >= 0 && idx < _popSize) ? _birds[idx].vy       : 0.0f; }
uint32_t Game::getScore(int idx)  const { return (idx >= 0 && idx < _popSize) ? _birds[idx].score    : 0;    }

float Game::getPipeDistNorm() const {
    // Distance to nearest upcoming pipe, normalized to [0,1]
    float nearest = (float)SCREEN_W;
    for (int p = 0; p < 3; p++) {
        float dist = _pipes[p].x - (BIRD_X + BIRD_W);
        if (dist >= 0 && dist < nearest) nearest = dist;
    }
    return nearest / (float)SCREEN_W;
}

float Game::getGapCenterNorm() const {
    // Gap center y of nearest upcoming pipe, normalized to [0,1]
    float nearest = (float)SCREEN_W;
    int   nearIdx = 0;
    for (int p = 0; p < 3; p++) {
        float dist = _pipes[p].x - (BIRD_X + BIRD_W);
        if (dist >= 0 && dist < nearest) { nearest = dist; nearIdx = p; }
    }
    float gapCy = (_pipes[nearIdx].gapTop + _pipes[nearIdx].gapBot) * 0.5f;
    return gapCy / (float)FLOOR_Y;
}

int Game::getAliveCount() const {
    int cnt = 0;
    for (int i = 0; i < _popSize; i++) if (_birds[i].alive) cnt++;
    return cnt;
}

int Game::getBestAliveIdx() const {
    int best = -1;
    uint32_t bestScore = 0;
    for (int i = 0; i < _popSize; i++) {
        if (_birds[i].alive && _birds[i].score >= bestScore) {
            bestScore = _birds[i].score;
            best = i;
        }
    }
    return best;
}

// ── Rendering helpers ────────────────────────────────────────────────────────
void Game::drawPipeAt(Adafruit_SSD1306& d, const Pipe& p) const {
    int x = (int)p.x;
    // Top pipe: from y=0 to gapTop
    d.fillRect(x, 0, PIPE_W, p.gapTop, SSD1306_WHITE);
    // Bottom pipe: from gapBot to FLOOR_Y
    d.fillRect(x, p.gapBot, PIPE_W, FLOOR_Y - p.gapBot, SSD1306_WHITE);
}

void Game::drawBirdAt(Adafruit_SSD1306& d, float y, float vy) const {
    const uint8_t* sprite;
    if      (vy < -1.5f) sprite = BIRD_SPRITE_UP;
    else if (vy >  1.5f) sprite = BIRD_SPRITE_DOWN;
    else                  sprite = BIRD_SPRITE_FLAT;
    d.drawBitmap(BIRD_X, (int)y, sprite, 7, 7, SSD1306_WHITE);
}

void Game::drawManual(Adafruit_SSD1306& d, uint8_t diff) const {
    d.clearDisplay();
    // Floor
    d.drawFastHLine(0, FLOOR_Y, SCREEN_W, SSD1306_WHITE);
    // Pipes
    for (int p = 0; p < 3; p++) drawPipeAt(d, _pipes[p]);
    // Bird
    if (_birds[0].alive)
        drawBirdAt(d, _birds[0].y, _birds[0].vy);
    // Score
    d.setTextSize(1);
    d.setTextColor(SSD1306_WHITE);
    d.setCursor(0, 0);
    d.print("D:");
    d.print(diff);
    d.print(" S:");
    d.print(_birds[0].score);
}

void Game::drawTraining(Adafruit_SSD1306& d, uint8_t gen, int alive,
                         uint32_t bestScore, uint32_t bestEver) const {
    d.clearDisplay();
    // Header strip (top 9 px)
    d.setTextSize(1);
    d.setTextColor(SSD1306_WHITE);
    d.setCursor(0, 0);
    char buf[24];
    snprintf(buf, sizeof(buf), "G:%02u A:%02u/%02u", gen, alive, _popSize);
    d.print(buf);
    // Best score right-aligned area
    d.setCursor(78, 0);
    snprintf(buf, sizeof(buf), "B:%05lu", (unsigned long)bestEver);
    d.print(buf);

    // Floor
    d.drawFastHLine(0, FLOOR_Y, SCREEN_W, SSD1306_WHITE);
    // Pipes
    for (int p = 0; p < 3; p++) drawPipeAt(d, _pipes[p]);
    // Best alive bird
    int best = getBestAliveIdx();
    if (best >= 0)
        drawBirdAt(d, _birds[best].y, _birds[best].vy);
}

void Game::drawInference(Adafruit_SSD1306& d, uint32_t bestEver) const {
    d.clearDisplay();
    // Floor
    d.drawFastHLine(0, FLOOR_Y, SCREEN_W, SSD1306_WHITE);
    // Pipes
    for (int p = 0; p < 3; p++) drawPipeAt(d, _pipes[p]);
    // Bird
    if (_birds[0].alive)
        drawBirdAt(d, _birds[0].y, _birds[0].vy);
    // "FPGA" badge — top-right, inverted 12×7
    d.fillRect(SCREEN_W - 28, 0, 28, 8, SSD1306_WHITE);
    d.setTextColor(SSD1306_BLACK);
    d.setTextSize(1);
    d.setCursor(SCREEN_W - 26, 0);
    d.print("FPGA");
    d.setTextColor(SSD1306_WHITE);
    // Score
    d.setCursor(0, 0);
    d.print("S:");
    d.print(_birds[0].score);
}
