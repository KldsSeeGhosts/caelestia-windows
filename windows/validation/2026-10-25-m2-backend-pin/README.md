# M2 backend pin move

Pin `1401042969e4b7ab3cfb314fc76945ab081db3de` -> `525786fc81f13346cb196dca5ab356f89ad707a5`
(`windows/m2-services` on the backend fork): merges of the four reviewed M2
backend branches on the previous pin.

| Branch | Tip | Review |
| --- | --- | --- |
| `windows/m2-power-profile-results` | `327cd09` | accepted (Sol) |
| `windows/m2-bluetooth-pairing-policy` | `e6275ff` | accepted (Sol review + orchestrator check of the final fix) |
| `windows/m2-brightness-strict-route` | `63eee61` | accepted (three Sol rounds; final gamma fix by the orchestrator) |
| `windows/m2-notification-mirror-consent` | `3da2296` | accepted (Sol review; final fix checked by the orchestrator) |

The only merge conflict was the additive test target list in
`src/windows/test/CMakeLists.txt`, resolved as a union.

## Results (2026-10-25, ~21:00-21:11)

Backend Qt Tests on `525786f` (VS x64, clang-cl 20.1.8, Qt 6.11.2, Ninja,
MSVC linker, SDK mt.exe), fakes only:

| Suite | Passed |
| --- | ---: |
| power_profiles_test | 12 |
| bt_pairing_policy_test | 20 |
| brightness_route_test | 81 |
| notification_mirror_consent_test | 8 |
| mpris_status_test | 6 |
| mpris_art_cache_test | 5 |
| pw_audio_control_test | 16 |
| upower_status_test | 9 |

`Build-Prototype.ps1` rebuilt the shared build at the new pin (exit 0).
`Test-Environment.ps1 -Json` reports `expectedBackendRevision` =
`actualBackendRevision` = `525786f`; its tool blockers only reflect running
outside the VS developer shell.

Every M2 prototype harness then passed sequentially on the rebuilt build
(source tree dirty only by this uncommitted pin move): Audio, Battery, Media,
Network, Bluetooth, Apps, Tray, Session, Notifications, Brightness.

## Not validated

No harness enables writes or mirroring. Strict brightness, power profile
writes, Bluetooth pairing, and notification mirroring now run against a
backend that supports them, but their live behavior still needs the
orchestrator's acceptance runs on the desktop.
