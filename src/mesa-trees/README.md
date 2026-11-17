# mesa-ps4 tree pin

| base | pin |
|---|---|
| `orbis-ports/mesa-ps4` `1a59cc147b54` (branch `orbis`, public) | see `mesa-ps4-HEAD.txt` |

    scripts/restore-mesa-tree.sh <dir>

## Why not the patch series

`src/mesa-patches-ps4` applies **35 of 45**; 9 fail, including
`0041-resync-the-series-with-the-shipped-tree.patch`, which defines
`wsi_orbis_cursor_update`. Without it the RADV PRX link fails:

    Failed to build FSELF: missing library for symbol (wsi_orbis_cursor_update)

Before this pin the only copy of the delta was 27 uncommitted files in one
workstation's `mesa-build/`. The series stays useful for review; the bundle is
what reproduces a build.

Verified 2026-11-17: restored into a fresh clone and diffed against the built
tree — no source differences (only meson/`__pycache__` byproducts).
