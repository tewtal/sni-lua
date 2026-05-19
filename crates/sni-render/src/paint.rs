//! Painter: turns a [`DrawList`] (SNES pixel coords) into egui shapes inside
//! a target viewport.
//!
//! The transform is the important part. Scripts address pixels in SNES space
//! (0..256 × 0..224); the renderer maps that onto wherever the capture frame
//! is on screen so a hitbox drawn at `(sx, sy)` lands exactly on the game's
//! pixels. Scaling is uniform and letterboxed; text uses the embedded bitmap
//! font drawn as nearest-neighbour quads so it stays crisp at any zoom.

use egui::epaint::{Mesh, RectShape, Shadow, Vertex, WHITE_UV};
use egui::{Color32, Painter, Pos2, Rect, Rounding, Shape, Stroke, Vec2};
use geo::{BooleanOps, Coord, LineString, MultiPolygon, Polygon, TriangulateEarcut};

use crate::font::Font;
use crate::{Canvas, Color, DrawCmd, DrawList, PathPrimitive, ShadowSpec, TextAlign, TextVAlign};

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
        TextSizing::GameScaled { mult: 1.0 }
    }
}

fn col(c: Color) -> Color32 {
    Color32::from_rgba_unmultiplied(c.r, c.g, c.b, c.a)
}

/// Maps the active script canvas onto a screen rect: uniform scale, centred,
/// letterboxed. Build one per frame from the area the capture occupies.
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
        let scale = (area.width() / canvas.w).min(area.height() / canvas.h);
        let w = canvas.w * scale;
        let h = canvas.h * scale;
        let origin = Pos2::new(area.center().x - w * 0.5, area.center().y - h * 0.5);
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

    /// The screen rect the canvas actually occupies.
    pub fn screen_rect(&self) -> Rect {
        Rect::from_min_size(
            self.origin,
            Vec2::new(self.canvas.w * self.scale, self.canvas.h * self.scale),
        )
    }

    pub fn canvas(&self) -> Canvas {
        self.canvas
    }

    /// Inverse of [`Self::pt`]: map a screen point back into canvas
    /// coordinates. Returns `None` when the point is outside the canvas rect.
    pub fn screen_to_canvas(&self, p: Pos2) -> Option<(f32, f32)> {
        if self.scale <= 0.0 {
            return None;
        }
        let x = (p.x - self.origin.x) / self.scale;
        let y = (p.y - self.origin.y) / self.scale;
        if x < 0.0 || y < 0.0 || x > self.canvas.w || y > self.canvas.h {
            return None;
        }
        Some((x, y))
    }

    #[inline]
    fn pt(&self, x: f32, y: f32) -> Pos2 {
        Pos2::new(
            self.origin.x + x * self.scale,
            self.origin.y + y * self.scale,
        )
    }

    #[inline]
    fn len(&self, v: f32) -> f32 {
        v * self.scale
    }
}

/// Paint every command in `list` into `painter` using `vp`. `sizing` is the
/// app-wide text sizing mode/scale; per-label `scale` multiplies on top.
pub fn paint(painter: &Painter, vp: &Viewport, list: &DrawList, sizing: TextSizing) {
    let painter = &painter.with_clip_rect(vp.screen_rect());
    for cmd in &list.cmds {
        match cmd {
            DrawCmd::Text {
                x,
                y,
                text,
                color,
                scale,
                font,
                bg,
                outline,
                align,
                valign,
            } => paint_text(
                painter, vp, *x, *y, text, *color, *scale, *font, sizing, *bg, *outline, *align,
                *valign,
            ),

            DrawCmd::Rect {
                x,
                y,
                w,
                h,
                color,
                fill,
                thickness,
                shadow,
            } => {
                let rect = Rect::from_min_size(vp.pt(*x, *y), Vec2::new(vp.len(*w), vp.len(*h)));
                paint_rect_shape(painter, rect, 0.0, *fill, *color, *thickness, *shadow, vp);
            }

            DrawCmd::RoundRect {
                x,
                y,
                w,
                h,
                radius,
                color,
                fill,
                thickness,
                shadow,
            } => {
                let rect = Rect::from_min_size(vp.pt(*x, *y), Vec2::new(vp.len(*w), vp.len(*h)));
                paint_rect_shape(
                    painter,
                    rect,
                    vp.len(*radius),
                    *fill,
                    *color,
                    *thickness,
                    *shadow,
                    vp,
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
                let r = Rect::from_min_size(vp.pt(*x, *y), Vec2::splat(vp.scale.max(1.0)));
                painter.rect_filled(r, 0.0, col(*color));
            }

            DrawCmd::Circle {
                x,
                y,
                radius,
                color,
                fill,
                thickness,
            } => {
                let c = vp.pt(*x, *y);
                let r = vp.len(*radius);
                if let Some(f) = fill {
                    painter.circle_filled(c, r, col(*f));
                }
                painter.circle_stroke(c, r, Stroke::new(vp.len(*thickness).max(1.0), col(*color)));
            }

            DrawCmd::Triangle {
                x1,
                y1,
                x2,
                y2,
                x3,
                y3,
                color,
                fill,
                thickness,
            } => {
                let p = [vp.pt(*x1, *y1), vp.pt(*x2, *y2), vp.pt(*x3, *y3)];
                if let Some(f) = fill {
                    painter.add(Shape::convex_polygon(p.to_vec(), col(*f), Stroke::NONE));
                }
                let s = Stroke::new(vp.len(*thickness).max(1.0), col(*color));
                painter.add(Shape::closed_line(p.to_vec(), s));
            }

            DrawCmd::Poly {
                points,
                closed,
                color,
                fill,
                thickness,
            } => {
                if points.len() < 2 {
                    continue;
                }
                let p: Vec<Pos2> = points.iter().map(|(x, y)| vp.pt(*x, *y)).collect();
                let s = Stroke::new(vp.len(*thickness).max(1.0), col(*color));
                if *closed {
                    if let Some(f) = fill {
                        painter.add(Shape::convex_polygon(p.clone(), col(*f), Stroke::NONE));
                    }
                    painter.add(Shape::closed_line(p, s));
                } else {
                    painter.add(Shape::line(p, s));
                }
            }

            DrawCmd::GradientLine {
                x1,
                y1,
                x2,
                y2,
                start,
                end,
                thickness,
            } => paint_gradient_line(painter, vp, *x1, *y1, *x2, *y2, *start, *end, *thickness),

            DrawCmd::GradientRect {
                x,
                y,
                w,
                h,
                radius,
                start,
                end,
                vertical,
                shadow,
            } => {
                let rect = Rect::from_min_size(vp.pt(*x, *y), Vec2::new(vp.len(*w), vp.len(*h)));
                if let Some(shadow) = shadow {
                    paint_shadow(painter, rect, vp.len(*radius), *shadow, vp);
                }
                let poly = if *radius > 0.0 {
                    round_rect_polygon(*x, *y, *w, *h, *radius)
                } else {
                    rect_polygon(*x, *y, *w, *h)
                };
                if let Some(mesh) = polygon_mesh(vp, &poly, *start, *end, *vertical) {
                    painter.add(Shape::mesh(mesh));
                }
            }

            DrawCmd::Path {
                shapes,
                color,
                fill,
                thickness,
            } => {
                let union = union_shapes(shapes);
                if union.0.is_empty() {
                    continue;
                }
                if let Some(f) = fill {
                    for poly in &union.0 {
                        if let Some(mesh) = polygon_mesh(vp, poly, *f, *f, false) {
                            painter.add(Shape::mesh(mesh));
                        }
                    }
                }
                if let Some(c) = color {
                    let stroke = Stroke::new(vp.len(*thickness).max(1.0), col(*c));
                    for poly in &union.0 {
                        paint_polygon_outline(painter, vp, poly, stroke);
                    }
                }
            }

            DrawCmd::Arc {
                x,
                y,
                radius,
                start_deg,
                end_deg,
                color,
                fill,
                thickness,
            } => {
                let centre = vp.pt(*x, *y);
                let r = vp.len(*radius);
                let sweep = (*end_deg - *start_deg).abs();
                let steps = ((sweep / 6.0).ceil() as usize)
                    .clamp(2, 180)
                    .max((r / 8.0) as usize)
                    .min(360);
                let mut pts: Vec<Pos2> = Vec::with_capacity(steps + 2);
                for i in 0..=steps {
                    let t = i as f32 / steps as f32;
                    let a = (start_deg + (end_deg - start_deg) * t).to_radians();
                    pts.push(Pos2::new(centre.x + r * a.cos(), centre.y + r * a.sin()));
                }
                let s = Stroke::new(vp.len(*thickness).max(1.0), col(*color));
                if let Some(f) = fill {
                    let mut poly = Vec::with_capacity(pts.len() + 1);
                    poly.push(centre);
                    poly.extend_from_slice(&pts);
                    painter.add(Shape::convex_polygon(poly, col(*f), Stroke::NONE));
                }
                painter.add(Shape::line(pts, s));
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn paint_rect_shape(
    painter: &Painter,
    rect: Rect,
    radius: f32,
    fill: Option<Color>,
    color: Color,
    thickness: f32,
    shadow: Option<ShadowSpec>,
    vp: &Viewport,
) {
    if let Some(shadow) = shadow {
        paint_shadow(painter, rect, radius, shadow, vp);
    }
    let shape = RectShape::new(
        rect,
        rounding(radius),
        fill.map(col).unwrap_or(Color32::TRANSPARENT),
        Stroke::new(vp.len(thickness).max(1.0), col(color)),
    );
    painter.add(shape);
}

fn paint_shadow(painter: &Painter, rect: Rect, radius: f32, shadow: ShadowSpec, vp: &Viewport) {
    let shape = Shadow {
        offset: Vec2::new(vp.len(shadow.dx), vp.len(shadow.dy)),
        blur: vp.len(shadow.blur),
        spread: vp.len(shadow.spread),
        color: col(shadow.color),
    }
    .as_shape(rect, rounding(radius));
    painter.add(shape);
}

fn rounding(radius: f32) -> Rounding {
    Rounding::same(radius.max(0.0))
}

#[allow(clippy::too_many_arguments)]
fn paint_gradient_line(
    painter: &Painter,
    vp: &Viewport,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    start: Color,
    end: Color,
    thickness: f32,
) {
    let p1 = vp.pt(x1, y1);
    let p2 = vp.pt(x2, y2);
    let dir = p2 - p1;
    let len = dir.length();
    let th = vp.len(thickness).max(1.0);
    if len <= f32::EPSILON {
        painter.circle_filled(p1, th * 0.5, col(start));
        return;
    }
    let n = Vec2::new(-dir.y, dir.x) * (th * 0.5 / len);
    let mut mesh = Mesh::default();
    let base = mesh.vertices.len() as u32;
    mesh.vertices.push(Vertex {
        pos: p1 + n,
        uv: WHITE_UV,
        color: col(start),
    });
    mesh.vertices.push(Vertex {
        pos: p1 - n,
        uv: WHITE_UV,
        color: col(start),
    });
    mesh.vertices.push(Vertex {
        pos: p2 - n,
        uv: WHITE_UV,
        color: col(end),
    });
    mesh.vertices.push(Vertex {
        pos: p2 + n,
        uv: WHITE_UV,
        color: col(end),
    });
    mesh.indices
        .extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
    painter.add(Shape::mesh(mesh));
}

fn polygon_mesh(
    vp: &Viewport,
    polygon: &Polygon<f32>,
    start: Color,
    end: Color,
    vertical: bool,
) -> Option<Mesh> {
    let raw = polygon.earcut_triangles_raw();
    if raw.vertices.is_empty() || raw.triangle_indices.is_empty() {
        return None;
    }
    let (mut min_x, mut max_x) = (f32::INFINITY, f32::NEG_INFINITY);
    let (mut min_y, mut max_y) = (f32::INFINITY, f32::NEG_INFINITY);
    for [x, y] in &raw.vertices {
        min_x = min_x.min(*x);
        max_x = max_x.max(*x);
        min_y = min_y.min(*y);
        max_y = max_y.max(*y);
    }
    let span = if vertical {
        (max_y - min_y).max(f32::EPSILON)
    } else {
        (max_x - min_x).max(f32::EPSILON)
    };
    let mut mesh = Mesh::default();
    for [x, y] in raw.vertices {
        let t = if vertical {
            ((y - min_y) / span).clamp(0.0, 1.0)
        } else {
            ((x - min_x) / span).clamp(0.0, 1.0)
        };
        mesh.vertices.push(Vertex {
            pos: vp.pt(x, y),
            uv: WHITE_UV,
            color: lerp_color(start, end, t),
        });
    }
    mesh.indices
        .extend(raw.triangle_indices.into_iter().map(|idx| idx as u32));
    Some(mesh)
}

fn lerp_color(a: Color, b: Color, t: f32) -> Color32 {
    let lerp = |lhs: u8, rhs: u8| -> u8 {
        (lhs as f32 + (rhs as f32 - lhs as f32) * t)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    Color32::from_rgba_unmultiplied(
        lerp(a.r, b.r),
        lerp(a.g, b.g),
        lerp(a.b, b.b),
        lerp(a.a, b.a),
    )
}

fn union_shapes(shapes: &[PathPrimitive]) -> MultiPolygon<f32> {
    let mut union: Option<MultiPolygon<f32>> = None;
    for shape in shapes {
        let poly = match shape {
            PathPrimitive::Rect { x, y, w, h } => rect_polygon(*x, *y, *w, *h),
            PathPrimitive::RoundRect { x, y, w, h, radius } => {
                round_rect_polygon(*x, *y, *w, *h, *radius)
            }
            PathPrimitive::Circle { x, y, radius } => circle_polygon(*x, *y, *radius),
        };
        let next = MultiPolygon(vec![poly]);
        union = Some(match union {
            Some(cur) => cur.union(&next),
            None => next,
        });
    }
    union.unwrap_or_else(|| MultiPolygon(vec![]))
}

fn paint_polygon_outline(painter: &Painter, vp: &Viewport, polygon: &Polygon<f32>, stroke: Stroke) {
    let exterior = ring_points(polygon.exterior(), vp);
    if exterior.len() >= 2 {
        painter.add(Shape::closed_line(exterior, stroke));
    }
    for hole in polygon.interiors() {
        let inner = ring_points(hole, vp);
        if inner.len() >= 2 {
            painter.add(Shape::closed_line(inner, stroke));
        }
    }
}

fn ring_points(ring: &LineString<f32>, vp: &Viewport) -> Vec<Pos2> {
    let coords = &ring.0;
    let end = coords.len().saturating_sub(1);
    coords[..end]
        .iter()
        .map(|coord| vp.pt(coord.x, coord.y))
        .collect()
}

fn rect_polygon(x: f32, y: f32, w: f32, h: f32) -> Polygon<f32> {
    Polygon::new(
        LineString(vec![
            Coord { x, y },
            Coord { x: x + w, y },
            Coord { x: x + w, y: y + h },
            Coord { x, y: y + h },
            Coord { x, y },
        ]),
        vec![],
    )
}

fn round_rect_polygon(x: f32, y: f32, w: f32, h: f32, radius: f32) -> Polygon<f32> {
    let r = radius.clamp(0.0, w.abs().min(h.abs()) * 0.5);
    if r <= 0.0 {
        return rect_polygon(x, y, w, h);
    }
    let steps = ((r / 3.0).ceil() as usize).clamp(3, 12);
    let mut pts = Vec::with_capacity(steps * 4 + 5);
    pts.push(Coord { x: x + r, y });
    append_arc(&mut pts, x + w - r, y + r, r, -90.0, 0.0, steps);
    append_arc(&mut pts, x + w - r, y + h - r, r, 0.0, 90.0, steps);
    append_arc(&mut pts, x + r, y + h - r, r, 90.0, 180.0, steps);
    append_arc(&mut pts, x + r, y + r, r, 180.0, 270.0, steps);
    pts.push(pts[0]);
    Polygon::new(LineString(pts), vec![])
}

fn circle_polygon(x: f32, y: f32, radius: f32) -> Polygon<f32> {
    let steps = ((radius.abs() / 3.0).ceil() as usize).clamp(8, 64);
    let mut pts = Vec::with_capacity(steps + 1);
    for i in 0..steps {
        let t = i as f32 / steps as f32;
        let a = t * std::f32::consts::TAU;
        pts.push(Coord {
            x: x + radius * a.cos(),
            y: y + radius * a.sin(),
        });
    }
    pts.push(pts[0]);
    Polygon::new(LineString(pts), vec![])
}

fn append_arc(
    pts: &mut Vec<Coord<f32>>,
    cx: f32,
    cy: f32,
    radius: f32,
    start_deg: f32,
    end_deg: f32,
    steps: usize,
) {
    for i in 0..=steps {
        let t = i as f32 / steps as f32;
        let a = (start_deg + (end_deg - start_deg) * t).to_radians();
        let next = Coord {
            x: cx + radius * a.cos(),
            y: cy + radius * a.sin(),
        };
        if pts.last().copied() != Some(next) {
            pts.push(next);
        }
    }
}

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
    bg: Option<Color>,
    outline: Option<Color>,
    align: TextAlign,
    valign: TextVAlign,
) {
    let c = col(color);
    let snes_px = vp.scale / vp.canvas().snes_ratio();
    let px = match sizing {
        TextSizing::GameScaled { mult } => snes_px * mult * label_scale,
        TextSizing::FixedScreen { px } => px * label_scale,
    }
    .max(1.0);

    let advance = font.advance() as f32 * px;
    let line_advance = font.line_advance() as f32 * px;
    let widest = text
        .split('\n')
        .map(|line| line.chars().count())
        .max()
        .unwrap_or(0) as f32;
    let n_lines = text.split('\n').count().max(1) as f32;
    let text_w = widest * advance;
    let text_h = (n_lines * line_advance).max(line_advance);
    let ax = match align {
        TextAlign::Left => 0.0,
        TextAlign::Center => text_w * 0.5,
        TextAlign::Right => text_w,
    };
    let ay = match valign {
        TextVAlign::Top => 0.0,
        TextVAlign::Middle => text_h * 0.5,
        TextVAlign::Bottom => text_h,
    };
    let origin = vp.pt(x, y) - Vec2::new(ax, ay);

    if let Some(b) = bg {
        if widest > 0.0 {
            let pad = px;
            painter.rect_filled(
                Rect::from_min_size(
                    Pos2::new(origin.x - pad, origin.y - pad),
                    Vec2::new(text_w + 2.0 * pad, text_h + 2.0 * pad),
                ),
                0.0,
                col(b),
            );
        }
    }

    let lay = |painter: &Painter, dx: f32, dy: f32, paint: Color32| {
        let mut pen_x = origin.x + dx;
        let mut pen_y = origin.y + dy;
        for ch in text.chars() {
            if ch == '\n' {
                pen_x = origin.x + dx;
                pen_y += line_advance;
                continue;
            }
            let g = font.glyph(ch);
            for (row, bits) in g.iter().enumerate() {
                if *bits == 0 {
                    continue;
                }
                for bit in 0..font.width() {
                    if bits & (1 << bit) != 0 {
                        let rx = pen_x + bit as f32 * px;
                        let ry = pen_y + row as f32 * px;
                        painter.rect_filled(
                            Rect::from_min_size(Pos2::new(rx, ry), Vec2::splat(px)),
                            0.0,
                            paint,
                        );
                    }
                }
            }
            pen_x += advance;
        }
    };

    if let Some(o) = outline {
        let oc = col(o);
        for (dx, dy) in [
            (-px, -px),
            (0.0, -px),
            (px, -px),
            (-px, 0.0),
            (px, 0.0),
            (-px, px),
            (0.0, px),
            (px, px),
        ] {
            lay(painter, dx, dy, oc);
        }
    }
    lay(painter, 0.0, 0.0, c);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn viewport_fits_and_centres() {
        let area = Rect::from_min_size(Pos2::ZERO, Vec2::new(1024.0, 448.0));
        let vp = Viewport::fit(area, Canvas::native());
        let r = vp.screen_rect();
        assert_eq!(r.width(), 512.0);
        assert_eq!(r.height(), 448.0);
        assert_eq!(r.min.x, 256.0);
        assert_eq!(r.min.y, 0.0);
    }
}
