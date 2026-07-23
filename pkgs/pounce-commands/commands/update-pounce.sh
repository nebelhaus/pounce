#!/bin/bash
# pounce: name = Update Pounce
# pounce: description = Update to the latest release via Homebrew
# pounce: icon = arrow.down.circle

# One-tap self-update for Homebrew installs (the non-nebelhaus path — Nix users
# update via their flake, so this bails for them, see the guard below). Runs
#   brew update && brew upgrade pounce && brew services restart pounce
#
# Two things force the Terminal detour rather than running inline:
#   1. `brew services restart pounce` restarts THIS daemon — the one that
#      spawned this script. Run as a child of the daemon, the restart would kill
#      the update mid-flight. A Terminal window is its own process, so it
#      survives the daemon bounce and finishes the job.
#   2. `brew update`/`upgrade` take a while and are chatty; the user should see
#      progress, not a frozen palette.

# `brew` lives in Homebrew's bindir (/opt/homebrew/bin on Apple Silicon,
# /usr/local/bin on Intel); the daemon inherits launchd's bare PATH without it.
# Needed here for the guard check below — the Terminal that runs the actual
# upgrade is a login shell and finds brew on its own.
for _d in /opt/homebrew/bin /usr/local/bin; do
    [ -d "$_d" ] && case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
done
export PATH; unset _d

notify() { osascript -e "display notification \"$1\" with title \"Update Pounce\""; }

# Guard: only Homebrew installs can be brew-upgraded. If brew is missing, or
# pounce isn't one of its formulae (a Nix / from-source install), say so instead
# of running `brew upgrade pounce` and printing a confusing "no such formula".
if ! command -v brew >/dev/null 2>&1; then
    notify "Homebrew not found — this only updates brew installs of Pounce."
    exit 0
fi
if ! brew list --formula pounce >/dev/null 2>&1; then
    notify "Pounce wasn't installed via Homebrew — update it the way you installed it."
    exit 0
fi

# Run the upgrade in a fresh Terminal window: detached from the daemon (so the
# service restart can't kill it) and visible (so the user watches it happen).
osascript <<'EOF'
tell application "Terminal"
    activate
    do script "echo '🐾 Updating Pounce via Homebrew…'; echo; if brew update && brew upgrade pounce && brew services restart pounce; then echo; echo '✅ Pounce is up to date.'; else echo; echo '❌ Update failed — see the output above.'; fi"
end tell
EOF
