#!/usr/bin/env bash
# One-click installer for the chatgpt-style-cursor-overlay skill (macOS / Linux).
# Copies SKILL.md + scripts/ into one or more OpenBot agents' local skill folders.
#
#   ./install.sh                      # current agent (run from inside an agent workspace)
#   ./install.sh --agent Linus        # by agent name or id
#   ./install.sh --all                # every agent on this machine
#   ./install.sh --hook               # --all, plus auto-install for agents created later
#   ./install.sh --unhook             # remove the auto-install job
#
# --hook uses a launchd LaunchAgent with WatchPaths on the Agents folder, so nothing
# polls: launchd wakes the job only when that folder changes.
set -euo pipefail

SKILL='chatgpt-style-cursor-overlay'
LABEL='site.openbot.cursor-overlay-skill'
AGENT=''; ALL=0; HOOK=0; UNHOOK=0; REPO=''; ROOT=''; QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --all) ALL=1; shift ;;
    --hook) HOOK=1; ALL=1; shift ;;
    --unhook) UNHOOK=1; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --openbot-root) ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
stage_dir() { printf '%s' "${HOME}/Library/Application Support/OpenBotSkills/${SKILL}"; }
plist_path() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$LABEL"; }

if [ "$UNHOOK" = 1 ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl remove "$LABEL" 2>/dev/null || true
  rm -f "$(plist_path)"
  say "Removed $LABEL. Existing agent installs are left in place; new agents will not get the skill."
  exit 0
fi

REPO="${REPO:-$(cd "$(dirname "$0")" && pwd)}"
[ -f "$REPO/SKILL.md" ] || { echo "SKILL.md not found in '$REPO' - run from the repo root or pass --repo."; exit 1; }
ROOT="${ROOT:-$HOME/OpenBot}"
AGENTS="$ROOT/Agents"
[ -d "$AGENTS" ] || { echo "No OpenBot Agents folder at '$AGENTS' - pass --openbot-root."; exit 1; }

find_agent_id_by_name() {
  # openbot.db can be locked; copy it and grep the JSON text (no SQLite needed).
  local db="$HOME/Library/Application Support/OpenBot/openbot.db" tmp
  [ -f "$db" ] || return 0
  tmp="$(mktemp -t ob_inst)"
  cp "$db" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  LC_ALL=C tr -c '[:print:]' '\n' < "$tmp" \
    | grep -a -o "\"id\":\"agent-[0-9a-fA-F-]\{36\}\",\"name\":\"$1\"" \
    | sed -E 's/.*"(agent-[0-9a-fA-F-]{36})".*/\1/' | sort -u || true
  rm -f "$tmp"
}

targets=()
if [ "$ALL" = 1 ]; then
  while IFS= read -r d; do targets+=("$d"); done < <(find "$AGENTS" -maxdepth 1 -type d -name 'agent-*' | sort)
elif printf '%s' "$AGENT" | grep -Eq '^agent-[0-9a-fA-F-]{36}$'; then
  targets=("$AGENTS/$AGENT")
elif [ -n "$AGENT" ]; then
  while IFS= read -r id; do [ -n "$id" ] && targets+=("$AGENTS/$id"); done < <(find_agent_id_by_name "$AGENT")
  [ ${#targets[@]} -gt 0 ] || { echo "No agent named '$AGENT'. Use --all or an agent id."; exit 1; }
else
  cwd_agent="$(pwd | grep -Eo 'agent-[0-9a-fA-F-]{36}' | head -1 || true)"
  if [ -n "$cwd_agent" ]; then targets=("$AGENTS/$cwd_agent");
  else
    say 'Available agents:'
    find "$AGENTS" -maxdepth 1 -type d -name 'agent-*' -exec basename {} \; | sed 's/^/  /'
    echo 'Specify --agent <name|id> or --all (or --hook to install for all agents and keep new ones up to date).'
    exit 1
  fi
fi

copy_into() {  # $1 = agent dir
  local dst changed=0
  for sdir in .agents/skills .claude/skills; do
    dst="$1/$sdir/$SKILL"
    mkdir -p "$dst/scripts"
    for f in SKILL.md scripts/cursor_overlay.ps1 scripts/cursor_overlay.py; do
      if [ ! -f "$dst/$f" ] || ! cmp -s "$REPO/$f" "$dst/$f"; then
        cp "$REPO/$f" "$dst/$f"; changed=1
      fi
    done
  done
  if [ "$changed" = 1 ]; then say "Installed $SKILL -> $1"; else say "Up to date: $1"; fi
}

for d in "${targets[@]}"; do
  [ -d "$d" ] || { echo "missing agent dir: $d" >&2; continue; }
  copy_into "$d"
done

if [ "$HOOK" = 0 ]; then
  say 'Done. If a running OpenBot does not show the skill, restart it or have the agent register the folder with its skill tool.'
  say 'Tip: add --hook to keep agents created later up to date automatically.'
  exit 0
fi

# --- Auto-update for agents created later: staged copy + launchd WatchPaths (no polling). ---
STAGE="$(stage_dir)"; mkdir -p "$STAGE/scripts"
cp "$REPO/SKILL.md" "$STAGE/SKILL.md"
cp "$REPO/scripts/cursor_overlay.ps1" "$REPO/scripts/cursor_overlay.py" "$STAGE/scripts/"
cp "$REPO/install.sh" "$STAGE/install.sh"
chmod +x "$STAGE/install.sh"
say "Staged a copy of the skill at $STAGE"

if [ "$(uname -s)" != "Darwin" ]; then
  say "Auto-update (--hook) uses launchd, which is macOS only. On Linux either re-run --all after"
  say "creating an agent, or add a systemd user timer for: bash $STAGE/install.sh --all --quiet"
  exit 0
fi

PLIST="$(plist_path)"; mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$STAGE/install.sh</string>
    <string>--all</string>
    <string>--quiet</string>
    <string>--openbot-root</string>
    <string>$ROOT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>WatchPaths</key><array><string>$AGENTS</string></array>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$STAGE/keeper.log</string>
  <key>StandardErrorPath</key><string>$STAGE/keeper.log</string>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
  say "LaunchAgent $LABEL loaded: runs at login and whenever $AGENTS changes."
elif launchctl load "$PLIST" 2>/dev/null; then
  say "LaunchAgent $LABEL loaded (legacy load): runs at login and when $AGENTS changes."
else
  echo "Could not load the LaunchAgent. New agents need: ./install.sh --all" >&2
fi
