# Titan Quest: the alert-latch regression in ntdll.prx, found and fixed (2026-11-19)

Resolved. Root cause and the compiled A/B that proves it are below.
Full evidence, every log and every profile revision: `/home/zpeirce/junk/tq-trace-20261119/`.

## What was known going in

`docs/HANDOFF-2026-11-05.md:1399` records the four fixes that brought Titan Quest up on
01.34 (2026-11-06) — 1066 (= archive 0972, `fd_owner` of pseudo fds), 1067 (= archive 0988,
`gethostbyname` through the PS4 resolver shim, built with `-femulated-tls`), 1068 (server
sockets non-blocking via `SO_NBIO` 0x1200), and the `futimes` recursion fix in
prospero-win's `wine/ps5/pw_wine_compat.c`. **All four are present and intact in the current
build inputs**, audited by content, not by patch number — the numbers were reused, and
slackian's 1066/1067/1068 are winegstreamer/rtworkq patches today.

One trap found while checking: `prospero-win/` in the repo root — the default `$PW_ROOT` at
`scripts/build-app-ps4.sh:17` — is stale on branch `sync-trial-2` (2026-10-29) and does
**not** contain `3d9ff33`, the commit carrying those fixes; its `pw_compat_futimens` calls
bare `futimes`. Builds dodge it only because `scripts/build-orbis-ps4-fast.sh:20,27`
overrides `PW_ROOT=worktrees/playden-ps4-0170`, which does have them. Anything built with
the default path reintroduces the Create black screen.

## The fault

Deterministic, reproduced on four packages, identical instruction every time:

    thqno_api.dll @ 7A850000   frames 3-7
      -> galaxy.dll @ 78220000  frames 0-2
           FAULT at RVA 0x113887 : 8b 03 (mov eax,[ebx]) / 51 / ff .. (call [eax+disp])
           ebx = 0  edx = 5b3d736e  thread 0028  ~9 s in  frames_put=0  reason=guest-exit

`C:\Games\TitanQuestAE\THQNOnline\gog\galaxy.dll`, the GOG Galaxy SDK, called from THQ
Nordic Online. 2026-11-17 saw the same RVA at a different image base (eip=78023887,
alloc=77F10000). It is a virtual call on a NULL object, or equally consistent with an
unchecked NULL returned by a lookup or an allocation.

## The bisect — 11 candidate files to one module, five packages, no compilation

`candidate-0158` was installed as a control and **Titan Quest reached gameplay** — so the
"worked at 01.58" end now rests on a run, not on a handoff entry. Each A/B was built with
`scripts/repackage-orbis-ab.py` from the 02.69 stage and verified to differ from it in
exactly the intended files; every one passed `check-ps4-package-parity.py` (exit 0, 0 FAIL)
and `PkgTool.Core pkg_validate` (27/27).

| pkg | reverted to 01.58 | result |
|---|---|---|
| 0273 | `i386 iphlpapi.dll` only | faults — 1038 CLEARED |
| 0274 | ntdll + wineserver (6 files) | **plays** |
| 0275 | ntdll only (prx + both PEs) | **plays** — wineserver cleared |
| 0276 | `sce_module/ntdll.prx` + unix copy only | **plays** — both ntdll.dll PEs cleared |

**Cleared** — each sat at 02.69 in a package where the game played: `ws2_32.prx`,
`wineserver.prx`, `libvulkan.prx`, `win32u.prx`, `wineps5.prx`, `xinput1_3.prx`,
`relocated_wine_app.prx`, both `iphlpapi.dll`, `kernelbase.dll`, `wined3d`, `d3dx9_*`.

## Hypotheses tested and killed

- **1036 / DXVK external memory.** Wrong: `+loaddll` shows no `d3d11`, `dxgi` or `d3d9`
  module is ever loaded. The crash is in online-services init, before graphics.
- **The resolver (1067).** Intact: `gethostbyname("PS5")` — the exact 01.25 fault site —
  returns, then `galaxy-log.gog.com` resolves to 91.222.185.217 and the UDP `sendto`
  succeeds.
- **schannel.** `err:secur32:SECUR32_initSchannelSP no schannel support` fires just before
  the fault, but `candidate-0158` ships zero GnuTLS files too. Pre-existing.
- **1038 legacy `GetAdaptersInfo`.** A detailed mechanism was built around it — the NetCtl
  fallback answering the size query with `ERROR_BUFFER_OVERFLOW` where the raw NSI error
  used to say "no adapters" — and the 0273 A/B killed it outright. 01.58 makes the same
  single `GetAdaptersInfo` call and carries on.
- **"Online services are now reachable, unlike in November."** Killed by the control: same
  console, same prefix, same reachable GOG, and 01.58 plays.
- **7df46bd per-page exec migration.** `PW_PS4_EXEC_MIGRATE_RANGE_MAX=0` in the profile's
  `[debug] env` disabled it (klog: `source=env`, zero `exec-range-per-page` events) and the
  fault was identical. Also proves the profile env **does** reach `ntdll.prx`.

## Root cause, found and fixed

Not 1040/1041. The bisect's second lead was the right one: **1079, the thread-alert
kqueue rework**, in `dlls/ntdll/unix/sync.c` of the wine-ps5 tree.

`server_queue_process_apc`'s PS5 arm set `entry->ps5.pending = 1` *unconditionally* — it
latched the alert as still-pending even when the kqueue write had already delivered it. So
every alert was signalled twice, and the next alertable wait returned `STATUS_ALERTED`
immediately instead of blocking. GOG Galaxy's init does an alertable wait on an object it
has not finished constructing; the early return let it proceed on a null `this`, which is
exactly the `mov eax,[ebx]` with `ebx = 0` at `galaxy.dll+0x113887`.

The fix latches only when the alert was *not* delivered:

```c
status = STATUS_SUCCESS;
if (entry->ps5.owner)
{
    owned = 1;
    if ((fd = ps5_thread_alert_kqueue_locked( entry->ps5.owner )) >= 0 &&
        kevent( fd, &signal_event, 1, NULL, 0, NULL ) == -1)
        status = STATUS_INVALID_HANDLE;
    if (fd < 0 || status != STATUS_SUCCESS) entry->ps5.pending = 1;
}
else
{
    entry->ps5.pending = 1;
    ERR( "PW_ALERT_DROPPED tid=%04x had no owner; latched instead\n", ... );
}
```

The `else` arm keeps the old behaviour for the case it was actually written for — an alert
with no owning thread — and logs it, so a regression here is visible rather than silent.

**Proof, a compiled control/fixed A/B from the same tree, one commit apart:**

| pkg | `ntdll.prx` built from | Titan Quest |
|---|---|---|
| 0290 | fix reverted (CONTROL) | faults at ~10 s, same RVA `0x113887`, `ebx = 0` |
| 0291 | fix applied (FIXED) | **plays** — 55 s of gameplay, no fault |

Run of Us 2 and Splinter Cell were unchanged by the fix in both directions, so it is not a
blunt behavioural shift. The fix is `cd8d267` on the working tree, carried into the pinned
wine-ps5 tree as **`ee7b06d`**, which is what `src/wine-trees/wine-ps5-HEAD.txt` names.

### Two corrections to the section this replaces

- **1040/1041 large-address-aware was the wrong lead.** It is still unreachable from a
  profile, and closing that is still worth doing, but it had nothing to do with this fault.
- **`PW_PS4_GUEST_SAMPLER=1` is not the alert-trace knob and never was.** The shipped code
  reads **`PW_PS4_ALERT_LOG`**. The earlier note that the probe "cleared" the alert path was
  therefore unfounded — the trace was never on. The bisect landed on precisely that area.

## Method notes worth keeping

- **The build marker cannot identify an A/B package.** It lives in `relocated_wine_app.prx`,
  so any A/B that does not replace that module reports the base build's marker. Identify an
  installed package by `/user/app/<TITLE>/app.json`'s `url` and the PKG header digest at
  offset `0xFE0`. This briefly fooled us on 0273.
- `PkgTool.Core` needs `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` and
  `LD_LIBRARY_PATH=~/.cache/orbis-ports/openssl11/lib`.
- klog timestamps are the watcher's receive time from a buffered GoldHEN flush. They lag and
  must not be ordered against ps5log timestamps.
- Arm the log receiver **before** a test. The 2026-11-17 failure was undiagnosable because
  nothing was listening; every result here came from a run that was being watched.
