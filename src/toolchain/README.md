# The toolchain shim

`prospero-clang` presents the OpenOrbis SDK under the name
`tools/build_wine_ps5.sh` demands. It lives here, in git, and is copied to
`build/ps4-wine-sdk/bin/` — which is ignored — because it is not generated:
it carries a dozen decisions that were each measured on hardware, and losing it
would mean rediscovering all of them.

The ones that cost the most to find:

| flag | why |
|---|---|
| `-fno-visibility-from-dllstorageclass` | the PS4 target silently overrides `visibility("default")`, the branch Wine's `DECLSPEC_EXPORT` takes, so every Unix-side export compiled to `GLOBAL HIDDEN` and the modules exported only libc |
| `-z separate-loadable-segments` | Orbis pages are 16 KiB and the loader checks that each `PT_LOAD` *starts* on one; `max-page-size` alone only keeps `offset ≡ vaddr (mod page)` and still left segment 1 at `0x13fae0` |
| `-lSceLibcInternal` before `-lc` | the SDK ships libc only as a static archive, so each module otherwise gets a private `__environ` and the title's `setenv` never reaches Wine's `getenv` |
| `prx_init_array.ld` | `__attribute__((constructor))` emits `.ctors` on this target, not `.init_array`, so prospero-win's `module_start` walked an empty range and no constructor ran |
| `module_param.o` (not `crtlib.o`) | a module needs `.data.sce_module_param` or create-fself crashes, but `crtlib.o` also defines `module_start`/`module_stop`, which the PRXDESC1 descriptor already provides |
| `PW_PRX_LINK=1` | `libwineshim.a` is this port's stand-in for `wine/ps5/*`; linking both defines every `__wrap_*` twice |

The shim discovers the repo root from its own path and uses the paired SDK
bundle's headers, linker script and compatibility archive by default. Set
`MESA_BUILD` only when deliberately building against another matching
SDK/compatibility tree. Keep this copy and the build one in step;
`scripts/sync-toolchain.sh` copies src → build and reports any drift.
