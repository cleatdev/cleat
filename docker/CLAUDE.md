# Clipboard

This environment runs inside Docker with clipboard bridge forwarding.
`xclip`, `pbcopy`, `xsel`, and `clip` all work for COPYING text to the host clipboard.
The primary mechanism writes to a shared file that the host picks up automatically.
OSC 52 terminal escape sequences are used as a fallback when the bridge is unavailable.
Paste/read-back (`xclip -o`, `xsel -o`, `pbpaste`) is not supported — do NOT try to verify clipboard contents after copying.
The copy succeeded if the command exits 0. Do not run a second command to check.
