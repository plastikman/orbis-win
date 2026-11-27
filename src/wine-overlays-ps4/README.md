# PS4 Wine build overlays

These are small PS4-only source patches applied after Prosperowin's pinned
Wine patch series and before building the PS4 PE outputs. They preserve PS4
behavior that is not yet present in the pinned Prosperowin series.

`iphlpapi-legacy-netctl.patch` keeps the `GetAdaptersInfo` NetCtl fallback.
Prosperowin's newer `GetAdaptersAddresses` fallback does not cover this
separate legacy API. The patch is also retained in `src/wine-patches-ps4/` as
an investigation archive; this copy is the explicit build input.
