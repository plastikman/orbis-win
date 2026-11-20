# PS4 MMDevAPI fix payload

These two PE modules were built from Wine source commit
`490f6d5dcbb2a5047345b8af88d114bbcaad69a8` with
`src/wine-patches-ps4/1036-mmdevapi-keep-persisted-audio-names.patch` applied.
The normal PE install in the cached ABI-v4 build predates this patch, so the
package job overlays this matched architecture pair and records each hash in
`BUILD-MANIFEST.txt`.

| File | SHA-256 |
| --- | --- |
| `mmdevapi-i386.dll` | `ba4fa55c0b70c803492368b63cd4248c329d4ca1789701e5c00e4fad0f86c88d` |
| `mmdevapi-x86_64.dll` | `765bda2ffbe01dc191b72aac3a8b61137ef6a6d7018df84e6d296d1aa5709b80` |
