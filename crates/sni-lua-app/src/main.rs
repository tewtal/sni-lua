//! sni-lua: Lua overlay scripting for SNES over SNI/USB2SNES.
//!
//! M1 deliverable: egui/wgpu window, app shell, config persistence, a Tokio
//! runtime ready for the SNI client, and a LuaJIT smoke test proving the
//! vendored build links. SNI connect / poll engine / scripting / capture land
//! in M2–M6.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod config;

use std::sync::Arc;

use config::Config;
use eframe::egui;
use sni_render::{DrawList, SNES_H, SNES_W};
use tokio::runtime::Runtime;

fn main() -> eframe::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "sni_lua=info,warn".into()),
        )
        .init();

    // One multi-thread Tokio runtime for all async SNI work. The egui app
    // never `.await`s on the UI thread; it talks to async tasks via channels
    // (wired up in M2+).
    let rt = Runtime::new().expect("failed to start tokio runtime");
    let _guard = rt.enter();

    let native_options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([960.0, 720.0])
            .with_min_inner_size([640.0, 480.0])
            .with_title("sni-lua — SNES overlay scripting over SNI"),
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
    /// Latest draw list. In M4+ the script host writes this; M5 paints it.
    draw_list: Arc<parking_lot::Mutex<DrawList>>,
    status: String,
}

impl App {
    fn new(_cc: &eframe::CreationContext<'_>, rt: Runtime) -> Self {
        let config = Config::load();

        // Prove the LuaJIT vendored build is linked and working.
        let lua_status = match sni_lua_api::ScriptHost::new()
            .and_then(|h| h.eval_number("return 2 ^ 10"))
        {
            Ok(v) => format!("LuaJIT OK (2^10 = {v})"),
            Err(e) => format!("LuaJIT FAILED: {e}"),
        };

        Self {
            _rt: rt,
            config,
            draw_list: Arc::new(parking_lot::Mutex::new(DrawList::default())),
            status: format!("Ready. {lua_status}"),
        }
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        egui::TopBottomPanel::top("top").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.heading("sni-lua");
                ui.separator();
                ui.label("SNI:");
                ui.add(
                    egui::TextEdit::singleline(&mut self.config.sni_endpoint)
                        .desired_width(220.0),
                );
                if ui.button("Connect").clicked() {
                    // M2: spawn SNI client connect on the runtime.
                    self.status = format!(
                        "Connect not yet wired (M2). Endpoint: {}",
                        self.config.sni_endpoint
                    );
                }
                ui.separator();
                ui.label("Poll ms:");
                ui.add(egui::DragValue::new(&mut self.config.poll_interval_ms).range(1..=1000));
            });
        });

        egui::SidePanel::left("scripts")
            .resizable(true)
            .default_width(220.0)
            .show(ctx, |ui| {
                ui.heading("Scripts");
                ui.separator();
                if ui.button("Load script… (M4)").clicked() {
                    self.status = "Script loading lands in M4.".into();
                }
                ui.label(
                    egui::RichText::new("No script loaded")
                        .italics()
                        .weak(),
                );
                ui.separator();
                ui.heading("Capture");
                ui.label(format!("Mode: {} (M6)", self.config.capture_mode));
            });

        egui::TopBottomPanel::bottom("status").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.label("Status:");
                ui.label(&self.status);
            });
        });

        // The overlay viewport. M5 will scale-fit a 256x224 SNES surface here
        // (or a transparent canvas in TransparentOverlay mode); M6 puts the
        // capture feed behind it.
        egui::CentralPanel::default().show(ctx, |ui| {
            let avail = ui.available_size();
            let (rect, _resp) =
                ui.allocate_exact_size(avail, egui::Sense::hover());
            let painter = ui.painter_at(rect);
            painter.rect_filled(rect, 0.0, egui::Color32::from_rgb(18, 18, 22));

            // Letterboxed SNES viewport guide so the coordinate space is clear.
            let scale = (rect.width() / SNES_W).min(rect.height() / SNES_H);
            let vw = SNES_W * scale;
            let vh = SNES_H * scale;
            let origin = egui::pos2(
                rect.center().x - vw / 2.0,
                rect.center().y - vh / 2.0,
            );
            let view = egui::Rect::from_min_size(origin, egui::vec2(vw, vh));
            painter.rect_stroke(
                view,
                0.0,
                egui::Stroke::new(1.0, egui::Color32::from_gray(70)),
            );
            painter.text(
                view.center(),
                egui::Align2::CENTER_CENTER,
                "SNES overlay viewport (256×224)\ncapture feed → M6 · script draw → M5",
                egui::FontId::proportional(14.0),
                egui::Color32::from_gray(120),
            );

            // Drain whatever a (future) script pushed so the path is exercised.
            let _ = self.draw_list.lock().cmds.len();
        });
    }

    fn on_exit(&mut self) {
        self.config.save();
    }
}
