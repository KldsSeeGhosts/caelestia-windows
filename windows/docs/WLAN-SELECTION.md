# Windows WLAN selection boundary

Network names are display text, not write selectors. When the native backend
exposes selection IDs, the shell preserves each opaque ID through row reuse,
connect, saved-network details and forget. It neither decodes nor reconstructs
the ID from an SSID, BSSID, adapter name or profile name.

Two rows with the same displayed name remain separate. A removed ID does not
fall back to another same-name row. Older backends without the ID API retain
their compatibility route only when the current name identifies one row;
ambiguous names are refused before any write.

Connect results stay pending until a terminal native result. The native facade
binds that result to the selected ID; a name-only or different-ID observation
cannot complete the service's ID request. A synchronous stale-ID rejection
also clears pending state. A request is not successful completion.

The shell still collects no password. A new protected network is handed to
Windows Settings; saved profiles and supported open networks use the native
route. Forget and radio/disconnect operations without native completion
receipts remain requested and unverified. Cancelling attribution is not a
promise to disconnect Windows.

The service and native-facade projection fixtures use only synthetic objects.
Wrapper/detail tests execute the actual QML JavaScript with synthetic rows.
They do not scan, connect, forget a real profile or qualify a physical WLAN
adapter. Driver/adapter/location/recovery acceptance remains with the
[network hardware owner](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/issues/14).
