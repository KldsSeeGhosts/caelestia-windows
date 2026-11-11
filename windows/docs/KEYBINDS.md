# Keybinds reference

Back to the [Caelestia for Windows user guide](USER-GUIDE.md).

On Linux, Caelestia relies on Hyprland (`hyprland.conf` or `keybinds.lua`) to capture global shortcuts and run window/workspace dispatchers. On Windows, the Quickshell backend provides a built-in `HotkeyManager` (`Quickshell.Windows.Hotkeys`) that registers chords without the Windows key through `RegisterHotKey` and runs every chord with the Windows key, and every lone-modifier tap or hold, through a low-level keyboard hook (`WH_KEYBOARD_LL`). A `Win+<Key>` bind can opt in to `RegisterHotKey` with `"register": true`; see [Routing](#routing-registerhotkey-or-the-keyboard-hook).

Defaults are staged from `defaults/windows/keybinds.json`. Production seeds `config/keybinds.json` under the recorded profile on first launch only.

---

## Where `keybinds.json` lives

1. **Built-in defaults:** Shipped in the repository at `defaults/windows/keybinds.json`.
2. **User overrides:** `CAELESTIA_WINDOWS_KEYBINDS` selects an explicit file first. Otherwise `"configFile":"keybinds.json"` resolves under `CAELESTIA_CONFIG_DIR` when that file exists, so production uses `%LOCALAPPDATA%\caelestia-windows\config\keybinds.json`. The legacy fallback `"userFile":"caelestia/windows/keybinds.json"` resolves under Qt GenericDataLocation.

`HotkeyManager` watches your `keybinds.json` file and reloads bindings automatically within 200 ms whenever you save changes. It also re-evaluates punctuation keys automatically when your active Windows keyboard layout changes.

---

## Extending vs replacing defaults

If you want to keep the default bindings and only override or add a few keys, set `"extends": "defaults"` at the top of your user `keybinds.json`:

```json
{
    "extends": "defaults",
    "binds": [
        {
            "keys": "Super+Space",
            "action": "global",
            "name": "caelestia:launcher",
            "description": "Toggle launcher"
        },
        {
            "keys": "Super+Q",
            "action": "dispatch",
            "dispatch": "closewindow",
            "description": "Close focused window"
        }
    ]
}
```

If you omit `"extends": "defaults"`, your `"binds"` array replaces the default table (except newly introduced default `"global"` binds marked with `"since"` whose key combo and shortcut name are not yet taken in your file).

---

## Key combo syntax (`keys`)

Write key combinations as `Modifier+Modifier+Key` (case-insensitive):

- **Modifiers:**
  - `Super`, `Win`, `Meta`, `Logo` (Windows key)
  - `Ctrl`, `Control`
  - `Alt`, `Menu` (Alt key)
  - `Shift`
- **Lone modifier tap:** A single modifier by itself (for example `"Super"`) fires as a tap when pressed and released without another key (`onRelease`). Combinations of multiple modifiers without a regular key are rejected.
- **Letters and digits:** `A`–`Z`, `0`–`9`
- **Function keys:** `F1`–`F24`
- **Navigation and editing:** `Return` / `Enter`, `Space`, `Tab`, `Escape` / `Esc`, `Backspace`, `Delete` / `Del`, `Insert` / `Ins`, `Home`, `End`, `PageUp` / `Page_Up` / `Prior`, `PageDown` / `Page_Down` / `Next`, `Left`, `Right`, `Up`, `Down`, `Print` / `PrintScreen` / `SysRq`, `Pause`, `ScrollLock`, `CapsLock`, `Apps`
- **Punctuation:** `Slash` (`/`), `Period` (`.`), `Comma` (`,`), `Minus` (`-`), `Equal` / `Plus` (`=`), `BracketLeft` (`[`), `BracketRight` (`]`), `Semicolon` (`;`), `Apostrophe` (`'`), `Grave` (`` ` ``), `Backslash` (`\`)
- **Numpad:** `KP_0`–`KP_9` (or `Numpad0`–`Numpad9`), `KP_Add`, `KP_Subtract`, `KP_Multiply`, `KP_Divide`, `KP_Decimal`
- **Media and hardware keys:** `VolumeUp` / `AudioRaiseVolume`, `VolumeDown` / `AudioLowerVolume`, `VolumeMute` / `AudioMute`, `MediaNext` / `AudioNext`, `MediaPrev` / `AudioPrev`, `MediaPlayPause` / `AudioPlay` / `AudioPause`, `MediaStop` / `AudioStop`, `Mail`, `Calculator`
- **Raw virtual key codes:** `vk:0xNN` or `0xNN` (`0x01`–`0xFE`)

> [!NOTE]
> `Ctrl+Alt+Delete` is reserved by the Windows kernel (`Winlogon`) and cannot be bound.

---

## Bind actions (`action`)

Each object in `"binds"` supports `"keys"`, `"action"`, `"description"`, `"onRelease"` (`bool`), `"repeat"` (`bool`) and `"register"` (`bool`, see [Routing](#routing-registerhotkey-or-the-keyboard-hook)), plus action-specific fields:

### 1. `"global"` — trigger a Caelestia `CustomShortcut`

Fires a QML `GlobalShortcut` (`CustomShortcut`) registered with `appid: "caelestia"`:

```json
{
    "keys": "Super+D",
    "action": "global",
    "name": "caelestia:dashboard",
    "description": "Toggle dashboard"
}
```

Available Caelestia global shortcut names:

| Shortcut `name` | Description | Source component |
| --- | --- | --- |
| `caelestia:nexus` | Open the Nexus settings window | `daemons/Shortcuts.qml` |
| `caelestia:screenshot` | Glazier screenshot picker and editor | `daemons/Shortcuts.qml` |
| `caelestia:screenshotFreeze` | Glazier screenshot (frozen picker variant) | `daemons/Shortcuts.qml` |
| `caelestia:record` | Start or stop a recording | `daemons/Shortcuts.qml` |
| `caelestia:launcher` | Toggle launcher (fires on release unless interrupted) | `daemons/Shortcuts.qml` |
| `caelestia:launcherInterrupt` | Interrupt lone-Super launcher tap | `daemons/Shortcuts.qml` |
| `caelestia:dashboard` | Toggle top dashboard drawer | `daemons/Shortcuts.qml` |
| `caelestia:session` | Toggle session power menu | `daemons/Shortcuts.qml` |
| `caelestia:sidebar` | Toggle right notification & sidebar drawer | `daemons/Shortcuts.qml` |
| `caelestia:utilities` | Toggle utilities quick-toggles drawer | `daemons/Shortcuts.qml` |
| `caelestia:showall` | Toggle launcher, dashboard, OSD, and utilities together | `daemons/Shortcuts.qml` |
| `caelestia:clearNotifs` | Close all active notifications | `services/Notifs.qml` |
| `caelestia:clipboard` | Open or close the Windows clipboard history picker | `modules/clipboard/ClipboardOverlay.qml` |
| `caelestia:toggleDnd` | Toggle Do Not Disturb | `services/Notifs.qml` |
| `caelestia:mediaToggle` | Play/pause active GSMTC media player | `services/Players.qml` |
| `caelestia:mediaPrev` | Previous track | `services/Players.qml` |
| `caelestia:mediaNext` | Next track | `services/Players.qml` |
| `caelestia:mediaStop` | Stop playback (note: GSMTC has no native stop command) | `services/Players.qml` |
| `caelestia:brightnessUp` | Increase monitor brightness | `services/Brightness.qml` |
| `caelestia:brightnessDown` | Decrease monitor brightness | `services/Brightness.qml` |

All handlers in the table are staged in production, plus `caelestia:volumeUp`, `caelestia:volumeDown`, and `caelestia:volumeMute` from the audio adapter. Service actions retain their control gates. Production targets the focused monitor; bounded previews target their selected screen.

### Screenshots and recording

The shell draws the screenshot picker, editor and recording controls by default.
The bundled Caelestia Capture helper, maintained from Glazier, encodes recordings
and provides the classic UI opt-out. The installer places `caelestia-capture.exe`
beside `qs.exe` in the versioned payload, so an update or rollback keeps the
matching shell and helper together. The shell starts the helper with the profile's
`state\caelestia\theme-tokens.json`, and passes `--no-hotkeys` so exactly one
owner handles each chord.

The shell binds the same chords Glazier used:

| Action | Default keys | Shortcut |
| --- | --- | --- |
| Screenshot | `PrintScreen` and `Win+Shift+S` | `caelestia:screenshot`, `caelestia:screenshotFreeze` |
| Start or stop recording | `Win+Shift+R` | `caelestia:record` |

These binds deliberately do not set `"register": true`: the shell's keyboard
hook owns them and Glazier's own hotkeys are disabled. To use a different
chord, replace the `PrintScreen` / `Win+Shift+S` / `Win+Shift+R` entries in your
`keybinds.json`; do not add the same chord twice. The three entries carry
`since`, so a legacy profile that replaces the defaults without
`"extends": "defaults"` receives them unless that chord or the
`caelestia:screenshot`, `caelestia:screenshotFreeze` or `caelestia:record`
name is already used.

The launcher also offers **Screenshot** and **Record screen**. IPC callers can
use `screenshot capture` or the upstream `picker open`, `openFreeze`,
`openClip`, and `openFreezeClip` functions. All use the configured capture UI
and open its frozen picker and editor.

#### Shell screenshot picker

`windows.capture.ui` in `shell.json` chooses the screenshot and recording interface:
`"classic"` starts Glazier as described above, and `"shell"` (the default) opens
a picker drawn by the shell itself. Every entry point follows the setting: the
`PrintScreen` and `Win+Shift+S` chords, the launcher Screenshot action, IPC
`screenshot capture` and the `picker` functions. Launcher Record and the record
shortcut follow the same setting. A `glazier.exe` override in `glazier.json`
always uses the classic tool. Explicit saved values stay unchanged.

To opt out of the shell UI:

```json
{"windows":{"capture":{"ui":"classic"}}}
```

The picker freezes every screen first, then lets you drag a region, click a
window to select it, or click where no window is to select the whole monitor.
Esc or a right click cancels. Releasing the mouse opens the editor over the
selection and saves nothing. The `open`, `openFreeze`, `openClip` and
`openFreezeClip` names all do this, as the classic tool treats them alike. The
selection cannot span monitors, and the picker always freezes the screen.

The editor has Pencil (`P`), Highlighter (`H`), Line (`L`), Arrow (`A`),
Rectangle (`R`) and Circle (`C`), a colour and size popover (nine colours, S, M
and L), Undo (`Ctrl+Z`), Redo (`Ctrl+Y` or `Ctrl+Shift+Z`), Clear (press twice),
Copy (`Ctrl+C`), Save (`Ctrl+S`) and Close (`Esc`, which first closes an open
popover). The toolbar sits below the selection, above it when there is no room,
or inside it, and it can be dragged. Text, Blur, numbered steps, the ruler, the
eraser and zoom are not there yet.

Nothing is written until you choose Save. Save writes the image with its
annotations to `Pictures\Screenshots` (or `Pictures` if that folder cannot be created) as
`annotate-%Y-%m-%d_%H-%M-%S.png`, adding ` (2)`, ` (3)` for a repeat. Copy puts
it on the clipboard. Each closes the editor and shows the thumbnail, which is
the only confirmation: there is no success toast. With the thumbnail turned off,
Save shows a toast with the file name, as the classic tool does. A failed Save
or Copy shows an error and keeps the editor open.

After a capture the picker shows a thumbnail at the bottom right of the work
area, as the classic tool does. Up to five exist in total, across all monitors.
Each monitor stacks its own upward with the newest at the bottom, and a sixth
removes the oldest one wherever it is. Hovering shows buttons for Copy, Save (only for a capture that was
copied and not saved), Show in folder and Close, and pauses the timeout. Clicking
the card opens the image with the default application, because reopening it in
the editor is not built yet. Press the card and move to drag the image into another app.
A saved capture drags its saved file. A copied capture drags a temporary copy with a normal
screenshot name, removed once its card has closed and 5 minutes have passed since the last drag. Dragging never saves to
the screenshots folder.
Two keys in `shell.json` control it:

```json
{"windows":{"capture":{"thumbnail":true,"thumbnailSeconds":6}}}
```

`thumbnail` set to `false` turns the thumbnail off. `thumbnailSeconds` is how long
a thumbnail stays, and `0` keeps it until it is closed. A capture that was only
copied keeps a preview file in the temp directory until its thumbnail closes.
Save writes it to `Pictures\Screenshots` with the picker's naming, without a toast. Show in
folder saves it first and opens the folder.

A development or recovery build can be pointed at another Glazier with an
absolute path in `%LOCALAPPDATA%\caelestia-windows\config\glazier.json`:

```json
{"executable": "D:\\Apps\\Glazier\\glazier.exe"}
```

The bundled executable is preferred when present; there is no separate
`%LOCALAPPDATA%\Programs\Glazier` install location. If the bundled executable is
missing, Screenshot and Record screen report that Glazier is unavailable and
nothing else changes.

Standalone Glazier still reads `%APPDATA%\Glazier\config.toml`. The shell's
launch options do not modify that file.

`caelestia:nexus` opens the upstream Nexus settings window as a detached top-level window (`modules/nexus/WindowFactory.qml`). **No default key is shipped for it**; add a `global` bind with `"name": "caelestia:nexus"` to use it. If the chord includes the Windows key, add `"register": true` so the window comes to the front instead of opening behind the focused application:

```json
{
    "extends": "defaults",
    "binds": [
        {
            "keys": "Super+Comma",
            "action": "global",
            "name": "caelestia:nexus",
            "register": true,
            "description": "Open Nexus settings"
        }
    ]
}
```

The utilities drawer's "settings" quick toggle opens the same window. The bar popout wrapper also maps a popout's detached mode to this window on the requested page, although no staged Windows popout requests it yet. See [the Nexus page support table](USER-GUIDE.md#nexus-settings-windows) for what each page can change on Windows.

`caelestia:clipboard` ships with **no default key**. Add a bind in your own
`keybinds.json`; the picker reads Windows' native clipboard history, so it
needs no capture daemon. Binding `Super+V` replaces Windows' own Win+V panel for
that chord (Caelestia registers it through `HotkeyManager`, so the shell sees it
first while it runs). The feature is also gated by
`windows.clipboard.enabled` in `shell.json`; see
[the clipboard notes](../services/clipboard/README.md).

The picker also has an IPC target, so it can be opened without a key bind:

```powershell
$prefix = "$env:LOCALAPPDATA\Programs\caelestia-windows"
# The shell runs from the selected version, not the prefix root.
$runtime = Join-Path $prefix ("versions\" + (Get-Content "$prefix\install.json" -Raw | ConvertFrom-Json).current)
& "$runtime\qs.exe" -p "$runtime\shell" ipc call clipboard toggle
& "$runtime\qs.exe" -p "$runtime\shell" ipc call clipboard open
& "$runtime\qs.exe" -p "$runtime\shell" ipc call clipboard close
& "$runtime\qs.exe" -p "$runtime\shell" ipc call clipboard state
```

Calling the prefix root's `qs.exe -p "$prefix\shell"` instead reports "No running
instances", because the running shell's path is the version directory.

## Routing: RegisterHotKey or the keyboard hook

| Chord | Delivered by |
| --- | --- |
| No Windows key, for example `Ctrl+Alt+C` | `RegisterHotKey`, falling back to the hook if Windows refuses it |
| With the Windows key (default) | The keyboard hook. It consumes the chord before the desktop supervisor and does nothing while an elevated app has the foreground |
| With the Windows key and `"register": true` | `RegisterHotKey`, falling back to the hook if Windows refuses it |
| Lone modifier tap or hold | The keyboard hook |

Only a `WM_HOTKEY` delivery gives the shell permission to take the foreground, so a bind that opens a window (Nexus, a picker) needs `"register": true` when its chord has the Windows key; without it the window can open behind the focused application. Leave it off for everything else.

A hook-backed Win chord also swallows the Windows key release and replays a masked one, so Explorer's own Win+<key> handling (including its Win+V clipboard flyout) cannot run after the chord. Binding `Super+V` to `caelestia:clipboard` therefore opens only the Caelestia picker.

`"register": true` has these consequences:

- The hook still injects a masking key tap while the Windows key is down, so the Start menu stays closed when the key is released.
- The bind also fires while an elevated app has the foreground, as chords without the Windows key already do.
- The setting is ignored, and the hook keeps the chord, for the taskbar shortcuts the desktop supervisor consumes when `windows.hideTaskbar` is on (the chords in the note below), because Windows would never deliver them. The log records `Ignoring register for ...`.
- If several binds share one chord, the chord is registered when any of them sets it.

## Shipped default keys

| Action | Default keys | Target |
| --- | --- | --- |
| Toggle the launcher (lone Super tap) | `Super` (tap on release) | `caelestia:launcher` |
| Screenshot | `PrintScreen`, `Win+Shift+S` | `caelestia:screenshot`, `caelestia:screenshotFreeze` |
| Start or stop a recording | `Win+Shift+R` | `caelestia:record` |
| Toggle the launcher, dashboard, OSD and utilities together | `Super+K` | `caelestia:showall` |
| Toggle the dashboard | `Super+Shift+D` | `caelestia:dashboard` |
| Toggle the notification sidebar | `Super+N` | `caelestia:sidebar` |
| Toggle utilities | `Super+Shift+U` | `caelestia:utilities` |
| Toggle the session menu (Ctrl+Alt+Delete is reserved by Windows) | `Ctrl+Alt+End` | `caelestia:session` |
| Clear all notifications | `Ctrl+Alt+C` | `caelestia:clearNotifs` |
| Toggle do not disturb | `Super+Shift+N` | `caelestia:toggleDnd` |
| Play or pause the active player | `Ctrl+Super+Space` | `caelestia:mediaToggle` |
| Play or pause the active player | `XF86AudioPlay` | `caelestia:mediaToggle` |
| Next track | `Ctrl+Super+Equal` | `caelestia:mediaNext` |
| Next track | `XF86AudioNext` | `caelestia:mediaNext` |
| Previous track | `Ctrl+Super+Minus` | `caelestia:mediaPrev` |
| Previous track | `XF86AudioPrev` | `caelestia:mediaPrev` |
| Stop the active player when it supports stop | `Ctrl+Super+Backspace` | `caelestia:mediaStop` |
| Stop the active player when it supports stop | `XF86AudioStop` | `caelestia:mediaStop` |
| Raise the default output volume | `XF86AudioRaiseVolume` | `caelestia:volumeUp` |
| Lower the default output volume | `XF86AudioLowerVolume` | `caelestia:volumeDown` |
| Mute or unmute the default output | `XF86AudioMute` | `caelestia:volumeMute` |
| Mute or unmute the default output | `Super+Shift+M` | `caelestia:volumeMute` |
| Raise the active display brightness | `Ctrl+Alt+Page_Up` | `caelestia:brightnessUp` |
| Lower the active display brightness | `Ctrl+Alt+Page_Down` | `caelestia:brightnessDown` |
| Lock Windows | `Super+L` | `rundll32.exe user32.dll,LockWorkStation` |

> [!NOTE]
> Explorer taskbar shortcuts are not keybind entries. While
> `windows.hideTaskbar` is true, the desktop supervisor consumes Win+T,
> Win+Shift+T, Win+B, Win+digit, Win+Shift+digit, Win+Ctrl+digit,
> Win+Alt+digit and Win+Alt+Enter with a low-level hook so they cannot reveal
> the hidden taskbar. They cannot be changed in `keybinds.json`; a lone Super
> tap and Super+L are unchanged. Injected or remapped versions of these chords
> are consumed too, unless they carry the shell/supervisor mask signature.


### 2. `"dispatch"` — run a window or workspace dispatcher

Sends a Hyprland-style dispatcher string to the Windows backend:

```json
{
    "keys": "Super+1",
    "action": "dispatch",
    "dispatch": "workspace 1",
    "description": "Switch to workspace 1"
}
```

Hotkey `dispatch` actions invoke the backend `Hyprland.dispatch` directly, bypassing the QML HyprService allowlist. No dispatch bindings are shipped by default. Add them only after configuring the intended workspace/tiling behavior. The following backend dispatchers exist:

| Dispatcher | Description |
| --- | --- |
| `workspace <n>` | Switch to numbered virtual desktop `n`, creating it if needed up to the configured limit |
| `workspace +1` / `-1` / `r+1` / `r-1` / `e+1` / `e-1` | Switch to the next or previous virtual desktop. `r` and `e` resolve the same way on Windows; there is no empty-desktop search |
| `workspace name:<name>` | Switch to an existing named virtual desktop |
| `workspace empty` | Switch to the first empty virtual desktop, creating one if needed |
| `workspace previous` | Switch to previously focused virtual desktop |
| `movetoworkspace <target>` | Move a window to the target and follow it; the target accepts every `workspace` form except `special:` |
| `movetoworkspacesilent <target>` | Move a window to the target without switching |
| `centerwindow` | Center the active floating window on its monitor's work area; a scrolling-layout tile centers its column, a dwindle/master tile is unchanged |
| `pin` / `pin on` / `pin off` | Toggle or force an all-desktop pin; needs the pin exports of `VirtualDesktopAccessor.dll`, otherwise it logs an unsupported reason and does nothing |
| `resizeactive <width> <height>` | Resize the active window by pixels or `%` of its current size; `0` keeps an axis unchanged |
| `resizeactive exact <width> <height>` | Set the size, using the monitor size for `%` values; a `0` axis keeps its current size |
| `closewindow` / `killactive` | Close active window (`WM_CLOSE`) |
| `togglefloating` | Float or retile the active window |
| `fullscreen` | Toggle fullscreen (`0`) or maximize (`1`) |
| `movefocus l` / `r` / `u` / `d` | Move focus to the tiled neighbor on the left, right, top, or bottom |
| `movewindow l` / `r` / `u` / `d` | Move or swap the active tiled window in the given direction |
| `swapwindow l` / `r` / `u` / `d` | Swap the active tiled window with its neighbor |
| `togglesplit` | Toggle split direction (`dwindle` layout) |
| `splitratio +0.1` / `-0.1` | Adjust split ratio or master factor; `layoutmsg splitratio ...` is equivalent |
| `togglespecialworkspace <name>`, `togglegroup`, `changegroupactive` | Refused with a named warning; see the mapping note below |

#### Hyprland bind mapping

The ported Linux binds use Hyprland's Lua dispatcher names. `Hyprland.dispatch`
accepts those as well as the classic names above, for example
`hl.dsp.focus({workspace="+1"})`,
`hl.dsp.window.move({workspace="r-1",follow=false})`,
`hl.dsp.window.center()`, `hl.dsp.window.pin({action="on"})`,
`hl.dsp.window.resize({x=0,y=100,relative=true})` and
`hl.dsp.layout("splitratio 0.6")`.

**Maps:** workspace selection and relative moves; `movetoworkspace` and
`movetoworkspacesilent` with numeric, relative or `previous` targets;
`centerwindow`; `pin` with `on`/`off`; relative and exact `resizeactive` with a
pixel or percent axis; focus/move/swap by direction; floating,
fullscreen/maximize, split and layout messages; `exec`, `global` and `no_op`.

**Does not map:**

- *Special/scratchpad workspaces.* Windows virtual desktops are exclusive and
  user-visible, so there is no hidden scratchpad that can be layered over the
  current desktop. `workspace special:<name>`,
  `movetoworkspace special:<name>`, `togglespecialworkspace <name>`,
  `hl.dsp.workspace.toggle_special(<name>)` and
  `hl.dsp.focus({workspace="special:<name>"})` log a named refusal and do
  nothing. A faithful mapping would need a separate named-desktop or overlay
  subsystem.
- *Window groups/tabs.* DWM has no group stack to add to, cycle or lock, so
  `togglegroup`, `changegroupactive`, `hl.dsp.group.*`,
  `hl.dsp.window.cycle_next` and `hl.dsp.window.move({out_of_group=true})` log
  a named refusal. Use the native Alt+Tab switcher for window cycling.
- *Monitor dispatch.* `focusmonitor` and
  `movecurrentworkspacetomonitor` assume per-monitor workspaces; the Windows
  virtual-desktop model is global across monitors.
- *`swapnext` / `cyclenext`.* Use `swapwindow <direction>` for a directional
  swap and the native task switcher for cycling.

### 3. `"ipc"` — call a Caelestia `IpcHandler`

Calls a QML `IpcHandler` target and function inside the running shell:

```json
{
    "keys": "Super+N",
    "action": "ipc",
    "target": "drawers",
    "function": "toggle",
    "args": ["sidebar"],
    "description": "Toggle notification sidebar"
}
```

The installed shell also exposes the explicit
panel-off action `displays off`. It asks the shell's own window to process
Windows display power (`WM_SYSCOMMAND` / `SC_MONITORPOWER = 2`). A keybind call
waits until the keyboard hook has seen every key of the triggering chord come
up, so holding the chord cannot switch the panels off under your fingers; any
other key or mouse button pressed first cancels the request. A direct
`ipc call` has no chord and sends at once. The action changes no topology,
resolution, scale or window position and writes no setting. Normal input wakes
the panels; keep-awake, remote input or background activity can wake them. No
default key is shipped; add this bind to opt in:

```json
{
    "keys": "Super+Shift+O",
    "action": "ipc",
    "target": "displays",
    "function": "off",
    "description": "Turn the panels off (wake with input)"
}
```

The action is also callable without a key:

```powershell
$prefix = "$env:LOCALAPPDATA\Programs\caelestia-windows"
$runtime = Join-Path $prefix ("versions\" + (Get-Content "$prefix\install.json" -Raw | ConvertFrom-Json).current)
& "$runtime\qs.exe" -p "$runtime\shell" ipc call displays off
```

Live-checked on two monitors: the panels go dark, and the monitor
topology, scale and window placement are kept. Prefer it over a monitor's power
button: on DisplayPort the button is a hot-unplug, so Windows removes the
monitor and rearranges the desktop (see ).

### 4. `"exec"` — launch an external command

Runs a command line in a detached process:

```json
{
    "keys": "Super+Return",
    "action": "exec",
    "command": "wt.exe",
    "description": "Open Windows Terminal"
}
```

### 5. `"key"` — synthesize a virtual key tap

Sends a synthetic key press (`sendVk`) to the foreground window:

```json
{
    "keys": "CapsLock",
    "action": "key",
    "key": "Escape",
    "description": "Map CapsLock to Escape"
}
```

### 6. `"reload"` — reload the shell configuration

Triggers a live Quickshell reload:

```json
{
    "keys": "Super+Shift+R",
    "action": "reload",
    "description": "Reload Caelestia shell"
}
```
