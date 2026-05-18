//! Retained draw-list + overlay painter.
//!
//! Scripts don't paint directly. Each frame they emit [`DrawCmd`]s into a
//! [`DrawList`]; the egui paint pass consumes the latest list via [`paint`],
//! mapping SNES pixel coords onto the capture viewport with [`Viewport`].
//! This decoupling lets script execution and screen refresh run at different
//! rates without tearing.

mod font;
mod paint;

pub use font::Font;
pub use paint::{paint, TextSizing, Viewport};

/// SNES framebuffer is 256x224 (or 256x239). Scripts address pixels in SNES
/// space; the renderer scales to the capture/overlay viewport.
pub const SNES_W: f32 = 256.0;
pub const SNES_H: f32 = 224.0;

#[derive(Debug, Clone, Copy)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Color {
    pub const fn rgba(r: u8, g: u8, b: u8, a: u8) -> Self {
        Self { r, g, b, a }
    }

    /// Parse `0xAARRGGBB` (the convention Mesen/BizHawk script authors expect).
    pub fn from_argb(argb: u32) -> Self {
        Self {
            a: (argb >> 24) as u8,
            r: (argb >> 16) as u8,
            g: (argb >> 8) as u8,
            b: argb as u8,
        }
    }
}

#[derive(Debug, Clone)]
pub enum DrawCmd {
    Text {
        x: f32,
        y: f32,
        text: String,
        color: Color,
        /// Per-label size multiplier on top of the global overlay size.
        /// 1.0 = the font's native pixel size.
        scale: f32,
        /// Typeface for this label (script-selectable via `gfx.font`).
        font: Font,
    },
    Rect {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
        /// `None` = outline only; `Some` = filled with this color.
        fill: Option<Color>,
        thickness: f32,
    },
    Line {
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        color: Color,
        thickness: f32,
    },
    Pixel {
        x: f32,
        y: f32,
        color: Color,
    },
}

/// One frame's worth of draw commands, in SNES pixel coordinates.
#[derive(Debug, Default, Clone)]
pub struct DrawList {
    pub cmds: Vec<DrawCmd>,
}

impl DrawList {
    pub fn clear(&mut self) {
        self.cmds.clear();
    }
    pub fn push(&mut self, cmd: DrawCmd) {
        self.cmds.push(cmd);
    }
}
