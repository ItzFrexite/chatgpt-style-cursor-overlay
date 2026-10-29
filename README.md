# ChatGPT-style cursor overlay (OpenBot skill)

A cursor-highlight overlay that looks like ChatGPT's agent cursor: a rounded arrow
pointer with a soft radial glow, moving at ~60fps while your real mouse cursor is kept
locked to the arrow's tip. The arrow and glow are tinted to the running OpenBot agent's
avatar colour automatically.

No browser, no Computer Use, no dependencies: PowerShell + .NET (WPF) on Windows,
python3 + PyObjC (the macOS system python) on macOS.

## Files

```
SKILL.md                      skill definition (frontmatter + workflow + pitfalls)
scripts/cursor_overlay.ps1    the overlay - Windows
scripts/cursor_overlay.py     the overlay - macOS
scripts/keeper.ps1            sign-in keeper that keeps new agents up to date (Windows)
install.ps1                   installer + keeper hook - Windows
install.sh                    installer + launchd hook - macOS / Linux
```

## Try it directly (no OpenBot needed)

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts\cursor_overlay.ps1 -DurationSec 9
```

```bash
# macOS
python3 scripts/cursor_overlay.py --duration 9
```

Options (Windows flag / macOS flag):

| Meaning | Windows | macOS |
|---|---|---|
| how long the overlay runs (default 9s) | `-DurationSec N` | `--duration N` |
| `demo` = figure-eight sweep, `point` = glide to target and hold | `-Pattern demo\|point` | `--pattern demo\|point` |
| target for `point` | `-X n -Y n` | `--x n --y n` |
| explicit colour | `-Color "#RRGGBB"` | `--color "#RRGGBB"` |
| HSL hue for arrow + glow | `-Hue 0-360` | `--hue 0-360` |
| whose `avatarHue` to use (auto-detected from the agent folder path) | `-AgentId <guid>` | `--agent-id <guid>` |
| OpenBot DB path for the colour lookup | (fixed `%APPDATA%\OpenBot\openbot.db`) | `--db`, `OPENBOT_DB` |

Colour priority: colour > hue > agent's `avatarHue` from the OpenBot DB > ChatGPT blue.
macOS coordinates are display **points** (1 point = 2 physical pixels on Retina).

## Install into OpenBot

Recommended (uses OpenBot's own skill library, so the Skills dialog works normally):

1. Put this folder somewhere an agent can read, e.g. its workspace, and have that agent
   register it as a local skill — or use **Skills → Create skill** in the app.
2. Toggle the skill on per agent in **Settings → Skills**. Nothing needs to run periodically;
   a new agent gets it by installing/enabling it once, the same way you enable any skill.

```bash
# macOS / Linux - one-shot copy into every agent's skill folders (alternative)
./install.sh --all
```

```powershell
# Windows - same alternative
powershell -ExecutionPolicy Bypass -File install.ps1 -All
```

Both copy `SKILL.md` + `scripts/` into each agent's `.agents/skills/` and `.claude/skills/`
folders and skip files that are already identical. If a running OpenBot doesn't pick the
skill up, restart it, or have the agent register the folder with its own skill tool.

> **Why the Skills toggle can say "Could not change the skill state":** OpenBot refuses to
> enable/disable a skill whose files differ from its library copy, and a hand-copied folder
> counts as "changed". Fix: delete that hand-copied folder (e.g.
> `<agent>\.claude\skills\chatgpt-style-cursor-overlay`) and install the skill from the
> library instead — then the toggle works.

### Optional: auto-install into agents created later

If you'd rather not enable it by hand for every future agent:

- **Windows** `install.ps1 -Hook` — installs for all current agents, stages a standalone copy
  at `%LOCALAPPDATA%\OpenBotSkills\chatgpt-style-cursor-overlay`, and adds a sign-in keeper
  that blocks on a `FileSystemWatcher`: no timer and no CPU while idle, and it copies the
  skill into a new agent folder within ~1s of it appearing (log: `<stage>\keeper.log`).
  Task Scheduler registration needs elevated rights; without it the installer falls back to a
  Startup-folder shortcut. `-Hook -Poll` uses one short hash-compare pass per hour instead of
  a resident watcher. `-Unhook` removes it.
- **macOS** `install.sh --hook` — stages a copy at
  `~/Library/Application Support/OpenBotSkills/…` and loads a launchd LaunchAgent
  (`site.openbot.cursor-overlay-skill`) with `RunAtLoad` + `WatchPaths` on the Agents folder,
  so launchd starts the job only when that folder changes — also no polling. `--unhook` removes it.
- Both keep a standalone copy outside the repo, so the auto-update survives deleting the clone.
- Either way a new agent only *sees* the skill at its next new session (skill folders are
  scanned at session start), and hand-copied installs still hit the toggle caveat above.
