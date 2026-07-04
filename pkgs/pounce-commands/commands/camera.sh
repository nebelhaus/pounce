#!/bin/bash
# pounce: name = Camera
# pounce: description = Quick peek through your camera
# pounce: icon = web.camera
# pounce: submenu = true

# Camera peek (à la Raycast): swaps the palette into a live, mirrored camera
# preview. Enter or Esc closes; ⇧Enter opens a dropdown to pick between all
# available cameras (the choice is remembered for next time).
#
# The preview is rendered natively by the daemon (--camera mode) — AVFoundation
# lives in the Swift binary, not here. Registered submenu=true so the palette
# swaps straight into the preview with no close→reopen flash.
exec pounce --camera
