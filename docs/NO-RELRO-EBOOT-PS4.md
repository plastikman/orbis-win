# PS4 relocatable Wine eboot without `PT_SCE_RELRO`

The relocatable app releases its low-address stub eboot before loading the
Windows guest. Max's PS4 module-loader probe found that the PS4 loader
re-applies module 0's `PT_SCE_RELRO` protection on later module loads, over
whatever mappings occupy that address range at the time. A RELRO segment in
the released eboot can therefore make reused guest pages read-only and
non-executable. The tested fix is to build the stub eboot without
`PT_SCE_RELRO`.

The eboot's writable data must remain mapped after its code is released:
libkernel's `sceKernelGetModuleList` reads module 0's data segment after the
release. The linker script puts that segment at `0x7fff0000`, in the 64 KiB
no-access window above 32-bit guest allocations. The current layout is:

```text
RX: 0x400000..0x409a70    released before guest startup
RW: 0x7fff0000..0x7fff1060 retained for libkernel
PT_SCE_RELRO: absent
```

`create-fself` v0.5.4 requires a `PT_GNU_RELRO` input header but drops it when
there is no `.data.rel.ro` section. The build links with `-z norelro`, folds
`.data.rel.ro` into `.data`, then converts the unused `PT_GNU_STACK` header
into an empty `PT_GNU_RELRO` for `create-fself`. The tool checks the linked ELF
and final OELF layout. The eboot-only link omits the whole-archived
`liborbis-compat.a`; that archive's `carve` BSS would exceed the reserved
64 KiB window and is not needed by the stub.

The relocatable builder enables this layout by default. Set
`PW_EBOOT_NO_RELRO=0` only for a deliberate comparison with the prior eboot
layout. Exec migration and the rest of the known-good runtime fixes remain
enabled; this change does not remove or replace them.

## Hardware validation

Package 1090 was built from the exact 1088 package stage, changing the eboot
only; all 1,791 non-eboot payload files matched 1088. The uploaded installer
was read back over FTP and its hash matched the local package. On 2026-11-03,
the user confirmed Oblivion and Fallout: New Vegas worked, and Fallout 3 reached
gameplay. The FO3 log showed active Vulkan present calls and no DMEM allocation
failures at the observed point. This validates the new eboot layout across the
three titles with the other memory fixes retained; it does not prove those
fixes can be removed.

```text
Installer: IV0000-GLDS10044_00-GLDS100440000000.pkg
SHA-256: 4714c41a6522d155527a88cd57ae256cd668709ea45164c9e62a15cd558b2023
Size: 449,183,744 bytes
Eboot SHA-256: 5e6819e52d7031e20633e38229d33764139654f044a876dddbc62da685f4fd58
FO3 app log: /home/zpeirce/codex_scratch/fnv-no-relro-kept-data-1090/run-20261103/build-ps4-logs/ps5log-20261103-063201.log
```

The linker/converter layout is adapted from Max's `ps4-wine` changes at
`1799f8a92c3197fd3483b8e07ebc609deb87aa82` and
`6394f19f74e1ff0f845c153a0cf41d3196642c51`.
