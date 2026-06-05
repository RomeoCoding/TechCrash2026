# Neural Flappy Bird — Milestone 2 (ESP32 Neural-Network Training)

Minimal, from-scratch implementation of **Challenge 9, Milestone 2 (100 pts)**.

The ESP32 trains a population of small neural networks to play Flappy Bird using
a genetic algorithm, **entirely on-device** (no PC). The OLED shows the live
population, generation number, alive count, and best score, and the birds
visibly improve over generations.

> Milestone 2 is **ESP32-only** — the FPGA is not part of the M2 control path,
> so no FPGA project is needed here.

## Requirement → implementation map

| Requirement | Where (`esp32/src/main.cpp`) |
|---|---|
| Replace manual control with a training simulation | whole `loop()` runs the sim |
| Population of ≥30 birds in parallel | `POP_SIZE 40`, `pop[]` |
| Each bird has its own neural network | `Bird::net` (a `Net` per bird) |
| Inputs: height, velocity, dist to next obstacle, dist to gap | `in[0..3]` in `simStep()` |
| 1 hidden layer with 4 neurons | `NN_HID 4`, `Net::forward()` |
| 1 output neuron deciding flap | sigmoid(out) > 0.5 → flap |
| Same deterministic course per generation | `buildCourse(seed)` from fixed per-gen seed |
| Fitness = survival / progress / score | `fitness++` per frame + `score*50` bonus |
| Keep top performers | `ELITE 6` kept via `orderIdx` sort |
| Next gen bred from the best | `nextGeneration()` copies elite parents |
| Copy parents + small/large mutations | `mutate()` (`MUT_STD`, occasional `BIGMUT_STD`) |
| OLED: population, generation, alive, best | `draw()` HUD + bird dots |
| Visible improvement over generations | best score climbs; printed to serial each gen |

## Neural network

```
4 inputs ─► 4 hidden (tanh) ─► 1 output (sigmoid)   → flap if > 0.5
```
Inputs (all normalized):
1. bird height
2. bird velocity
3. distance to next pipe
4. distance to the gap center

25 weights total (16 + 4 + 4 + 1), stored as a contiguous `float` block so the
GA can mutate them directly.

## Genetic algorithm

- **Population:** 40 birds, each a random network at gen 1.
- **Evaluation:** every bird flies the *same* deterministic pipe course; fitness
  = frames survived, with a strong bonus for pipes passed.
- **Selection:** top `ELITE = 6` by fitness are carried over unchanged (elitism)
  and used as parents.
- **Breeding:** remaining birds copy a random elite parent, then mutate — each
  weight has a 15% chance of a small Gaussian nudge, with a 3% chance of a large
  mutation for exploration.

This is enough to show clear learning within ~10–30 generations.

## Build & flash (PlatformIO)

```powershell
& "$env:USERPROFILE\.platformio\penv\Scripts\pio.exe" run -t upload `
    -d projects\flappy-m2\esp32 --upload-port COM3
```
Close any open serial monitor first or COM3 will be busy.

## Wiring

Only the OLED is needed:

| OLED pin | ESP32 pin |
|---|---|
| SDA | GPIO21 |
| SCL | GPIO22 |
| VCC | 3V3 |
| GND | GND |

I2C address `0x3C`.

## What you'll see

- Top-left: `G<gen> A:<alive>` — generation number and birds still alive.
- Top-right: `B:<thisGen>/<everBest>` — best score this generation / all-time best.
- The flock of birds (dots) flying through the scrolling pipes; the lead bird is
  drawn as a filled circle.
- Watch the all-time best climb generation over generation. The serial monitor
  also prints a one-line summary per generation.
