//! Hidden host window: recorder commands, tray icon and notifications.

use crate::config::{self, Config};
use crate::control::{self, Command, Options};
use crate::gfx::Gfx;
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicIsize, Ordering};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::DirectWrite::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Graphics::Imaging::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::*;

pub const CLASS: PCWSTR = w!("CaelestiaCaptureHost");
pub const WM_APP_ALREADY_RUNNING: u32 = WM_APP + 5;
const WM_APP_TRAY: u32 = WM_APP + 3;
const TRAY_ID: u32 = 1;

const CMD_SETTINGS: usize = 3;
const CMD_RELOAD: usize = 4;
const CMD_EXIT: usize = 6;
const CMD_RECORD: usize = 7;
const WM_APP_RECORDING_CHANGED: u32 = WM_APP + 7;

static HOST: AtomicIsize = AtomicIsize::new(0);
static EXITING: AtomicBool = AtomicBool::new(false);

struct App {
    gfx: Rc<Gfx>,
    cfg: Rc<Config>,
    /// --theme-file, also applied after a settings reload.
    theme_file: Option<String>,
    icon: HICON,
    recording_icon: HICON,
    taskbar_created: u32,
}

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
    static LAST_SAVED: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
}

pub fn hwnd() -> HWND {
    HWND(HOST.load(Ordering::SeqCst) as *mut _)
}

fn load_config(theme_file: Option<&str>) -> (Config, Option<String>) {
    let (mut cfg, error) = config::load();
    if let Some(path) = theme_file {
        cfg.theme_file = path.to_owned();
    }
    (cfg, error)
}

pub fn run(options: Options) -> Result<()> {
    unsafe {
        let instance: HINSTANCE = GetModuleHandleW(None)?.into();
        let gfx = Rc::new(Gfx::new()?);
        let icon = make_icon(&gfx, false).unwrap_or_else(|_| LoadIconW(None, IDI_APPLICATION).unwrap_or_default());
        let recording_icon = make_icon(&gfx, true).unwrap_or(icon);
        let wc = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(wndproc),
            hInstance: instance,
            hIcon: icon,
            lpszClassName: CLASS,
            ..Default::default()
        };
        RegisterClassExW(&wc);
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            CLASS,
            w!("Caelestia capture"),
            WS_OVERLAPPED,
            0,
            0,
            0,
            0,
            None,
            None,
            Some(instance),
            None,
        )?;
        HOST.store(hwnd.0 as isize, Ordering::SeqCst);

        let (cfg, error) = load_config(options.theme_file.as_deref());
        let taskbar_created = RegisterWindowMessageW(w!("TaskbarCreated"));
        APP.with_borrow_mut(|app| {
            *app = Some(App {
                gfx,
                cfg: Rc::new(cfg.clone()),
                theme_file: options.theme_file.clone(),
                icon,
                recording_icon,
                taskbar_created,
            });
        });
        control::start(hwnd)?;
        control::directory(&cfg);
        add_tray(hwnd, icon);
        if let Some(error) = error {
            notify("Caelestia capture settings were not loaded", &error, None, true);
        }
        if let Some(command) = options.command {
            if let Err(e) = control(command) {
                control::error(e.clone());
                notify("Caelestia capture control failed", &e, None, true);
            }
        }

        let mut msg = MSG::default();
        while !EXITING.load(Ordering::SeqCst) && GetMessageW(&mut msg, None, 0, 0).0 > 0 {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        remove_tray(hwnd);
        crate::recording::shutdown();
        crate::thumbnail::shutdown();
        let _ = DestroyWindow(hwnd);
        APP.with_borrow_mut(|app| {
            if let Some(app) = app.take() {
                let _ = DestroyIcon(app.icon);
                if app.recording_icon != app.icon {
                    let _ = DestroyIcon(app.recording_icon);
                }
            }
        });
        Ok(())
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    unsafe {
        match msg {
            WM_APP_RECORDING_CHANGED => update_recording_tray(),
            control::WM_CONTROL => control::dispatch(),
            WM_APP_ALREADY_RUNNING => notify("Caelestia capture is running", "Use the Caelestia launcher or shortcuts to capture.", None, false),
            WM_APP_TRAY => match (lp.0 & 0xffff) as u32 {
                WM_CONTEXTMENU | WM_RBUTTONUP => show_menu(hwnd),
                NIN_BALLOONUSERCLICK => {
                    if let Some(path) = LAST_SAVED.with_borrow(|p| p.clone()) {
                        reveal(&path);
                    }
                }
                _ => {}
            },
            WM_DESTROY => {
                EXITING.store(true, Ordering::SeqCst);
                PostQuitMessage(0);
            }
            _ => {
                let created = APP.with_borrow(|a| a.as_ref().map(|a| (a.taskbar_created, a.icon)));
                if let Some((id, icon)) = created {
                    if msg == id && id != 0 {
                        add_tray(hwnd, icon);
                        recording_changed();
                    }
                }
                return DefWindowProcW(hwnd, msg, wp, lp);
            }
        }
        LRESULT(0)
    }
}

/// Public recorder commands are explicit actions.
pub fn control(command: Command) -> std::result::Result<(), String> {
    if !control::accepts(control::phase(), &command) {
        return Err(format!("Command is not valid while {:?}", control::phase()));
    }
    match command {
        Command::Status => {}
        Command::Stop => crate::recording::stop(),
        Command::Pause => crate::recording::pause(true),
        Command::Resume => crate::recording::pause(false),
        Command::Discard => crate::recording::discard(),
        Command::Audio { system_sound, mic } => crate::recording::audio(system_sound, mic),
        Command::Record { fullscreen, system_sound, mic, region, ui } => {
            let region = control::recording_target(fullscreen, region)?;
            let (gfx, cfg) = APP.with_borrow(|a| a.as_ref().map(|a| (a.gfx.clone(), a.cfg.clone())))
                .ok_or("Caelestia capture is not running")?;
            if crate::recording::exists() {
                return Err("Caelestia capture is busy".into());
            }
            gfx.reload_theme(&cfg.theme_file);
            crate::thumbnail::reload_theme(&gfx);
            crate::recording::record_region(gfx, cfg, region, system_sound, mic, ui)
                .map_err(|e| e.message().to_string())?;
        }
    }
    Ok(())
}

pub fn recording_changed() {
    unsafe {
        let _ = PostMessageW(Some(hwnd()), WM_APP_RECORDING_CHANGED, WPARAM(0), LPARAM(0));
    }
}

fn update_recording_tray() {
    let recording = crate::recording::running();
    let mut data = tray_data(hwnd());
    data.uFlags = NIF_TIP | NIF_ICON;
    fill(&mut data.szTip, if recording { "Caelestia capture - Recording" } else { "Caelestia capture" });
    data.hIcon = APP.with_borrow(|a| a.as_ref().map(|a| if recording { a.recording_icon } else { a.icon })).unwrap_or_default();
    unsafe {
        let _ = Shell_NotifyIconW(NIM_MODIFY, &data);
    }
}

fn fill(dst: &mut [u16], s: &str) {
    let n = dst.len() - 1;
    for (d, c) in dst.iter_mut().zip(s.encode_utf16().take(n).chain(std::iter::once(0))) {
        *d = c;
    }
}

fn tray_data(hwnd: HWND) -> NOTIFYICONDATAW {
    NOTIFYICONDATAW { cbSize: size_of::<NOTIFYICONDATAW>() as u32, hWnd: hwnd, uID: TRAY_ID, ..Default::default() }
}

fn add_tray(hwnd: HWND, icon: HICON) {
    let mut data = tray_data(hwnd);
    data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
    data.uCallbackMessage = WM_APP_TRAY;
    data.hIcon = icon;
    fill(&mut data.szTip, "Caelestia capture");
    data.Anonymous.uVersion = NOTIFYICON_VERSION_4;
    unsafe {
        let _ = Shell_NotifyIconW(NIM_ADD, &data);
        let _ = Shell_NotifyIconW(NIM_SETVERSION, &data);
    }
}

fn remove_tray(hwnd: HWND) {
    unsafe {
        let _ = Shell_NotifyIconW(NIM_DELETE, &tray_data(hwnd));
    }
}

/// Shows a tray notification. Clicking it reveals `path` when given.
pub fn notify(title: &str, body: &str, path: Option<PathBuf>, error: bool) {
    LAST_SAVED.with_borrow_mut(|p| *p = path);
    let mut data = tray_data(hwnd());
    data.uFlags = NIF_INFO;
    fill(&mut data.szInfoTitle, title);
    fill(&mut data.szInfo, if body.is_empty() { " " } else { body });
    data.dwInfoFlags = if error { NIIF_ERROR } else { NIIF_INFO } | NIIF_NOSOUND;
    unsafe {
        let _ = Shell_NotifyIconW(NIM_MODIFY, &data);
    }
}

pub fn reveal(path: &std::path::Path) {
    let args = HSTRING::from(format!("/select,\"{}\"", path.display()));
    unsafe {
        ShellExecuteW(None, w!("open"), w!("explorer.exe"), &args, PCWSTR::null(), SW_SHOWNORMAL);
    }
}

pub fn open_video(path: &std::path::Path) -> Result<()> {
    unsafe {
        let result =
            ShellExecuteW(None, w!("open"), &HSTRING::from(path.as_os_str()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL);
        if result.0 as isize <= 32 {
            return Err(Error::new(E_FAIL, "Windows could not open the recording in its default player"));
        }
        Ok(())
    }
}

fn open_path(path: &std::path::Path) {
    let target = HSTRING::from(path.as_os_str());
    unsafe {
        let r = ShellExecuteW(None, w!("open"), &target, PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL);
        if r.0 as isize <= 32 {
            ShellExecuteW(None, w!("open"), w!("notepad.exe"), &target, PCWSTR::null(), SW_SHOWNORMAL);
        }
    }
}

fn show_menu(hwnd: HWND) {
    unsafe {
        let Ok(menu) = CreatePopupMenu() else { return };
        if crate::recording::exists() {
            let _ = AppendMenuW(menu, MF_STRING, CMD_RECORD, w!("Stop recording"));
        }
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        let _ = AppendMenuW(menu, MF_STRING, CMD_SETTINGS, w!("Edit settings"));
        let _ = AppendMenuW(menu, MF_STRING, CMD_RELOAD, w!("Reload settings"));
        // Managed by the shell's installation. Never create or modify a
        // separate autostart entry, including a historical Glazier entry.
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        let _ = AppendMenuW(menu, MF_STRING, CMD_EXIT, w!("Exit"));

        let mut pt = POINT::default();
        let _ = GetCursorPos(&mut pt);
        let _ = SetForegroundWindow(hwnd);
        let cmd = TrackPopupMenuEx(menu, (TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON).0, pt.x, pt.y, hwnd, None).0 as usize;
        let _ = DestroyMenu(menu);
        let _ = PostMessageW(Some(hwnd), WM_NULL, WPARAM(0), LPARAM(0));
        match cmd {
            CMD_RECORD => crate::recording::stop(),
            CMD_SETTINGS => {
                let _ = config::load();
                open_path(&config::path());
            }
            CMD_RELOAD => {
                let theme_file = APP.with_borrow(|a| a.as_ref().and_then(|a| a.theme_file.clone()));
                let (cfg, error) = load_config(theme_file.as_deref());
                control::directory(&cfg);
                crate::thumbnail::reload(&cfg);
                APP.with_borrow_mut(|a| {
                    if let Some(a) = a {
                        a.cfg = Rc::new(cfg);
                    }
                });
                if let Some(error) = error {
                    notify("Caelestia capture settings were not loaded", &error, None, true);
                }
            }
            CMD_EXIT => {
                // COM can dispatch the menu inside an export or render. Let
                // that live borrow finish before destroying any app windows.
                EXITING.store(true, Ordering::SeqCst);
                let _ = PostMessageW(Some(hwnd), WM_NULL, WPARAM(0), LPARAM(0));
            }
            _ => {}
        }
    }
}

/// Renders the app icon: the pink rounded square with a white "G".
fn make_icon(gfx: &Gfx, recording: bool) -> Result<HICON> {
    unsafe {
        let size = GetSystemMetrics(SM_CXSMICON).max(16) as u32;
        let target = gfx.wic.CreateBitmap(size, size, &GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad)?;
        let rt = gfx.d2d.CreateWicBitmapRenderTarget(&target, &crate::export::target_props())?;
        let brush = rt.CreateSolidColorBrush(&crate::theme::rgb(if recording { 0xdc2626 } else { 0xdb2777 }), None)?;
        let s = size as f32;
        let font = gfx.text_format(s * 0.62, DWRITE_FONT_WEIGHT_SEMI_BOLD, true)?;
        rt.BeginDraw();
        rt.Clear(Some(&D2D1_COLOR_F::default()));
        let r = crate::gfx::rect(0.0, 0.0, s, s);
        rt.FillRoundedRectangle(&D2D1_ROUNDED_RECT { rect: r, radiusX: s * 0.22, radiusY: s * 0.22 }, &brush);
        brush.SetColor(&crate::theme::WHITE);
        rt.DrawText(
            &crate::gfx::wide(if recording { "R" } else { "G" }),
            &font,
            &crate::gfx::rect(0.0, -s * 0.03, s, s),
            &brush,
            D2D1_DRAW_TEXT_OPTIONS_NONE,
            DWRITE_MEASURING_MODE_NATURAL,
        );
        rt.EndDraw(None, None)?;
        let mut pixels = vec![0u8; (size * size * 4) as usize];
        target.CopyPixels(std::ptr::null(), size * 4, &mut pixels)?;
        // Icons take straight alpha.
        for px in pixels.chunks_exact_mut(4) {
            let a = px[3] as u32;
            if a > 0 && a < 255 {
                for c in &mut px[..3] {
                    *c = ((*c as u32 * 255 + a / 2) / a).min(255) as u8;
                }
            }
        }
        let color = CreateBitmap(size as i32, size as i32, 1, 32, Some(pixels.as_ptr().cast()));
        let mask_bits = vec![0u8; (size.div_ceil(16) * 2 * size) as usize];
        let mask = CreateBitmap(size as i32, size as i32, 1, 1, Some(mask_bits.as_ptr().cast()));
        let info = ICONINFO { fIcon: TRUE, hbmMask: mask, hbmColor: color, ..Default::default() };
        let icon = CreateIconIndirect(&info);
        let _ = DeleteObject(color.into());
        let _ = DeleteObject(mask.into());
        icon
    }
}
