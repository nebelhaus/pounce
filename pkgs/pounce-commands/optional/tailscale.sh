#!/bin/bash
# pounce: name = Tailscale
# pounce: description = Peers, IPs & connect toggle
# pounce: icon = network.badge.shield.half.filled
# pounce: submenu = true

# Tailscale panel: connect/disconnect, copy your tailnet IP, and copy any
# peer's IP straight from the palette.
# Needs the tailscale CLI (ships inside Tailscale.app, or brew install tailscale).

# External tools may live in Homebrew (solo installs) or a Nix profile
# (nebelhaus); the daemon inherits launchd's bare PATH with neither. Prepend
# every common package-manager bindir that exists so the tool resolves however
# pounce was installed.
for _d in /opt/homebrew/bin /usr/local/bin /run/current-system/sw/bin \
          "$HOME/.nix-profile/bin" "/etc/profiles/per-user/${USER:-$(id -un)}/bin"; do
    [ -d "$_d" ] && case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
done
export PATH; unset _d

notify() {
    osascript -e "display notification \"${1//\"/}\" with title \"Tailscale\""
}

TS=$(command -v tailscale)
if [[ -z "$TS" && -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]]; then
    TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
fi
# Guards answer through pounce, not a notification: for a submenu command the
# palette is already showing a loading panel, and only a pounce call fills it.
if [[ -z "$TS" ]]; then
    printf 'tailscale CLI not found\tbrew install tailscale (or install Tailscale.app)\texclamationmark.triangle' \
        | pounce -p "Tailscale" -i "network.badge.shield.half.filled" >/dev/null
    exit 0
fi

status=$("$TS" status 2>&1)
rc=$?

if [[ $rc -ne 0 || "$status" == *"Tailscale is stopped"* || "$status" == *"Logged out"* ]]; then
    selected=$(printf 'Connect\tTailscale is down\tpower' \
        | pounce -p "Tailscale" -i "network.badge.shield.half.filled")
    if [[ -n "$selected" ]]; then
        if "$TS" up >/dev/null 2>&1; then
            notify "Connected"
        else
            notify "Could not connect — try the Tailscale menu bar app"
        fi
    fi
    exit 0
fi

myip=$("$TS" ip -4 2>/dev/null | head -1)

list="Copy My IP"$'\t'"$myip"$'\t'"doc.on.doc"$'\t\t'"This Machine"
list="$list"$'\n'"Disconnect"$'\t'"tailscale down"$'\t'"power"$'\t\t'"This Machine"

# Peer lines look like: 100.x.y.z  hostname  user@  os  state…
while read -r ip host _user _os state _rest; do
    case "$ip" in 100.*) ;; *) continue ;; esac
    [[ "$ip" == "$myip" ]] && continue
    if [[ "$state" == "offline" ]]; then
        row="$host"$'\t'"$ip · offline"$'\t'"moon.zzz"$'\t'"Copy IP"$'\t'"Peers"$'\t'"$ip"
    else
        row="$host"$'\t'"$ip"$'\t'"desktopcomputer"$'\t'"Copy IP"$'\t'"Peers"$'\t'"$ip"
    fi
    list="$list"$'\n'"$row"
done <<< "$status"

selected=$(printf '%s\n' "$list" | pounce -p "Tailscale" -i "network.badge.shield.half.filled")
[[ -z "$selected" ]] && exit 0

# Result: action \t title \t subtitle \t icon \t actions \t group \t ip
title=$(printf '%s' "$selected" | cut -f2)
peerip=$(printf '%s' "$selected" | cut -f7)

case "$title" in
    "Copy My IP")
        printf '%s' "$myip" | pbcopy
        notify "Copied $myip"
        ;;
    "Disconnect")
        if "$TS" down >/dev/null 2>&1; then
            notify "Disconnected"
        else
            notify "Could not disconnect"
        fi
        ;;
    *)
        if [[ -n "$peerip" ]]; then
            printf '%s' "$peerip" | pbcopy
            notify "Copied $peerip ($title)"
        fi
        ;;
esac
