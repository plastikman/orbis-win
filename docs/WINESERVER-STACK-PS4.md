# Keep the in-process wineserver stack request on PS4

Wine's PS4 patch `0110-server-run-in-process-on-ps5.patch` asks for a 1 MiB
stack for the in-process wineserver thread. The PS4 SDK's pthread interposer
raises small stack requests to a 16 MiB floor backed by flexible memory. The
existing `pw_pthread_stack_ps4.c` wrapper was linked only into NTDLL and only
recognized caller-supplied stack addresses, so it did not handle this
size-only wineserver request.

The PS4 PRX build now compiles a wineserver-specific variant of that wrapper
and links it with `--wrap=pthread_create`. It intercepts only the explicit
1 MiB request, calls `scePthreadCreate` directly with the original attributes,
and retries with a 512 KiB stack only if libkernel rejects the first request.
The retry preserves the detach and guard settings. The wrapper reports the
requested size, create status, effective stack and query status to klog. NTDLL
keeps its existing wrapper behavior.

## PS4 validation

Package 1088 was built from the relocatable Fallout New Vegas 1087 stage and
installed as `IV0000-GLDS10044_00-GLDS100440000000.pkg`. User confirmed that
gameplay worked. The run stayed alive for about 10 minutes 48 seconds; Vulkan
presents succeeded, and telemetry reported no dmem failures. The klog showed:

```text
wineserver: stack requested=1024K direct=0 retry_attr=-1 retry_512K=-1 actual=7ed8d0000+1024K query=0
```

Thus the 1 MiB request was accepted directly, with no fallback. The final
memory sample was `flexible_free=281600K`, `dmem_failures=0`, `heap=58096K`.
The exact installer SHA-256 was
`c22073de550f6ede5c834d660b94baf5ca399d65395e1fcb8c4e7a19527c0b4f`.
The corresponding package and run logs are archived under
`/home/zpeirce/codex_scratch/fnv-wineserver-stack-1088/`.
