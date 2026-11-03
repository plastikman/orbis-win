# GitHub Actions PS4 package build

The `orbis-win-build` ARC runner is restricted to `worker4` and `worker5`. The
workflow is manual or tag-triggered (`v*`) and does not run for pull requests.
It builds the relocatable split-runtime app package and its complete base
package, then uploads only age-encrypted packages plus a plain-text provenance
manifest. Sony firmware modules are kept in the private runner cache and never
published in plaintext.

## One-time private cache setup

The runner's `orbis-win-build-cache` PVC is mounted at `/orbis-cache`. Populate
`/orbis-cache/deps` with these paths from the validated build workstation:

```text
build/ps4-wine-sdk/             generated PS4 compiler support files
mesa-build/                     patched Mesa source and validated build-orbis
openssl11/lib/{libssl,libcrypto}.so.1.1
prospero-win/                   exact Wine source/build/PE/PRX cache
sce_module/{libc,libSceFios2}.prx  private firmware modules
sdk/orbis-sdk-v1/               checksummed OpenOrbis SDK bundle
manifest.txt                    source commits and cache provenance
```

The workflow refuses to run if a required cache input is absent. Refresh this
cache deliberately when the pinned Wine or Mesa base changes. The PVC is private
to the cluster; do not copy it into GitHub artifacts.

The package scripts and generated Wine makefiles still use the historical
`/home/zpeirce/ps4-gladius` root. `prepare-runner.sh` creates that symlink to the
Actions checkout and links in the private cached dependency trees. This keeps
the tested generated build tree usable without rewriting its embedded paths.

## Artifact decryption

Packages contain Sony firmware modules, so the workflow encrypts each `.pkg`
with age before uploading. Configure repository variable `PKG_AGE_RECIPIENT`
with the public recipient from the private identity created for this project.
Keep the corresponding private identity outside the repository and cluster.
Decrypt an artifact on the build workstation with:

```sh
age --decrypt --identity ~/.config/orbis-win/pkg-build-age.key \
  --output package.pkg package.pkg.age
```

The artifact has a 30-day retention period. Workflow triggers are limited to
manual runs and pushed `v*` tags; do not add public pull-request triggers to a
self-hosted runner with access to the private cache.
