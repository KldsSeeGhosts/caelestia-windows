//! Event-driven topmost repair for the capture UI, on the host's UI thread.

use std::cell::Cell;
use windows::Win32::Foundation::*;
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::*;

pub const WM_REPAIR: u32 = WM_APP + 8;

thread_local! {
    static TARGET: Cell<HWND> = const { Cell::new(HWND(std::ptr::null_mut())) };
    static PENDING: Cell<bool> = const { Cell::new(false) };
}

pub struct Guard(Vec<HWINEVENTHOOK>);

impl Guard {
    pub fn start(target: HWND) -> Result<Self> {
        let mut guard = Self(Vec::new());
        // Do not skip our process: capture creation/show and our own reorder
        // events must also be reconciled. OUTOFCONTEXT delivers on this thread.
        for event in [EVENT_OBJECT_REORDER, EVENT_OBJECT_SHOW, EVENT_OBJECT_LOCATIONCHANGE] {
            let hook = unsafe { SetWinEventHook(event, event, None, Some(changed), 0, 0, WINEVENT_OUTOFCONTEXT) };
            if hook.is_invalid() {
                return Err(Error::from_thread());
            }
            guard.0.push(hook);
        }
        TARGET.set(target);
        Ok(guard)
    }
}

impl Drop for Guard {
    fn drop(&mut self) {
        TARGET.set(HWND::default());
        PENDING.set(false);
        for hook in &self.0 {
            unsafe {
                let _ = UnhookWinEvent(*hook);
            }
        }
    }
}

unsafe extern "system" fn changed(_: HWINEVENTHOOK, event: u32, hwnd: HWND, object: i32, child: i32, _: u32, _: u32) {
    unsafe {
        let desktop_reorder = event == EVENT_OBJECT_REORDER && hwnd == GetDesktopWindow();
        if !desktop_reorder
            && (object != OBJID_WINDOW.0 || child != CHILDID_SELF as i32 || GetAncestor(hwnd, GA_ROOT) != hwnd)
        {
            return;
        }
        let target = TARGET.get();
        if !target.is_invalid() && !PENDING.replace(true) {
            // Never restack inside a callback or a capture state's live borrow.
            if PostMessageW(Some(target), WM_REPAIR, WPARAM(0), LPARAM(0)).is_err() {
                PENDING.set(false);
            }
        }
    }
}

unsafe extern "system" fn collect_capture(hwnd: HWND, data: LPARAM) -> BOOL {
    unsafe {
        if IsWindowVisible(hwnd).as_bool() {
            let mut class = [0u16; 64];
            let len = GetClassNameW(hwnd, &mut class) as usize;
            if ["GlazierOverlay", "GlazierThumbnail", "GlazierRecording", "GlazierRecordingBorder"]
                .iter()
                .any(|name| class[..len].iter().copied().eq(name.encode_utf16()))
            {
                (*(data.0 as *mut Vec<HWND>)).push(hwnd);
            }
        }
        TRUE
    }
}

#[derive(Clone, Copy)]
struct Window {
    hwnd: HWND,
    rect: RECT,
    capture: bool,
}

struct Snapshot {
    captures: Vec<HWND>,
    windows: Vec<Window>,
}

unsafe extern "system" fn collect_window(hwnd: HWND, data: LPARAM) -> BOOL {
    unsafe {
        let snapshot = &mut *(data.0 as *mut Snapshot);
        let mut rect = RECT::default();
        let capture = snapshot.captures.contains(&hwnd);
        // Leave our other UI alone, including owned menus/dialogs which Windows
        // may require to stay above their owner. All capture UI uses this thread.
        let foreign = GetWindowThreadProcessId(hwnd, None) != GetCurrentThreadId();
        if (capture || foreign)
            && IsWindowVisible(hwnd).as_bool()
            && !IsIconic(hwnd).as_bool()
            && GetWindowRect(hwnd, &mut rect).is_ok()
        {
            snapshot.windows.push(Window { hwnd, rect, capture });
        }
        TRUE
    }
}

fn overlaps(a: RECT, b: RECT) -> bool {
    a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
}

// Input is top to bottom. Preserve capture-to-capture order, including when
// recording controls, a thumbnail and a screenshot overlay coexist.
fn raise_order(windows: &[Window]) -> Vec<HWND> {
    let blocked = windows.iter().enumerate().any(|(index, window)| {
        window.capture && windows[..index].iter().any(|above| !above.capture && overlaps(above.rect, window.rect))
    });
    if !blocked {
        return Vec::new();
    }
    windows.iter().rev().filter(|window| window.capture).map(|window| window.hwnd).collect()
}

pub fn repair() -> usize {
    PENDING.set(false);
    unsafe {
        let mut snapshot = Snapshot { captures: Vec::new(), windows: Vec::new() };
        let _ = EnumThreadWindows(
            GetCurrentThreadId(),
            Some(collect_capture),
            LPARAM((&mut snapshot.captures as *mut Vec<HWND>) as isize),
        );
        if snapshot.captures.is_empty() {
            return 0;
        }
        if EnumWindows(Some(collect_window), LPARAM((&mut snapshot as *mut Snapshot) as isize)).is_err() {
            return 0;
        }
        let order = raise_order(&snapshot.windows);
        // A panel repair caused by another foreign topmost window can put the
        // panel above capture again. Raise the capture group bottom to top once.
        // Caelestia recognizes these classes as shell surfaces and will not
        // counter-raise over them. Our next event sees no foreign overlap above
        // the group, so it does nothing. Capture windows never count as blockers
        // for each other, and their relative order is unchanged, so they cannot
        // ping-pong. No timer, foreground request or activation is involved.
        for hwnd in &order {
            let _ = SetWindowPos(
                *hwnd,
                Some(HWND_TOPMOST),
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
            );
        }
        order.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn window(id: usize, capture: bool, x: i32) -> Window {
        Window { hwnd: HWND(id as *mut _), rect: RECT { left: x, top: 0, right: x + 100, bottom: 100 }, capture }
    }

    #[test]
    fn foreign_repair_preserves_capture_order_and_settles() {
        let panel = window(1, false, 0);
        let overlay = window(2, true, 0);
        let controls = window(3, true, 0);
        let border = window(4, true, 0);
        let thumbnail = window(5, true, 0);
        let group = [overlay, controls, border, thumbnail];
        assert_eq!(
            raise_order(&[panel, overlay, controls, border, thumbnail]),
            vec![thumbnail.hwnd, border.hwnd, controls.hwnd, overlay.hwnd]
        );
        let settled = [overlay, controls, border, thumbnail, panel];
        assert!(raise_order(&settled).is_empty());
        assert!(raise_order(&group).is_empty(), "capture windows must not raise each other");
        assert_eq!(raise_order(&[overlay, panel, controls]), vec![controls.hwnd, overlay.hwnd]);
    }

    #[test]
    fn unrelated_windows_do_not_trigger_a_raise() {
        let capture = window(1, true, 0);
        assert!(raise_order(&[window(2, false, 100), capture]).is_empty(), "touching edges do not overlap");
        assert!(raise_order(&[capture, window(2, false, 0)]).is_empty(), "a window below cannot block capture");
        assert!(raise_order(&[window(2, false, 0)]).is_empty());
    }
}
