# Installed-shell live checklist

Run on the installed shell, with one QA owner and no other active tiler.
Record the installed version, Windows build, monitor/DPI setup and outcomes.
Use disposable content; never capture clipboard, notification or account data.
Only exercise controls you explicitly enabled. Restore changed settings.
Mark missing hardware or unavailable integrations as not tested, not passed.

## Shell, bar and focus

- Open each drawer from the bar, then press Escape: it closes and focus returns to the previous app.
- Click outside an open drawer: it dismisses, and the underlying app receives the click.
- Repeat on each monitor/DPI: text and icons stay sharp, panels fit the screen and input follows their visible bounds.

## Apps and launcher

- Open the launcher, type part of an installed app's name: matching results appear without launching anything.
- Launch a harmless app once: exactly one window opens and the launcher closes.
- Reopen the launcher and clear the query: navigation works and recent/frequent ordering reflects that launch.

## Audio

- Play quiet test audio and open the audio controls: the active output and volume agree with Windows.
- Change volume, then mute/unmute: sound and the shell indication follow each action.
- Select another available output, then restore it: audio routes there and the selected device updates.

## Battery and power

- Compare the battery icon/popout with Windows: charge, AC status and absence of a battery agree.
- On a battery device, unplug/reconnect AC: charging state updates without reopening the shell.
- If power-mode writes are enabled, select a supported mode: Windows reflects it; restore the original mode.

## Bluetooth

- Open Bluetooth with the radio available: devices and connected state agree with Windows Settings.
- With radio controls enabled, switch Bluetooth off/on: the shell follows each state without stale connected rows.
- Connect/disconnect a disposable paired device: its state updates; a failed attempt leaves controls usable.

## Brightness

- Open brightness controls: supported displays have usable controls; unsupported ones are not presented as writable.
- Adjust one supported display slightly: only that display changes; restore its brightness.
- Use a brightness key on supported hardware: the OSD reflects the result and disappears without stealing app focus.

## Media

- Start a local test track/video: title, player and playback state appear in the dashboard.
- Pause/resume and seek where supported: the player and shell stay in sync.
- Close the player: stale metadata disappears; with two players, selecting one directs controls only to that player.

## Network

- Open the network popout: active connection and signal/link state agree with Windows.
- With controls enabled, disconnect/reconnect a disposable connection: status transitions settle to the actual result.
- Dismiss a connection/password prompt: no connection is started and no password appears in logs or screenshots.

## Notifications

- Trigger a harmless notification from a test app: one banner appears and the sidebar retains it.
- Dismiss that test notification: it disappears from the expected banner/history surfaces without affecting other entries.
- Toggle Do Not Disturb, trigger another test notification, then restore it: banner suppression follows the setting.

## Session

- Open the power/session panel and navigate with keyboard: focus is visible and Escape closes it.
- Choose a destructive action, then cancel its confirmation: no session action occurs and the panel remains usable.
- If separately authorized, choose Lock: Windows' own lock screen appears; unlock returns to the shell.

## Workspaces and active window

- Switch between two apps: the active-window label follows focus without retaining the previous app's title.
- Switch virtual desktops from the workspace UI: the selected indicator and Windows desktop agree.
- Move an app between desktops with the enabled command: it appears on the destination, with no duplicate/stale entry.

## Tiling

- With tiling explicitly enabled and one tiler active, open two allowed test apps: they fit the work area without overlap.
- Maximize/restore, then move one app between monitors: focus and geometry settle without a correction loop.
- Exclude or float one test app: it stays freely movable; an impossible fit is explained rather than repeatedly resized.

## Tray

- Open the tray: visible icons correspond to running tray apps, without duplicate Explorer/shell interception.
- Activate a harmless icon and open its context menu: each targets the correct app and the menu stays on-screen.
- Exit/reopen that tray app: its icon disappears/reappears without restarting the shell.

## Combined panels and desktop integration

- Open dashboard, launcher, sidebar and session in succession: transitions finish and no invisible panel blocks input.
- Adjust one appearance setting, then restore it: bar, drawers and OSD update consistently without clipped content.
- With desktop/taskbar takeover already enabled, maximize/restore a test app: reserved work areas remain correct and app input is not trapped.
