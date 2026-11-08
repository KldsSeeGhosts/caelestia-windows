# Preview limitations

This is a Windows 11 x64 preview, not a certification for every Windows build,
display, device, assistive technology or security-policy configuration.
Release-specific build and package results belong to the matching GitHub
release and Actions runs.

- **Unsigned packages:** Windows security policy may block the scripts or
  executables. Do not disable Smart App Control, antivirus or organizational
  protections to run a preview. A self-signed certificate is not a trusted
  publisher signature.
- **Accessibility:** primary launcher, Nexus and session-menu keyboard paths
  have been exercised, but complete Narrator, high-contrast, reduced-motion and
  visible-focus certification is not established. Session-menu focus return on
  every same-monitor configuration is not certified.
- **Wallpaper Engine:** the integration is opt-in and off for a fresh profile;
  Nexus > Services enables it once Wallpaper Engine is installed and running.
  Selection and restoration are supported through the production bridge. Rare
  desktop flashes and unsolicited brightness overlays remain unqualified;
  seamless presented-frame handoff is not guaranteed.
- **Wallpaper Engine while disabled:** a running engine keeps a visible
  wallpaper window that the shell cannot place its own background above. The
  bundled wallpaper and palette stay selected, but the engine's window covers
  the desktop until the process quits. Fixing that needs a backend change.
- **Wallpaper provenance:** the fresh-or-upgrade marker records its decision
  once. An existing profile whose entire `state/caelestia` directory was
  removed is indistinguishable from a fresh one; deleting only
  `wallpaper/desktop.json` keeps the recorded provenance.
- **Capture:** shipped screenshots, recordings and previews are 8-bit SDR sRGB.
  They do not preserve an HDR source as an HDR output. See
  [capture color policy](CAPTURE-COLOR.md).
- **Optional Python tools:** the basic fixed-palette shell does not need Python.
  Dynamic wallpaper colors require the supported classic CPython launcher and
  pinned optional packages. Windows Store/install-manager aliases are not
  provisioned automatically. See [release installation](INSTALL-RELEASE.md).
- **Performance:** bounded comparisons and package smoke checks do not
  establish long-term leak freedom or whole-application CPU, GPU and wakeup
  improvements. No such blanket performance claim is made.
- **Hardware and recovery:** untested mixed-DPI, hotplug, device-denial,
  sleep/wake and security-policy combinations are not implied by a passing
  build or smoke result. Capability refusals should be reported rather than
  treated as successful actions.
- **Translations and retained versions:** this tooling selection omits Qt
  translation catalogs. Installer cleanup may retain an older payload when it
  cannot safely prove removal is appropriate.

Desktop takeover, autostart and tiling remain deliberate opt-ins. Keep one
active tiler. Updates preserve the previous payload for rollback and preserve
the profile on ordinary uninstall.
