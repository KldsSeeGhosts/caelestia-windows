# Capture color policy: HDR and SDR

Status: accepted for the current release candidate. The reasoning
behind the choice is in [decisions/capture-color-policy.md](decisions/capture-color-policy.md);
this page is the route map, the code policy and the manual check.

Source revisions: shell `dev` 4c634f5e, backend `windows/deps/quickshell` 858874f,
Glazier `windows/deps/glazier` d4383db3.

## Every capture route and its owner

| Route | Owner | Capture path and pixel format | Consumer | Shipped | Output needs |
| --- | --- | --- | --- | --- | --- |
| Screenshot (hotkeys, launcher, IPC) | Glazier `--capture` | GDI `BitBlt` into a 32-bit DIB, BGRA (`src/capture.rs`) | PNG and `CF_DIB` (`src/export.rs`) | yes | SDR sRGB |
| Screen recording | Glazier `--record` | WGC monitor, `B8G8R8A8UIntNormalized` (`src/recording_media.rs`) | H.264 MP4, MF `MFVideoFormat_RGB32` | yes | SDR sRGB |
| Bar active-window preview | Backend `ScreencopyView` | WGC window, SDR frame pool (`src/windows/capture.cpp`) | Shared NT-handle texture, then a Qt Quick D3D11 texture (`src/windows/wayland/screencopy_view.cpp`) | yes | SDR sRGB |
| `Screenshot` QML singleton | Backend `CaptureThread::grabMonitor` | WGC monitor, SDR frame pool, staging readback to `QImage` | PNG | no shell consumer | SDR sRGB |
| `ScreenRecorder` QML singleton | Backend `recorder::RegionCapture` | WGC monitor, `B8G8R8A8UIntNormalized` (`src/windows/recorder/region_capture.cpp`) | MP4 | no shell consumer | SDR sRGB |
| Video wallpaper | Backend `video_wallpaper.cpp` | Media Foundation decode into a shared BGRA8 frame; not screen capture | Qt Quick texture | yes | SDR sRGB |

Glazier owns the picker, editor and recorder; the shell only launches it
(`windows/shell/adapters/services/Glazier.qml`, `Recorder.qml`). The backend's
`Screenshot` and `ScreenRecorder` singletons are still registered in the
`Quickshell.Windows` module but no shipped QML references them.

## Policy: SDR output everywhere

No route needs HDR preservation. Screenshots and recordings are shared as 8-bit
PNG and SDR H.264; the preview is an sRGB Qt Quick thumbnail. An HDR file would
look wrong for every consumer.

On an HDR display, Windows.Graphics.Capture with an 8-bit pool gives an SDR
frame, but it is **not** the system's tone-mapped frame. Microsoft documents
that HDR capture needs `R16G16B16A16_FLOAT` through the whole pipeline plus
app-side HDR-to-SDR tone mapping, and warns that 8-bit capture of HDR content
overclips ("washed out")
([Screen capture](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture),
[Use DirectX with Advanced Color](https://learn.microsoft.com/en-us/windows/win32/direct3darticles/high-dynamic-range#capturing-hdr-and-wcg-screen-content)).
OBS's WGC implementation makes the same distinction: it requests FP16 on an HDR
monitor and tone maps in its own shader, while its "force SDR" option is the
8-bit path.

So HDR highlights can clip in the preview on an HDR display. Accepted: no visual
defect has been reproduced, and a real HDR path would need FP16 capture, SDR
white level scaling and a tone-mapping pass in every consumer. The code never
requests an FP16 pool (no `R16G16B16A16` in `src/windows`).

## Code policy

- `src/windows/capture_format.hpp` owns the SDR layout once:
  `SDR_FRAME_FORMAT` = `B8G8R8A8_UNORM` / `B8G8R8A8UIntNormalized` /
  `QImage::Format_RGB32`, the format Microsoft documents for the WGC pool.
- `chooseFrameFormat` tries that format, then the 8-bit `R8G8B8A8` fallback
  (the format the backend used before the policy was explicit), then reports
  that no format is available. Both attempts log the HRESULT; a session with no
  format stops with `stopped(true)` instead of staying silently black.
- The chosen format travels with the frame: `SharedFrame::format` is set by the
  producer and the Qt consumer creates its scene-graph texture with
  `frame->format`. The producer, the shared texture and the consumer cannot
  drift apart.
- The Qt consumer imports the texture through the RHI with the layout that
  matches `frame->format` (`capture_texture.cpp`), shared with the video
  wallpaper. `QSGD3D11Texture::fromNative` is not used: in Qt 6.11.2 it wraps a
  BGRA8 texture as RGBA8, D3D11 rejects the SRV and the preview stays empty.
- `grabMonitor` reads back with the chosen `QImage` layout.
- Device loss: `GetDeviceRemovedReason()` is checked in the frame callback and
  at start. A lost device stops the session with `stopped(true)` and a warning.
  Recovery needs a new device and frame pool and is tracked in backend
  [#65](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/issues/65),
  not here.

Probe on this machine (read-only pool creation, no capture session): WGC
accepted `B8G8R8A8_UNORM`, `R8G8B8A8_UNORM` and `R16G16B16A16_FLOAT`, and
rejected `R10G10B10A2_UNORM` with `E_INVALIDARG`. The fallback is therefore
real, and the FP16 pool is available but deliberately unused.

## Tests

`src/windows/test/capture_format_test.cpp` (offscreen fixture, no session and no
desktop observed):

- policy and fallback descriptor consistency, negotiation order, and the
  no-format outcome;
- WGC accepts the policy format and the fallback (pool create/close);
- a shared texture in each policy format is imported through the same Qt RHI
  path the consumer uses, and the reported RHI format must match. A BGRA8
  texture wrapped as RGBA8 fails this test with `E_INVALIDARG`.

Not covered: repeated live capture sessions' handle and GPU object counts.
There is no existing capture fixture, and a probe shows D3D11 retains one
process handle per shared resource until device teardown, so a handle count
would measure the driver rather than this code. Physical HDR validation is
blocked: needs maintainer at the PC.

## Manual check (three steps)

Run on the maintainer's PC with one HDR and one SDR display. Record the display
mode and SDR white level with the result.

1. On the HDR display, put a bright HDR window (HDR game or video) next to an
   SDR window. Hover the bar's active-window preview over each. Correct: the SDR
   window matches the screen; the HDR window may lose highlight detail but has
   no red/blue swap, banding or black frame.
2. Take a Glazier screenshot and a five-second Glazier recording of the same SDR
   window, then open both in an SDR viewer. Correct: colors match the screen, no
   magenta or green cast.
3. Move that window from the SDR display to the HDR display while the preview is
   live. Correct: the preview keeps updating and its colors stay correct after
   the move.

