#!/usr/bin/env python3
"""ChatGPT-style cursor overlay for macOS: rounded arrow + soft circular glow tracking the
real cursor, tinted to the running OpenBot agent's avatar colour.

Uses PyObjC (AppKit + Quartz), which ships with the macOS system python3 at /usr/bin/python3.
No installs, no third-party packages. Mirrors scripts/cursor_overlay.ps1 on Windows.

Usage:
  python3 cursor_overlay.py [--duration 9] [--pattern demo|point] [--x N] [--y N]
                           [--color "#RRGGBB"] [--hue 0-360] [--agent-id <guid>] [--db <path>]

--pattern demo : sweeps a figure-eight across the screen (showcase).
--pattern point: glides from the current cursor position to --x,--y and holds.
Coordinates are in display points (top-left origin). On a Retina display one point = two
physical pixels, so pass point values in points (half the pixel numbers you see in a screenshot).
Colour priority: --color > --hue > agent's avatarHue from the OpenBot DB > ChatGPT blue (hue 221).
"""

import argparse
import colorsys
import math
import os
import re
import shutil
import sys
import tempfile
import time

AGENT_ID_RE = r'agent-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

WIN = 64          # overlay window side, in points
TIP = 32.0        # arrow tip (hotspot) inside the window - centred so the glow is never clipped
GLOW_R = 26.0     # glow radius (fits inside WIN)
ARROW_SCALE = 0.7
ARROW = [(8, 6), (8, 26), (13.6, 20.8), (17.4, 29.6), (21, 28), (17.2, 19.4), (25, 19.4)]


def parse_args():
    p = argparse.ArgumentParser(description='ChatGPT-style cursor overlay (macOS)')
    p.add_argument('--duration', type=float, default=9)
    p.add_argument('--pattern', choices=['demo', 'point'], default='demo')
    p.add_argument('--x', type=float, default=-1)
    p.add_argument('--y', type=float, default=-1)
    p.add_argument('--color', default='')
    p.add_argument('--hue', type=float, default=-1)
    p.add_argument('--agent-id', default='')
    p.add_argument('--db', default='')
    return p.parse_args()


def db_candidates(explicit):
    if explicit:
        return [explicit]
    home = os.path.expanduser('~')
    out = [os.environ.get('OPENBOT_DB', '')]
    out.append(os.path.join(home, 'Library', 'Application Support', 'OpenBot', 'openbot.db'))
    out.append(os.path.join(home, '.config', 'OpenBot', 'openbot.db'))
    out.append(os.path.join(home, '.local', 'share', 'OpenBot', 'openbot.db'))
    return [p for p in out if p]


def find_agent_hue(agent_id, paths):
    """openbot.db may be locked; copy it and regex the JSON text (no SQLite needed)."""
    for db in paths:
        if not os.path.isfile(db):
            continue
        tmp = os.path.join(tempfile.gettempdir(), 'ob_hue_%s.db' % os.urandom(6).hex())
        try:
            shutil.copyfile(db, tmp)
            with open(tmp, 'rb') as fh:
                text = fh.read().decode('latin-1', 'ignore')
            m = re.search('"id":"%s".{0,900}?"avatarHue":\\s*(\\d+)' % re.escape(agent_id), text, re.S)
            if m:
                return int(m.group(1))
        except OSError:
            pass
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass
    return None


def main():
    args = parse_args()

    rgb, used_hue = None, None
    if args.color:
        hex_ = args.color.lstrip('#')
        if not re.fullmatch('[0-9a-fA-F]{6}', hex_):
            sys.exit('--color must be #RRGGBB')
        rgb = tuple(int(hex_[i:i + 2], 16) for i in (0, 2, 4))
    else:
        agent_id = args.agent_id
        if args.hue < 0 and not agent_id:
            for path in (os.path.dirname(os.path.abspath(__file__)), os.getcwd()):
                m = re.search(AGENT_ID_RE, path)
                if m:
                    agent_id = m.group(0)
                    break
        if args.hue < 0 and agent_id:
            h = find_agent_hue(agent_id, db_candidates(args.db))
            if h is not None:
                args.hue = h
        if args.hue < 0:
            args.hue = 221  # ChatGPT blue fallback
        used_hue = args.hue
        r, g, b = colorsys.hls_to_rgb(args.hue / 360.0, 0.53, 0.72)
        rgb = (int(round(r * 255)), int(round(g * 255)), int(round(b * 255)))

    try:
        from AppKit import (NSApplication, NSApplicationActivationPolicyAccessory, NSBackingStoreBuffered,
                            NSColor, NSGradient, NSMakePoint, NSMakeRect, NSBezierPath,
                            NSLineCapStyleRound, NSLineJoinStyleRound, NSScreen, NSView, NSWindow,
                            NSWindowCollectionBehaviorCanJoinAllSpaces, NSWindowCollectionBehaviorFullScreenAuxiliary,
                            NSWindowCollectionBehaviorIgnoresCycle, NSWindowCollectionBehaviorStationary,
                            NSWindowStyleMaskBorderless)
        from Foundation import NSDate
        import Quartz
    except ImportError as exc:
        sys.exit('PyObjC is not available for this python3 (%s). Run it with the system '
                 '/usr/bin/python3, or pip install pyobjc.' % exc)

    screen = NSScreen.screens()[0]          # main display: global coordinate reference
    sw, sh = float(screen.frame().size.width), float(screen.frame().size.height)

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)   # no Dock icon, no menu

    class OverlayView(NSView):
        def drawRect_(self, rect):
            # glow: radial gradient centred on the tip
            inner = NSColor.colorWithSRGBRed_green_blue_alpha_(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0, 55 / 255.0)
            outer = NSColor.colorWithSRGBRed_green_blue_alpha_(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0, 0.0)
            NSGradient.alloc().initWithStartingColor_endingColor_(inner, outer) \
                .drawFromPoint_startRadius_toPoint_endRadius_angle_(NSMakePoint(TIP, TIP), 0.0,
                                                                    NSMakePoint(TIP, TIP), GLOW_R, 0.0)
            path = NSBezierPath.bezierPath()
            for i, (px, py) in enumerate(ARROW):
                # top-left path coords -> Cocoa bottom-left, tip lands on the hotspot
                x, y = px * ARROW_SCALE + (TIP - ARROW[0][0] * ARROW_SCALE), \
                       ARROW_SCALE * (ARROW[0][1] - py) + TIP
                (path.moveToPoint_ if i == 0 else path.lineToPoint_)(NSMakePoint(x, y))
            path.closePath()
            path.setLineJoinStyle_(NSLineJoinStyleRound)
            path.setLineCapStyle_(NSLineCapStyleRound)
            white = NSColor.colorWithSRGBRed_green_blue_alpha_(1, 1, 1, 235 / 255.0)
            body = NSColor.colorWithSRGBRed_green_blue_alpha_(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0, 1.0)
            path.setLineWidth_(5.0)           # fat white round-joined outline = the rounded look
            path.setStrokeColor_(white)
            path.stroke()
            path.setLineWidth_(2.6)
            path.setFillColor_(body)
            path.fill()
            path.setStrokeColor_(body)
            path.stroke()

    win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
        NSMakeRect(0, 0, WIN, WIN), NSWindowStyleMaskBorderless, NSBackingStoreBuffered, False)
    win.setOpaque_(False)
    win.setBackgroundColor_(NSColor.clearColor())
    win.setLevel_(Quartz.kCGFloatingWindowLevel + 4)
    win.setCollectionBehavior_(NSWindowCollectionBehaviorCanJoinAllSpaces |
                              NSWindowCollectionBehaviorStationary |
                              NSWindowCollectionBehaviorIgnoresCycle |
                              NSWindowCollectionBehaviorFullScreenAuxiliary)
    win.setIgnoresMouseEvents_(True)         # click-through
    win.setHasShadow_(False)
    win.setMovable_(False)
    win.setReleasedWhenClosed_(False)
    view = OverlayView.alloc().initWithFrame_(NSMakeRect(0, 0, WIN, WIN))
    win.setContentView_(view)
    win.orderFrontRegardless_()

    def current_cursor():
        try:
            p = Quartz.CGEventGetLocation(Quartz.CGEventCreate(None))
            return float(p.x), float(p.y)
        except Exception:
            return sw / 2.0, sh / 2.0

    sx, sy = current_cursor()
    tx, ty = (sx, sy) if args.x < 0 else (args.x, args.y)
    if args.y < 0:
        ty = sy

    Quartz.CGAssociateMouseAndMouseCursorPosition(True)

    def place(px, py):
        win.setFrameOrigin_(NSMakePoint(px - TIP, (sh - py) - TIP))
        try:
            Quartz.CGWarpMouseCursorPosition(NSMakePoint(px, py))
        except Exception:
            pass

    deadline = time.time() + args.duration
    ticks, total = 0, int(args.duration * 60)
    while time.time() < deadline:
        ticks += 1
        if args.pattern == 'demo':
            a = ticks * 0.022
            px = sw / 2 + (sw / 3.2) * math.sin(a)
            py = sh / 2 + (sh / 4.2) * math.sin(2 * a)
        else:
            t = min(1.0, ticks / max(1, total * 0.4))
            e = t * t * (3 - 2 * t)          # smoothstep ease
            px, py = sx + (tx - sx) * e, sy + (ty - sy) * e
        place(px, py)
        app.runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(0.016))

    win.close()
    tag = 'hue=%d' % int(used_hue) if used_hue is not None else 'color=#%s' % args.color.lstrip('#')
    print('overlay finished (agent=%s %s rgb=%d,%d,%d)' % (args.agent_id, tag, *rgb))


if __name__ == '__main__':
    main()
