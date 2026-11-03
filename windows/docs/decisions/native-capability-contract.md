# Native capability and command results

Caelestia must report what Windows supports and what an operation actually did.
This contract extends existing service objects. It is not a service framework.

## Decision

Keep observation initialization independent of model size and command support.
A successful empty model is healthy. `initialized` means the adapter exists,
not that desktop dispatch works.

Each adopted capability reports `availability`, `reason`, `provider`, and
`operations`. Availability is `available`, `unavailable`, `disabled`, or `denied`.
Reasons are stable machine-readable strings. Available capabilities have an
empty reason. Disabled means configuration withheld permission. Denied means
Windows refused access. Unavailable identifies a platform or provider failure.
Provider kind is `documented-api` or `build-gated-private-com`.
Operation support is independent for switch, create, move, remove, and pin.
Unsupported operations must not be inferred from another operation's support.

Desktop control uses one C++ availability enum, including its failure reason.
QML receives a derived map, so availability and reason cannot contradict each
other. The existing accessor state and compatibility booleans remain in place.
`PinDispatchResult` describes only pin calls. Activation sources describe input
permission, and tiling failure reasons describe geometry. None fits desktop
availability or asynchronous completion, so desktop-specific result types live
beside `VirtualDesktops`.

Commands distinguish `accepted`, `observed`, `denied`, `superseded`, and
`timed-out`. Accepted means the provider took the request, never completion.
Only observed state proves completion. A deadline reports failure, not success.
Switch and creation results carry request IDs because they can finish later.
An immediate refusal has no ID. The result signal preserves transitions even
when the next request replaces `lastCommand`. Other operations retain their
existing APIs and do not claim an observed result until migrated.

## Desktop-control adoption

`Hyprland.desktopControl` exposes the existing desktop object's `capability`,
`lastCommand`, and result signal without changing classic or Lua dispatch.
Unknown builds report `unavailable/unsupported-build`. Explorer loss reports
`unavailable/provider-disconnected`. Opt-out reports `disabled/dispatch-disabled`.
Access refusal reports `denied/permission-denied`. A rejected switch reports
`denied/command-rejected`, while observed completion reports `observed`.

The [documented IVirtualDesktopManager API](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-ivirtualdesktopmanager)
reads window membership and moves owned windows. It does not enumerate, create,
or switch desktops. Those operations remain explicitly build-gated private COM.
There is no synthetic-input fallback.

Older boolean-only backends retain dispatch compatibility with provider
`unknown` and reason `legacy-unverified`. Their void dispatch result is
`unknown/legacy-result-unavailable`, never success. Missing capability properties
fail closed with `unavailable/legacy-capability-unknown`.
Future placement services can adopt the same fields using their own domain
enums and observation events, without replacing existing public entry points.
