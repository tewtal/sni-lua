//! Painter: turns a [`DrawList`] (SNES pixel coords) into egui shapes inside
//! a target viewport.
//!
//! The transform is the important part. Scripts address pixels in SNES space
//! (0..256 × 0..224); the renderer maps that onto wherever the capture frame
//! is on screen so a hitbox drawn at `(sx, sy)` lands exactly on the game's
//! pixels. Scaling is uniform and letterboxed; text uses the embedded bitmap
//! font drawn as nearest-neighbour quads so it stays crisp at any zoom.

use egui::{Color32, Painter, Pos2, Rect, Stroke, Vec2};

use crate::font::Font;
use crate::{Canvas, Color, DrawCmd, DrawList};

/// How overlay text is sized. The "too big" complaint comes from text being
/// `viewport_scale × font_scale` tall; this gives the user/script control.
#[derive(Debug, Clone, Copy)]
pub enum TextSizing {
    /// One font-pixel == `mult` SNES pixels, then scaled with the viewport.
    /// Text stays aligned to game pixels and zooms with the window. This is
    /// the retro-authentic mode. `mult` defaults to 1.0.
    GameScaled { mult: f32 },
    /// One font-pixel == `px` actual screen pixels, independent of viewport
    /// zoom. Text is the same readable size regardless of window size.
    FixedScreen { px: f32 },
}

impl Default for TextSizing {
    fn default() -> Self {
        // Compact-friendly default; with the 5x7 font this is much smaller
        // than the old fixed 8x8 @ full viewport scale.
        TextSizing::GameScaled { mult: 1.0 }
    }
}

fn col(c: Color) -> Color32 {
    Color32::from_rgba_unmultiplied(c.r, c.g, c.b, c.a)
}

/// Maps the active script canvas onto a screen rect: uniform scale, centred,
/// letterboxed. Build one per frame from the area the capture occupies.
///
/// Decoupling the canvas (script coord space) from this fit means a script
/// drawing in 512x448 lands in exactly the same on-screen place as one
/// drawing in 256x224 — only the precision differs.
#[derive(Clone, Copy)]
pub struct Viewport {
    origin: Pos2,
    /// Screen pixels per canvas pixel.
    scale: f32,
    canvas: Canvas,
}

impl Viewport {
    /// Fit `canvas` inside `area`, preserving aspect ratio.
    pub fn fit(area: Rect, canvas: Canvas) -> Self {
        let scale =
            (area.width() / canvas.w).min(area.height() / canvas.h);
        let w = canvas.w * scale;
        let h = canvas.h * scale;
        let origin = Pos2::new(
            area.center().x - w * 0.5,
            area.center().y - h * 0.5,
        );
        Self {
            origin,
            scale,
            canvas,
        }
    }

    /// Back-compat: fit the native SNES canvas. Prefer [`Viewport::fit`].
    pub fn fit_native(area: Rect) -> Self {
        Self::fit(area, Canvas::native())
    }

    /// The screen rect the canvas actually occupies (for a border /
    /// background fill behind the overlay).
    pub fn screen_rect(&self) -> Rect {
        Rect::from_min_size(
            self.origin,
            Vec2::new(self.canvas.w * self.scale, self.canvas.h * self.scale),
        )
    }

    pub fn canvas(&self) -> Canvas {
        self.canvas
    }

    #[inline]
    fn pt(&self, x: f32, y: f32) -> Pos2 {
        Pos2::new(self.origin.x + x * self.scale, self.origin.y + y * self.scale)
    }

    #[inline]
    fn len(&self, v: f32) -> f32 {
        v * self.scale
    }
}

/// Paint every command in `list` into `painter` using `vp`. `sizing` is the
/// app-wide text sizing mode/scale; per-label `scale` multiplies on top.
/// Call inside the egui paint pass for the panel hosting the capture frame.
pub fn paint(
    painter: &Painter,
    vp: &Viewport,
    list: &DrawList,
    sizing: TextSizing,
) {
    for cmd in &list.cmds {
        match cmd {
            DrawCmd::Text {
                x,
                y,
                text,
                color,
                scale,
                font,
            } => paint_text(
                painter, vp, *x, *y, text, *color, *scale, *font, sizing,
            ),

            DrawCmd::Rect {
                x,
                y,
                w,
                h,
                color,
                fill,
                thickness,
            } => {
                let r = Rect::from_min_size(
                    vp.pt(*x, *y),
                    Vec2::new(vp.len(*w), vp.len(*h)),
                );
                if let Some(f) = fill {
                    painter.rect_filled(r, 0.0, col(*f));
                }
                painter.rect_stroke(
                    r,
                    0.0,
                    Stroke::new(vp.len(*thickness).max(1.0), col(*color)),
                );
            }

            DrawCmd::Line {
                x1,
                y1,
                x2,
                y2,
                color,
                thickness,
            } => {
                painter.line_segment(
                    [vp.pt(*x1, *y1), vp.pt(*x2, *y2)],
                    Stroke::new(vp.len(*thickness).max(1.0), col(*color)),
                );
            }

            DrawCmd::Pixel { x, y, color } => {
                // One SNES pixel = one scaled quad, so it stays visible when
                // zoomed up over the capture.
                let r = Rect::from_min_size(
                    vp.pt(*x, *y),
                    Vec2::splat(vp.scale.max(1.0)),
                );
                painter.rect_filled(r, 0.0, col(*color));
            }
        }
    }
}

/// Draw `text` with the selected bitmap `font`. Each set bit becomes a
/// nearest-neighbour quad so text is crisp at any zoom (never blurred like a
/// vector font over a pixel-art capture). `\n` starts a new line at the
/// original x. Screen-space pixel size is decided by `sizing`.
#[allow(clippy::too_many_arguments)]
fn paint_text(
    painter: &Painter,
    vp: &Viewport,
    x: f32,
    y: f32,
    text: &str,
    color: Color,
    label_scale: f32,
    font: Font,
    sizing: TextSizing,
) {
    let c = col(color);

    // Screen-space size of one font pixel, per the global sizing mode, with
    // the per-label multiplier on top. This single value is the whole fix
    // for "text too big": FixedScreen ignores viewport zoom; GameScaled.mult
    // and label_scale shrink it.
    //
    // In GameScaled mode we size relative to a *SNES* pixel, not a canvas
    // pixel, so a HUD looks identical whether the script draws in a 256 or
    // 512 canvas — only its positioning precision differs. (screen px per
    // SNES px = vp.scale / snes_ratio = vp.scale * canvas.w / 256.)
    let snes_px = vp.scale / vp.canvas().snes_ratio();
    let px = match sizing {
        TextSizing::GameScaled { mult } => snes_px * mult * label_scale,
        TextSizing::FixedScreen { px } => px * label_scale,
    }
    .max(1.0);

    let origin = vp.pt(x, y);
    let mut pen_x = origin.x;
    let mut pen_y = origin.y;
    let advance = font.advance() as f32 * px;
    let line_advance = font.line_advance() as f32 * px;

    for ch in text.chars() {
        if ch == '\n' {
            pen_x = origin.x;
            pen_y += line_advance;
            continue;
        }
        let g = font.glyph(ch);
        for (row, bits) in g.iter().enumerate() {
            if *bits == 0 {
                continue;
            }
            for bit in 0..font.width() {
                // bit 0 is leftmost pixel (LSB-first, both font tables).
                if bits & (1 << bit) != 0 {
                    let rx = pen_x + bit as f32 * px;
                    let ry = pen_y + row as f32 * px;
                    painter.rect_filled(
                        Rect::from_min_size(
                            Pos2::new(rx, ry),
                            Vec2::splat(px),
                        ),
                        0.0,
                        c,
                    );
                }
            }
        }
        pen_x += advance;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn viewport_fits_and_centres() {
        // A 1024x448 area: native 256x224 scales by min(4, 2) = 2.
        let area = Rect::from_min_size(Pos2::ZERO, Vec2::new(1024.0, 448.0));
        let vp = Viewport::fit(area, Canvas::native());
        let r = vp.screen_rect();
        assert_eq!(r.width(), 512.0); // 256 * 2
        assert_eq!(r.height(), 448.0); // 224 * 2
        assert_eq!(r.min.x, 256.0); // (1024 - 512) / 2
        assert_eq!(r.min.y, 0.0);
    }

    #[test]
    fn canvas_origin_maps_to_viewport_origin() {
        let area =
            Rect::from_min_size(Pos2::new(10.0, 20.0), Vec2::splat(512.0));
        let vp = Viewport::fit(area, Canvas::native());
        assert_eq!(vp.pt(0.0, 0.0), vp.screen_rect().min);
    }

    #[test]
    fn higher_res_canvas_occupies_same_screen_area() {
        // The whole point of decoupling: a 2x canvas must land in exactly
        // the same on-screen rect as native — only precision differs.
        let area = Rect::from_min_size(Pos2::ZERO, Vec2::new(1024.0, 448.0));
        let native = Viewport::fit(area, Canvas::native());
        let hi = Viewport::fit(area, Canvas::scaled(2));
        assert_eq!(native.screen_rect(), hi.screen_rect());
        // Canvas centre maps to the same screen point in both.
        assert_eq!(native.pt(128.0, 112.0), hi.pt(256.0, 224.0));
    }

    #[test]
    fn scaled_canvas_is_clamped() {
        assert_eq!(Canvas::scaled(0).w, super::super::SNES_W); // min 1x
        assert_eq!(Canvas::scaled(9999).w, super::super::SNES_W * 8.0);
    }
}
