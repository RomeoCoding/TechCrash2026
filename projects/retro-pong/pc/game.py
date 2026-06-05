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

# Power-up orbs
POWERUP_R         = 10
POWERUP_SPAWN_MIN = 5.0
POWERUP_SPAWN_MAX = 15.0

# type → (label, core color, glow color)
POWERUP_TYPES = {
    'shot':  ('⚡', (255, 180,  0), (255, 230, 80)),   # orange — recharge power shot
    'grow':  ('+',  ( 80, 220, 80), (150, 255, 150)),  # green  — bigger paddle 8 s
    'chaos': ('∞',  (200,  80, 255), (220, 150, 255)), # purple — 4 extra balls, no lose
}
PADDLE_GROW_BONUS = 40   # px added to paddle height
PADDLE_GROW_TIME  = 8.0  # seconds

# ---------------------------------------------------------------------------
# Tilt control tuning (P1 / FPGA accelerometer)
# ---------------------------------------------------------------------------
# TILT_RANGE: accel counts (relative to the calibrated rest point) that map to
#   a full half-screen of paddle travel. Smaller = more sensitive (less tilt
#   needed to reach the edges). ADXL345 ±2g: 1g ≈ 256 counts, so 130 ≈ ~30°.
TILT_RANGE     = 130
TILT_DEADZONE  = 8      # counts around rest that map to dead-centre (kills jitter)
TILT_SMOOTH    = 0.5    # 0=instant (jittery), 1=frozen. 0.5 ≈ snappy but smooth
TILT_CAL_SAMPLES = 30   # packets averaged at startup to find the rest point

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
        self.multi_spawn_t   = 2.0   # time until second ball spawns

        # Power-up orb
        self.powerup_pos    = None   # (x, y) or None
        self.powerup_type   = None   # 'shot' | 'grow' | 'chaos'
        self.powerup_timer  = random.uniform(POWERUP_SPAWN_MIN, POWERUP_SPAWN_MAX)
        self.powerup_pulse  = 0.0
        self.last_toucher   = None

        # Grow timers per player
        self.grow_timer     = [0.0, 0.0]
        self.base_h         = [PADDLE_H_NORMAL, PADDLE_H_NORMAL]  # tracks base without grow

        # Chaos mode: extra balls that don't cause scoring
        self.chaos_balls    = []   # list of Ball — disappear on exit, no score loss

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
        self.powerup_pos          = None
        self.powerup_type         = None
        self.powerup_timer        = random.uniform(POWERUP_SPAWN_MIN, POWERUP_SPAWN_MAX)
        self.powerup_pulse        = 0.0
        self.last_toucher         = None
        self.grow_timer           = [0.0, 0.0]
        self.chaos_balls          = []
        # Keep narrow/multi from switches
        for p in [P1, P2]:
            base_h = PADDLE_H_NARROW if self.narrow else PADDLE_H_NORMAL
            self.p_h[p] = base_h
            self.base_h[p] = base_h

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
        self.narrow = narrow
        for p in [P1, P2]:
            self.base_h[p] = PADDLE_H_NARROW if narrow else PADDLE_H_NORMAL
            if not self.shrink_active[p] and self.grow_timer[p] <= 0:
                self.p_h[p] = self.base_h[p]

    def clamp_paddle(self, player):
        h  = self.p_h[player]
        lo = h / 2
        hi = SCREEN_H - h / 2
        self.p_y[player] = max(lo, min(hi, self.p_y[player]))

    def handle_paddle_hit(self, ball, player):
        """Reflect ball off paddle; apply power shot if pending."""
        self.last_toucher = player
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
            return P2
        if ball.x > SCREEN_W:
            return P1
        return None

    def update_grow_timers(self, dt):
        for p in [P1, P2]:
            if self.grow_timer[p] > 0:
                self.grow_timer[p] -= dt
                if self.grow_timer[p] <= 0:
                    # revert to base (unless shrunk)
                    if not self.shrink_active[p]:
                        self.p_h[p] = self.base_h[p]

    def update_powerup(self, dt):
        self.powerup_pulse = (self.powerup_pulse + dt * 4) % (2 * math.pi)
        if self.powerup_pos is None:
            self.powerup_timer -= dt
            if self.powerup_timer <= 0:
                margin = 80
                x = random.randint(P1_X + PADDLE_W + margin, P2_X - margin)
                y = random.randint(60, SCREEN_H - 60)
                self.powerup_pos = (x, y)
                self.powerup_type = random.choice(list(POWERUP_TYPES.keys()))

        # Tick chaos balls — bounce walls, paddle collisions, remove on exit
        for cb in list(self.chaos_balls):
            cb.update(dt)
            cb.bounce_wall()
            self.check_ball_paddle(cb)
            # Remove chaos ball if it exits either side (no score)
            if cb.x + cb.size < 0 or cb.x > SCREEN_W:
                self.chaos_balls.remove(cb)

    def check_powerup_collision(self, ball):
        """Returns powerup type string if ball hits orb, else None."""
        if self.powerup_pos is None:
            return None
        px, py = self.powerup_pos
        bx = ball.x + ball.size / 2
        by = ball.y + ball.size / 2
        if math.hypot(bx - px, by - py) < POWERUP_R + ball.size / 2:
            ptype = self.powerup_type
            self.powerup_pos  = None
            self.powerup_type = None
            self.powerup_timer = random.uniform(POWERUP_SPAWN_MIN, POWERUP_SPAWN_MAX)
            return ptype
        return None

    def apply_powerup(self, ptype, speed):
        beneficiary = self.last_toucher if self.last_toucher is not None else P1
        if ptype == 'shot':
            self.power_shot_available[beneficiary] = True
        elif ptype == 'grow':
            self.grow_timer[beneficiary] = PADDLE_GROW_TIME
            if not self.shrink_active[beneficiary]:
                self.p_h[beneficiary] = min(self.base_h[beneficiary] + PADDLE_GROW_BONUS,
                                            SCREEN_H // 2)
        elif ptype == 'chaos':
            for _ in range(12):
                b = Ball(speed)
                b.x = float(random.randint(100, SCREEN_W - 100))
                b.y = float(random.randint(60, SCREEN_H - 60))
                self.chaos_balls.append(b)


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

    # P1 controls (left side)
    p1_shot  = "SHOT:RDY" if gs.power_shot_available[P1] else ("SHOT:ARM" if gs.power_shot_pending[P1] else "SHOT:--")
    p1_shrink = "SHRINK:RDY" if gs.shrink_available[P1] else "SHRINK:--"
    p1_col_shot   = CYAN if gs.power_shot_pending[P1] else (WHITE if gs.power_shot_available[P1] else GREY_MID)
    p1_col_shrink = YELLOW if gs.shrink_available[P1] else GREY_MID
    surf.blit(font_small.render(f"KEY0:{p1_shot}", True, p1_col_shot),   (8, SCREEN_H - 36))
    surf.blit(font_small.render(f"KEY1:{p1_shrink}", True, p1_col_shrink), (8, SCREEN_H - 50))

    # P2 controls (right side)
    p2_shot   = "SHOT:RDY" if gs.power_shot_available[P2] else ("SHOT:ARM" if gs.power_shot_pending[P2] else "SHOT:--")
    p2_shrink = "SHRINK:RDY" if gs.shrink_available[P2] else "SHRINK:--"
    p2_col_shot   = CYAN if gs.power_shot_pending[P2] else (WHITE if gs.power_shot_available[P2] else GREY_MID)
    p2_col_shrink = YELLOW if gs.shrink_available[P2] else GREY_MID
    surf.blit(font_small.render(f"SPC:{p2_shot}", True, p2_col_shot),    (SCREEN_W - 120, SCREEN_H - 36))
    surf.blit(font_small.render(f"ENT:{p2_shrink}", True, p2_col_shrink), (SCREEN_W - 120, SCREEN_H - 50))

def draw_powerup(surf, gs, font_small):
    if gs.powerup_pos is None or gs.powerup_type is None:
        return
    px, py = gs.powerup_pos
    label, core_col, glow_col = POWERUP_TYPES[gs.powerup_type]
    glow_r = int(POWERUP_R + 4 + 3 * math.sin(gs.powerup_pulse))
    glow_surf = pygame.Surface((glow_r * 2 + 2, glow_r * 2 + 2), pygame.SRCALPHA)
    pygame.draw.circle(glow_surf, (*glow_col, 80), (glow_r + 1, glow_r + 1), glow_r)
    surf.blit(glow_surf, (px - glow_r - 1, py - glow_r - 1))
    pygame.draw.circle(surf, core_col, (px, py), POWERUP_R)
    pygame.draw.circle(surf, WHITE, (px, py), POWERUP_R, 2)
    t = font_small.render(label, True, WHITE)
    surf.blit(t, (px - t.get_width() // 2, py - t.get_height() // 2))

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

    # Tilt calibration: average the first N packets to learn the board's
    # resting ay reading, then map tilt relative to that. Avoids the paddle
    # sitting pinned at an edge due to mounting angle / chip offset.
    tilt_zero    = 0.0
    cal_samples  = []
    calibrated   = False

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
                            speed_idx = 1  # reset to NORMAL on new game
                            gs = GameState(SPEED_TABLE[speed_idx])
                        elif gs.serving:
                            gs.serving = False

        # ----------------------------------------------------------------
        # 2. Read FPGA packet (or keyboard demo for P1)
        # ----------------------------------------------------------------
        pkt = read_fpga_packet(ser1)
        if pkt:
            data = parse_packet(pkt)
            ay = data['ay']

            if not calibrated:
                # Collect rest-point samples; hold paddle centred meanwhile.
                cal_samples.append(ay)
                gs.p_y[P1] = SCREEN_H / 2
                if len(cal_samples) >= TILT_CAL_SAMPLES:
                    tilt_zero  = sum(cal_samples) / len(cal_samples)
                    calibrated = True
                    print(f"[tilt] calibrated rest ay = {tilt_zero:.0f}")
            else:
                # Tilt relative to the calibrated rest point.
                rel = ay - tilt_zero
                if abs(rel) < TILT_DEADZONE:
                    rel = 0.0
                # Normalise to [-1, +1] over TILT_RANGE, then to screen.
                norm   = max(-1.0, min(1.0, rel / TILT_RANGE))
                half_h = gs.p_h[P1] / 2
                target_y = (norm + 1.0) / 2.0 * (SCREEN_H - gs.p_h[P1]) + half_h
                # Light exponential smoothing — responsive but not jittery.
                gs.p_y[P1] = gs.p_y[P1] * TILT_SMOOTH + target_y * (1.0 - TILT_SMOOTH)

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

            # SW modifiers — speed applies immediately at next point reset
            new_speed_idx = data['speed_idx']
            if new_speed_idx != speed_idx:
                speed_idx = new_speed_idx
                new_speed = SPEED_TABLE[speed_idx]
                for b in gs.balls + gs.chaos_balls:
                    if b.speed > 0:
                        scale = new_speed / b.speed
                        b.vx *= scale
                        b.vy *= scale
                        b.speed = new_speed

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
        # 4. Shrink / grow timers + power-up tick
        # ----------------------------------------------------------------
        gs.update_shrink_timers(dt)
        gs.update_grow_timers(dt)
        if not gs.serving and gs.pause_timer <= 0 and gs.winner is None:
            gs.update_powerup(dt)

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

                # Power-up collision
                ptype = gs.check_powerup_collision(ball)
                if ptype:
                    gs.apply_powerup(ptype, SPEED_TABLE[speed_idx])
                    SND_POWER.play()

                # Score check
                scorer = gs.check_ball_score(ball)
                if scorer is not None:
                    if gs.chaos_balls:
                        # Chaos mode: losing a real ball just removes it, no score
                        gs.balls.remove(ball)
                        if not gs.balls:
                            # All real balls gone — spawn a fresh one, chaos ends
                            gs.chaos_balls.clear()
                            gs.balls = [Ball(SPEED_TABLE[speed_idx])]
                            gs.pause_timer = 0.8
                    else:
                        gs.scores[scorer] += 1
                        SND_POINT.play()
                        send_score(ser1, ser2, gs.scores[P1], gs.scores[P2])
                        gs.flash_side  = scorer
                        gs.flash_timer = 0.12
                        if gs.scores[scorer] >= MAX_SCORE:
                            gs.winner    = scorer
                            gs.win_timer = 3.0
                            SND_WIN.play()
                        else:
                            speed_idx = 1  # reset to NORMAL each round
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
        for cb in gs.chaos_balls:
            pygame.draw.rect(screen, (200, 80, 255), cb.rect())
        draw_powerup(screen, gs, font_small)
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
