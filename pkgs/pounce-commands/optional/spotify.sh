#!/bin/bash
# pounce: name = Spotify
# pounce: description = Playback controls
# pounce: icon = music.note
# pounce: submenu = true

# Spotify remote — drives the desktop app over AppleScript. No login, no API
# keys; just needs Spotify.app installed.

notify() {
    osascript -e "display notification \"${1//\"/}\" with title \"Spotify\""
}

if [[ ! -d "/Applications/Spotify.app" && ! -d "$HOME/Applications/Spotify.app" ]]; then
    notify "Spotify.app not found — brew install --cask spotify"
    exit 0
fi

if [[ "$(osascript -e 'application "Spotify" is running' 2>/dev/null)" != "true" ]]; then
    selected=$(printf 'Open Spotify\tSpotify is not running\tmusic.note' \
        | pounce -p "Spotify" -i "music.note")
    [[ -n "$selected" ]] && open -a "Spotify"
    exit 0
fi

state=$(osascript -e 'tell application "Spotify" to player state as string' 2>/dev/null)
track=$(osascript -e 'tell application "Spotify" to name of current track' 2>/dev/null)
artist=$(osascript -e 'tell application "Spotify" to artist of current track' 2>/dev/null)
shuffle=$(osascript -e 'tell application "Spotify" to shuffling' 2>/dev/null)

now="$track — $artist"
[[ -z "$track" ]] && now="Nothing queued"

list=""
add() {
    if [[ -n "$list" ]]; then list="$list"$'\n'"$1"; else list="$1"; fi
}

if [[ "$state" == "playing" ]]; then
    add "Pause"$'\t'"$now"$'\t'"pause.fill"
else
    add "Play"$'\t'"$now"$'\t'"play.fill"
fi
add "Next Track"$'\t\t'"forward.fill"
add "Previous Track"$'\t\t'"backward.fill"
if [[ "$shuffle" == "true" ]]; then
    add "Shuffle Off"$'\t'"Shuffle is on"$'\t'"shuffle"
else
    add "Shuffle On"$'\t'"Shuffle is off"$'\t'"shuffle"
fi
add "Copy Song Link"$'\t'"$now"$'\t'"link"
add "Open Spotify"$'\t\t'"music.note"

selected=$(printf '%s\n' "$list" | pounce -p "Spotify" -i "music.note")
[[ -z "$selected" ]] && exit 0

choice=$(printf '%s' "$selected" | cut -f2)
case "$choice" in
    "Play"|"Pause")
        osascript -e 'tell application "Spotify" to playpause'
        ;;
    "Next Track")
        osascript -e 'tell application "Spotify" to next track'
        ;;
    "Previous Track")
        osascript -e 'tell application "Spotify" to previous track'
        ;;
    "Shuffle On")
        osascript -e 'tell application "Spotify" to set shuffling to true'
        notify "Shuffle on"
        ;;
    "Shuffle Off")
        osascript -e 'tell application "Spotify" to set shuffling to false'
        notify "Shuffle off"
        ;;
    "Copy Song Link")
        # spotify:track:<id> → https://open.spotify.com/track/<id>
        uri=$(osascript -e 'tell application "Spotify" to spotify url of current track' 2>/dev/null)
        id="${uri##*:}"
        if [[ "$uri" == spotify:track:* && -n "$id" ]]; then
            printf 'https://open.spotify.com/track/%s' "$id" | pbcopy
            notify "Link copied: $now"
        else
            notify "No track playing"
        fi
        ;;
    "Open Spotify")
        open -a "Spotify"
        ;;
esac
