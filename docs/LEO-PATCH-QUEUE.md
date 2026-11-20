# Leo's prospero-win patches not yet in Orbis-Win

## STATUS 2026-11-12: ported, and nothing portable remains

39 of the 66 are ported as `src/wine-patches-ps4/1036-1074`, in five batches,
each built and tested on hardware (FNV 37.1-39.0 in-world throughout, against
a 37.8 baseline). The remaining 27 are NOT a backlog of missing features:

| class | count | meaning |
|---|---|---|
| already present as our own variant | ~24 | convergence work, not porting |
| needs Leo's PS5 runtime files | 2 | `0976` wants `wine/ps5/pw_wine_sections.c`; `1010` wants `../pw_title_notify.h` |
| genuinely absent | **0** | - |

**The `frac` column below is unreliable and must not be used to decide.**
Measured today: `0510` scored `0.00` while we had it in full (ours is a
superset with `__x86_64__` and a `WINE_HOST_PAGE_SIZE` override); `0530` and
`0879` likewise scored low while being fully present, `0879` including Leo's
own comment text verbatim plus our `poll()` improvement. Content matching
cannot see through a divergent implementation. Three triage calls were wrong
because they searched Leo's *prose* terms (`wake_pipe`) instead of the code's
symbols; the only check that settled each case was reading our implementation
of the same function.

Ordering is load-bearing when applying: `0989` needs `0987`, and `0966`,
`0990`, `0992` need `0951`/`0990`, so a single pass makes them look like
conflicts. Two passes picks them up.

What is left is the convergence decision, not porting: per AGENTS.md, prefer
upstream's implementation and justify any divergence we keep. The eight
`ps5drv.c` cursor/window patches are the largest cluster and want their own
test cycle.

---


Audited by content with `scripts/audit-patch-presence.py` against
`worktrees/playden-ps4-0170/.deps/wine-ps5/source` on 2026-11-12, from `leo/main`
(`leolobato/prospero-win`, fetched as remote `leo` in `prospero-win/`).

**169 of Leo's patches: 103 present, 18 partial, 48 absent.** Only the 66 that are not
fully present are listed. `frac` is how much of the patch's added code was found, so a
high partial is usually a near-miss worth diffing rather than a fresh port.

⚠ Numbers collide with Orbis-Win's own series (our 0981 is a different patch from his).
Port by content, give each a new Orbis-Win number, and keep his subject for provenance.

## 1. Threads, waits and alerts (4)

| status | frac | patch | what it does |
|---|---|---|---|
| partial | 0.87 | `0680-server-ps5-wait-watchdog.patch` | server: A wait watchdog for the PS5 (diagnostic, off by |
| absent | 0.15 | `0964-ntdll-ps5-retire-thread-alert-kqueues.patch` | ntdll: Own PS5 alert kqueues by live thread. |
| absent | 0.05 | `0985-ntdll-ps5-start-hosted-drivers-without-thread-a` | ntdll: Start a PS5 title's hosted drivers without thread |
| absent | 0.00 | `0992-ntoskrnl-ps5-wait-for-a-dualshock-4-by-its-hid-` | ntoskrnl: Wait for a PS5 title's DualShock 4 by its HID |

## 2. Controllers and input (10)

| status | frac | patch | what it does |
|---|---|---|---|
| partial | 0.87 | `0470-xinput-ps5-title-controller.patch` | xinput: Read the PS5 title's controller. |
| partial | 0.87 | `0471-xinput-ps5-four-controllers.patch` | xinput: Read the PS5 title's four controllers. |
| absent | 0.23 | `1006-win32u-ps5-list-a-mouse-and-a-keyboard-for-raw-` | win32u: List a mouse and a keyboard for raw input on PS5. |
| absent | 0.16 | `0955-wow64win-convert-the-input-of-send-hardware-inp` | wow64win: Convert the INPUT of NtUserSendHardwareInput. |
| absent | 0.11 | `0952-ntoskrnl-ps5-host-the-hid-drivers-in-the-game.p` | ntoskrnl: Host the controller's HID drivers in a PS5 title's |
| absent | 0.02 | `0951-winebus-ps5-title-controller-as-hid-gamepad.pat` | winebus: Show the PS5 title's controller as a HID gamepad. |
| absent | 0.01 | `0966-winebus-ps5-other-controllers-as-hid-gamepads.p` | winebus: Show the PS5 title's other controllers as HID gamepads. |
| absent | 0.00 | `0990-winebus-ps5-title-controller-as-dualshock-4.pat` | winebus: Show the PS5 title's controllers as DualShock 4s on |
| absent | 0.00 | `0991-xinput-ps5-no-controller-beside-a-dualshock-4.p` | xinput: Report no PS5 title controller beside a DualShock 4. |
| absent | 0.00 | `1008-ntdll-ps5-host-the-controllers-drivers-without-` | ntdll: Host the controller's drivers without nsiproxy on request. |

## 3. Memory and address space (10)

| status | frac | patch | what it does |
|---|---|---|---|
| partial | 0.87 | `0974-ntdll-fault-on-protected-pages-that-share-a-hos` | ntdll: Fault on protected pages that share a host page with |
| partial | 0.60 | `0530-ntdll-syscall-dispatcher-slot-in-large-host-pag` | ntdll: Keep the syscall dispatcher slot inside a large host |
| partial | 0.35 | `1000-ntdll-let-wine-large-address-aware-give-a-32-bi` | ntdll: Let WINE_LARGE_ADDRESS_AWARE give a 32-bit program 4 |
| absent | 0.17 | `0988-ntdll-let-the-kernel-write-a-page-beside-a-prot` | ntdll: Let the kernel write a page beside a protected one. |
| absent | 0.16 | `0976-ntdll-server-ps5-small-anonymous-sections-in-di` | ntdll, server: Keep small anonymous sections in direct memory |
| absent | 0.14 | `1005-ntdll-ps5-say-what-fills-a-32-bit-address-space` | ntdll: Say what fills a 32-bit program's address space on |
| absent | 0.00 | `0510-ntdll-ps5-host-page-size.patch` | ntdll: Use the host page size on PS5. |
| absent | 0.00 | `0975-ntdll-clear-decommitted-pages-beside-protected-` | ntdll: Clear decommitted pages beside protected ones. |
| absent | 0.00 | `0987-ntdll-report-hot-writes-only-beside-a-read-only` | ntdll: Report hot writes only beside a read-only data page. |
| absent | 0.00 | `0989-ntdll-report-hot-writes-beside-a-read-only-page` | ntdll: Report hot writes beside a read-only page only on |

## 4. Display and windows (11)

| status | frac | patch | what it does |
|---|---|---|---|
| partial | 0.88 | `0420-win32u-ps5-driver-cursor.patch` | win32u: Draw the application's cursor in the PS5 user driver. |
| partial | 0.88 | `0430-win32u-ps5-driver-window-view.patch` | win32u: Let the PS5 user driver present the visible windows |
| partial | 0.71 | `0740-win32u-ps5-vulkan-hardware-cursor.patch` | win32u: Show the cursor over PS5 Vulkan frames with |
| absent | 0.19 | `1014-win32u-ps5-leave-the-display-to-the-title-in-a-` | win32u: Leave the display to the title in a headless process |
| absent | 0.11 | `0995-win32u-ps5-show-where-the-pointer-is-and-keep-w` | win32u: Show where the PS5 pointer is and keep windows in |
| absent | 0.00 | `0879-win32u-ps5-report-a-drained-wake-pipe.patch` | win32u: Report the wake pipe as handled in the PS5 driver. |
| absent | 0.00 | `0950-win32u-ps5-scale-the-cursor-with-a-scaled-swapc` | win32u: Keep the pointer on a scaled PS5 swapchain and stop |
| absent | 0.00 | `0968-win32u-ps5-keep-the-pointer-in-a-window-under-a` | win32u: Limit the PS5 pointer by a swapchain window's place |
| absent | 0.00 | `0978-win32u-ps5-show-a-smaller-display-mode-where-wi` | win32u: Show a smaller PS5 display mode where win32u puts |
| absent | 0.00 | `0983-win32u-ps5-report-the-120-hz-output-rate.patch` | win32u: Report the PS5's 120 Hz output rate. |
| absent | 0.00 | `0998-win32u-keep-the-video-memory-size-within-32-bit` | win32u: Keep the video memory size within 32 bits. |

## 5. Network (5)

| status | frac | patch | what it does |
|---|---|---|---|
| partial | 0.50 | `1016-ntdll-convert-the-received-tos-and-ttl-control-` | ntdll: Convert the received TOS and TTL control messages the |
| partial | 0.38 | `0760-ws2-32-read-fqdn-once.patch` | ws2_32: Read a fresh fully qualified computer name once |
| absent | 0.05 | `1003-ntoskrnl-ps5-host-nsiproxy-in-the-game.patch` | ntoskrnl: Host nsiproxy in a PS5 title's game too. |
| absent | 0.00 | `1004-dnsapi-fail-without-the-unix-library.patch` | dnsapi: Fail instead of calling a Unix side that did not |
| absent | 0.00 | `1018-iphlpapi-leave-the-dns-servers-out-when-dnsquer` | iphlpapi: Leave the DNS servers out when DnsQueryConfig |

## 6. Wineserver and files (11)

| status | frac | patch | what it does |
|---|---|---|---|
| partial | 0.80 | `0101-server-realpath-into-server-memory.patch` | server: Resolve file names into server-owned memory. |
| partial | 0.35 | `0170-ntdll-ps5-track-directories-from-the-server.pat` | ntdll: Track directories received from the server on PS5. |
| partial | 0.33 | `1015-server-ps5-keep-system-apcs-for-a-title-s-secon` | server: Keep system APCs for a title's second process on |
| absent | 0.25 | `1013-ntdll-ps5-let-the-title-act-once-the-server-is-` | ntdll: Let the title act once the server is connected on PS5. |
| absent | 0.17 | `0979-ntdll-ps5-report-the-storage-for-a-title-s-root` | ntdll: Report the storage for a title's root directory on PS5. |
| absent | 0.14 | `1011-ntdll-ps5-connect-to-a-server-in-another-proces` | ntdll: Connect to a server that another process of the |
| absent | 0.11 | `1002-server-ps5-say-what-holds-the-files-when-an-ope` | server: Say what holds the files when an open runs out of |
| absent | 0.10 | `0993-server-ps5-park-read-only-file-descriptors.patc` | server: Park read-only file descriptors past a budget on PS5. |
| absent | 0.08 | `1019-server-ps5-watch-many-directories.patch` | server: Watch many directories on PS5. |
| absent | 0.00 | `1009-server-ps5-park-files-bound-to-a-completion-por` | server: Park files bound to a completion port on PS5. |
| absent | 0.00 | `1017-server-accept-a-send-buffer-size-of-0-on-freebs` | server: Accept a send buffer size of 0 on FreeBSD too. |

## 7. Other (15)

| status | frac | patch | what it does |
|---|---|---|---|
| partial | 0.90 | `0883-ntdll-ps5-native-wow64-signal-entry.patch` | ntdll: support native WoW64 PS5 signal entry and verified xstate layout |
| partial | 0.80 | `0959-vkd3d-shader-fx-implement-pass-assignment-for-f` | vkd3d-shader/fx: Implement pass assignment for fx_2_0 |
| partial | 0.33 | `0485-winegstreamer-release-a-parser-once-after-a-fai` | winegstreamer: Release a parser's elements once after a failed connect. |
| partial | 0.33 | `1007-ntdll-ps5-report-only-reserved-space-as-free-to` | ntdll: Report only reserved space as free to a 32-bit program |
| absent | 0.23 | `1010-ntdll-ps5-title-notifications-and-invites.patch` | ntdll: Let the PS5 title show notifications and ask about invites. |
| absent | 0.19 | `0481-winegstreamer-media-failure.patch` | winegstreamer: Fail media creation cleanly. |
| absent | 0.14 | `1012-ntdll-one-syscall-dispatcher-slot-value-for-eve` | ntdll: Keep one syscall dispatcher slot value for every |
| absent | 0.12 | `0977-kernelbase-list-drives-nothing-has-published.pa` | kernelbase: Find drives by their roots when none are |
| absent | 0.08 | `0953-winebus-wow64-thunks-for-a-hosted-32-bit-game.p` | winebus: Add WoW64 calls for a 32-bit game hosting it. |
| absent | 0.06 | `0954-setupapi-ps5-write-services-without-a-service-m` | setupapi: Write a service's registry key when there is no |
| absent | 0.00 | `0480-winegstreamer-ps5-static-plugins.patch` | winegstreamer: Register the PS5 static media plugins. |
| absent | 0.00 | `0482-rtworkq-cleanup-groups.patch` | rtworkq: Release cleanup groups with queues. |
| absent | 0.00 | `0958-ntdll-honor-wine-cpu-topology-s-processor-count` | ntdll: Honor WINE_CPU_TOPOLOGY's processor count. |
| absent | 0.00 | `0969-msvcp90-make-ctype-char-narrow-a-vtable-tail-ca` | msvcp90: Make ctype<char>::narrow() a vtable tail call, like |
| absent | 0.00 | `0999-winegstreamer-ps5-play-mp3-and-wav-through-dire` | winegstreamer: Register the PS5 WAV, MP3 and ID3 plugins. |

