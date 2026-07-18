#!/bin/bash
# pounce: name = Lowercase
# pounce: description = Lowercase the selected text
# pounce: icon = textformat

# Lowercase: replace the current selection with an all-lowercase version — the
# sibling of Capitalize, same `pounce --transform` primitive with the `tr`
# direction flipped.
exec pounce --transform 'tr "[:upper:]" "[:lower:]"'
