"""
Retro Pong -- Single Player vs CPU
CrashTech VLSI Hackathon 2026

Player 1: DE10-Lite FPGA board
  - Tilt forward/back  -> left paddle up/down
  - SW[9:8]            -> ball speed (00=slow 01=normal 10=fast 11=insane)

CPU: right paddle tracks the ball automatically.

Usage:
  python game.py --port COM3   # ESP32_P1 COM port
  python game.py               # keyboard demo (W/S keys)
"""

import argparse
import math
import random

import numpy as np
import pygame
import serial

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCREEN_W, SCREEN_H = 800, 600
FPS = 60

PADDLE_W     = 12
PADDLE_H     = 80
BALL_SIZE    = 12
MAX_SCORE    = 7

PADDLE_SPEED = 7   # px/frame keyboard demo
CPU_SPEED    = 5   # px/frame CPU max movement

P1,  CPU = 0, 1
P1_X     = 30
CPU_X    = SCREEN_W - 30 - PADDLE_W

BLACK    = (0,   0,   0)
WHITE    = (255, 255, 255)
GREY_DIM = (34,  34,  34)
GREY_MID = (100, 100, 100)

SPEED_TABLE = {0: 5, 1: 7, 2: 10, 3: 14}

# ---------------------------------------------------------------------------
# Sound helpers
# ---------------------------------------------------------------------------
def make_beep(freq_hz, duration_ms, sample_rate=44100):
    n = int(sample_rate * duration_ms / 1000)
    t = np.linspace(0, duration_ms / 1000, n, False)
    wave = np.sign(np.sin(2 * np.pi * freq_hz * t))
    wave = (wave * 28000).astype(np.int16)
    stereo = np.column_stack([wave, wave])
    return pygame.sndarray.make_sound(stereo)

# ---------------------------------------------------------------------------
# Serial helpers
# ---------------------------------------------------------------------------
def open_serial(port, baud=115200):
    try:
        return serial.Serial(port, baud, timeout=0.02)
    except serial.SerialException as e:
        print(f"[WARN] Could not open {port}: {e}")
        return None

def read_fpga_packet(ser):
    """Non-blocking. Returns 11-byte bytearray or None."""
    if ser is None or ser.in_waiting < 1:
        return None
    b = ser.read(1)
    if b != b'\xaa':
        return None
    rest = ser.read(10)
    if len(rest) == 10 and rest[-1] == 0x55:
        return bytearray(b) + bytearray(rest)
    return None

def send_score(ser, p1, cpu):
    pkt = bytes([0xCC, p1, cpu, 0x55])
    if ser:
        try:
            ser.write(pkt)
        except Exception:
            pass

def parse_packet(pkt):
    ay    = int.from_bytes(pkt[3:5], byteorder='little', signed=True)
    sw_hi = pkt[9] & 0x03
    return {'ay': ay, 'speed_idx': sw_hi}

# ---------------------------------------------------------------------------
# Ball
# ---------------------------------------------------------------------------
class Ball:
    def __init__(self, speed):
        self.size  = BALL_SIZE
        self.speed = speed
        self.reset(speed)

    def reset(self, speed):
        self.x = float(SCREEN_W // 2 - self.size // 2)
        self.y = float(SCREEN_H // 2 - self.size // 2)
        angle_deg = random.choice([
            random.uniform(30,  60),
            random.uniform(120, 150),
            random.uniform(210, 240),
            random.uniform(300, 330),
        ])
        a       = math.radians(angle_deg)
        self.vx = math.cos(a) * speed
        self.vy = math.sin(a) * speed
        self.speed = speed

    def center(self):
        return self.x + self.size / 2, self.y + self.size / 2

    def rect(self):
        return pygame.Rect(int(self.x), int(self.y), self.size, self.size)

    def update(self):
        self.x += self.vx
        self.y += self.vy

    def bounce_wall(self):
        if self.y <= 0:
            self.y  = 0
            self.vy = abs(self.vy)
            return True
        if self.y + self.size >= SCREEN_H:
            self.y  = float(SCREEN_H - self.size)
            self.vy = -abs(self.vy)
            return True
        return False

# ---------------------------------------------------------------------------
# Game state
# ---------------------------------------------------------------------------
class GameState:
    def __init__(self, speed):
        self.scores      = [0, 0]
        self.ball        = Ball(speed)
        self.p_y         = [float(SCREEN_H // 2), float(SCREEN_H // 2)]
        self.flash_side  = None
        self.flash_timer = 0.0
        self.pause_timer = 0.0
        self.serving     = True
        self.winner      = None
        self.win_timer   = 0.0

    def paddle_rect(self, player):
        x = P1_X if player == P1 else CPU_X
        y = int(self.p_y[player] - PADDLE_H / 2)
        return pygame.Rect(x, y, PADDLE_W, PADDLE_H)

    def clamp_paddle(self, player):
        self.p_y[player] = max(PADDLE_H / 2,
                               min(SCREEN_H - PADDLE_H / 2, self.p_y[player]))

    def move_cpu(self):
        diff = self.ball.center()[1] - self.p_y[CPU]
        self.p_y[CPU] += max(-CPU_SPEED, min(CPU_SPEED, diff))
        self.clamp_paddle(CPU)

    def handle_hit(self, player):
        self.ball.vx = -self.ball.vx
        rel = (self.ball.center()[1] - self.p_y[player]) / (PADDLE_H / 2)
        rel = max(-1.0, min(1.0, rel))
        self.ball.vy = rel * self.ball.speed * 0.75
        max_vy = self.ball.speed * 0.9
        self.ball.vy = max(-max_vy, min(max_vy, self.ball.vy))

    def check_collisions(self):
        b    = self.ball.rect()
        p1r  = self.paddle_rect(P1)
        if self.ball.vx < 0 and b.colliderect(p1r):
            self.ball.x = float(p1r.right)
            self.handle_hit(P1)
            return True
        cpur = self.paddle_rect(CPU)
        if self.ball.vx > 0 and b.colliderect(cpur):
            self.ball.x = float(cpur.left - self.ball.size)
            self.handle_hit(CPU)
            return True
        return False

    def check_score(self):
        if self.ball.x + self.ball.size < 0:
            return CPU
        if self.ball.x > SCREEN_W:
            return P1
        return None

    def reset_point(self, speed):
        self.ball = Ball(speed)

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------
def draw_centre_line(surf):
    for y in range(10, SCREEN_H, 20):
        pygame.draw.rect(surf, GREY_DIM, (SCREEN_W // 2 - 2, y, 4, 10))

def draw_scores(surf, font_large, gs):
    p1t  = font_large.render(str(gs.scores[P1]),  True, WHITE)
    cput = font_large.render(str(gs.scores[CPU]), True, WHITE)
    surf.blit(p1t,  (SCREEN_W // 4 - p1t.get_width() // 2,  20))
    surf.blit(cput, (3 * SCREEN_W // 4 - cput.get_width() // 2, 20))

def draw_labels(surf, font_small):
    t1 = font_small.render("P1",  True, GREY_MID)
    t2 = font_small.render("CPU", True, GREY_MID)
    surf.blit(t1, (SCREEN_W // 4 - t1.get_width() // 2, 70))
    surf.blit(t2, (3 * SCREEN_W // 4 - t2.get_width() // 2, 70))

def draw_speed(surf, font_small, speed_idx):
    names = {0: "SLOW", 1: "NORMAL", 2: "FAST", 3: "INSANE"}
    t = font_small.render(f"SPEED: {names[speed_idx]}", True, GREY_MID)
    surf.blit(t, (8, SCREEN_H - 18))

def draw_flash(surf, side, alpha):
    s = pygame.Surface((SCREEN_W // 2, SCREEN_H), pygame.SRCALPHA)
    s.fill((255, 255, 255, int(alpha)))
    surf.blit(s, (0 if side == P1 else SCREEN_W // 2, 0))

def draw_scanlines(surf, scanline_surf):
    surf.blit(scanline_surf, (0, 0))

def draw_win(surf, font_large, font_med, winner, win_timer):
    overlay = pygame.Surface((SCREEN_W, SCREEN_H), pygame.SRCALPHA)
    overlay.fill((0, 0, 0, 180))
    surf.blit(overlay, (0, 0))
    name = "PLAYER 1" if winner == P1 else "CPU"
    t1 = font_large.render(f"{name} WINS!", True, WHITE)
    surf.blit(t1, (SCREEN_W // 2 - t1.get_width() // 2, SCREEN_H // 2 - 30))
    if win_timer <= 0:
        t2 = font_med.render("Press any key to restart", True, GREY_MID)
        surf.blit(t2, (SCREEN_W // 2 - t2.get_width() // 2, SCREEN_H // 2 + 30))

def draw_serve(surf, font_med):
    t = font_med.render("Press any key to serve", True, GREY_MID)
    surf.blit(t, (SCREEN_W // 2 - t.get_width() // 2, SCREEN_H // 2 + 40))

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', default=None, help='ESP32_P1 COM port')
    args = parser.parse_args()

    ser = open_serial(args.port) if args.port else None
    demo_mode = (ser is None)
    if demo_mode:
        print("[INFO] No serial -- keyboard demo mode (W/S for P1)")

    pygame.mixer.pre_init(44100, -16, 2, 512)
    pygame.init()
    pygame.mixer.init()

    screen = pygame.display.set_mode((SCREEN_W, SCREEN_H))
    pygame.display.set_caption("PONG -- CrashTech VLSI 2026")
    clock = pygame.time.Clock()

    font_large = pygame.font.SysFont("monospace", 48, bold=True)
    font_med   = pygame.font.SysFont("monospace", 28, bold=True)
    font_small = pygame.font.SysFont("monospace", 14)

    scanline_surf = pygame.Surface((SCREEN_W, SCREEN_H), pygame.SRCALPHA)
    for row in range(0, SCREEN_H, 2):
        pygame.draw.line(scanline_surf, (0, 0, 0, 25), (0, row), (SCREEN_W, row))

    SND_PADDLE = make_beep(440,  40)
    SND_WALL   = make_beep(220,  30)
    SND_POINT  = make_beep(880, 180)
    SND_WIN    = make_beep(523, 600)

    speed_idx = 1
    gs = GameState(SPEED_TABLE[speed_idx])
    running = True

    while running:
        dt = clock.tick(FPS) / 1000.0

        # Events
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            if event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    running = False
                elif gs.winner is not None and gs.win_timer <= 0:
                    gs = GameState(SPEED_TABLE[speed_idx])
                elif gs.serving:
                    gs.serving = False

        # P1 input
        pkt = read_fpga_packet(ser)
        if pkt:
            data = parse_packet(pkt)
            ay = max(-180, min(180, data['ay']))
            gs.p_y[P1] = (ay + 180) / 360.0 * (SCREEN_H - PADDLE_H) + PADDLE_H / 2
            new_idx = data['speed_idx']
            if new_idx != speed_idx:
                speed_idx = new_idx
        elif demo_mode:
            keys = pygame.key.get_pressed()
            if keys[pygame.K_w]:
                gs.p_y[P1] -= PADDLE_SPEED
            if keys[pygame.K_s]:
                gs.p_y[P1] += PADDLE_SPEED
            gs.clamp_paddle(P1)

        # Timers
        if gs.flash_timer > 0:
            gs.flash_timer -= dt
        if gs.pause_timer > 0:
            gs.pause_timer -= dt
            if gs.pause_timer <= 0:
                gs.serving = False
        if gs.winner is not None:
            gs.win_timer -= dt

        # Gameplay
        if not gs.serving and gs.pause_timer <= 0 and gs.winner is None:
            gs.move_cpu()
            gs.ball.update()

            if gs.ball.bounce_wall():
                SND_WALL.play()

            if gs.check_collisions():
                SND_PADDLE.play()

            scorer = gs.check_score()
            if scorer is not None:
                gs.scores[scorer] += 1
                SND_POINT.play()
                send_score(ser, gs.scores[P1], gs.scores[CPU])
                gs.flash_side  = scorer
                gs.flash_timer = 0.12
                if gs.scores[scorer] >= MAX_SCORE:
                    gs.winner    = scorer
                    gs.win_timer = 3.0
                    SND_WIN.play()
                else:
                    gs.reset_point(SPEED_TABLE[speed_idx])
                    gs.pause_timer = 1.0

        # Draw
        screen.fill(BLACK)
        draw_centre_line(screen)
        pygame.draw.rect(screen, WHITE, gs.paddle_rect(P1))
        pygame.draw.rect(screen, WHITE, gs.paddle_rect(CPU))
        pygame.draw.rect(screen, WHITE, gs.ball.rect())
        draw_scores(screen, font_large, gs)
        draw_labels(screen, font_small)
        draw_speed(screen, font_small, speed_idx)

        if gs.flash_timer > 0 and gs.flash_side is not None:
            draw_flash(screen, gs.flash_side, int(200 * gs.flash_timer / 0.12))
        if gs.serving:
            draw_serve(screen, font_med)
        if gs.winner is not None:
            draw_win(screen, font_large, font_med, gs.winner, gs.win_timer)

        draw_scanlines(screen, scanline_surf)
        pygame.display.flip()

    if ser:
        ser.close()
    pygame.quit()


if __name__ == '__main__':
    main()
