#!/bin/bash
# pounce: name = Find Files
# pounce: description = Search files & folders by name
# pounce: icon = doc.text.magnifyingglass
# pounce: submenu = true

# Find Files: a Spotlight-style search for files & folders by name, live as you
# type. Selecting a hit opens it in its default app (⏎), reveals it in Finder
# (⌘⏎), or copies its path (⌥⏎) — all read-only, nothing is moved or deleted.
#
# Re-invokes `pounce` in file-search mode; the daemon swaps it into the live
# palette window (registered submenu=true), so there's no close→reopen flash
# between the launcher and the file search. The search itself runs in-process on
# the daemon's live NSMetadataQuery (the same Spotlight index the app launcher
# uses), scoped to your home directory by default — tune it under `fileSearch`
# in ~/.config/pounce/config.json.
exec pounce --find-files
