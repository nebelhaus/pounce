#!/bin/bash
# pounce: name = Emoji
# pounce: description = Search & paste emoji
# pounce: icon = face.smiling
# pounce: submenu = true

# Emoji Picker: open the emoji grid with fuzzy name/keyword search. Enter copies
# the highlighted emoji to the clipboard — and, when clipboard.autoPaste is
# enabled and the daemon holds Accessibility, pastes it straight at the cursor
# of the previously focused app, like clipboard history. Frecency floats
# frequently used glyphs to the top.
#
# Re-invokes `pounce` in emoji mode; the daemon swaps it into the live palette
# window (this command is registered submenu=true), so there's no close→reopen
# flash between the palette and the picker.
exec pounce --emoji
