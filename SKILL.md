---
name: chatgpt-style-cursor-overlay
description: Draw a ChatGPT-agent-style animated cursor overlay on Windows or macOS - a rounded arrow with a soft circular glow that tracks the real mouse pointer, tinted to the running agent's colour by default. Use when the user wants a visible/highlighted cursor, an agent-style pointer, or to watch the mouse being moved on screen.
example-prompt: Show me a ChatGPT-style cursor and move it around the screen so I can watch it.
---

# ChatGPT-style cursor overlay

Renders a transparent always-on-top window containing a rounded arrow pointer with a soft radial glow, moved by a ~60fps timer while the real system cursor is kept aligned to the arrow's tip. The arrow and glow are tinted to the running OpenBot agent's avatar colour automatically. No installs, no third-party packages: `scripts/cursor_overlay.ps1` (PowerShell + .NET WPF) on Windows, `scripts/cursor_overlay.py` (python3 + PyObjC - the macOS system python) on macOS.

## Workflow

1. Pick the script for the OS. Windows: `scripts/cursor_overlay.ps1`. macOS: `python3 scripts/cursor_overlay.py` (same flags with `--`: `--duration`, `--pattern demo|point`, `--x/--y`, `--color`, `--hue`, `--agent-id`, `--db`). Run the Windows script in the foreground with ~15s of timeout headroom:
   - `-DurationSec N` — how long the overlay runs (default 9).
   - `-Pattern demo|point` — `demo` sweeps a figure-eight across the screen; `point` glides from the current cursor position to `-X,-Y` (physical pixels) and holds.
   - `-X` / `-Y` — target for `point`.
   - `-Color "#RRGGBB"` — explicit colour override (wins over everything).
   - `-Hue 0-360` — HSL hue for the arrow/glow.
   - `-AgentId <guid>` — whose `avatarHue` to use.
   - Colour priority: `-Color` > `-Hue` > agent's `avatarHue` from the OpenBot DB > ChatGPT blue (hue 221). Agent id is inferred from the script/cwd path (`...\Agents\agent-<guid>\...`), so an agent running it from its own workspace automatically gets its own colour. The closing line reports `agent=`, `hue=`/`color=`, and `rgb=` — check it matches the expected colour.
   - macOS only: coordinates are display **points** (1 point = 2 physical pixels on Retina), the run needs an interactive GUI session as the logged-in user, and the colour lookup checks `~/Library/Application Support/OpenBot/openbot.db` (override with `--db` or `OPENBOT_DB`).
   - The script prints `overlay finished` when it closes.
2. Combine with input injection: move/click with `SetCursorPos` + `mouse_event` (Windows) or `CGWarpMouseCursorPosition` (macOS) as usual; for a demo, prefer the script's own synced motion.
3. To use it while doing other work, launch it as a background process with a long `-DurationSec`, then drive the real cursor with your own `SetCursorPos` calls; the arrow tracks whatever the real cursor does when `-Pattern point` is used without a target... simpler: run `-Pattern point -X <x> -Y <y>` per action, or keep the demo loop running only for showcases.

## Known pitfalls (already handled in the script — keep them fixed if you edit it)

- `SetCursorPos` uses physical pixels; WPF window `Left/Top` use DIPs. Convert with device DPI from `GetDeviceCaps` (index 88). `SystemParameters.DpiX` can return 0 in a bare PowerShell runspace — do not trust it.
- The glow circle must fit entirely inside the overlay window or the window edge slices it flat (looks like a clipped square). The script centres the hotspot in a 64x64 window and keeps the 52px glow inside.
- Rounded look comes from a fat white round-joined stroke path under a blue round-joined stroke of the same path. A plain filled path looks sharp/aliased.
- `Path.Stroke` is a Brush, not a Pen; use `StrokeLineJoin`/`StrokeStartLineCap` with `PenLineJoin`/`PenLineCap` enums.
- Agent colour lookup: `openbot.db` (Windows `%APPDATA%\OpenBot\openbot.db`, macOS `~/Library/Application Support/OpenBot/openbot.db`) is locked while OpenBot runs — copy it to a temp file first and regex the JSON text for `"id":"<agentId>"...avatarHue":N`; no SQLite tooling needed. The DB path is per-OS-user; on another machine/user it may not exist, in which case the blue fallback applies (or pass `-Hue`/`--hue`). The white outline stroke stays white for contrast whatever the colour.

## Install and enable

- Normal route: the skill sits in OpenBot's local skill library and you enable it per agent in **Settings → Skills** (toggle). Nothing runs in the background; a new agent gets it the same way.
- One-shot alternative: `install.ps1 -All` (Windows) or `install.sh --all` (macOS/Linux) copies `SKILL.md` + `scripts/` into every agent's `.agents/skills/` and `.claude/skills/` folders, skipping identical files. `-Agent <name|id>` / `--agent <name|id>` targets one agent; running either from inside an agent workspace targets that agent.
- Hand-copied installs look "locally modified" to OpenBot, so the Skills toggle can fail with **Could not change the skill state**. Fix: delete the copied folder (`<agent>\.claude\skills\chatgpt-style-cursor-overlay` and its `.agents` twin) and install from the library - the toggle then works.
- Optional, only if you want future agents covered automatically:
- Windows: `install.ps1 -Hook` installs into every agent and adds a sign-in keeper (`scripts/keeper.ps1`) that blocks on a FileSystemWatcher and copies the skill into a new agent folder within ~1s of it appearing. No timer and no CPU while idle; log at `%LOCALAPPDATA%\OpenBotSkills\chatgpt-style-cursor-overlay\keeper.log`. Use `-Hook -Poll` if a resident watcher is unwanted (one short hash-compare pass per hour), and `-Unhook` to remove it. Task Scheduler registration needs elevation; without it the installer falls back to a Startup-folder shortcut.
- macOS: `install.sh --hook` adds a launchd LaunchAgent (`site.openbot.cursor-overlay-skill`) with `RunAtLoad` + `WatchPaths` on the Agents folder, so launchd wakes it only when that folder changes - also no polling. `--unhook` removes it.
- Both keep a standalone copy of the skill outside the repo, so the auto-update survives deleting the clone.
- In every case a new agent only *sees* the skill at its next new session (OpenBot scans skill folders at session start).

## Verify

- The script exits printing `overlay finished`; if the process is killed by a command timeout the overlay disappears.
- Ask the user to confirm the glow looks fully circular and the arrow tip sits on the real cursor.
