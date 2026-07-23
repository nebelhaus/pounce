#!/bin/bash
# pounce: name = Update Pounce
# pounce: description = Update to the latest release via Homebrew
# pounce: icon = arrow.down.circle

# One-tap self-update for Homebrew installs (the non-nebelhaus path — Nix users
# update via their flake, so this bails for them; see the guard). Runs, silently
# in the background with progress reported via notifications:
#   brew update && brew upgrade pounce && brew services restart pounce

# `brew` lives in Homebrew's bindir (/opt/homebrew/bin on Apple Silicon,
# /usr/local/bin on Intel); the daemon inherits launchd's bare PATH without it.
for _d in /opt/homebrew/bin /usr/local/bin /run/current-system/sw/bin \
          "$HOME/.nix-profile/bin" "/etc/profiles/per-user/${USER:-$(id -un)}/bin"; do
    [ -d "$_d" ] && case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
done
export PATH; unset _d

notify() { osascript -e "display notification \"$1\" with title \"Update Pounce\""; }

# ── detached worker ──────────────────────────────────────────────────────────
# The foreground re-execs this script as `--run` inside a fresh session (see the
# perl/setsid line below), so this branch runs in its OWN process group, divorced
# from the pounce daemon that launched us. That divorce is load-bearing: the final
# `brew services restart pounce` bounces that daemon, and launchd SIGKILLs the
# job's whole process group on stop — a worker still in that group would be killed
# after the "stop" and before the "start", leaving the service down. Out of the
# group, we survive the restart and fire the closing notification.
if [ "$1" = "--run" ]; then
    if brew update && brew upgrade pounce; then
        brew services restart pounce
        notify "Pounce is up to date ✅"
    else
        notify "Update failed — run 'brew upgrade pounce' in a terminal to see why."
    fi
    exit 0
fi

# ── foreground: guard, hand off to the worker, return fast ───────────────────

# Guard: only Homebrew installs can be brew-upgraded. If brew is missing, or
# pounce isn't one of its formulae (a Nix / from-source install), say so instead
# of running a confusing `brew upgrade pounce`.
if ! command -v brew >/dev/null 2>&1; then
    notify "Homebrew not found — this only updates brew installs of Pounce."
    exit 0
fi
if ! brew list --formula pounce >/dev/null 2>&1; then
    notify "Pounce wasn't installed via Homebrew — update it the way you installed it."
    exit 0
fi

# Launch the worker in a new session (POSIX::setsid) so it outlives the daemon
# restart, with stdio fully detached. /usr/bin/perl ships with every macOS, so
# this needs nothing installed and no `setsid` binary (macOS has none). Then
# notify and return — the palette closes at once and the upgrade churns unseen.
/usr/bin/perl -e 'use POSIX qw(setsid); setsid(); exec("/bin/bash", @ARGV)' "$0" --run \
    >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true
notify "Updating Pounce in the background… you'll get a notification when it's done."
exit 0
