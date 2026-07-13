#!/bin/bash
# pounce: name = Caffeinate
# pounce: description = Keep the Mac awake
# pounce: icon = cup.and.saucer
# pounce: submenu = true

# Keep-awake toggle on top of the system `caffeinate` (no extra installs):
# -d keeps the display on, -i blocks idle sleep. Picking "Let the Mac Sleep"
# (or the timer running out) ends it.

notify() {
    osascript -e "display notification \"${1//\"/}\" with title \"Caffeinate\""
}

# Only track the caffeinate WE started (other processes spawn their own —
# Claude Code, for one — and those are not ours to report or kill).
pidfile="${TMPDIR:-/tmp}/pounce-caffeinate.pid"

if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    selected=$(printf 'Let the Mac Sleep\tKeeping the Mac awake — select to stop\tmoon.zzz' \
        | pounce -p "Caffeinate" -i "cup.and.saucer")
    if [[ -n "$selected" ]]; then
        kill "$(cat "$pidfile")" 2>/dev/null
        rm -f "$pidfile"
        notify "Sleep re-enabled"
    fi
    exit 0
fi
rm -f "$pidfile"

list="Keep Awake Indefinitely"$'\t'"Until you turn it off"$'\t'"infinity"
list="$list"$'\n'"Keep Awake 30 Minutes"$'\t\t'"clock"
list="$list"$'\n'"Keep Awake 1 Hour"$'\t\t'"clock"
list="$list"$'\n'"Keep Awake 2 Hours"$'\t\t'"clock"

selected=$(printf '%s\n' "$list" | pounce -p "Keep the Mac awake…" -i "cup.and.saucer")
[[ -z "$selected" ]] && exit 0

choice=$(printf '%s' "$selected" | cut -f2)
case "$choice" in
    "Keep Awake Indefinitely")
        nohup caffeinate -di >/dev/null 2>&1 & echo $! >"$pidfile"
        notify "Staying awake until you turn it off"
        ;;
    "Keep Awake 30 Minutes")
        nohup caffeinate -di -t 1800 >/dev/null 2>&1 & echo $! >"$pidfile"
        notify "Staying awake for 30 minutes"
        ;;
    "Keep Awake 1 Hour")
        nohup caffeinate -di -t 3600 >/dev/null 2>&1 & echo $! >"$pidfile"
        notify "Staying awake for 1 hour"
        ;;
    "Keep Awake 2 Hours")
        nohup caffeinate -di -t 7200 >/dev/null 2>&1 & echo $! >"$pidfile"
        notify "Staying awake for 2 hours"
        ;;
esac
