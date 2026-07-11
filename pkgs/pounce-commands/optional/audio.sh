#!/bin/bash
# pounce: name = Audio Devices
# pounce: description = Switch sound output & input
# pounce: icon = hifispeaker
# pounce: submenu = true

# Audio device switcher.
# Needs SwitchAudioSource:  brew install switchaudio-osx

# The daemon's environment may not include Homebrew.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

notify() {
    osascript -e "display notification \"${1//\"/}\" with title \"Audio Devices\""
}

if ! command -v SwitchAudioSource >/dev/null 2>&1; then
    notify "SwitchAudioSource not found — brew install switchaudio-osx"
    exit 0
fi

current_out=$(SwitchAudioSource -c -t output 2>/dev/null)
current_in=$(SwitchAudioSource -c -t input 2>/dev/null)

list=""
add() { # add <line> — append a tab-separated row
    if [[ -n "$list" ]]; then list="$list"$'\n'"$1"; else list="$1"; fi
}

while IFS= read -r dev; do
    [[ -z "$dev" ]] && continue
    if [[ "$dev" == "$current_out" ]]; then
        add "$dev"$'\t'"✓ Current output"$'\t'"speaker.wave.2.fill"$'\t\t'"Output"
    else
        add "$dev"$'\t\t'"speaker.wave.2"$'\t\t'"Output"
    fi
done < <(SwitchAudioSource -a -t output 2>/dev/null)

while IFS= read -r dev; do
    [[ -z "$dev" ]] && continue
    if [[ "$dev" == "$current_in" ]]; then
        add "$dev"$'\t'"✓ Current input"$'\t'"mic.fill"$'\t\t'"Input"
    else
        add "$dev"$'\t\t'"mic"$'\t\t'"Input"
    fi
done < <(SwitchAudioSource -a -t input 2>/dev/null)

if [[ -z "$list" ]]; then
    notify "No audio devices found"
    exit 0
fi

selected=$(printf '%s\n' "$list" | pounce -p "Audio Devices" -i "hifispeaker")
[[ -z "$selected" ]] && exit 0

# Result: action \t title \t subtitle \t icon \t actions \t group
dev=$(printf '%s' "$selected" | cut -f2)
group=$(printf '%s' "$selected" | cut -f6)

kind="output"
[[ "$group" == "Input" ]] && kind="input"

if SwitchAudioSource -t "$kind" -s "$dev" >/dev/null 2>&1; then
    notify "Now using $dev for $kind"
else
    notify "Could not switch $kind to $dev"
fi
