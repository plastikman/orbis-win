# Orbis-Win v0.0.7

## Audio device initialization

Fix repeated wrapping of persisted Windows audio endpoint names during Wine
startup. This keeps the saved `Speakers (...)` and `Microphone (...)` names
stable across launches. The package includes matching 32-bit and 64-bit
MMDevAPI modules built from the patched Wine source.

## Runtime package

The v0.0.7 console package uses app version **02.16**. It retains the existing
relocatable launcher and PS4 runtime payload, with the MMDevAPI fix above.
`BUILD-MANIFEST.txt` records package and module hashes.
