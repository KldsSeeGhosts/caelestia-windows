//! First-party settings in `%APPDATA%\Caelestia\capture\config.toml`.
//! A legacy Glazier config is copied only when this destination is absent.

use serde::Deserialize;
use std::path::PathBuf;

#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
pub struct Config {
    pub hotkeys: Vec<String>,
    pub recording_hotkey: String,
    pub recording_directory: String,
    pub recording_fps: u32,
    pub save_directory: String,
    pub filename_format: String,
    pub default_tool: String,
    pub default_color: String,
    pub default_size: f32,
    pub show_magnifier: bool,
    pub show_tool_options: bool,
    pub toolbar_theme: String,
    pub theme_file: String,
    pub show_thumbnail: bool,
    pub thumbnail_seconds: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            hotkeys: vec!["PrintScreen".into(), "Win+Shift+S".into()],
            recording_hotkey: "Win+Shift+R".into(),
            recording_directory: String::new(),
            recording_fps: 30,
            save_directory: String::new(),
            filename_format: String::new(),
            default_tool: "pencil".into(),
            default_color: "#FF4444".into(),
            default_size: 3.0,
            show_magnifier: true,
            show_tool_options: true,
            toolbar_theme: "auto".into(),
            theme_file: String::new(),
            show_thumbnail: true,
            thumbnail_seconds: 6,
        }
    }
}

const TEMPLATE: &str = r##"# Caelestia capture settings. Choose "Reload settings" from the tray menu after editing.

# Shortcuts that freeze all monitors and open the region picker.
# Modifiers: Ctrl, Alt, Shift, Win. Keys: A-Z, 0-9, F1-F24, PrintScreen, Insert,
# Delete, Home, End, PageUp, PageDown, Pause, ScrollLock, Space.
# "Win+Shift+S" and "PrintScreen" take over the Windows Snipping Tool shortcuts.
hotkeys = ["PrintScreen", "Win+Shift+S"]

# Separate recording picker. Press again while recording to stop.
recording_hotkey = "Win+Shift+R"
# Empty uses Videos\Screen Recordings. Environment variables are expanded.
recording_directory = ""
# Frames per second, from 1 to 60.
recording_fps = 30

# Folder for saved annotations. Empty uses Pictures\Screenshots, then Pictures.
save_directory = ""

# File name without extension. %Y %m %d %H %M %S expand to the current time.
# Empty uses annotate-%Y-%m-%d_%H-%M-%S.
filename_format = ""

# pencil, highlighter, line, arrow, rect, circle, text, blur, step or ruler.
default_tool = "pencil"
default_color = "#FF4444"
default_size = 3

# Show the zoom control on the selection and the color/size button in the toolbar.
show_magnifier = true
show_tool_options = true

# Toolbar appearance: "auto" follows the Windows app theme, or "dark" / "light".
toolbar_theme = "auto"

# Optional absolute path to a versioned theme-token JSON file.
theme_file = ""

# Floating exported-image previews. Hover pauses dismissal; 0 stays until closed.
show_thumbnail = true
thumbnail_seconds = 6
"##;

pub fn dir() -> PathBuf {
    let base = std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    base.join("Caelestia").join("capture")
}

pub fn path() -> PathBuf {
    dir().join("config.toml")
}

/// Loads settings, creating the commented template on first run.
/// Returns the defaults and an error message when the file is invalid.
pub fn load() -> (Config, Option<String>) {
    let base = std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    let (cfg, error) = load_paths(&path(), &base.join("Glazier").join("config.toml"));
    // Audio choices migrate separately, without ever rewriting legacy state.
    // A refused audio migration must not discard valid screenshot settings.
    let audio_error = initialize_file(&dir().join("state.toml"), &base.join("Glazier").join("state.toml"), None)
        .err().map(|e| format!("Could not migrate audio settings: {e}"));
    (cfg, error.or(audio_error))
}

fn load_paths(path: &std::path::Path, legacy: &std::path::Path) -> (Config, Option<String>) {
    if let Err(e) = initialize(path, legacy) {
        return (Config::default(), Some(format!("Could not initialize config.toml: {e}")));
    }
    match std::fs::read_to_string(&path) {
        Ok(text) => match toml::from_str::<Config>(&text) {
            Ok(cfg) => (cfg, None),
            Err(e) => (Config::default(), Some(format!("config.toml: {}", e.message()))),
        },
        Err(e) => (Config::default(), Some(format!("Could not read config.toml: {e}"))),
    }
}

fn initialize(path: &std::path::Path, legacy: &std::path::Path) -> std::io::Result<()> {
    initialize_file(path, legacy, Some(TEMPLATE.as_bytes()))
}

fn initialize_file(path: &std::path::Path, legacy: &std::path::Path, fallback: Option<&[u8]>) -> std::io::Result<()> {
    use std::io::Write;
    // exists() alone cannot distinguish access denial from absence. Only
    // NotFound authorizes creation, and create_new closes the overwrite race.
    match std::fs::metadata(path) {
        Ok(_) => return Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let contents = match std::fs::read(legacy) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => match fallback {
            Some(bytes) => bytes.to_vec(),
            None => return Ok(()),
        },
        Err(e) => return Err(e),
    };
    if let Some(parent) = path.parent() { std::fs::create_dir_all(parent)?; }
    match std::fs::OpenOptions::new().write(true).create_new(true).open(path) {
        Ok(mut file) => file.write_all(&contents),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
        Err(e) => Err(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn template_matches_defaults() {
        let cfg: Config = toml::from_str(TEMPLATE).unwrap();
        let def = Config::default();
        assert_eq!(cfg.hotkeys, def.hotkeys);
        assert_eq!(cfg.recording_hotkey, def.recording_hotkey);
        assert_eq!(cfg.recording_fps, def.recording_fps);
        assert_eq!(cfg.default_tool, def.default_tool);
        assert_eq!(cfg.default_size, def.default_size);
        assert_eq!(cfg.toolbar_theme, def.toolbar_theme);
        assert_eq!(cfg.theme_file, def.theme_file);
        assert_eq!(cfg.show_thumbnail, def.show_thumbnail);
        assert_eq!(cfg.thumbnail_seconds, def.thumbnail_seconds);
    }

    #[test]
    fn legacy_settings_copy_only_if_missing_and_never_rewrite_user_files() {
        let dir = std::env::temp_dir().join(format!("capture-config-test-{}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        let legacy = dir.join("legacy.toml");
        let current = dir.join("capture").join("config.toml");
        let old = b"recording_directory = 'D:\\Old Recordings'\nrecording_fps = 24\n";
        std::fs::write(&legacy, old).unwrap();
        let (cfg, error) = load_paths(&current, &legacy);
        assert!(error.is_none());
        assert_eq!(cfg.recording_fps, 24);
        assert_eq!(cfg.recording_directory, r"D:\Old Recordings");
        assert_eq!(std::fs::read(&legacy).unwrap(), old);
        std::fs::write(&current, b"recording_fps = 48").unwrap();
        assert_eq!(load_paths(&current, &legacy).0.recording_fps, 48);
        assert_eq!(std::fs::read(&current).unwrap(), b"recording_fps = 48");
        std::fs::write(&current, b"invalid = [").unwrap();
        assert!(load_paths(&current, &legacy).1.is_some());
        assert_eq!(std::fs::read(&current).unwrap(), b"invalid = [");
        let old_state = dir.join("old-state.toml");
        let state = dir.join("capture").join("state.toml");
        std::fs::write(&old_state, b"mic = true\nsound = false").unwrap();
        initialize_file(&state, &old_state, None).unwrap();
        assert_eq!(std::fs::read(&state).unwrap(), std::fs::read(&old_state).unwrap());
        std::fs::write(&state, b"mic = false").unwrap();
        initialize_file(&state, &old_state, None).unwrap();
        assert_eq!(std::fs::read(&state).unwrap(), b"mic = false");
        assert_eq!(std::fs::read(&old_state).unwrap(), b"mic = true\nsound = false");
        std::fs::remove_file(state).unwrap();
        std::fs::remove_file(old_state).unwrap();
        std::fs::remove_file(current).unwrap();
        std::fs::remove_file(legacy).unwrap();
        std::fs::remove_dir(dir.join("capture")).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
}
