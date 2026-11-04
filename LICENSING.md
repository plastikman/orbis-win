# Licensing

Project-authored code in `orbis-win` is licensed under the GNU Lesser General
Public License, version 2.1 or (at your option) any later version. The full
license text is in [`LICENSE`](LICENSE). This follows the license used by
[`prospero-win`](https://github.com/mpereiraesaa/prospero-win), which this
repository ports to the PS4.

Individual SPDX identifiers and copyright notices take precedence for the
files that carry them. For example, `src/gfx-hang-probe/main.c` is MIT-licensed;
the corresponding MIT license text is in [`LICENSES/MIT.txt`](LICENSES/MIT.txt).

Patch files under `src/wine-patches-ps4/`, `src/prospero-win-patches-ps4/`,
`src/mesa-patches-ps4/` and `patches/` are intended to be applied to their
respective upstream projects. They do not replace the copyright notices or
license terms of the upstream source they modify. When distributing a patched
build, comply with the license of each component and preserve its notices.

The repository license does not cover separately fetched SDKs, Wine/Mesa/DXVK
sources, console firmware modules, game files, or generated packages. Those
remain subject to their own terms and are not included here.
