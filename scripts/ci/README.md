# GitHub Actions PS4 package build

The `orbis-win-build` ARC runner is restricted to `worker4` and `worker5`. The
workflow is manual or tag-triggered (`v*`) and does not run for pull requests.
It builds the relocatable split-runtime app package and its complete base
package, then uploads the unencrypted `.pkg` files plus a plain-text provenance
manifest as a GitHub Actions artifact. This repository is public, so anyone
with repository access can download those packages. The CI build uses tracked
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
```

Run `scripts/ci/sync-cache.sh` from the build workstation to copy these inputs
and refresh their provenance manifest. The package job rebuilds the other PRXs,
then restores this exact verified ABI-v3 PE/PRX pair because the package stage
checks both hashes. This copies the files; it does not move or replace the local
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

Download the app and base `.pkg` files directly from the workflow run's
`orbis-win-<run>-<attempt>` artifact. Verify their hashes against
`BUILD-MANIFEST.txt` before installation. The OpenOrbis stub sources and their
GPL-3.0 license are tracked under `src/openorbis-module-stubs/`.

The artifact has a 30-day retention period. Workflow triggers are limited to
manual runs and pushed `v*` tags; do not add public pull-request triggers to a
self-hosted runner with access to the private cache.
