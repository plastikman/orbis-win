# PS4 external USB storage

Orbis-Win can expose a USB volume already mounted by the PS4 to a Windows game.
The console mounts supported FAT/exFAT media; Orbis-Win does not implement an
exFAT driver. The PS4 title sandbox normally cannot see `/mnt`, so this feature
uses GoldHEN's optional title jailbreak request. The marker is honored only by
packages built with the Orbis-Win external-storage source change; older releases
ignore it.

## Enable it

Create an empty marker file:

```text
/data/prospero-win/external-storage.enabled
```

Create it over GoldHEN FTP, then restart Orbis-Win and launch the game. Remove
the file and restart to return to sandbox-only access. Without GoldHEN, the
request fails safely and the game starts without external drives.

The marker applies to every game launched by this Orbis-Win install. When
enabled, GoldHEN restores the title's original UID while retaining the expanded
filesystem view, and Orbis-Win restores the saved jail state before handing
control back to the launcher or closing.

This exposes the PS4's existing mount to Wine; it does not mount or format a
drive. USB game reads and writes still need hardware qualification with the
target filesystem and console firmware.

## Drive letters

Mounted `/mnt/usb0` through `/mnt/usb7` become `D:` through `K:` in the game's
Wine prefix. Empty console USB slots are omitted. The drive map is refreshed
when the game process starts; connect or remove a drive between runs and
restart the game to refresh it. The prefix stores the mapping in the same
`.pw-symlinks` sidecar used for Wine's other virtual DOS links.

Use the PS4's safe-removal action before disconnecting a drive. Do not unplug
storage while the console is using it.

## Console acceptance

1. With the marker absent, launch Orbis-Win and confirm it remains sandboxed.
2. Attach a PS4-mounted FAT or exFAT USB drive, create the marker, and relaunch.
   Confirm the log reports storage enabled and the expected slot mask.
3. Launch a test title from `D:` (or the corresponding mapped drive) and confirm
   it can read its files. If testing writes, use a disposable game folder.
4. Remove the marker and relaunch; confirm the drive letters are no longer
   published. Repeat after a safe disconnect/reconnect to check slot refresh.
