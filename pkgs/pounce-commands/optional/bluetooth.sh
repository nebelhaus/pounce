#!/bin/bash
# pounce: name = Bluetooth
# pounce: description = Connect & disconnect devices
# pounce: icon = wave.3.right
# pounce: submenu = true

# Bluetooth device picker (AirPods, keyboards, controllers, …).
# Needs blueutil:  brew install blueutil

# The daemon's environment may not include Homebrew.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

notify() {
    osascript -e "display notification \"${1//\"/}\" with title \"Bluetooth\""
}

# Guards answer through pounce, not a notification: for a submenu command the
# palette is already showing a loading panel, and only a pounce call fills it.
if ! command -v blueutil >/dev/null 2>&1; then
    printf 'blueutil not found\tbrew install blueutil\texclamationmark.triangle' \
        | pounce -p "Bluetooth" -i "wave.3.right" >/dev/null
    exit 0
fi

if [[ "$(blueutil --power 2>/dev/null)" == "0" ]]; then
    selected=$(printf 'Turn Bluetooth On\tBluetooth is currently off\twave.3.right' \
        | pounce -p "Bluetooth" -i "wave.3.right")
    if [[ -n "$selected" ]]; then
        blueutil --power 1
        notify "Bluetooth turned on"
    fi
    exit 0
fi

devicon() { # guess an SF Symbol from the device name
    case "$1" in
        *[Aa]ir[Pp]ods*|*[Bb]uds*) echo "airpods" ;;
        *[Hh]eadphone*|*WH-*)      echo "headphones" ;;
        *[Kk]eyboard*)             echo "keyboard" ;;
        *[Mm]ouse*)                echo "magicmouse" ;;
        *[Ss]peaker*)              echo "hifispeaker" ;;
        *[Cc]ontroller*|*Xbox*)    echo "gamecontroller" ;;
        *)                         echo "wave.3.right" ;;
    esac
}

list=""
add() {
    if [[ -n "$list" ]]; then list="$list"$'\n'"$1"; else list="$1"; fi
}

# blueutil --paired lines look like:
#   address: 12-34-56-78-9a-bc, connected (-60 dBm), not favourite, paired, name: "Buds", ...
while IFS= read -r line; do
    [[ "$line" != address:* ]] && continue
    addr="${line#address: }"; addr="${addr%%,*}"
    name=$(printf '%s' "$line" | sed -En 's/.*name: "([^"]*)".*/\1/p')
    [[ -z "$name" ]] && name="$addr"
    # The MAC rides along as a hidden trailing field; the UI ignores fields
    # past `group` but echoes the full line back on selection.
    if [[ "$line" == *", not connected,"* ]]; then
        add "$name"$'\t'"Not connected"$'\t'"$(devicon "$name")"$'\t'"Connect"$'\t'"Devices"$'\t'"$addr"
    else
        add "$name"$'\t'"✓ Connected"$'\t'"$(devicon "$name")"$'\t'"Disconnect"$'\t'"Devices"$'\t'"$addr"
    fi
done < <(blueutil --paired 2>/dev/null)

# Power is on but no devices listed: blueutil enumerates nothing when the
# calling app (here: the pounce daemon) lacks the Bluetooth TCC grant.
if [[ -z "$list" ]]; then
    selected=$(printf 'No devices found\tIf devices are paired, grant Pounce Bluetooth access\tlock.shield' \
        | pounce -p "Bluetooth" -i "wave.3.right")
    [[ -n "$selected" ]] && open "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
    exit 0
fi

add "Turn Bluetooth Off"$'\t\t'"power"$'\t\t'"Power"

selected=$(printf '%s\n' "$list" | pounce -p "Bluetooth" -i "wave.3.right")
[[ -z "$selected" ]] && exit 0

# Result: action \t title \t subtitle \t icon \t actions \t group \t addr
name=$(printf '%s' "$selected" | cut -f2)
status=$(printf '%s' "$selected" | cut -f3)
addr=$(printf '%s' "$selected" | cut -f7)

if [[ "$name" == "Turn Bluetooth Off" ]]; then
    blueutil --power 0
    notify "Bluetooth turned off"
    exit 0
fi

if [[ "$status" == "✓ Connected" ]]; then
    if blueutil --disconnect "$addr" 2>/dev/null; then
        notify "Disconnected $name"
    else
        notify "Could not disconnect $name"
    fi
else
    notify "Connecting to $name…"
    if blueutil --connect "$addr" 2>/dev/null; then
        notify "Connected $name"
    else
        notify "Could not connect $name — is it in range?"
    fi
fi
