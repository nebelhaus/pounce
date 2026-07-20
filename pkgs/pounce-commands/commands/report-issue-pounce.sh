#!/bin/bash
# pounce: name = Report Pounce Issue
# pounce: description = Open a pre-filled bug report on GitHub
# pounce: icon = ladybug

# Opens github.com/nebelhaus/pounce with a new-issue form pre-filled from a
# template. No hosted .github/ISSUE_TEMPLATE needed — the title/body/labels ride
# in the URL query, so this works even against a repo without one.

repo="nebelhaus/pounce"

# Environment footer, best-effort. `pounce --version` prints "pounce <ver>".
version=$(pounce --version 2>/dev/null | awk '{print $2}')
[ -z "$version" ] && version="unknown"
macos=$(sw_vers -productVersion 2>/dev/null)
[ -z "$macos" ] && macos="unknown"

body="**What happened?**


**What did you expect?**


**Steps to reproduce**
1.
2.
3.

---
- pounce: ${version}
- macOS: ${macos}"

# Pure-bash percent-encoding — no python/jq dependency (the daemon inherits
# launchd's bare PATH, so we can't assume either is on it).
urlencode() {
    local s="$1" out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c" ; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

url="https://github.com/${repo}/issues/new"
url+="?labels=bug"
url+="&title=$(urlencode '[bug] ')"
url+="&body=$(urlencode "$body")"

open "$url"
