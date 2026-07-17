#!/bin/bash
# pounce: name = GitHub
# pounce: description = Your PRs, issues & repos
# pounce: icon = arrow.triangle.branch
# pounce: submenu = true

# GitHub jump menu — pick a category, then fuzzy-pick the PR/issue/repo and it
# opens in the browser.
# Needs an authenticated gh CLI:  brew install gh && gh auth login

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
    osascript -e "display notification \"${1//\"/}\" with title \"GitHub\""
}

# Guards answer through pounce, not a notification: for a submenu command the
# palette is already showing a loading panel, and only a pounce call fills it.
if ! command -v gh >/dev/null 2>&1; then
    printf 'gh not found\tbrew install gh && gh auth login\texclamationmark.triangle' \
        | pounce -p "GitHub" -i "arrow.triangle.branch" >/dev/null
    exit 0
fi

menu="My Pull Requests"$'\t'"Open PRs you authored"$'\t'"arrow.triangle.branch"
menu="$menu"$'\n'"Review Requests"$'\t'"PRs waiting on your review"$'\t'"eye"
menu="$menu"$'\n'"My Issues"$'\t'"Open issues assigned to you"$'\t'"exclamationmark.circle"
menu="$menu"$'\n'"My Repositories"$'\t'"Jump to one of your repos"$'\t'"folder"
menu="$menu"$'\n'"Notifications"$'\t'"github.com/notifications"$'\t'"bell"

selected=$(printf '%s\n' "$menu" | pounce -p "GitHub" -i "arrow.triangle.branch")
[[ -z "$selected" ]] && exit 0
choice=$(printf '%s' "$selected" | cut -f2)

# Each gh call yields "title \t subtitle \t url" lines (jq @tsv escapes any
# embedded tabs).
case "$choice" in
    "My Pull Requests")
        prompt="Your open PRs"; icon="arrow.triangle.branch"
        data=$(gh search prs --author=@me --state=open --limit 30 \
            --json title,repository,number,url \
            --jq '.[] | [.title, "\(.repository.nameWithOwner) #\(.number)", .url] | @tsv' 2>/dev/null)
        ;;
    "Review Requests")
        prompt="PRs to review"; icon="eye"
        data=$(gh search prs --review-requested=@me --state=open --limit 30 \
            --json title,repository,number,url \
            --jq '.[] | [.title, "\(.repository.nameWithOwner) #\(.number)", .url] | @tsv' 2>/dev/null)
        ;;
    "My Issues")
        prompt="Your open issues"; icon="exclamationmark.circle"
        data=$(gh search issues --assignee=@me --state=open --limit 30 \
            --json title,repository,number,url \
            --jq '.[] | [.title, "\(.repository.nameWithOwner) #\(.number)", .url] | @tsv' 2>/dev/null)
        ;;
    "My Repositories")
        prompt="Your repositories"; icon="folder"
        data=$(gh repo list --limit 50 \
            --json nameWithOwner,description,url \
            --jq '.[] | [.nameWithOwner, .description // "", .url] | @tsv' 2>/dev/null)
        ;;
    "Notifications")
        open "https://github.com/notifications"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac

if [[ -z "$data" ]]; then
    notify "Nothing found — is gh authenticated? (gh auth status)"
    exit 0
fi

# Rows: title \t subtitle \t icon \t\t\t url — the URL rides along as a hidden
# trailing field the UI ignores but echoes back on selection.
list=""
while IFS=$'\t' read -r title subtitle url; do
    [[ -z "$title" ]] && continue
    row="$title"$'\t'"$subtitle"$'\t'"$icon"$'\t\t\t'"$url"
    if [[ -n "$list" ]]; then list="$list"$'\n'"$row"; else list="$row"; fi
done <<< "$data"

selected=$(printf '%s\n' "$list" | pounce -p "$prompt" -i "$icon")
[[ -z "$selected" ]] && exit 0

url=$(printf '%s' "$selected" | cut -f7)
[[ "$url" == https://* ]] && open "$url"
