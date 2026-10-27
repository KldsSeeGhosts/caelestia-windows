# Keybinds reference

Back to the [Caelestia for Windows user guide](USER-GUIDE.md).

On Linux, Caelestia relies on Hyprland (`hyprland.conf` or `keybinds.lua`) to capture global shortcuts and run window/workspace dispatchers. On Windows, the Quickshell backend provides a built-in `HotkeyManager` (`Quickshell.Windows.Hotkeys`) that registers Win32 hotkeys (`RegisterHotKey`) and a low-level keyboard hook (`WH_KEYBOARD_LL`) when needed for lone-modifier taps or `Win+<Key>` overrides.

Defaults are staged at `shell/defaults/windows/keybinds.json`. Production seeds `config/keybinds.json` under the recorded profile on first launch only.

---

## Where `keybinds.json` lives

1. **Built-in defaults:** Shipped in the shell directory at `defaults/windows/keybinds.json`.
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

Each object in `"binds"` supports `"keys"`, `"action"`, `"description"`, `"onRelease"` (`bool`), and `"repeat"` (`bool`), plus action-specific fields:

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

`caelestia:nexus` opens the upstream Nexus settings window as a detached top-level window (`modules/nexus/WindowFactory.qml`). **No default key is shipped for it**; add a `global` bind with `"name": "caelestia:nexus"` to use it, for example:

```json
{
    "extends": "defaults",
    "binds": [
        {
            "keys": "Super+Comma",
            "action": "global",
            "name": "caelestia:nexus",
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
& "$prefix\qs.exe" -p "$prefix\shell" ipc call clipboard toggle
& "$prefix\qs.exe" -p "$prefix\shell" ipc call clipboard open
& "$prefix\qs.exe" -p "$prefix\shell" ipc call clipboard close
& "$prefix\qs.exe" -p "$prefix\shell" ipc call clipboard state
```

## Shipped default keys

| Action | Default keys | Target |
| --- | --- | --- |
| Toggle the launcher (lone Super tap) | `Super` (tap on release) | `caelestia:launcher` |
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

The installed shell (not the combined dev prototype) also exposes the explicit
panel-off action `displays off`. It asks
the shell's own window to process Windows display power (`WM_SYSCOMMAND` /
`SC_MONITORPOWER = 2`) after a 500 ms delay, so the triggering key release does
not immediately wake the panels again. It changes no topology, resolution,
scale or window position and writes no setting. Normal input wakes the panels;
keep-awake, remote input or background activity can wake them. No default key
is shipped; add this bind to opt in:

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
& "$prefix\qs.exe" -p "$prefix\shell" ipc call displays off
```

Only fakes have exercised this path. Whether Windows retains the monitor
topology and window placement is a live QA check, not a guarantee; physically
switching a monitor off may still remove it.

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
