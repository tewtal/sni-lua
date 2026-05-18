//! sni-lua: Lua overlay scripting for SNES over SNI/USB2SNES.
//!
//! M2 deliverable: the SNI gRPC client wired into the app via a background
//! actor. Connect/disconnect, device listing + selection, memory-mapping
//! detection, and a live read probe that surfaces real bytes + round-trip
//! latency — the number the M3 poll engine exists to hide.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod config;
mod platform;
mod sni_actor;

use std::sync::Arc;

use config::Config;
use eframe::egui;
use sni_actor::{Cmd, CmdSender, ConnState, SniHandle};
use sni_cache::{PollConfig, PollEngine};
use sni_client::MemRegion;
use sni_lua_api::{Console, ScriptHost, WriteSink};
use sni_render::DrawList;
use tokio::runtime::Runtime;

/// Bridges Lua `snes.write(...)` to the SNI actor as a fire-and-forget
/// command. Lives behind `Arc<dyn WriteSink>` in the script host.
struct ActorWriteSink {
    tx: CmdSender,
}
impl WriteSink for ActorWriteSink {
    fn queue_write(&self, region: MemRegion, data: Vec<u8>) {
        self.tx.send(Cmd::Write { region, data });
    }
}


fn capture_settings(config: &Config) -> sni_capture::CaptureSettings {
    sni_capture::CaptureSettings {
        width: config.capture_width,
        height: config.capture_height,
        fps: config.capture_fps,
    }
}

fn main() -> eframe::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "sni_lua=info,warn".into()),
        )
        .init();

    // One multi-thread Tokio runtime for all async SNI work. The egui app
    // never `.await`s on the UI thread; it talks to the SNI actor via channels.
    let rt = Runtime::new().expect("failed to start tokio runtime");
    let _guard = rt.enter();

    // Decide window style up front: transparent-overlay mode needs a
    // borderless, transparent, always-on-top window (click-through is added
    // at the Win32 level once the HWND exists).
    let start_cfg = Config::load();
    let transparent = start_cfg.capture_mode == "transparent";

    let mut vb = egui::ViewportBuilder::default()
        .with_inner_size([960.0, 720.0])
        .with_min_inner_size([640.0, 480.0])
        .with_title("sni-lua — SNES overlay scripting over SNI");
    if transparent {
        vb = vb
            .with_transparent(true)
            .with_decorations(false)
            .with_always_on_top();
    }

    let native_options = eframe::NativeOptions {
        viewport: vb,
        ..Default::default()
    };

    eframe::run_native(
        "sni-lua",
        native_options,
        Box::new(|cc| Ok(Box::new(App::new(cc, rt)))),
    )
}

struct App {
    _rt: Runtime,
    config: Config,
    sni: SniHandle,
    engine: Arc<PollEngine>,
    /// Lua script host. Runs `on_frame` from egui's update loop (UI thread).
    host: ScriptHost,
    console: Arc<Console>,
    /// Latest script-produced draw list (M5 paints it).
    draw_list: DrawList,
    status: String,
    script_path: String,
    show_console: bool,

    // Live memory inspector (M2 demo of real reads + latency).
    probe_addr_hex: String,
    probe_size: u32,

    // Capture (M6). Source runs only in composited mode; transparent mode
    // opens no device and relies on window transparency instead.
    capture: Option<sni_capture::CaptureSource>,
    capture_devices: Vec<sni_capture::DeviceDesc>,
    capture_tex: Option<egui::TextureHandle>,
    /// seq of the frame currently in `capture_tex`, to skip redundant
    /// GPU uploads when the device frame hasn't advanced.
    capture_tex_seq: u64,
    /// Last transparent-overlay window mode pushed to the native viewport.
    window_overlay_applied: Option<bool>,
    /// Last click-through mouse state pushed to the native window.
    click_through_applied: bool,
}

impl App {
    fn new(_cc: &eframe::CreationContext<'_>, rt: Runtime) -> Self {
        let config = Config::load();
        let sni = sni_actor::spawn();

        // Spawn the poll engine. It reads the actor's shared client slot each
        // cycle, so connect / device-switch needs no engine restart.
        let slot = sni.client_slot.clone();
        let engine = sni_cache::spawn(
            move || slot.load_full().as_ref().clone(),
            PollConfig {
                frame_budget_ms: config.frame_budget_ms.max(1),
                demand_window: std::time::Duration::from_millis(
                    config.demand_window_ms.max(50) as u64,
                ),
                ..PollConfig::default()
            }, // (App::poll_config mirrors this; kept inline pre-construction)
        );

        // Lua host: shares the poll engine (for cached reads) and a write
        // sink that forwards `snes.write` to the SNI actor.
        let sink = Arc::new(ActorWriteSink { tx: sni.sender() });
        let host = ScriptHost::with_sink(engine.clone(), sink).expect("LuaJIT init failed");
        let console = host.console();
        // M1 LuaJIT health check, now via the real host.
        let lua_status = match host.eval_number("return 2 ^ 10") {
            Ok(v) => format!("LuaJIT OK (2^10 = {v})"),
            Err(e) => format!("LuaJIT FAILED: {e}"),
        };

        // Enumerate capture devices once at startup (cheap; refreshable from
        // the UI). Open the source only in composited mode.
        let capture_devices = sni_capture::list_devices();
        let capture = if sni_capture::CaptureMode::parse(&config.capture_mode)
            == sni_capture::CaptureMode::Composited
        {
            Some(sni_capture::CaptureSource::open(
                config.capture_device,
                capture_settings(&config),
            ))
        } else {
            None
        };

        let mut app = Self {
            _rt: rt,
            config: config.clone(),
            sni,
            engine,
            host,
            console,
            draw_list: DrawList::default(),
            status: format!("Ready. {lua_status}"),
            script_path: config
                .last_script
                .as_ref()
                .map(|p| p.display().to_string())
                .unwrap_or_default(),
            show_console: true,
            // Super Metroid: WRAM $7E:0AF6 = Samus X position (u16). In the
            // FxPakPro space that's $F5_0AF6.
            probe_addr_hex: "F50AF6".to_string(),
            probe_size: 2,
            capture,
            capture_devices,
            capture_tex: None,
            capture_tex_seq: 0,
            window_overlay_applied: None,
            click_through_applied: false,
        };
        // Auto-load the last script if one was remembered.
        if !app.script_path.is_empty() {
            app.load_script_from_path();
        }
        app
    }

    /// Read the script file at `self.script_path` and (re)load it into the
    /// host. Errors go to the console + status line, never panic.
    fn load_script_from_path(&mut self) {
        let path = self.script_path.clone();
        match std::fs::read_to_string(&path) {
            Ok(src) => {
                let name = std::path::Path::new(&path)
                    .file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| path.clone());
                match self.host.load_script(&src, &name) {
                    Ok(()) => {
                        self.status = format!("Loaded script: {name}");
                        self.config.last_script = Some(path.into());
                        self.config.save();
                    }
                    Err(e) => self.status = format!("Script error: {e}"),
                }
            }
            Err(e) => self.status = format!("Cannot read {path}: {e}"),
        }
    }

    fn parsed_probe_region(&self) -> Option<MemRegion> {
        let addr = u32::from_str_radix(self.probe_addr_hex.trim_start_matches("0x"), 16).ok()?;
        if self.probe_size == 0 || self.probe_size > 4096 {
            return None;
        }
        Some(MemRegion::fxpak(addr, self.probe_size))
    }

    /// Build the engine's PollConfig from the persisted settings. One place
    /// so spawn and every live `set_config` stay consistent (a partial
    /// `..default()` would silently reset the other tunables).
    fn poll_config(&self) -> PollConfig {
        PollConfig {
            frame_budget_ms: self.config.frame_budget_ms.max(1),
            demand_window: std::time::Duration::from_millis(
                self.config.demand_window_ms.max(50) as u64,
            ),
            ..PollConfig::default()
        }
    }

    /// Translate the persisted overlay-text settings into the renderer's
    /// sizing mode for this frame.
    fn text_sizing(&self) -> sni_render::TextSizing {
        let s = self.config.text_size.clamp(0.1, 8.0);
        if self.config.text_sizing_mode == "screen" {
            // In screen mode the slider is "small..big"; scale to a sane
            // screen-pixel range (1px font-pixel is tiny, ~4px is large).
            sni_render::TextSizing::FixedScreen { px: s * 2.0 }
        } else {
            sni_render::TextSizing::GameScaled { mult: s }
        }
    }

    /// Resolve the canvas to use this frame and push it onto the host so the
    /// script's `gfx.width()/height()` are correct *during* `on_frame`.
    /// "script" honors the script's request; anything else overrides it.
    fn apply_canvas(&self) -> sni_render::Canvas {
        use sni_render::Canvas;
        let c = match self.config.canvas_mode.as_str() {
            "native" => Canvas::native(),
            "2x" => Canvas::scaled(2),
            "3x" => Canvas::scaled(3),
            "4x" => Canvas::scaled(4),
            // "script": leave whatever the script last requested in place.
            _ => self.host.requested_canvas(),
        };
        self.host.set_canvas(c);
        c
    }

    /// (Re)open the capture source to match the current mode + device.
    /// Composited opens the device; transparent closes it (the window's
    /// transparency provides the "background" instead).
    fn restart_capture(&mut self) {
        // Dropping the old source stops its thread cleanly first.
        self.capture = None;
        self.capture_tex = None;
        self.capture_tex_seq = 0;
        if sni_capture::CaptureMode::parse(&self.config.capture_mode)
            == sni_capture::CaptureMode::Composited
        {
            self.capture = Some(sni_capture::CaptureSource::open(
                self.config.capture_device,
                capture_settings(&self.config),
            ));
        }
    }

    fn apply_window_mode(&mut self, ctx: &egui::Context, frame: &eframe::Frame, transparent: bool) {
        if self.window_overlay_applied != Some(transparent) {
            ctx.send_viewport_cmd(egui::ViewportCommand::Transparent(transparent));
            ctx.send_viewport_cmd(egui::ViewportCommand::Decorations(!transparent));
            ctx.send_viewport_cmd(egui::ViewportCommand::WindowLevel(if transparent {
                egui::WindowLevel::AlwaysOnTop
            } else {
                egui::WindowLevel::Normal
            }));
            self.window_overlay_applied = Some(transparent);
        }

        let want_click_through = transparent && self.config.overlay_click_through;
        if self.click_through_applied != want_click_through {
            ctx.send_viewport_cmd(egui::ViewportCommand::MousePassthrough(want_click_through));
            platform::set_click_through(frame, want_click_through);
            self.click_through_applied = want_click_through;
        }
    }

    fn capture_uv_rect(&self, frame_size: [usize; 2], canvas: sni_render::Canvas) -> egui::Rect {
        let frame_w = frame_size[0].max(1) as f32;
        let frame_h = frame_size[1].max(1) as f32;

        let left = self
            .config
            .capture_crop_left
            .min(frame_size[0].saturating_sub(1) as u32) as f32;
        let top = self
            .config
            .capture_crop_top
            .min(frame_size[1].saturating_sub(1) as u32) as f32;
        let mut right = frame_w
            - self
                .config
                .capture_crop_right
                .min(frame_size[0].saturating_sub(1) as u32) as f32;
        let mut bottom = frame_h
            - self
                .config
                .capture_crop_bottom
                .min(frame_size[1].saturating_sub(1) as u32) as f32;
        let mut left = left;
        let mut top = top;
        if right <= left {
            right = (left + 1.0).min(frame_w);
        }
        if bottom <= top {
            bottom = (top + 1.0).min(frame_h);
        }

        if self.config.capture_crop_mode == "aspect" && canvas.h > 0.0 {
            let target = canvas.w / canvas.h;
            let crop_w = right - left;
            let crop_h = bottom - top;
            if crop_w > 0.0 && crop_h > 0.0 && target > 0.0 {
                let current = crop_w / crop_h;
                if current > target {
                    let new_w = crop_h * target;
                    let dx = (crop_w - new_w) * 0.5;
                    left += dx;
                    right -= dx;
                } else if current < target {
                    let new_h = crop_w / target;
                    let dy = (crop_h - new_h) * 0.5;
                    top += dy;
                    bottom -= dy;
                }
            }
        }

        egui::Rect::from_min_max(
            egui::pos2(left / frame_w, top / frame_h),
            egui::pos2(right / frame_w, bottom / frame_h),
        )
    }

    /// Upload the latest capture frame into an egui texture (only when the
    /// frame actually advanced) and return its handle for drawing.
    fn capture_texture(&mut self, ctx: &egui::Context) -> Option<&egui::TextureHandle> {
        let frame = self.capture.as_ref()?.latest()?;
        if self.capture_tex.is_none() || frame.seq != self.capture_tex_seq {
            let img = egui::ColorImage::from_rgba_unmultiplied(
                [frame.width as usize, frame.height as usize],
                &frame.pixels,
            );
            let opts = egui::TextureOptions {
                // Nearest keeps the captured pixel art crisp, matching the
                // overlay's deliberate hard-edged look.
                magnification: egui::TextureFilter::Nearest,
                minification: egui::TextureFilter::Linear,
                ..Default::default()
            };
            match &mut self.capture_tex {
                Some(t) => t.set(img, opts),
                None => {
                    self.capture_tex = Some(ctx.load_texture("capture", img, opts));
                }
            }
            self.capture_tex_seq = frame.seq;
        }
        self.capture_tex.as_ref()
    }
}

impl eframe::App for App {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        if self.config.capture_mode == "transparent" {
            [0.0, 0.0, 0.0, 0.0]
        } else {
            egui::Color32::from_rgba_unmultiplied(12, 12, 12, 180).to_normalized_gamma_f32()
        }
    }

    fn update(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        // Keep the UI repainting so capture frames / poll snapshots stay live
        // without user input.
        ctx.request_repaint_after(std::time::Duration::from_millis(16));

        // Transparent overlay and click-through are separate states: the
        // window can be transparent and borderless while still letting the
        // user interact with the app controls.
        let want_transparent = self.config.capture_mode == "transparent";
        if ctx.input_mut(|i| {
            i.consume_key(
                egui::Modifiers::CTRL | egui::Modifiers::SHIFT,
                egui::Key::F10,
            )
        }) {
            self.config.overlay_click_through = false;
            self.config.save();
            self.status = "Overlay click-through disabled".to_string();
        }
        self.apply_window_mode(ctx, frame, want_transparent);

        let snap = {
            // Short-lived clone of the actor state; never hold the lock across
            // egui widget code that could re-enter.
            let s = self.sni.state.lock();
            (
                s.conn.clone(),
                s.devices.clone(),
                s.selected_uri.clone(),
                s.mapping,
                s.last_probe.clone(),
            )
        };
        let (conn, devices, selected_uri, mapping, last_probe) = snap;

        // Resolve the canvas before the frame so gfx.width()/height() are
        // correct inside on_frame, then run the script against the latest
        // cached snapshot (lock-free; no SNI round trip on the UI thread).
        // In "script" mode the script may change the canvas during the frame,
        // so re-read it afterwards for the viewport.
        self.apply_canvas();
        self.draw_list = self.host.run_frame();
        let active_canvas = if self.config.canvas_mode == "script" {
            self.host.requested_canvas()
        } else {
            self.apply_canvas()
        };

        egui::TopBottomPanel::top("top").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.heading("sni-lua");
                ui.separator();
                ui.label("SNI:");
                ui.add(
                    egui::TextEdit::singleline(&mut self.config.sni_endpoint).desired_width(220.0),
                );

                let connected = matches!(conn, ConnState::Connected);
                if !connected {
                    let connecting = matches!(conn, ConnState::Connecting);
                    if ui
                        .add_enabled(!connecting, egui::Button::new("Connect"))
                        .clicked()
                    {
                        self.sni.send(Cmd::Connect {
                            endpoint: self.config.sni_endpoint.clone(),
                        });
                    }
                } else {
                    if ui.button("Disconnect").clicked() {
                        self.sni.send(Cmd::Disconnect);
                    }
                    if ui.button("↻ Devices").clicked() {
                        self.sni.send(Cmd::RefreshDevices);
                    }
                }

                ui.separator();
                let (txt, col) = match &conn {
                    ConnState::Disconnected => ("● disconnected".to_string(), egui::Color32::GRAY),
                    ConnState::Connecting => ("● connecting…".to_string(), egui::Color32::YELLOW),
                    ConnState::Connected => (
                        "● connected".to_string(),
                        egui::Color32::from_rgb(0, 200, 0),
                    ),
                    ConnState::Error(e) => (
                        format!("● error: {e}"),
                        egui::Color32::from_rgb(220, 60, 60),
                    ),
                };
                ui.colored_label(col, txt);
            });
        });

        egui::SidePanel::left("scripts")
            .resizable(true)
            .default_width(260.0)
            .show(ctx, |ui| {
                ui.heading("Script");
                ui.separator();
                ui.label(egui::RichText::new("Lua file path").small().weak());
                ui.add(
                    egui::TextEdit::singleline(&mut self.script_path)
                        .desired_width(f32::INFINITY)
                        .hint_text("examples/sm_hud.lua"),
                );
                ui.horizontal(|ui| {
                    let has_path = !self.script_path.trim().is_empty();
                    if ui
                        .add_enabled(has_path, egui::Button::new("Load"))
                        .clicked()
                    {
                        self.load_script_from_path();
                    }
                    if ui
                        .add_enabled(
                            has_path && self.host.is_loaded(),
                            egui::Button::new("↻ Reload"),
                        )
                        .clicked()
                    {
                        self.load_script_from_path();
                    }
                    ui.checkbox(&mut self.show_console, "Console");
                });
                let (txt, col) = if self.host.is_loaded() {
                    ("● script running", egui::Color32::from_rgb(0, 200, 0))
                } else if self.script_path.trim().is_empty() {
                    ("○ no script", egui::Color32::GRAY)
                } else {
                    (
                        "● stopped (see console)",
                        egui::Color32::from_rgb(220, 60, 60),
                    )
                };
                ui.colored_label(col, txt);

                ui.add_space(12.0);
                ui.heading("Overlay");
                ui.separator();
                ui.horizontal(|ui| {
                    ui.label("Text size");
                    if ui
                        .add(
                            egui::Slider::new(&mut self.config.text_size, 0.3..=4.0)
                                .fixed_decimals(2),
                        )
                        .changed()
                    {
                        self.config.save();
                    }
                });
                ui.horizontal(|ui| {
                    ui.label("Sizing");
                    let mut mode = self.config.text_sizing_mode.clone();
                    egui::ComboBox::from_id_salt("text_sizing")
                        .selected_text(if mode == "screen" {
                            "Fixed screen px"
                        } else {
                            "Game-scaled"
                        })
                        .show_ui(ui, |ui| {
                            ui.selectable_value(
                                &mut mode,
                                "game".to_string(),
                                "Game-scaled (zooms, pixel-aligned)",
                            );
                            ui.selectable_value(
                                &mut mode,
                                "screen".to_string(),
                                "Fixed screen px (constant size)",
                            );
                        });
                    if mode != self.config.text_sizing_mode {
                        self.config.text_sizing_mode = mode;
                        self.config.save();
                    }
                });
                ui.label(
                    egui::RichText::new(
                        "Scripts default to the compact 5x7 font; \
                         gfx.font(\"normal\") selects the larger 8x8.",
                    )
                    .small()
                    .weak(),
                );

                ui.add_space(6.0);
                ui.horizontal(|ui| {
                    ui.label("Canvas");
                    let mut m = self.config.canvas_mode.clone();
                    let label = match m.as_str() {
                        "native" => "Native 256x224",
                        "2x" => "2x  512x448",
                        "3x" => "3x  768x672",
                        "4x" => "4x  1024x896",
                        _ => "Script-controlled",
                    };
                    egui::ComboBox::from_id_salt("canvas_mode")
                        .selected_text(label)
                        .show_ui(ui, |ui| {
                            ui.selectable_value(
                                &mut m,
                                "script".into(),
                                "Script-controlled (gfx.scale/canvas)",
                            );
                            ui.selectable_value(&mut m, "native".into(), "Native 256x224");
                            ui.selectable_value(&mut m, "2x".into(), "2x  512x448");
                            ui.selectable_value(&mut m, "3x".into(), "3x  768x672");
                            ui.selectable_value(&mut m, "4x".into(), "4x  1024x896");
                        });
                    if m != self.config.canvas_mode {
                        self.config.canvas_mode = m;
                        self.config.save();
                    }
                });
                let ac = self.host.requested_canvas();
                ui.label(
                    egui::RichText::new(format!(
                        "active canvas: {}x{}  (gfx.width/height report this)",
                        ac.w as u32, ac.h as u32
                    ))
                    .small()
                    .weak(),
                );

                ui.add_space(12.0);
                ui.heading("Capture");
                ui.separator();
                ui.horizontal(|ui| {
                    ui.label("Mode");
                    let mut m = self.config.capture_mode.clone();
                    egui::ComboBox::from_id_salt("capture_mode")
                        .selected_text(if m == "transparent" {
                            "Transparent overlay"
                        } else {
                            "Composited"
                        })
                        .show_ui(ui, |ui| {
                            ui.selectable_value(
                                &mut m,
                                "composited".into(),
                                "Composited (capture feed in-app)",
                            );
                            ui.selectable_value(
                                &mut m,
                                "transparent".into(),
                                "Transparent overlay (over your own capture)",
                            );
                        });
                    if m != self.config.capture_mode {
                        self.config.capture_mode = m;
                        if self.config.capture_mode != "transparent" {
                            self.config.overlay_click_through = false;
                        }
                        self.config.save();
                        self.restart_capture();
                        self.window_overlay_applied = None;
                    }
                });

                if self.config.capture_mode == "composited" {
                    ui.horizontal(|ui| {
                        ui.label("Device");
                        let cur = self
                            .capture_devices
                            .iter()
                            .find(|d| d.index == self.config.capture_device)
                            .map(|d| d.name.clone())
                            .unwrap_or_else(|| format!("#{}", self.config.capture_device));
                        let mut chosen = self.config.capture_device;
                        egui::ComboBox::from_id_salt("capture_dev")
                            .selected_text(cur)
                            .show_ui(ui, |ui| {
                                for d in &self.capture_devices {
                                    ui.selectable_value(
                                        &mut chosen,
                                        d.index,
                                        format!("{} (#{})", d.name, d.index),
                                    );
                                }
                            });
                        if chosen != self.config.capture_device {
                            self.config.capture_device = chosen;
                            self.config.save();
                            self.restart_capture();
                        }
                    });
                    if ui.small_button("↻ Rescan devices").clicked() {
                        self.capture_devices = sni_capture::list_devices();
                    }
                    if let Some(frame) = self.capture.as_ref().and_then(|c| c.latest()) {
                        ui.label(
                            egui::RichText::new(format!(
                                "current input: {}x{}",
                                frame.width, frame.height
                            ))
                            .small()
                            .weak(),
                        );
                    }
                    ui.horizontal(|ui| {
                        ui.label("Input");
                        let mut changed = false;
                        changed |= ui
                            .add(
                                egui::DragValue::new(&mut self.config.capture_width)
                                    .range(0..=7680)
                                    .speed(16),
                            )
                            .changed();
                        ui.label("x");
                        changed |= ui
                            .add(
                                egui::DragValue::new(&mut self.config.capture_height)
                                    .range(0..=4320)
                                    .speed(16),
                            )
                            .changed();
                        ui.label("@");
                        changed |= ui
                            .add(
                                egui::DragValue::new(&mut self.config.capture_fps)
                                    .range(0..=240)
                                    .speed(1),
                            )
                            .changed();
                        ui.label("FPS");
                        if changed {
                            self.config.save();
                        }
                    });
                    ui.horizontal(|ui| {
                        if ui.small_button("Apply input").clicked() {
                            self.config.save();
                            self.restart_capture();
                        }
                        if ui.small_button("Auto input").clicked() {
                            self.config.capture_width = 0;
                            self.config.capture_height = 0;
                            self.config.capture_fps = 0;
                            self.config.save();
                            self.restart_capture();
                        }
                    });
                    ui.horizontal(|ui| {
                        ui.label("Crop mode");
                        let mut mode = self.config.capture_crop_mode.clone();
                        let label = if mode == "stretch" {
                            "Stretch crop"
                        } else {
                            "Crop to canvas"
                        };
                        egui::ComboBox::from_id_salt("capture_crop_mode")
                            .selected_text(label)
                            .show_ui(ui, |ui| {
                                ui.selectable_value(&mut mode, "aspect".into(), "Crop to canvas");
                                ui.selectable_value(&mut mode, "stretch".into(), "Stretch crop");
                            });
                        if mode != self.config.capture_crop_mode {
                            self.config.capture_crop_mode = mode;
                            self.config.save();
                        }
                    });
                    ui.horizontal(|ui| {
                        ui.label("Crop");
                        let mut changed = false;
                        ui.label("L");
                        changed |= ui
                            .add(
                                egui::DragValue::new(&mut self.config.capture_crop_left)
                                    .range(0..=8192)
                                    .speed(1),
                            )
                            .changed();
                        ui.label("T");
                        changed |= ui
                            .add(
                                egui::DragValue::new(&mut self.config.capture_crop_top)
                                    .range(0..=8192)
                                    .speed(1),
                            )
                            .changed();
                        ui.label("R");
                        changed |= ui
                            .add(
                                egui::DragValue::new(&mut self.config.capture_crop_right)
                                    .range(0..=8192)
                                    .speed(1),
                            )
                            .changed();
                        ui.label("B");
                        changed |= ui
                            .add(
                                egui::DragValue::new(&mut self.config.capture_crop_bottom)
                                    .range(0..=8192)
                                    .speed(1),
                            )
                            .changed();
                        if changed {
                            self.config.save();
                        }
                    });
                    if ui.small_button("Reset crop").clicked() {
                        self.config.capture_crop_left = 0;
                        self.config.capture_crop_top = 0;
                        self.config.capture_crop_right = 0;
                        self.config.capture_crop_bottom = 0;
                        self.config.save();
                    }
                    if self.capture_devices.is_empty() {
                        ui.label(
                            egui::RichText::new(
                                "No capture devices found. Plug in your \
                                 HDMI/USB capture card and rescan.",
                            )
                            .small()
                            .weak(),
                        );
                    }
                } else {
                    let mut click = self.config.overlay_click_through;
                    if ui.checkbox(&mut click, "Click-through mouse").changed() {
                        self.config.overlay_click_through = click;
                        self.config.save();
                    }
                    ui.label(
                        egui::RichText::new(
                            "Window is transparent + always-on-top. \
                             Ctrl+Shift+F10 disables click-through.",
                        )
                        .small()
                        .weak(),
                    );
                }

                ui.add_space(12.0);
                ui.heading("Device");
                ui.separator();
                if devices.is_empty() {
                    ui.label(
                        egui::RichText::new(
                            "No devices. Connect to SNI, start your emulator / FXPAK.",
                        )
                        .italics()
                        .weak(),
                    );
                } else {
                    let mut chosen = selected_uri.clone();
                    egui::ComboBox::from_id_salt("device")
                        .selected_text(
                            chosen
                                .as_deref()
                                .and_then(|u| {
                                    devices
                                        .iter()
                                        .find(|d| d.uri == u)
                                        .map(|d| format!("{} ({})", d.display_name, d.kind))
                                })
                                .unwrap_or_else(|| "— select —".into()),
                        )
                        .show_ui(ui, |ui| {
                            for d in &devices {
                                let label = format!("{} ({})", d.display_name, d.kind);
                                ui.selectable_value(&mut chosen, Some(d.uri.clone()), label);
                            }
                        });
                    if chosen != selected_uri {
                        if let Some(uri) = chosen {
                            self.sni.send(Cmd::SelectDevice { uri });
                        }
                    }
                    ui.label(format!(
                        "Mapping: {}",
                        mapping
                            .map(|m| format!("{m:?}"))
                            .unwrap_or_else(|| "—".into())
                    ));
                }

                ui.add_space(12.0);
                ui.heading("Live memory probe");
                ui.separator();
                ui.label(
                    egui::RichText::new("FxPakPro address (hex). SM Samus X = F50AF6, Y = F50AFA.")
                        .small()
                        .weak(),
                );
                ui.horizontal(|ui| {
                    ui.label("0x");
                    ui.add(
                        egui::TextEdit::singleline(&mut self.probe_addr_hex).desired_width(90.0),
                    );
                    ui.label("size");
                    ui.add(egui::DragValue::new(&mut self.probe_size).range(1..=64));
                });
                let region = self.parsed_probe_region();
                if ui
                    .add_enabled(
                        region.is_some() && matches!(conn, ConnState::Connected),
                        egui::Button::new("Read once"),
                    )
                    .clicked()
                {
                    if let Some(r) = region {
                        self.sni.send(Cmd::Probe { region: r });
                    }
                }

                if let Some(r) = last_probe.region {
                    ui.add_space(6.0);
                    ui.label(format!("addr 0x{:06X}  size {}", r.address, r.size));
                    if let Some(err) = &last_probe.error {
                        ui.colored_label(egui::Color32::from_rgb(220, 60, 60), err);
                    } else {
                        let hex: String = last_probe
                            .bytes
                            .iter()
                            .map(|b| format!("{b:02X} "))
                            .collect();
                        ui.monospace(hex.trim_end());
                        // Little-endian interpretations (SNES is LE).
                        if last_probe.bytes.len() >= 2 {
                            let v = u16::from_le_bytes([last_probe.bytes[0], last_probe.bytes[1]]);
                            ui.label(format!("u16 LE = {v}  (0x{v:04X})"));
                        }
                        ui.colored_label(
                            egui::Color32::from_rgb(255, 170, 0),
                            format!("round-trip: {} ms", last_probe.rtt_ms),
                        );
                        ui.label(
                            egui::RichText::new(
                                "↑ raw one-shot latency. The poll engine below hides it.",
                            )
                            .small()
                            .weak(),
                        );
                    }
                }

                // --- Poll engine HUD: the M3 deliverable, live ---
                ui.add_space(12.0);
                ui.heading("Poll engine");
                ui.separator();
                let stats = self.engine.stats();
                egui::Grid::new("poll_stats")
                    .num_columns(2)
                    .spacing([8.0, 2.0])
                    .show(ui, |ui| {
                        ui.label("cycle");
                        ui.monospace(stats.cycle.to_string());
                        ui.end_row();
                        ui.label("watches");
                        ui.monospace(format!(
                            "{} active / {} total",
                            stats.watches, stats.watches_total
                        ));
                        ui.end_row();
                        ui.label("reads/cycle");
                        ui.monospace(format!(
                            "{} ({} B)",
                            stats.reads_last_cycle, stats.bytes_last_cycle
                        ));
                        ui.end_row();
                        ui.label("RTT (ewma)");
                        ui.monospace(format!(
                            "{:.1} ms (last {} ms)",
                            stats.rtt_ms_ewma, stats.last_rtt_ms
                        ));
                        ui.end_row();
                        ui.label("realtime");
                        ui.monospace(format!(
                            "{} w · {} ms sub-poll",
                            stats.realtime_watches, stats.realtime_rtt_ms
                        ));
                        ui.end_row();
                        ui.label("budget");
                        ui.monospace(format!(
                            "{} B (auto) · {:.0} B/ms",
                            stats.byte_budget, stats.throughput_bpms
                        ));
                        ui.end_row();
                    });
                if stats.budget_capped {
                    ui.colored_label(
                        egui::Color32::from_rgb(255, 170, 0),
                        "byte budget hit — some watches deferred",
                    );
                }
                if let Some(e) = stats.last_error {
                    ui.colored_label(
                        egui::Color32::from_rgb(220, 60, 60),
                        format!("last cycle error: {e}"),
                    );
                }

                ui.horizontal(|ui| {
                    ui.label("Frame budget");
                    if ui
                        .add(
                            egui::Slider::new(
                                &mut self.config.frame_budget_ms,
                                4..=66,
                            )
                            .suffix(" ms"),
                        )
                        .changed()
                    {
                        // Push live to the running engine; the adaptive
                        // budget re-converges to the new target within a
                        // few cycles.
                        self.engine.set_config(self.poll_config());
                        self.config.save();
                    }
                });
                ui.horizontal(|ui| {
                    ui.label("Demand window");
                    if ui
                        .add(
                            egui::Slider::new(
                                &mut self.config.demand_window_ms,
                                100..=5000,
                            )
                            .suffix(" ms"),
                        )
                        .changed()
                    {
                        self.engine.set_config(self.poll_config());
                        self.config.save();
                    }
                });
                ui.label(
                    egui::RichText::new(
                        "watches unread this long stop being polled \
                         (stay cached); frees bandwidth for live data",
                    )
                    .small()
                    .weak(),
                );
                ui.label(
                    egui::RichText::new(
                        "engine reads as much as it can while keeping bulk \
                         round-trips under this; backs off hard on overshoot",
                    )
                    .small()
                    .weak(),
                );

            });

        egui::TopBottomPanel::bottom("status").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.label("Status:");
                ui.label(&self.status);
            });
        });

        if self.show_console {
            egui::TopBottomPanel::bottom("console")
                .resizable(true)
                .default_height(140.0)
                .show(ctx, |ui| {
                    ui.horizontal(|ui| {
                        ui.heading("Console");
                        if ui.small_button("clear").clicked() {
                            self.console.lines.lock().clear();
                        }
                    });
                    ui.separator();
                    let lines = self.console.snapshot();
                    egui::ScrollArea::vertical()
                        .stick_to_bottom(true)
                        .auto_shrink([false, false])
                        .show(ui, |ui| {
                            for l in &lines {
                                ui.monospace(l);
                            }
                        });
                });
        }

        // Resolve everything that needs &mut self / ctx before the egui
        // closure (which borrows self immutably).
        let transparent = sni_capture::CaptureMode::parse(&self.config.capture_mode)
            == sni_capture::CaptureMode::TransparentOverlay;
        let cap_tex = if transparent {
            None
        } else {
            self.capture_texture(ctx).map(|t| (t.id(), t.size()))
        };
        let sizing = self.text_sizing();
        let loaded = self.host.is_loaded();

        let mut central = egui::CentralPanel::default();
        if transparent {
            // No backdrop in transparent mode — the desktop/your capture
            // software shows through the window instead.
            central = central.frame(egui::Frame::none().fill(egui::Color32::TRANSPARENT));
        }
        central.show(ctx, |ui| {
            let avail = ui.available_size();
            let sense = if transparent {
                egui::Sense::drag()
            } else {
                egui::Sense::hover()
            };
            let (rect, resp) = ui.allocate_exact_size(avail, sense);
            if transparent && resp.drag_started() {
                ctx.send_viewport_cmd(egui::ViewportCommand::StartDrag);
            }
            let painter = ui.painter_at(rect);

            if !transparent {
                painter.rect_filled(rect, 0.0, egui::Color32::from_rgb(18, 18, 22));
            }

            // Map the active script canvas onto the available area,
            // letterboxed. A higher-res canvas lands in the same screen
            // rect — only the script's drawing precision changes.
            let vp = sni_render::Viewport::fit(rect, active_canvas);
            let view = vp.screen_rect();

            if transparent {
                // Faint guide so the user can place the window; not painted
                // opaque so it stays see-through.
                painter.rect_stroke(
                    view,
                    0.0,
                    egui::Stroke::new(
                        1.0,
                        egui::Color32::from_rgba_unmultiplied(120, 120, 120, 60),
                    ),
                );
            } else if let Some((tex, frame_size)) = cap_tex {
                // Composited: draw the capture feed to fill the canvas rect,
                // overlay goes on top. Same rect as the overlay viewport so
                // script pixel coords line up with the game pixels.
                painter.image(
                    tex,
                    view,
                    self.capture_uv_rect(frame_size, active_canvas),
                    egui::Color32::WHITE,
                );
            } else {
                // No device frame yet — placeholder screen so the overlay
                // still reads against something.
                painter.rect_filled(view, 0.0, egui::Color32::from_rgb(8, 10, 16));
                painter.rect_stroke(
                    view,
                    0.0,
                    egui::Stroke::new(1.0, egui::Color32::from_gray(60)),
                );
                painter.text(
                    view.center(),
                    egui::Align2::CENTER_CENTER,
                    "Waiting for capture device…\n(pick one under Capture)",
                    egui::FontId::proportional(13.0),
                    egui::Color32::from_gray(110),
                );
            }

            // Overlay always on top of whatever background.
            sni_render::paint(&painter, &vp, &self.draw_list, sizing);

            if !loaded && !transparent {
                painter.text(
                    egui::pos2(view.center().x, view.min.y + 16.0),
                    egui::Align2::CENTER_CENTER,
                    "No script running. Set a Lua path and click Load.",
                    egui::FontId::proportional(13.0),
                    egui::Color32::from_gray(120),
                );
            }
        });
    }

    fn on_exit(&mut self) {
        self.config.save();
    }
}
