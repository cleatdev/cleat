# Clipboard

This environment runs inside Docker with clipboard bridge forwarding.
`xclip`, `pbcopy`, `xsel`, and `clip` all work for COPYING text to the host clipboard.
The primary mechanism writes to a shared file that the host picks up automatically.
OSC 52 terminal escape sequences are used as a fallback when the bridge is unavailable.
Reading text back (`xclip -o`, `xsel -o`, `pbpaste`) is not supported. An image the user pastes with ctrl+v reaches Claude Code on its own, so never read the clipboard yourself. Do NOT try to verify clipboard contents after copying.
The copy succeeded if the command exits 0. Do not run a second command to check.
