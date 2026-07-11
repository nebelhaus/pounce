#!/bin/bash
# pounce: name = SSH Hosts
# pounce: description = Connect to a host from ~/.ssh/config
# pounce: icon = terminal
# pounce: submenu = true

# Host picker over ~/.ssh/config (Include'd files too, one level deep).
# Enter opens ssh://<host> — macOS routes that to your default terminal.
# ⌘↵ copies the ssh command instead.

notify() {
    osascript -e "display notification \"${1//\"/}\" with title \"SSH Hosts\""
}

config="$HOME/.ssh/config"
if [[ ! -f "$config" ]]; then
    notify "No ~/.ssh/config found"
    exit 0
fi

# The config plus anything it Includes (globs allowed, relative to ~/.ssh).
files=("$config")
while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    pat="${pat/#\~/$HOME}"
    [[ "$pat" != /* ]] && pat="$HOME/.ssh/$pat"
    for f in $pat; do
        [[ -f "$f" ]] && files+=("$f")
    done
done < <(awk 'tolower($1) == "include" { for (i = 2; i <= NF; i++) print $i }' "$config")

# Host blocks → "host \t hostname" (wildcard patterns skipped, first block wins).
hosts=$(awk '
    tolower($1) == "host" {
        n = 0
        for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) block[++n] = $i
        for (i = 1; i <= n; i++)
            if (!(block[i] in dest)) { dest[block[i]] = ""; order[++total] = block[i] }
        next
    }
    tolower($1) == "hostname" {
        for (i = 1; i <= n; i++) if (dest[block[i]] == "") dest[block[i]] = $2
    }
    END { for (i = 1; i <= total; i++) printf "%s\t%s\n", order[i], dest[order[i]] }
' "${files[@]}")

if [[ -z "$hosts" ]]; then
    notify "No Host entries in ~/.ssh/config"
    exit 0
fi

list=""
while IFS=$'\t' read -r host dest; do
    [[ -z "$host" ]] && continue
    row="$host"$'\t'"$dest"$'\t'"terminal"$'\t'"Connect|cmd:Copy ssh command"
    if [[ -n "$list" ]]; then list="$list"$'\n'"$row"; else list="$row"; fi
done <<< "$hosts"

selected=$(printf '%s\n' "$list" | pounce -p "SSH Hosts" -i "terminal")
[[ -z "$selected" ]] && exit 0

# Result: action \t host \t hostname \t icon \t actions
action=$(printf '%s' "$selected" | cut -f1)
host=$(printf '%s' "$selected" | cut -f2)

case "$action" in
    cmd)
        printf 'ssh %s' "$host" | pbcopy
        notify "Copied: ssh $host"
        ;;
    *)
        open "ssh://$host"
        ;;
esac
