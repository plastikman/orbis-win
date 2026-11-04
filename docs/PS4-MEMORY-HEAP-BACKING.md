# PS4 Wine heap memory handling

This change set contains two separate controls for reducing avoidable flexible
memory use by native 32-bit games on PS4.

## Keep data pages non-executable when requested

`PW_PS4_FORCE_EXEC=0` opts out of Wine's process-wide force-exec behavior for
games whose executable image does not advertise `NX_COMPAT`. Without the
override, Wine can request executable protection for readable data pages; on
PS4 that can trigger the direct-memory exec migration path. The setting is
implemented in patch 1029 and enabled in the Fallout 3 and Fallout: New Vegas
profiles. Leave it unset for other titles unless their behavior has been
validated with the override.

## Back wineserver's private heap with direct memory

The in-process wineserver has its own `pw_wine_heap` instance. Patch 1031
initializes a PS4 direct-memory backing for that heap when
`PW_WINESERVER_HEAP_DIRECT=1` is set. Mappings retain a 64 MiB direct-memory
reserve; if an allocation cannot be served, the existing heap falls back to
anonymous mappings. The feature is enabled for Fallout 3 and Fallout: New Vegas
profiles, and remains off for other titles.

Set `PW_WINESERVER_HEAP_TRACE=1` to log heap and direct-memory counters at
startup and every 500,000 wineserver allocations. It is deliberately not set
by default to avoid routine diagnostic output.

## Hardware validation

On 2026-11-04, Fallout: New Vegas ran with native WoW64, both memory settings
enabled, and `iMultiSample=0` in the active prefix. Repeated V.A.T.S. entries
and a 20-minute idle period completed without a game crash. No DXVK image
allocation failure or storage-guard failure was seen after the MSAA setting
was corrected. Since the active prefix also changed from 8x MSAA to no MSAA,
this run validates the combined configuration but does not isolate which
memory setting prevented the earlier V.A.T.S. failure.

The code keeps direct allocation opt-in, preserves the anonymous fallback, and
does not change DXVK's texture-storage guard. `d3d9.textureMemory=0` is a
separate DXVK workaround and is not part of this memory change set.
