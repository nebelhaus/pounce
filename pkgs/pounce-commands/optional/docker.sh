#!/bin/bash
# pounce: name = Docker
# pounce: description = Start, stop & inspect containers
# pounce: icon = shippingbox.fill
# pounce: submenu = true

# Container picker for the docker CLI — works with any engine that answers
# `docker ps` (Docker Desktop, OrbStack, colima, …).

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
    osascript -e "display notification \"${1//\"/}\" with title \"Docker\""
}

# Guards answer through pounce, not a notification: for a submenu command the
# palette is already showing a loading panel, and only a pounce call fills it.
if ! command -v docker >/dev/null 2>&1; then
    printf 'docker not found\tInstall Docker Desktop, OrbStack or colima\texclamationmark.triangle' \
        | pounce -p "Docker" -i "shippingbox.fill" >/dev/null
    exit 0
fi

if ! docker info >/dev/null 2>&1; then
    selected=$(printf 'Start Docker\tThe engine is not running\tplay.circle' \
        | pounce -p "Docker" -i "shippingbox.fill")
    if [[ -n "$selected" ]]; then
        open -a "Docker" 2>/dev/null || open -a "OrbStack" 2>/dev/null \
            || notify "Could not find Docker Desktop or OrbStack to open"
    fi
    exit 0
fi

list=""
add() {
    if [[ -n "$list" ]]; then list="$list"$'\n'"$1"; else list="$1"; fi
}

while IFS=$'\t' read -r name state image; do
    [[ -z "$name" ]] && continue
    case "$state" in
        running)
            add "$name"$'\t'"Running · $image"$'\t'"play.fill"$'\t'"Stop|cmd:Restart|opt:Logs"
            ;;
        paused)
            add "$name"$'\t'"Paused · $image"$'\t'"pause.fill"$'\t'"Unpause|cmd:Stop|opt:Logs"
            ;;
        *)
            add "$name"$'\t'"${state} · $image"$'\t'"stop.fill"$'\t'"Start|cmd:Remove|opt:Logs"
            ;;
    esac
done < <(docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Image}}' 2>/dev/null)

if [[ -z "$list" ]]; then
    printf 'No containers\tThe engine is running — nothing to manage yet\tshippingbox' \
        | pounce -p "Docker" -i "shippingbox.fill" >/dev/null
    exit 0
fi

result=$(printf '%s\n' "$list" | pounce -p "Docker Containers" -i "shippingbox.fill")
[[ -z "$result" ]] && exit 0

# Result: action \t name \t subtitle \t icon \t actions
action=$(printf '%s' "$result" | cut -f1)
name=$(printf '%s' "$result" | cut -f2)
state=$(printf '%s' "$result" | cut -f3)

show_logs() {
    local f="${TMPDIR:-/tmp}/pounce-docker-${name}.log"
    docker logs --tail 500 "$name" >"$f" 2>&1
    open -a "Console" "$f" 2>/dev/null || open "$f"
}

case "$action" in
    enter)
        case "$state" in
            Running*)
                docker stop "$name" >/dev/null 2>&1 && notify "Stopped $name"
                ;;
            Paused*)
                docker unpause "$name" >/dev/null 2>&1 && notify "Unpaused $name"
                ;;
            *)
                if docker start "$name" >/dev/null 2>&1; then
                    notify "Started $name"
                else
                    notify "Could not start $name"
                fi
                ;;
        esac
        ;;
    cmd)
        case "$state" in
            Running*)
                docker restart "$name" >/dev/null 2>&1 && notify "Restarted $name"
                ;;
            Paused*)
                docker stop "$name" >/dev/null 2>&1 && notify "Stopped $name"
                ;;
            *)
                response=$(osascript -e "display dialog \"Remove container ${name//\"/}?\" buttons {\"Cancel\", \"Remove\"} default button \"Cancel\"" 2>/dev/null)
                if [[ "$response" == *"Remove"* ]]; then
                    docker rm "$name" >/dev/null 2>&1 && notify "Removed $name"
                fi
                ;;
        esac
        ;;
    opt)
        show_logs
        ;;
esac
