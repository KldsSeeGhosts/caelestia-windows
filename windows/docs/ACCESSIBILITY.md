# Staged-shell accessibility audit

Scope: the surfaces the Windows graph actually stages in
`windows/shell/sources.json` - launcher, session drawer, notification
actions and Nexus settings. Keyboard-only use plus the accessible names, roles
and actions a screen reader reads are in scope. Narrator was **not tested
(out of scope by maintainer)**.

## Method

The audit is a code review of the staged graph plus offscreen QML fixtures run
against a finished dev build. Every fixture stages the production map with
`Stage-ShellPrototype.ps1`, isolates the profile under `%TEMP%`, uses
`QT_QPA_PLATFORM=offscreen`, and drives the real component with `QtTest` key
events. No live install, shell restart, IPC or pointer input was used.

Existing gates were extended, not duplicated: `Test-AccessibilitySession.ps1`,
`Test-QuotaProviderKeyboard.ps1` and `Test-Nexus.ps1 -Suite Keyboard`. Two new
gates cover the launcher and notification actions.

## Surface matrix

| Surface | Keyboard reach/operate | Focus visible | Trapped in hidden drawer | `Accessible.name` / role | Windows high contrast | Reduced motion |
| --- | --- | --- | --- | --- | --- | --- |
| Launcher (search + action/app results) | Yes: open, type, Up/Down, Return, Escape (offscreen) | Search caret and list selection highlight; no ring on the field or result rows | No: only the search field is in the tab chain; results are selected, never focused | Yes after fix: named list rows and a named search field | Not read; palette does not adapt | Not read |
| Session drawer (`adapters/modules/session/Content.qml`) | Yes: open, Up/Down, Return/Enter, Escape; Tab and Shift+Tab walk a closed cycle over all four buttons, with and without vim keybinds and with the session GIF loaded | Yes: `FocusRing` on the focused button | No after fix: every button names both Tab neighbours, so focus cannot fall back to Qt's default chain, and Escape always reaches one | Yes: `Button` role and action names | Not read | Not read |
| Notification popup actions (`modules/notifications/Notification.qml`) | Yes after fix: expand, action, close and copy are in the tab chain and activate on Return/Enter/Space; collapsed cards take the hidden row out of traversal | Yes after fix: `FocusRing` on every control; collapsing hands focus to the expand control | No: the card is one shallow focus group | Yes after fix: names reflect current action/state | Not read | Not read |
| Notification sidebar (`modules/sidebar/Notif*.qml`) | No: expand, dismiss and actions are pointer-only (`MouseArea`/`StateLayer`) | Pointer state layer only | n/a | Missing on group/action controls | Not read | Not read |
| Nexus settings (`modules/nexus/**`) | Yes: Tab walks every page/sub-page, rows toggle/open, Return on nav opens a page; Escape closes the window after fix | Yes: `FocusRing` on rows, toggles and nav entries | No: the tab walk is a closed cycle and skips hidden/disabled rows | Partial: `RowButton`/nav entries named; inline slider, spinner and text-field controls have no row label | Not read | Not read |
| Quota provider tabs (`windows/quota/modules/quota/Content.qml`) | Yes: Tab/Shift+Tab, Return/Enter/Space, pointer parity | Yes: selected/focused tab treatment | No | Yes: provider labels and state in `Accessible.name` | Not read | Not read |

## Offscreen evidence

| Gate | Rows/checks | Result |
| --- | --- | --- |
| `windows/scripts/Test-AccessibilityLauncher.ps1` | 8 audit rows: focus on open, named search, action provider, row role/name, every instantiated row named, Up/Down, Return activation, Escape close | Pass after the launcher fix; all name/role rows failed before it |
| `windows/scripts/Test-AccessibilityNotifications.ps1` | 14 audit rows: action/close/copy/expand in tab chain, names and roles, Return invokes, Space dismisses, collapsed actions leave traversal, collapse moves focus from a focused action row, expanding restores traversal, and negative collapses (another surface, another card, an inactive window, a pointer click without row focus) leave focus alone | Pass; the 7 name/tab rows failed before the first fix, the 3 collapsed rows failed before the collapsed-state fix, and the 4 negative rows fail when every collapse grabs focus |
| `windows/scripts/Test-AccessibilitySession.ps1` | 133 checks, 4 audit rows: Return dispatches once with no confirmation UI, a full Tab/Shift+Tab walk with focus inside the drawer after every hop, Escape still closes the drawer after the walk, and the same walk with vim keybinds off/on and the session GIF Loader off/on | Pass after the full-cycle fix; the non-vim walk and Escape rows failed on the endpoint-only wrap, and the walk fails on `origin/dev` |
| `windows/scripts/Test-QuotaProviderKeyboard.ps1` | 28 assertions | Pass unchanged |
| `windows/scripts/Test-Nexus.ps1 -Suite Keyboard` | 36 pages/sub-pages, 27 reachable rows, plus close name and Escape | Pass after the Nexus fix; close name failed before it |

## Fixes in this change

1. Launcher results expose one named `ListItem` each (apps, actions, schemes,
   variants, wallpapers, calculator), and the search field is named
   "Search applications and actions".
2. Notification popup expand/action/close/copy controls joined the tab chain
   with `Button` roles, state-aware names, existing `FocusRing` treatment and
   Return/Enter/Space activation. A collapsed card takes those controls out of
   traversal and hands focus back to the visible expand control only when the
   collapse took focus from that card's own action row.
3. Nexus names its only close control and Escape now dismisses the inline
   overlay and the detached window through the same close signal.
4. Session drawer: all four buttons name both their Tab and
   Shift+Tab neighbour, so traversal is a closed cycle and never falls back to
   Qt's default chain; the vim keybind path uses the same links. Focus and
   Escape can no longer leave the drawer. Session actions run immediately, as
   in upstream Caelestia; the Windows confirmation step is gone, so there is no
   Cancel/Confirm group to tab into.

No colour, spacing, type or motion value was changed. Focus rings reuse the
existing `components/FocusRing.qml`; no new focus-ring appearance is proposed
in the diff.

## Not tested here

- Live desktop behaviour: hotkey entry into the launcher, real window focus
  return after the shell window closes, and per-monitor placement.
- Narrator or any screen reader session, by maintainer decision.
- Windows high contrast and reduced motion in a live theme change. The code
  audit is conclusive about the missing QML reader, but no visual pass was
  run.
- Notification mirroring, toast delivery and dismissal against a real Windows
  notification listener; the fixture uses an in-memory `NotifData`.
- Pointer gestures and touch.

## Follow-ups (not in this diff)

- Notification sidebar (`NotifDockList`/`NotifGroup`/`NotifActionList`): the
  whole card remains pointer-only. It needs a focus group, an expansion
  control and named action buttons, with the same offscreen pattern.
- Nexus inline controls: `SliderRow`, `StepperRow` and `TextFieldRow` should
  pass their row label to the inner control as `Accessible.name`.
- Windows settings: no QML reads high contrast or `SPI_GETCLIENTAREAANIMATION`
  / `UISettings.AnimationsEnabled`. The backend already uses the animation flag
  for panel transitions and disables blur under high contrast; a shell-wide
  policy (palette plus `Anim` durations) is a design change for the
  coordinator.
- Focus appearance on the launcher search field and selected result is
  deliberately unchanged; a visible focus ring there is a visual proposal for
  the coordinator, not part of this fix.
