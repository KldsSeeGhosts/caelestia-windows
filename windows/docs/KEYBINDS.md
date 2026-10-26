# Keybinds reference

Back to the [Caelestia for Windows user guide](USER-GUIDE.md).

On Linux, Caelestia relies on Hyprland (`hyprland.conf` or `keybinds.lua`) to capture global shortcuts and run window/workspace dispatchers. On Windows, the Quickshell backend provides a built-in `HotkeyManager` (`Quickshell.Windows.Hotkeys`) that registers Win32 hotkeys (`RegisterHotKey`) and a low-level keyboard hook (`WH_KEYBOARD_LL`) when needed for lone-modifier taps or `Win+<Key>` overrides.

`TODO(verify): confirm the exact staged default path (defaults/windows/keybinds.json) and user override path (e.g., %LOCALAPPDATA%\caelestia-windows\config\keybinds.json) from branch t3/global-shortcuts.`

---

## Where `keybinds.json` lives

1. **Built-in defaults:** Shipped in the shell directory at `defaults/windows/keybinds.json`.
2. **User overrides:** Configured via the `"userFile"` field in `defaults/windows/keybinds.json`, resolved relative to `%LOCALAPPDATA%` (or as an absolute path), typically `%LOCALAPPDATA%\caelestia-windows\config\keybinds.json` (`TODO(verify): confirm exact userFile value on branch t3/global-shortcuts`).

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
| `caelestia:launcher` | Toggle launcher (fires on release unless interrupted) | `daemons/Shortcuts.qml` |
| `caelestia:launcherInterrupt` | Interrupt lone-Super launcher tap | `daemons/Shortcuts.qml` |
| `caelestia:dashboard` | Toggle top dashboard drawer | `daemons/Shortcuts.qml` |
| `caelestia:session` | Toggle session power menu | `daemons/Shortcuts.qml` |
| `caelestia:sidebar` | Toggle right notification & sidebar drawer | `daemons/Shortcuts.qml` |
| `caelestia:utilities` | Toggle utilities quick-toggles drawer | `daemons/Shortcuts.qml` |
| `caelestia:showall` | Toggle launcher, dashboard, OSD, and utilities together | `daemons/Shortcuts.qml` |
| `caelestia:nexus` | Open Caelestia settings window (Nexus) | `daemons/Shortcuts.qml` |
| `caelestia:clearNotifs` | Close all active notifications | `services/Notifs.qml` |
| `caelestia:toggleDnd` | Toggle Do Not Disturb | `services/Notifs.qml` |
| `caelestia:mediaToggle` | Play/pause active GSMTC media player | `services/Players.qml` |
| `caelestia:mediaPrev` | Previous track | `services/Players.qml` |
| `caelestia:mediaNext` | Next track | `services/Players.qml` |
| `caelestia:mediaStop` | Stop playback (note: GSMTC has no native stop command) | `services/Players.qml` |
| `caelestia:brightnessUp` | Increase monitor brightness | `services/Brightness.qml` |
| `caelestia:brightnessDown` | Decrease monitor brightness | `services/Brightness.qml` |

`TODO(verify): confirm which of these CustomShortcut handlers are staged in the production Windows shell on branch t3/global-shortcuts.`

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

Supported dispatch commands on Windows (`TODO(verify): confirm whether hotkeys.cpp invokes the backend dispatcher directly or goes through the HyprService allowlist on branch t3/global-shortcuts`):

| Dispatcher | Description |
| --- | --- |
| `workspace 1..10` | Switch to numbered virtual desktop `1`–`10` |
| `workspace +1` / `workspace -1` / `workspace r+1` / `workspace r-1` | Switch to next or previous virtual desktop |
| `workspace e+1` / `workspace e-1` | Switch to next or previous occupied virtual desktop |
| `workspace previous` | Switch to previously focused virtual desktop |
| `movetoworkspace 1..10` | Move active window to virtual desktop `1`–`10` and follow it |
| `movetoworkspacesilent 1..10` | Move active window to virtual desktop `1`–`10` without switching |
| `closewindow` / `killactive` | Close active window (`WM_CLOSE`) |
| `togglefloating` | Float or retile the active window |
| `fullscreen` | Toggle fullscreen (`0`) or maximize (`1`) |
| `movefocus l` / `r` / `u` / `d` | Move focus to the tiled neighbor on the left, right, top, or bottom |
| `movewindow l` / `r` / `u` / `d` | Move or swap the active tiled window in the given direction |
| `swapnext` | Swap active window with the next tiled window |
| `togglesplit` | Toggle split direction (`dwindle` layout) |
| `splitratio +0.1` / `-0.1` | Adjust split ratio or master factor |

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
