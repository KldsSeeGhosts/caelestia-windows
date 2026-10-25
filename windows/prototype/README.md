# First compatibility prototype

Target: Caelestia's actual bar and one animated drawer, hosted by Windows
Quickshell, in a configuration that can run beside the normal desktop.

This directory intentionally contains no mock UI or launcher that runs the
unadapted root shell. The prototype is not implemented yet.

Implementation order:

1. Establish the Windows Qt/C++ toolchain and build the pinned backend.
2. Build the portable Caelestia plugin modules. Audit dependencies of Config,
   Settings, Components, Blobs, and their shared core before disabling services.
3. Check the Blobs/Components shaders on the selected Windows graphics backend.
4. Add an isolated entry point referencing the original Caelestia components
   and explicitly gated service adapters.
5. Verify the M1 criteria in `../ROADMAP.md` before expanding the entry point.

Keep screenshots, generated configuration, logs, binaries, and runtime state
under ignored `windows/.local/` paths. Never use the user's normal Caelestia,
ii, or ksg-shell configuration as prototype state.
