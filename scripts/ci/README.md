# GitHub Actions PS4 package build

The `orbis-win-build` ARC runner is restricted to `worker4` and `worker5`. The
workflow is manual or tag-triggered (`v*`) and does not run for pull requests.
It builds one complete ABI-v4 relocatable package with
`scripts/ci/build-abi4-package.sh`, the same script used on the build
workstation. The recipe is the one validated on hardware as GLDS10043 01.06 on
2026-11-05 (GTA IV, FNV, FO3, Oblivion native; MDK translator). The job fails
unless `scripts/check-ps4-package-parity.py` (relocation stub, Vulkan surface,
display, swapchain sizing, quit to launcher, PS4 RADV, PRX exports,
kernelbase diagnostics, signal-mask values)
and `PkgTool.Core pkg_validate` both pass. It uploads the unencrypted `.pkg`,
the two gate reports and a plain-text provenance manifest as a GitHub Actions
artifact.

Package numbering:
- `title_id` (default GLDS10043) picks the install slot and the installer
  filename. GLDS10043 is the test slot. GLDS10044 holds the hardware-validated
  baseline (01.21's tree as GLDS10044 01.01 since 2026-11-05; the 1090
  package before that); build for it only when deliberately promoting a
  fully validated build to replace the control.
- `version` (APP_VER, `NN.NN`) is required on manual runs and has no default.
  Tag runs derive it from the tag (`v1.08` or `v1.8` → `01.08`); other tag
  shapes fail the job. Use a number never used before for that title ID, and
  always increase it. It is how a console install is matched to a build.
  01.01–01.14 were used by local GLDS10043 builds on 2026-11-05, so the first
  CI build is 01.15. Local and CI builds share one sequence per title ID.

This repository is public, so anyone with repository access can download that
package. The CI build uses tracked
GPL-3.0 OpenOrbis source to generate the empty `libc.prx` and `libSceFios2.prx`
package stubs; the manifest records their hashes and source revision.

## One-time private cache setup

The runner's `orbis-win-build-cache` PVC is mounted at `/orbis-cache`. Populate
`/orbis-cache/deps` from the validated build workstation with:

```text
build/ps4-wine-sdk/             generated PS4 compiler support files
build/orbw00053-iret-selectors-wow64native/  validated ABI-v3 PE/PRX pair
mesa-build/                     patched Mesa source and validated build-orbis
openssl11/lib/{libssl,libcrypto}.so.1.1
prospero-win/                   exact Wine source/build/PE/PRX cache
sdk/orbis-sdk-v1/               checksummed OpenOrbis SDK bundle
manifest.txt                    source commits and cache provenance
abi4/source/                    ABI-v4 prospero-win source + .deps/wine-host build/install
abi4/build/wine-ps5/            ABI-v4 Unix Wine build (objects, make.log, prx/)
abi4/native/                    ABI-v4 native WoW64 PE outputs (wow64native.dll)
baseline/pkg-stage/             hardware-validated stage the parity gate compares against
```

`prepare-runner.sh` links `abi4/` to
`/home/zpeirce/codex_scratch/abi4-upstream-port-20261104`, because the ABI-v4
generated makefiles and the `.deps/wine-ps5` symlink embed that path. It links
`baseline/` to `pkgout/baseline`, which locally is a symlink to the promoted
stage (`pkgout/abi4-0121-baseline`). After any
change to the ABI-v4 trees (a ported patch, a rebuilt object), re-run
`scripts/ci/sync-cache.sh` so the runner builds what was validated locally.
Running `scripts/ci/build-abi4-package.sh` locally first, with
`OUT=<scratch dir>`, proves the cache inputs before you sync them.

Run `scripts/ci/sync-cache.sh` from the build workstation to copy these inputs
and refresh their provenance manifest. The package job relinks the Wine PRXs,
PS4 RADV, FreeType and wineps5 from the cached build trees, rebuilds the
kernelbase diagnostics DLL, builds the no-RELRO stub and app PRX, and stages
the matched ABI-v4 `wow64native` pair, whose hashes `build-abi4-package.sh`
pins. The ABI-v3 inputs above remain in the cache for local ABI-v3 builds. This copies the files; it does not move or replace the local
build trees, so ordinary local builds continue to work.
Do not run a cache sync while a GitHub package build is active. The workflow
refuses to run if a required cache input is absent. The PVC is private to the
cluster; do not copy it into GitHub artifacts.

The package scripts and generated Wine makefiles still use the historical
`/home/zpeirce/ps4-gladius` root. `prepare-runner.sh` creates that symlink to the
Actions checkout and links in the private cached dependency trees. This keeps
the tested generated build tree usable without rewriting its embedded paths.

The package step sets `PW_MODULE_STUBS_DIR` to `build/openorbis-module-stubs/`,
which `scripts/build-openorbis-module-stubs.sh` generates from tracked source.
Local package builds still use `sce_module/` unless that variable is set.

## Package artifacts

Download the complete `.pkg` directly from the workflow run's
`orbis-win-<run>-<attempt>` artifact. Verify its hash against
`BUILD-MANIFEST.txt` before installation. The OpenOrbis stub sources and their
GPL-3.0 license are tracked under `src/openorbis-module-stubs/`.

The artifact has a 30-day retention period. Workflow triggers are limited to
manual runs and pushed `v*` tags; do not add public pull-request triggers to a
self-hosted runner with access to the private cache.
