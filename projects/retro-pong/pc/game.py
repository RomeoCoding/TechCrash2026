"""
Retro Pong — CrashTech VLSI Hackathon 2026 (Challenge 8)

Player 1: DE10-Lite FPGA board
  - Tilt forward/back → left paddle up/down
  - KEY[0]  → power shot  (once per point)
  - KEY[1]  → shrink P2 paddle for 3 s (once per point)
  - SW[9:8] → ball speed preset (00=slow 01=normal 10=fast 11=insane)
  - SW[0]   → multi-ball (second ball spawns 2 s after serve)
  - SW[1]   → narrow paddle mode (both paddles shrink to 50 px)

Player 2: PC keyboard
  - UP / DOWN arrows → right paddle
  - SPACE            → power shot
  - ENTER            → shrink P1 paddle

Usage:
  python game.py --p1port COM3 --p2port COM4

  --p1port  COM port for ESP32_P1 (receives FPGA data, gets score back)
  --p2port  COM port for ESP32_P2 (score display only)
  --noports Run without serial (keyboard demo mode — P1 also on keyboard W/S)
"""

import argparse
import math
import random
import sys
import time

import numpy as np
import pygame
import serial

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCREEN_W, SCREEN_H = 800, 600
FPS = 60

PADDLE_W        = 12
PADDLE_H_NORMAL = 80
PADDLE_H_NARROW = 50   # SW[1] narrow mode baseline
PADDLE_H_SHRUNK = 32   # after shrink debuff applied on top of narrow
BALL_SIZE       = 12
MAX_SCORE       = 7

PADDLE_SPEED    = 7    # px/frame for keyboard player

# Player indices
P1, P2 = 0, 1

# Paddle X positions (left edge)
P1_X = 30
P2_X = SCREEN_W - 30 - PADDLE_W

# Colors
BLACK      = (0,   0,   0)
WHITE      = (255, 255, 255)
CYAN       = (0,   255, 255)
RED        = (255, 50,  50)
GREY_DIM   = (34,  34,  34)
GREY_MID   = (100, 100, 100)
YELLOW     = (255, 220, 50)

# Ball speeds by SW[9:8]
SPEED_TABLE = {0: 5, 1: 7, 2: 10, 3: 14}

# ---------------------------------------------------------------------------
# Procedural sounds (no audio files needed)
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

def send_score(ser1, ser2, p1, p2):
    pkt = bytes([0xCC, p1, p2, 0x55])
    if ser1:
        try: ser1.write(pkt)
        except: pass
    if ser2:
        try: ser2.write(pkt)
        except: pass

# ---------------------------------------------------------------------------
# Packet parsing
# ---------------------------------------------------------------------------
def parse_packet(pkt):
    """Return dict from 11-byte FPGA packet."""
    ay      = int.from_bytes(pkt[3:5], byteorder='little', signed=True)
    key     = pkt[7]
    sw_lo   = pkt[8]
    sw_hi   = pkt[9] & 0x03
    sw      = (sw_hi << 8) | sw_lo
    return {
        'ay':         ay,
        'key0':       bool(key & 0x01),
        'key1':       bool(key & 0x02),
        'multi_ball': bool(sw & 0x001),    # SW[0]
        'narrow':     bool(sw & 0x002),    # SW[1]
        'speed_idx':  (sw >> 8) & 0x03,   # SW[9:8]
    }

# ---------------------------------------------------------------------------
# Game state
# ---------------------------------------------------------------------------
class Ball:
    def __init__(self, speed):
        self.size  = BALL_SIZE
        self.reset(speed)
        self.trail = []   # list of (x, y) positions for trail

    def reset(self, speed):
        self.x  = float(SCREEN_W // 2 - self.size // 2)
        self.y  = float(SCREEN_H // 2 - self.size // 2)
        # Random angle in [30,60] or [120,150] degrees (never near-horizontal)
        angle_deg = random.choice([
            random.uniform(30, 60),
            random.uniform(120, 150),
            random.uniform(210, 240),
            random.uniform(300, 330),
        ])
        angle = math.radians(angle_deg)
        self.vx = math.cos(angle) * speed
        self.vy = math.sin(angle) * speed
        self.speed  = speed
        self.trail  = []
        self.trail_timer = 0.0   # seconds of trail remaining (power shot)

    def center(self):
        return self.x + self.size / 2, self.y + self.size / 2

    def rect(self):
        return pygame.Rect(int(self.x), int(self.y), self.size, self.size)

    def update(self, dt):
        self.trail.insert(0, (int(self.x), int(self.y)))
        if len(self.trail) > 6:
            self.trail.pop()
        if self.trail_timer > 0:
            self.trail_timer -= dt

        self.x += self.vx
        self.y += self.vy

    def bounce_wall(self):
        """Bounce off top/bottom walls. Returns True if bounced."""
        if self.y <= 0:
            self.y  = 0
            self.vy = abs(self.vy)
            return True
        if self.y + self.size >= SCREEN_H:
            self.y  = float(SCREEN_H - self.size)
            self.vy = -abs(self.vy)
            return True
        return False


class GameState:
    def __init__(self, speed):
        self.scores  = [0, 0]
        self.speed   = speed
        self.balls   = [Ball(speed)]
        self.p_y     = [float(SCREEN_H // 2), float(SCREEN_H // 2)]  # paddle centres
        self.p_h     = [PADDLE_H_NORMAL, PADDLE_H_NORMAL]            # current heights

        self.power_shot_available = [True, True]
        self.power_shot_pending   = [False, False]
        self.shrink_available     = [True, True]
        self.shrink_active        = [False, False]
        self.shrink_timer         = [0.0, 0.0]

        self.narrow          = False  # SW[1]
        self.multi_ball      = False  # SW[0]
        self.multi_spawned   = False
        self.multi_spawn_t   = 0.0   # time until second ball spawns

        # Key edge detection (previous frame state)
        self.prev_key0 = False
        self.prev_key1 = False
        self.prev_space = False
        self.prev_enter = False

        # Flash state (point scored)
        self.flash_side    = None   # P1 or P2
        self.flash_timer   = 0.0

        # Pause between points
        self.pause_timer   = 0.0
        self.serving       = True   # waiting for any key to start first ball

        # Win state
        self.winner        = None
        self.win_timer     = 0.0

    def paddle_rect(self, player):
        h = self.p_h[player]
        x = P1_X if player == P1 else P2_X
        y = int(self.p_y[player] - h / 2)
        return pygame.Rect(x, y, PADDLE_W, h)

    def paddle_color(self, player):
        if self.shrink_active[player]:
            # Flash red: alternate every 0.15 s
            tick = int(self.shrink_timer[player] / 0.15)
            return RED if tick % 2 == 0 else WHITE
        if self.power_shot_pending[player]:
            return CYAN
        return WHITE

    def reset_point(self, speed):
        """Reset ball(s) and per-point power-ups after a point is scored."""
        self.balls           = [Ball(speed)]
        self.power_shot_available = [True, True]
        self.power_shot_pending   = [False, False]
        self.shrink_available     = [True, True]
        self.shrink_active        = [False, False]
        self.shrink_timer         = [0.0, 0.0]
        self.multi_spawned        = False
        self.multi_spawn_t        = 2.0
        # Keep narrow/multi from switches
        for p in [P1, P2]:
            base_h = PADDLE_H_NARROW if self.narrow else PADDLE_H_NORMAL
            self.p_h[p] = base_h

    def trigger_power_shot(self, player):
        if self.power_shot_available[player] and not self.power_shot_pending[player]:
            self.power_shot_pending[player]   = True
            self.power_shot_available[player] = False  # consumed
            return True
        return False

    def trigger_shrink(self, player):
        opponent = 1 - player
        if self.shrink_available[player]:
            self.shrink_available[player]  = False
            self.shrink_active[opponent]   = True
            self.shrink_timer[opponent]    = 3.0
            base_h = PADDLE_H_NARROW if self.narrow else PADDLE_H_NORMAL
            self.p_h[opponent] = max(PADDLE_H_SHRUNK, base_h - 32)
            return True
        return False

    def update_shrink_timers(self, dt):
        for p in [P1, P2]:
            if self.shrink_active[p]:
                self.shrink_timer[p] -= dt
                if self.shrink_timer[p] <= 0:
                    self.shrink_active[p] = False
                    base_h = PADDLE_H_NARROW if self.narrow else PADDLE_H_NORMAL
                    self.p_h[p] = base_h

    def apply_narrow(self, narrow):
        """Apply SW[1] narrow mode change."""
        self.narrow = narrow
        for p in [P1, P2]:
            if not self.shrink_active[p]:
                self.p_h[p] = PADDLE_H_NARROW if narrow else PADDLE_H_NORMAL

    def clamp_paddle(self, player):
        h  = self.p_h[player]
        lo = h / 2
        hi = SCREEN_H - h / 2
        self.p_y[player] = max(lo, min(hi, self.p_y[player]))

    def handle_paddle_hit(self, ball, player):
        """Reflect ball off paddle; apply power shot if pending."""
        ball.vx = -ball.vx
        # New vy based on where ball hit the paddle
        cy = self.p_y[player]
        rel = (ball.center()[1] - cy) / (self.p_h[player] / 2)  # -1..+1
        rel = max(-1.0, min(1.0, rel))
        ball.vy = rel * ball.speed * 0.75

        # Clamp vy so ball never goes vertical
        max_vy = ball.speed * 0.9
        ball.vy = max(-max_vy, min(max_vy, ball.vy))

        if self.power_shot_pending[player]:
            new_speed = min(ball.speed * 1.4, SPEED_TABLE[3])
            scale = new_speed / ball.speed
            ball.vx *= scale
            ball.vy *= scale
            ball.speed = new_speed
            # Re-clamp vy so ball never goes vertical
            max_vy = ball.speed * 0.9
            ball.vy = max(-max_vy, min(max_vy, ball.vy))
            ball.trail_timer = 0.4
            self.power_shot_pending[player] = False

    def check_ball_paddle(self, ball):
        """Check collision between ball and both paddles."""
        b = ball.rect()

        p1r = self.paddle_rect(P1)
        if ball.vx < 0 and b.colliderect(p1r):
            ball.x = float(p1r.right)
            self.handle_paddle_hit(ball, P1)
            return 'paddle'

        p2r = self.paddle_rect(P2)
        if ball.vx > 0 and b.colliderect(p2r):
            ball.x = float(p2r.left - ball.size)
            self.handle_paddle_hit(ball, P2)
            return 'paddle'

        return None

    def check_ball_score(self, ball):
        """Returns scoring player index or None."""
        if ball.x + ball.size < 0:
            return P2   # P2 scores (ball left screen on P1 side)
        if ball.x > SCREEN_W:
            return P1   # P1 scores
        return None


# ---------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------
def draw_centre_line(surf):
    for y in range(10, SCREEN_H, 20):
        pygame.draw.rect(surf, GREY_DIM, (SCREEN_W // 2 - 2, y, 4, 10))

def draw_paddle(surf, gs, player):
    r = gs.paddle_rect(player)
    pygame.draw.rect(surf, gs.paddle_color(player), r)

def draw_ball(surf, ball):
    # Trail
    if ball.trail_timer > 0 and len(ball.trail) > 1:
        for i, (tx, ty) in enumerate(ball.trail):
            alpha = int(200 * (1 - i / len(ball.trail)))
            s = pygame.Surface((ball.size, ball.size), pygame.SRCALPHA)
            s.fill((255, 255, 200, alpha))
            surf.blit(s, (tx, ty))
    # Ball
    pygame.draw.rect(surf, WHITE, ball.rect())

def draw_scores(surf, font_large, gs):
    p1t = font_large.render(str(gs.scores[P1]), True, WHITE)
    p2t = font_large.render(str(gs.scores[P2]), True, WHITE)
    surf.blit(p1t, (SCREEN_W // 4 - p1t.get_width() // 2, 20))
    surf.blit(p2t, (3 * SCREEN_W // 4 - p2t.get_width() // 2, 20))

def draw_title(surf, font_med):
    t = font_med.render("PONG", True, GREY_MID)
    surf.blit(t, (SCREEN_W // 2 - t.get_width() // 2, 20))

def draw_modifiers(surf, font_small, gs, speed_idx):
    labels = []
    if gs.multi_ball: labels.append("2-BALL")
    if gs.narrow:     labels.append("NARROW")
    speed_names = {0: "SLOW", 1: "NORMAL", 2: "FAST", 3: "INSANE"}
    labels.append(f"SPEED:{speed_names[speed_idx]}")
    txt = "  ".join(labels)
    t = font_small.render(txt, True, GREY_MID)
    surf.blit(t, (8, SCREEN_H - 18))

def draw_flash(surf, side, alpha):
    flash = pygame.Surface((SCREEN_W // 2, SCREEN_H), pygame.SRCALPHA)
    flash.fill((255, 255, 255, int(alpha)))
    x = 0 if side == P1 else SCREEN_W // 2
    surf.blit(flash, (x, 0))

def draw_scanlines(surf, scanline_surf):
    surf.blit(scanline_surf, (0, 0))

def draw_win(surf, font_large, font_med, winner, win_timer):
    overlay = pygame.Surface((SCREEN_W, SCREEN_H), pygame.SRCALPHA)
    overlay.fill((0, 0, 0, 180))
    surf.blit(overlay, (0, 0))
    name = "PLAYER 1" if winner == P1 else "PLAYER 2"
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
    parser.add_argument('--p1port', default=None,  help='ESP32_P1 COM port')
    parser.add_argument('--p2port', default=None,  help='ESP32_P2 COM port')
    parser.add_argument('--noports', action='store_true', help='Run without serial (demo)')
    args = parser.parse_args()

    # --- Serial ---
    if args.noports:
        ser1, ser2 = None, None
        demo_mode = True
    else:
        ser1 = open_serial(args.p1port) if args.p1port else None
        ser2 = open_serial(args.p2port) if args.p2port else None
        demo_mode = False
        if ser1 is None and not args.noports:
            print("[WARN] P1 serial not available — running in demo mode (W/S for P1)")
            demo_mode = True

    # --- Pygame init ---
    pygame.mixer.pre_init(44100, -16, 2, 512)
    pygame.init()
    pygame.mixer.init()

    screen = pygame.display.set_mode((SCREEN_W, SCREEN_H))
    pygame.display.set_caption("PONG — CrashTech VLSI 2026")
    clock  = pygame.time.Clock()

    font_large = pygame.font.SysFont("monospace", 48, bold=True)
    font_med   = pygame.font.SysFont("monospace", 28, bold=True)
    font_small = pygame.font.SysFont("monospace", 14)

    # Pre-build scanline overlay
    scanline_surf = pygame.Surface((SCREEN_W, SCREEN_H), pygame.SRCALPHA)
    for row in range(0, SCREEN_H, 2):
        pygame.draw.line(scanline_surf, (0, 0, 0, 25), (0, row), (SCREEN_W, row))

    # Pre-generate sounds
    SND_PADDLE = make_beep(440, 40)
    SND_WALL   = make_beep(220, 30)
    SND_POINT  = make_beep(880, 180)
    SND_POWER  = make_beep(660, 60)
    SND_SHRINK = make_beep(300, 140)
    SND_WIN    = make_beep(523, 600)

    # Game state
    speed_idx   = 1  # default NORMAL
    ball_speed  = SPEED_TABLE[speed_idx]
    gs          = GameState(ball_speed)

    running = True

    while running:
        dt = clock.tick(FPS) / 1000.0

        # ----------------------------------------------------------------
        # 1. pygame events
        # ----------------------------------------------------------------
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            if event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    running = False
                # P2 actions (keyboard) — only when ball is in play
                if not gs.serving and gs.pause_timer <= 0 and gs.winner is None:
                    if event.key == pygame.K_SPACE:
                        if gs.trigger_power_shot(P2):
                            SND_POWER.play()
                    if event.key == pygame.K_RETURN:
                        if gs.trigger_shrink(P2):
                            SND_SHRINK.play()
                # Serve / restart during pause
                if gs.serving or gs.pause_timer > 0 or gs.winner is not None:
                    if event.key not in (pygame.K_ESCAPE,):
                        if gs.winner is not None and gs.win_timer <= 0:
                            gs = GameState(SPEED_TABLE[speed_idx])
                        elif gs.serving:
                            gs.serving = False

        # ----------------------------------------------------------------
        # 2. Read FPGA packet (or keyboard demo for P1)
        # ----------------------------------------------------------------
        pkt = read_fpga_packet(ser1)
        if pkt:
            data = parse_packet(pkt)
            ay         = data['ay']
            ay_clamped = max(-180, min(180, ay))
            # Map [-180,+180] → paddle centre y in [PADDLE_H/2, SCREEN_H-PADDLE_H/2]
            half_h = gs.p_h[P1] / 2
            gs.p_y[P1] = (ay_clamped + 180) / 360.0 * (SCREEN_H - gs.p_h[P1]) + half_h

            # KEY rising edges
            k0 = data['key0']
            k1 = data['key1']
            if k0 and not gs.prev_key0:
                if gs.trigger_power_shot(P1):
                    SND_POWER.play()
            if k1 and not gs.prev_key1:
                if gs.trigger_shrink(P1):
                    SND_SHRINK.play()
            gs.prev_key0 = k0
            gs.prev_key1 = k1

            # SW modifiers (take effect at next serve for speed; immediate for narrow/multi)
            new_speed_idx = data['speed_idx']
            if new_speed_idx != speed_idx:
                speed_idx = new_speed_idx  # applied at next reset_point

            new_narrow = data['narrow']
            if new_narrow != gs.narrow:
                gs.apply_narrow(new_narrow)

            gs.multi_ball = data['multi_ball']

        elif demo_mode:
            # Demo: W/S keys control P1
            keys = pygame.key.get_pressed()
            if keys[pygame.K_w]: gs.p_y[P1] -= PADDLE_SPEED
            if keys[pygame.K_s]: gs.p_y[P1] += PADDLE_SPEED
            gs.clamp_paddle(P1)

        # ----------------------------------------------------------------
        # 3. P2 keyboard paddle
        # ----------------------------------------------------------------
        keys = pygame.key.get_pressed()
        if keys[pygame.K_UP]:   gs.p_y[P2] -= PADDLE_SPEED
        if keys[pygame.K_DOWN]: gs.p_y[P2] += PADDLE_SPEED
        gs.clamp_paddle(P2)

        # ----------------------------------------------------------------
        # 4. Shrink timers
        # ----------------------------------------------------------------
        gs.update_shrink_timers(dt)

        # ----------------------------------------------------------------
        # 5. Flash / pause / win timers
        # ----------------------------------------------------------------
        if gs.flash_timer > 0:
            gs.flash_timer -= dt

        if gs.pause_timer > 0:
            gs.pause_timer -= dt
            if gs.pause_timer <= 0:
                gs.serving = False  # auto-serve after pause

        if gs.winner is not None:
            gs.win_timer -= dt

        # ----------------------------------------------------------------
        # 6. Ball update (skip when paused/serving/winner)
        # ----------------------------------------------------------------
        if not gs.serving and gs.pause_timer <= 0 and gs.winner is None:

            # Multi-ball spawn
            if gs.multi_ball and not gs.multi_spawned and len(gs.balls) < 2:
                gs.multi_spawn_t -= dt
                if gs.multi_spawn_t <= 0:
                    gs.balls.append(Ball(SPEED_TABLE[speed_idx]))
                    gs.multi_spawned = True

            for ball in list(gs.balls):
                ball.update(dt)

                # Wall bounce
                if ball.bounce_wall():
                    SND_WALL.play()

                # Paddle collision
                hit = gs.check_ball_paddle(ball)
                if hit:
                    SND_PADDLE.play()

                # Score check
                scorer = gs.check_ball_score(ball)
                if scorer is not None:
                    gs.scores[scorer] += 1
                    SND_POINT.play()
                    send_score(ser1, ser2, gs.scores[P1], gs.scores[P2])

                    gs.flash_side  = scorer
                    gs.flash_timer = 0.12

                    if gs.scores[scorer] >= MAX_SCORE:
                        gs.winner   = scorer
                        gs.win_timer = 3.0
                        SND_WIN.play()
                    else:
                        gs.reset_point(SPEED_TABLE[speed_idx])
                        gs.pause_timer = 1.0

                    break  # only one score event per frame

        # ----------------------------------------------------------------
        # 7. Draw
        # ----------------------------------------------------------------
        screen.fill(BLACK)
        draw_centre_line(screen)
        draw_paddle(screen, gs, P1)
        draw_paddle(screen, gs, P2)
        for ball in gs.balls:
            draw_ball(screen, ball)
        draw_scores(screen, font_large, gs)
        draw_title(screen, font_med)
        draw_modifiers(screen, font_small, gs, speed_idx)

        if gs.flash_timer > 0 and gs.flash_side is not None:
            alpha = int(200 * gs.flash_timer / 0.12)
            draw_flash(screen, gs.flash_side, alpha)

        if gs.serving:
            draw_serve(screen, font_med)

        if gs.winner is not None:
            draw_win(screen, font_large, font_med, gs.winner, gs.win_timer)

        draw_scanlines(screen, scanline_surf)
        pygame.display.flip()

    # ----------------------------------------------------------------
    # Cleanup
    # ----------------------------------------------------------------
    if ser1: ser1.close()
    if ser2: ser2.close()
    pygame.quit()


if __name__ == '__main__':
    main()
