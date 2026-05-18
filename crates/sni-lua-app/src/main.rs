//! sni-lua: Lua overlay scripting for SNES over SNI/USB2SNES.
//!
//! M2 deliverable: the SNI gRPC client wired into the app via a background
//! actor. Connect/disconnect, device listing + selection, memory-mapping
//! detection, and a live read probe that surfaces real bytes + round-trip
//! latency — the number the M3 poll engine exists to hide.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod config;
mod sni_actor;

use std::sync::Arc;

use config::Config;
use eframe::egui;
use sni_actor::{Cmd, ConnState, SniHandle};
use sni_client::MemRegion;
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
    // never `.await`s on the UI thread; it talks to the SNI actor via channels.
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
    sni: SniHandle,
    /// Latest draw list. In M4+ the script host writes this; M5 paints it.
    draw_list: Arc<parking_lot::Mutex<DrawList>>,
    status: String,

    // Live memory inspector (M2 demo of real reads + latency).
    probe_addr_hex: String,
    probe_size: u32,
}

impl App {
    fn new(_cc: &eframe::CreationContext<'_>, rt: Runtime) -> Self {
        let config = Config::load();

        let lua_status = match sni_lua_api::ScriptHost::new()
            .and_then(|h| h.eval_number("return 2 ^ 10"))
        {
            Ok(v) => format!("LuaJIT OK (2^10 = {v})"),
            Err(e) => format!("LuaJIT FAILED: {e}"),
        };

        let sni = sni_actor::spawn();

        Self {
            _rt: rt,
            config,
            sni,
            draw_list: Arc::new(parking_lot::Mutex::new(DrawList::default())),
            status: format!("Ready. {lua_status}"),
            // Super Metroid: WRAM $7E:0AF6 = Samus X position (u16). In the
            // FxPakPro space that's $F5_0AF6.
            probe_addr_hex: "F50AF6".to_string(),
            probe_size: 2,
        }
    }

    fn parsed_probe_region(&self) -> Option<MemRegion> {
        let addr = u32::from_str_radix(self.probe_addr_hex.trim_start_matches("0x"), 16).ok()?;
        if self.probe_size == 0 || self.probe_size > 4096 {
            return None;
        }
        Some(MemRegion::fxpak(addr, self.probe_size))
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // Keep the UI repainting while connected so probe results / future
        // poll snapshots stay live without user input.
        ctx.request_repaint_after(std::time::Duration::from_millis(33));

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

        egui::TopBottomPanel::top("top").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.heading("sni-lua");
                ui.separator();
                ui.label("SNI:");
                ui.add(
                    egui::TextEdit::singleline(&mut self.config.sni_endpoint)
                        .desired_width(220.0),
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
                    ConnState::Disconnected => {
                        ("● disconnected".to_string(), egui::Color32::GRAY)
                    }
                    ConnState::Connecting => {
                        ("● connecting…".to_string(), egui::Color32::YELLOW)
                    }
                    ConnState::Connected => {
                        ("● connected".to_string(), egui::Color32::from_rgb(0, 200, 0))
                    }
                    ConnState::Error(e) => {
                        (format!("● error: {e}"), egui::Color32::from_rgb(220, 60, 60))
                    }
                };
                ui.colored_label(col, txt);
            });
        });

        egui::SidePanel::left("scripts")
            .resizable(true)
            .default_width(260.0)
            .show(ctx, |ui| {
                ui.heading("Device");
                ui.separator();
                if devices.is_empty() {
                    ui.label(
                        egui::RichText::new("No devices. Connect to SNI, start your emulator / FXPAK.")
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
                                    devices.iter().find(|d| d.uri == u).map(|d| {
                                        format!("{} ({})", d.display_name, d.kind)
                                    })
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
                    egui::RichText::new(
                        "FxPakPro address (hex). SM Samus X = F50AF6, Y = F50AFA.",
                    )
                    .small()
                    .weak(),
                );
                ui.horizontal(|ui| {
                    ui.label("0x");
                    ui.add(
                        egui::TextEdit::singleline(&mut self.probe_addr_hex)
                            .desired_width(90.0),
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
                            let v = u16::from_le_bytes([
                                last_probe.bytes[0],
                                last_probe.bytes[1],
                            ]);
                            ui.label(format!("u16 LE = {v}  (0x{v:04X})"));
                        }
                        ui.colored_label(
                            egui::Color32::from_rgb(255, 170, 0),
                            format!("round-trip: {} ms", last_probe.rtt_ms),
                        );
                        ui.label(
                            egui::RichText::new(
                                "↑ this latency is what M3's batched poll engine will hide.",
                            )
                            .small()
                            .weak(),
                        );
                    }
                }
            });

        egui::TopBottomPanel::bottom("status").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.label("Status:");
                ui.label(&self.status);
            });
        });

        egui::CentralPanel::default().show(ctx, |ui| {
            let avail = ui.available_size();
            let (rect, _resp) = ui.allocate_exact_size(avail, egui::Sense::hover());
            let painter = ui.painter_at(rect);
            painter.rect_filled(rect, 0.0, egui::Color32::from_rgb(18, 18, 22));

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

            let _ = self.draw_list.lock().cmds.len();
        });
    }

    fn on_exit(&mut self) {
        self.config.save();
    }
}
