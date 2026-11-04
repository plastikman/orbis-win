# Bloodlines profile update — 2026-11-03

The existing `bloodlines-gog` profile was selected and running with native WoW64,
but the game rendered into the upper-left because its prefix registry still held
800x600 while the runtime desktop/swapchain was 1920x1080. The game was closed
before editing the prefix.

## Applied on the PS4

- Prefix: `/data/prospero-win/prefixes/bloodlines-gog/user.reg`
- `[Software\\Troika\\Vampire\\ResPatch]` now has `ScreenWidth=1920`
  (`dword:00000780`) and `ScreenHeight=1080` (`dword:00000438`). Existing BPP
  and windowed settings were preserved.
- Existing profile: `/data/prospero-win/profiles/bloodlines-gog.profile`
  updated to keyboard mode, retaining its profile ID, DXVK selection, 1920x1080
  desktop, and native CPU mode.
- Input: right stick moves the pointer (`mouse_speed=1200`); left stick emits
  WASD (`stick_deadzone=25`); Cross/ R1 left-click; L1 right-click; Circle
  crouches (Ctrl); Square reloads (R); Triangle switches perspective (Z); L2
  feeds (F); R2 uses/interacts (E); L3 blocks (Tab); D-pad sends arrow keys;
  Options sends Escape; Create sends Enter.

The mappings follow the Bloodlines PC manual's keyboard/mouse actions. The
profile uses the existing runtime input mapper; no package rebuild was needed.

## Preservation and verification

Original remote files were retained as:

- `/data/prospero-win/prefixes/bloodlines-gog/user.reg.pre-1080p-20261103`
- `/data/prospero-win/profiles/bloodlines-gog.profile.pre-kbm-20261103`

The updated profile and registry were retrieved after upload and matched their
local candidate SHA-256 hashes. Backup copies and readbacks are under
`/home/zpeirce/codex_scratch/bloodlines-profile/`.

Next check: launch Bloodlines and confirm the full-screen image is centered at
1080p and pointer/buttons operate as mapped. If the image remains cornered, keep
the resolution registry fix in place and investigate the game's swapchain/window
scaling separately; this update does not change DXVK code.

## Cross-console comparison goal

Bloodlines is also being tested by Max on a PS4 Slim. Treat this as a
cross-console performance comparison: keep the game build, native CPU mode,
resolution, graphics settings, scene/save, and measurement interval aligned
where possible. Record boot-to-menu time and gameplay FPS/frametime on each
console, along with hardware model and package hash. The current run only
confirms that Bloodlines reached the menu under the current native runtime; it
did not capture a matched performance baseline, so it cannot yet establish a
performance difference between consoles.

## OSK trigger fix and test package

The shared prospero-win 0.3.x OSK bridge is already in the relocated app PRX and
opens the Orbis IME after a two-finger touchpad click. The PS4 platform adapter
was the missing link: `src/native/pw_pad_ps4.c` copied buttons/sticks/triggers
from `OrbisPadData` but left `PwPadPs5Data.touch_data` zeroed. As a result,
`pad.touch_fingers >= 2` could never be true on PS4, even though IME preload
succeeded. The adapter now forwards the PS4 touch count and both touch samples
by field, allowing the existing shared gesture and IME flow to run. No input
polling loop, memory, or Wine runtime behavior was changed.

Built package 1100 from clean `prospero-win` HEAD `75f25351354b866e8cae8c17e828e386651ddb7e`
plus the PS4 touch-data forwarding change. It is a relocatable split-runtime
package; the eboot retains the no-RELRO/high-RW layout. The split package-stage
comparison against `pkgout/wine-app-split-runtime/pkg-stage` has the expected
changes in `eboot.bin`, `sce_module/relocated_wine_app.prx`, `pkg.gp4`, and
`param.sfo`; no Wine runtime files are included or replaced.

```text
Installer: IV0000-GLDS10044_00-GLDS100440000000.pkg
Local: /home/zpeirce/codex_scratch/bloodlines-osk-touch-1100-clean/package/IV0000-GLDS10044_00-GLDS100440000000.pkg
Size: 6,619,136 bytes
SHA-256: e3a096a165a57906b4f3e656b0645c7450b2bc1ebd08c01fa3d2bebfe0c03e43
FTP: /data/pkg/IV0000-GLDS10044_00-GLDS100440000000.pkg; RETR readback matched
```

Hardware check is pending. Install that exact filename, launch Bloodlines in
native mode, focus the character-name field, and click the touchpad with two
fingers. Check that the IME opens; the launch log should show a touchpad event
with `fingers=2` followed by `keyboard shown=1`. Enter a short ASCII name and
accept it to confirm the text reaches the focused field. The prior handoff's
`osk preload ... status=0` only proved module preload, not that the gesture
opened the keyboard.

## 1100 correction after immediate return to launcher

The first 1100 package installed and returned to the launcher immediately.
The active PS5 log showed this was before Wine/game startup: the split package
could not find `ntdll.prx` under either `/app0` or the sandbox `/app0`, then
reported `load status=-2147352574 stage=1` (`ENOENT`). This was caused by
installing an app-only package without a usable external Wine runtime.

The first attempt to upload the split runtime appeared successful, but FTP
readback of the NTDLL path returned 3,550,832 bytes with different content
while FTP LIST reported the expected 1,061,632-byte length. The same mismatch
occurred for a new temporary filename, so the split runtime was not trusted.
The uploaded directories were retained under
`/data/prospero-win/runtime-pre-bloodlines-osk-1100` and
`/data/prospero-win/runtime-bloodlines-osk1100-override-disabled`; the active
`/data/prospero-win/runtime` override is therefore absent and cannot shadow
the installed package runtime.

Replaced the installer at the same canonical FTP path with the matching full
relocatable package, built from the same PS4 touch-data forwarding source and
including its full runtime under `/app0`. Relocation remains enabled. The
package was fully retrieved from the console and SHA-256 verified:

```text
Installer: IV0000-GLDS10044_00-GLDS100440000000.pkg
Local: /home/zpeirce/codex_scratch/bloodlines-osk-touch-1100/base/IV0000-GLDS10044_00-GLDS100440000000.pkg
Remote: /data/pkg/IV0000-GLDS10044_00-GLDS100440000000.pkg
Size: 447,938,560 bytes
SHA-256: b984d95c5278ba8248f1b08fc523317b66e5d485a0fd01d31a98b39603b4b39a
```

The 6.3 MiB app-only package is not the one to install. The next run should
install the exact full package above, then confirm the log finds NTDLL in
`/app0` and reaches Wine startup before testing the two-finger OSK gesture.

## OSK report and corrected package (2026-11-03 evening)

The first runner-produced package did not include the local PS4 touchpad adapter
change: CI built root commit `9b97a18`, while the PS4 `pw_pad_ps4.c` change was
still only in the workstation. Its PS4 pad adapter zeroed `PwPadPs5Data.touch_data`,
so the shared `touch_fingers >= 2` gesture could never fire. Separately, the
console's `bloodlines-gog.profile` had no `[display] menu = true`; therefore
L3+R3 did not open the game overlay, and its Keyboard input action was not
available. The prior preload log only proved that `libSceImeDialog` loaded.

Corrected both causes:

- Added PS4 touchpad finger count and both touch samples to the adapter in
  commit `e277161` (`fix: forward PS4 touchpad input for OSK`). The code is now
  pushed to `ps4/no-relro-eboot-1090`.
- Set `menu = true` in the live profile at
  `/data/prospero-win/profiles/bloodlines-gog.profile`; FTP readback matches the
  815-byte candidate (SHA-256
  `031ba6671e6384b4bfc777e549895bf9331b2fe617cda5381d605ab4b1752f0b`). The
  repository profile copy has the same setting.
- Built a full, relocatable package locally, retaining the existing runtime,
  fonts, module stubs, and no-RELRO relocation fix. Do not install the earlier
  6.3 MiB split app-only artifact.

```text
Installer: IV0000-GLDS10044_00-GLDS100440000000.pkg
Local: /home/zpeirce/codex_scratch/bloodlines-osk-touch-1101/package/IV0000-GLDS10044_00-GLDS100440000000.pkg
Remote: /data/pkg/IV0000-GLDS10044_00-GLDS100440000000.pkg
Size: 445,644,800 bytes
SHA-256: bc9f46a89f36e568d4608f22a479dee6a5c55a9afa18674d4f3d228d7ea5224e
```

The FTP readback hash matches. Hardware validation passed on the PS4. The
runtime log records
`keyboard shown=1 init=0`, then `keyboard ended result=0 outcome=0 characters=4`;
the photo shows the four accepted characters appended to Bloodlines' prefilled
`UNNAMED` field. The user selected and deleted the prefilled name, confirming
the normal in-game edit path works too. The two-finger touchpad OSK is usable
for character-name entry end-to-end. The L3+R3 menu route is enabled in the
profile, but the user validated the touchpad route directly.
