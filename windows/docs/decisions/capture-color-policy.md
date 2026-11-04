# Capture color policy on mixed HDR and SDR displays

Status: accepted for the current release candidate.

Every shipped capture output is 8-bit SDR sRGB. This is a deliberate policy, not an oversight. This page records what each shipped consumer does, what Windows does with it on an HDR display, and what would make us revisit the policy.

Source revisions: shell `dev` 161f1f51, backend `windows/deps/quickshell` 7a523b23, Glazier `windows/deps/glazier` d4383db3.

## Shipped consumers

The shell ships three capture consumers. No other shipped QML captures screen pixels.

| Consumer | Capture route | Output | Policy |
| --- | --- | --- | --- |
| Screenshot (hotkeys, launcher, IPC) | Glazier, GDI `BitBlt` into a 32-bit DIB (`windows/deps/glazier/src/capture.rs:186-188`) | PNG and `CF_DIB`, 8-bit BGRA (`src/export.rs:119`, `src/export.rs:266`) | SDR sRGB |
| Screen recording (Utilities card, launcher) | Glazier, WGC monitor capture with `B8G8R8A8UIntNormalized` (`src/recording_media.rs:158`, `src/recording_media.rs:178`) | H.264 MP4 from `MFVideoFormat_RGB32` (`src/recording_media.rs:335-342`) | SDR sRGB |
| Bar active-window preview | Backend `ScreencopyView`, WGC window capture with `R8G8B8A8UIntNormalized` (`modules/bar/popouts/ActiveWindow.qml:98`, `src/windows/capture.cpp:52-53`, `src/windows/capture.cpp:526-531`) | 8-bit RGBA texture in Qt Quick (`src/windows/wayland/screencopy_view.cpp:86`, `:98`) | SDR sRGB |

The shell starts Glazier from `windows/shell/adapters/services/Glazier.qml:221` (`--capture`) and `windows/shell/adapters/services/Recorder.qml:229` (`--record`).

## What Windows does on an HDR display

When HDR is on, DWM composes in scRGB FP16 and lets values exceed 1.0. An 8-bit capture cannot hold those values. Microsoft documents the result for Windows.Graphics.Capture:

> "On systems with Windows HD color enabled, the content pixel format might not necessarily be DXGI_FORMAT_B8G8R8A8_UNORM. To avoid pixel overclipping (i.e. the captured content looks washed out) when capturing HDR content, consider using DXGI_FORMAT_R16G16B16A16_FLOAT for every component in the capturing pipeline"
>
> [Screen capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture)

Windows clips. It does not tone map. The Advanced Color article puts tone mapping on the capturing app: "after acquiring content frames, additional processing is required. For example, HDR-to-SDR tone mapping" ([Use DirectX with Advanced Color](https://learn.microsoft.com/en-us/windows/win32/direct3darticles/high-dynamic-range#capturing-hdr-and-wcg-screen-content)).

What the user sees:

- On an SDR display, all three consumers match the screen.
- On an HDR display, HDR content (games, HDR video) loses its highlights and can look washed out in recordings and in the window preview.
- The docs do not say how WGC maps SDR content when the user raises the SDR content brightness on an HDR display. They also do not describe GDI `BitBlt` on an HDR display at all. Both need a live check.

## Why HDR preservation is out of scope

Screenshots and recordings go to chat apps, issue trackers, and video players that expect 8-bit sRGB PNG and SDR H.264. An HDR file would look wrong for most recipients. The useful fix is HDR-to-SDR tone mapping, not HDR preservation. The preview is a thumbnail of at most 400 px (`windowPreviewSize`, `plugin/src/Caelestia/Config/tokens.hpp:113`) rendered by Qt Quick in sRGB, so clipped highlights there cost the user little.

Changing a frame pool to `R16G16B16A16Float` alone makes output worse. The Qt Quick sampler, the PNG encoder, and the H.264 encoder all expect sRGB, so raw scRGB values would render wrong. A real change needs FP16 capture, SDR white level scaling from `DISPLAYCONFIG_SDR_WHITE_LEVEL`, and a tone-mapping pass in every consumer.

## When to revisit

Revisit this policy when one of these happens:

- Users report washed-out recordings or screenshots of HDR games or video.
- Glazier moves still capture from GDI to WGC. Tone mapping then belongs in that change.
- A consumer needs HDR output, such as JPEG XR or HEVC Main10 recording.

## Unused backend routes

The backend compiles two more capture routes that no shipped QML references. They are `Screenshot` (`src/windows/system/screenshot.hpp:20-21`, `grabMonitor` at `src/windows/capture.cpp:347`) and `ScreenRecorder` with `recorder::RegionCapture` (`src/windows/system/screen_recorder.hpp:12-13`, `src/windows/recorder/region_capture.cpp:47-48`). Both are QML singletons in the `Quickshell.Windows` module, so QML can still import them. We leave them unused and do not invest in them. Deleting them is a separate follow-up.

## Known gap: no device-loss recovery in the preview

`CaptureWorker::start` creates its D3D11 device once (`src/windows/capture.cpp:235-246`). Nothing in `capture.cpp` calls `GetDeviceRemovedReason`. A frame callback failure is logged at debug level only (`src/windows/capture.cpp:728-729`). The device is released only in `CaptureWorker::shutdown` (`src/windows/capture.cpp:733-741`). After a GPU reset or driver update, the preview stops updating until the shell restarts. Glazier's recorder already checks for device loss (`src/recording_media.rs:228`, `:265`). Recreating the backend device is a follow-up.

## Validation

These checks need a physical HDR display beside an SDR display:

- Recording and preview of HDR content on the HDR display, compared with the screen.
- Screenshot and recording of SDR content on the HDR display with a raised SDR content brightness.
- A window preview while the window moves between the HDR and SDR displays.

The maintainer's PC has this hardware. A read-only `DisplayConfigGetDeviceInfo` probe on 2026-11-03 reported:

| Display | Advanced Color supported | Advanced Color enabled | Active mode | Bits per channel | SDR white level |
| --- | --- | --- | --- | --- | --- |
| 1 | yes | yes | HDR | 10 | 6000 (480 nits) |
| 2 | yes | no | SDR | 8 | 1000 (80 nits) |

None of these checks has run yet. They belong to live QA.
