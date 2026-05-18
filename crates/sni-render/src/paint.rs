//! Painter: turns a [`DrawList`] (SNES pixel coords) into egui shapes inside
//! a target viewport.
//!
//! The transform is the important part. Scripts address pixels in SNES space
//! (0..256 × 0..224); the renderer maps that onto wherever the capture frame
//! is on screen so a hitbox drawn at `(sx, sy)` lands exactly on the game's
//! pixels. Scaling is uniform and letterboxed; text uses the embedded bitmap
//! font drawn as nearest-neighbour quads so it stays crisp at any zoom.

use egui::{Color32, Painter, Pos2, Rect, Stroke, Vec2};

use crate::font::{glyph, ADVANCE, GLYPH_H, GLYPH_W};
use crate::{Color, DrawCmd, DrawList, SNES_H, SNES_W};

fn col(c: Color) -> Color32 {
    Color32::from_rgba_unmultiplied(c.r, c.g, c.b, c.a)
}

/// Maps SNES pixel space onto a screen rect: uniform scale, centred,
/// letterboxed. Build one per frame from the viewport the capture occupies.
#[derive(Clone, Copy)]
pub struct Viewport {
    origin: Pos2,
    scale: f32,
}

impl Viewport {
    /// Fit the 256x224 SNES surface inside `area` (the rect the capture frame
    /// is drawn in), preserving aspect ratio.
    pub fn fit(area: Rect) -> Self {
        let scale = (area.width() / SNES_W).min(area.height() / SNES_H);
        let w = SNES_W * scale;
        let h = SNES_H * scale;
        let origin = Pos2::new(
            area.center().x - w * 0.5,
            area.center().y - h * 0.5,
        );
        Self { origin, scale }
    }

    /// The screen rect the SNES surface actually occupies (for a border /
    /// background fill behind the overlay).
    pub fn screen_rect(&self) -> Rect {
        Rect::from_min_size(
            self.origin,
            Vec2::new(SNES_W * self.scale, SNES_H * self.scale),
        )
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

/// Paint every command in `list` into `painter` using `vp`. Call inside the
/// egui paint pass for the panel that hosts the capture frame.
pub fn paint(painter: &Painter, vp: &Viewport, list: &DrawList) {
    for cmd in &list.cmds {
        match cmd {
            DrawCmd::Text {
                x,
                y,
                text,
                color,
                scale,
            } => paint_text(painter, vp, *x, *y, text, *color, *scale),

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

/// Draw `text` with the embedded 8x8 bitmap font. Each set bit becomes a
/// filled quad of `vp.scale * font_scale` so it's nearest-neighbour crisp,
/// never blurred like a vector font would be over a pixel-art capture.
fn paint_text(
    painter: &Painter,
    vp: &Viewport,
    x: f32,
    y: f32,
    text: &str,
    color: Color,
    font_scale: f32,
) {
    let c = col(color);
    // Size of one font pixel in screen space.
    let px = (vp.scale * font_scale).max(1.0);
    let mut pen_x = vp.pt(x, y).x;
    let pen_y = vp.pt(x, y).y;

    for ch in text.chars() {
        if ch == '\n' {
            // Caller-controlled newlines: simple wrap to start x, next row.
            pen_x = vp.pt(x, y).x;
            // (single-line is the common case; multi-line scripts can offset
            // y themselves — kept minimal on purpose)
            continue;
        }
        let g = glyph(ch);
        for (row, bits) in g.iter().enumerate() {
            if *bits == 0 {
                continue;
            }
            for bit in 0..GLYPH_W {
                // bit 0 is leftmost pixel (LSB-first in this font table).
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
        pen_x += ADVANCE as f32 * px;
        let _ = GLYPH_H;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn viewport_fits_and_centres() {
        // A 1024x448 area: SNES 256x224 scales by min(4, 2) = 2.
        let area = Rect::from_min_size(Pos2::ZERO, Vec2::new(1024.0, 448.0));
        let vp = Viewport::fit(area);
        let r = vp.screen_rect();
        assert_eq!(r.width(), 512.0); // 256 * 2
        assert_eq!(r.height(), 448.0); // 224 * 2
        // Centred horizontally: (1024 - 512) / 2 = 256.
        assert_eq!(r.min.x, 256.0);
        assert_eq!(r.min.y, 0.0);
    }

    #[test]
    fn snes_origin_maps_to_viewport_origin() {
        let area = Rect::from_min_size(Pos2::new(10.0, 20.0), Vec2::splat(512.0));
        let vp = Viewport::fit(area);
        // SNES (0,0) must map to the top-left of the fitted surface.
        assert_eq!(vp.pt(0.0, 0.0), vp.screen_rect().min);
    }
}
