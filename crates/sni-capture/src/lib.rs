//! Capture-device background. Two modes (both selectable per the design):
//!
//! * [`CaptureMode::Composited`] — the app grabs the capture feed and draws
//!   the overlay on top inside its own window.
//! * [`CaptureMode::TransparentOverlay`] — the app renders only the overlay in
//!   a transparent, click-through, always-on-top window placed over the user's
//!   own capture software (OBS, etc.).
//!
//! Backend implementation lands in M6; this defines the mode enum the app and
//! config already reference.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureMode {
    Composited,
    TransparentOverlay,
}

impl Default for CaptureMode {
    fn default() -> Self {
        CaptureMode::Composited
    }
}
