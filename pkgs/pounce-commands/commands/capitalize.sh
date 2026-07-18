#!/bin/bash
# pounce: name = Capitalize
# pounce: description = Uppercase the selected text
# pounce: icon = textformat

# Capitalize: replace the current selection with an ALL-UPPERCASE version.
# Copies the selection (synthetic ⌘C), runs it through `tr`, and pastes the
# result back (synthetic ⌘V) — all inside the daemon, which holds the
# Accessibility grant (`pounce --request-accessibility`). The transform itself
# is just this one-line shell filter; swap `tr` for anything to make a new text
# action. See `pounce --transform`.
exec pounce --transform 'tr "[:lower:]" "[:upper:]"'
