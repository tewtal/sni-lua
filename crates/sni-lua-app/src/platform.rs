//! Platform window tweaks for transparent-overlay mode.
//!
//! eframe/winit gives us a transparent, borderless, always-on-top window, but
//! not *click-through* — mouse events still hit our window instead of the
//! capture software behind it. On Windows that requires the extended window
//! styles `WS_EX_LAYERED | WS_EX_TRANSPARENT` on the HWND, which we apply
//! directly via the raw window handle.
//!
//! Non-Windows builds get a no-op (documented limitation; the app still works
//! in composited mode everywhere).

use raw_window_handle::{HasWindowHandle, RawWindowHandle};

/// Make `window` click-through (input passes to whatever is behind it).
/// Returns whether it was applied, so the UI can report honestly.
pub fn set_click_through(window: &dyn HasWindowHandle, enabled: bool) -> bool {
    #[cfg(windows)]
    {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::{
            GetWindowLongPtrW, SetWindowLongPtrW, GWL_EXSTYLE, WS_EX_LAYERED, WS_EX_TRANSPARENT,
        };

        let Ok(handle) = window.window_handle() else {
            return false;
        };
        let RawWindowHandle::Win32(h) = handle.as_raw() else {
            return false;
        };
        let hwnd = HWND(h.hwnd.get() as *mut _);
        unsafe {
            let mut ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32;
            if enabled {
                ex |= WS_EX_LAYERED.0 | WS_EX_TRANSPARENT.0;
            } else {
                ex &= !WS_EX_TRANSPARENT.0;
            }
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex as isize);
        }
        true
    }
    #[cfg(not(windows))]
    {
        let _ = (window, enabled);
        false
    }
}
