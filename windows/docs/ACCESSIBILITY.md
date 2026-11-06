# Windows shell accessibility

This describes the production graph in `windows/shell/sources.json`: launcher,
session drawer, notification actions, Nexus settings and quota drawer. It is
a capability and limitations reference, not screen-reader certification.

## Keyboard and accessible metadata

- Launcher results expose named `ListItem` rows for apps, actions, schemes,
  variants, wallpapers and calculator results. The search field is named
  "Search applications and actions". Up/Down changes selectable/selected state
  while keyboard focus stays in search; Return activates and Escape closes.
  The search caret and selection highlight are visible, but neither the field
  nor result rows has a separate focus ring.
- Session buttons have action names, `Button` roles and the existing
  `FocusRing`. Tab and Shift+Tab form a closed cycle over all four buttons;
  the vim keybind path uses the same links. Escape closes the drawer.
  Session actions run immediately, as in upstream Caelestia. There is no
  confirmation group.
- Notification popup expand/action/close/copy controls are in the tab chain,
  have state-aware names and `Button` roles, and activate on Return/Enter/Space.
  Collapsed cards remove hidden controls from traversal. Collapse returns
  focus to the expand control only when that card's own action row held it.
- Nexus rows, toggles and navigation entries use focus rings. Tab skips
  hidden/disabled rows, Return on navigation opens a page, and Escape dismisses
  inline and detached settings through the same close signal. The close
  control is named. Slider, stepper and text-field rows pass their visible
  labels to the corresponding controls' accessible names.
- Quota supports Tab/Shift+Tab, Return/Enter/Space, arrows, Page Up/Down,
  Home/End and Escape across the segments, scrolling content and menu. Meters
  expose provider, window, remaining percentage and reset time in their
  accessible names. Segments and controls retain their existing focus rings.

These behaviors reuse upstream components and focus treatment. No separate
Windows visual style is implied.

## Known limitations

- Notification sidebar group expansion, dismissal and action controls remain
  pointer-only and lack the corresponding group/action accessibility metadata.
- The QML shell does not read Windows high contrast or
  `SPI_GETCLIENTAREAANIMATION` / `UISettings.AnimationsEnabled`.
  The backend uses the animation flag for panel transitions and disables blur
  under high contrast, but that is not a shell-wide palette/motion policy.
- A visible highlight or a named control alone does not establish successful
  Narrator navigation or announcement.

## Validation

Use the [public production smoke](../NATIVE-BUILD.md#smoke) for loading and the
[installed-shell live checklist](LIVE-CHECKLIST.md) for actual keyboard entry,
traversal, Escape, focus return and per-monitor placement.
Narrator/screen-reader use, live high-contrast and reduced-motion changes,
notification-listener behavior, pointer gestures and touch need separate
acceptance. No fixture or historical audit result is a current live pass.
Use synthetic content and keep recordings and results outside the checkout.
