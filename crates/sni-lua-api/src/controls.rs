//! Script-declared settings controls.
//!
//! A script calls `ui.checkbox/slider/...` (typically in `on_init`) to declare
//! a small settings panel. The app renders it in a "Script" tab and writes
//! user edits back into a shared value map the script reads with `ui.get(id)`.
//!
//! Design mirrors the rest of the host: single-threaded (`Rc<RefCell>`, lives
//! on the UI thread), declarative (declared once, not rebuilt per frame), and
//! persistent — every control value is mirrored into the per-script [`Store`]
//! under a reserved key so settings survive a reload/restart with no extra
//! script code.

use std::cell::RefCell;
use std::rc::Rc;

/// Reserved store key holding the `{ id = value }` map of control values.
/// Namespaced so it can't collide with a script's own `store.set` keys.
pub const STORE_KEY: &str = "__ui_controls";

/// One declared control. `value` is the live, user-editable state; the app
/// mutates it in place when the widget changes and the script reads it via
/// `ui.get`. Variants map 1:1 to an egui widget.
#[derive(Debug, Clone)]
pub enum Control {
    /// A non-interactive section heading, for grouping.
    Header { text: String },
    /// Free-standing explanatory text (rendered small/weak).
    Label { text: String },
    Checkbox {
        id: String,
        label: String,
        value: bool,
    },
    /// Integer-or-float slider. `step` 1.0 with whole bounds reads as an int.
    Slider {
        id: String,
        label: String,
        min: f64,
        max: f64,
        value: f64,
    },
    /// Single-line text field.
    Text {
        id: String,
        label: String,
        value: String,
    },
    /// Packed `0xAARRGGBB`, edited with an egui color picker.
    Color {
        id: String,
        label: String,
        value: u32,
    },
    /// One-of choice. `value` is the selected index into `options`.
    Select {
        id: String,
        label: String,
        options: Vec<String>,
        value: usize,
    },
    /// Momentary action. `pressed` latches true for exactly one
    /// `ScriptHost::take_button` drain (the script's `on_frame` polls it via
    /// `ui.pressed(id)`), so a click is delivered once and only once.
    Button {
        id: String,
        label: String,
        pressed: bool,
    },
}

impl Control {
    /// The control's id, or `None` for layout-only items (header/label).
    pub fn id(&self) -> Option<&str> {
        match self {
            Control::Header { .. } | Control::Label { .. } => None,
            Control::Checkbox { id, .. }
            | Control::Slider { id, .. }
            | Control::Text { id, .. }
            | Control::Color { id, .. }
            | Control::Select { id, .. }
            | Control::Button { id, .. } => Some(id),
        }
    }
}

/// The script's declared panel: an ordered list of controls. Shared
/// `Rc<RefCell>` so Lua closures can append during `on_init` and the app can
/// iterate/mutate it while rendering.
#[derive(Default)]
pub struct Controls {
    pub items: Vec<Control>,
}

pub type SharedControls = Rc<RefCell<Controls>>;

impl Controls {
    pub fn shared() -> SharedControls {
        Rc::new(RefCell::new(Controls::default()))
    }

    pub fn is_empty(&self) -> bool {
        // Layout-only items don't count: a script that only printed a header
        // hasn't really declared a settings panel worth a tab.
        !self.items.iter().any(|c| c.id().is_some())
    }

    /// Find the control with this id (interactive controls only).
    pub fn get(&self, id: &str) -> Option<&Control> {
        self.items.iter().find(|c| c.id() == Some(id))
    }
}
