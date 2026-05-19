//! User configuration, persisted as JSON next to the executable.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    /// SNI gRPC endpoint. SNI listens on 127.0.0.1:8191 by default.
    pub sni_endpoint: String,
    /// Poll cycle target in milliseconds. The cache engine batches all active
    /// watches into one MultiRead per cycle; lower = fresher but more load on
    /// the FXPAK's limited bandwidth.
    pub poll_interval_ms: u64,
    /// Latency target (ms) for the adaptive bulk-read budget. The engine
    /// reads as much as it can while keeping each bulk MultiRead's round
    /// trip at/under this, backing off hard when it overshoots. 16 ≈ one
    /// 60fps frame; raise it to let block data refresh faster at the cost
    /// of occasional longer cycles.
    pub frame_budget_ms: u32,
    /// Demand window (ms): an auto-registered watch the script hasn't read
    /// for this long stops being polled (goes dormant — stays cached, costs
    /// no bandwidth). Stops the watched set growing without bound as the
    /// script roams. Pinned watches (controller, frame counter, explicit
    /// snes.tier) are unaffected.
    pub demand_window_ms: u32,
    /// Output mode: "composited" or "streaming".
    pub capture_mode: String,
    /// Capture device index (composited mode). Capture cards enumerate as
    /// webcam-class devices.
    pub capture_device: u32,
    /// Preferred capture input width/height/fps. Zero means "auto".
    pub capture_width: u32,
    pub capture_height: u32,
    pub capture_fps: u32,
    /// Capture crop margins in source pixels, applied before scaling into the
    /// overlay canvas.
    pub capture_crop_left: u32,
    pub capture_crop_top: u32,
    pub capture_crop_right: u32,
    pub capture_crop_bottom: u32,
    /// "aspect" = center-crop the source to the canvas aspect after manual
    /// margins; "stretch" = stretch the cropped source into the canvas rect.
    pub capture_crop_mode: String,
    /// RGB key color for the detached streaming-output window.
    pub stream_key_color: [u8; 3],
    /// Open the detached, chroma-keyable "stream output" window (the one you
    /// capture in OBS). When false, the keyed overlay is shown only in the
    /// main app window and no extra window is opened.
    pub stream_detached_window: bool,
    /// Keep showing the overlay canvas inside the main app while the detached
    /// stream window is open. (Ignored when `stream_detached_window` is
    /// false — the in-app view *is* the output then.)
    pub stream_show_in_app_canvas: bool,
    /// Size the detached stream window to an integer multiple of the
    /// script's canvas automatically. When false, `stream_scale` is used.
    pub stream_auto_scale: bool,
    /// Integer pixel scale for the stream window (canvas size × this).
    /// Used as the override when `stream_auto_scale` is false, and as the
    /// initial pick when it is true.
    pub stream_scale: u32,
    /// Last loaded script path, restored on launch.
    pub last_script: Option<PathBuf>,
    /// Canvas (script coordinate space) policy:
    /// "script" = honor the script's gfx.canvas/scale (default native if it
    /// doesn't ask); "native" / "2x" / "3x" / "4x" = force that, ignoring
    /// the script's request.
    pub canvas_mode: String,
    /// Overlay text sizing mode: "game" (scales with viewport/zoom, retro,
    /// pixel-aligned) or "screen" (fixed on-screen size regardless of zoom).
    pub text_sizing_mode: String,
    /// Size multiplier. In "game" mode: font-pixels per SNES pixel. In
    /// "screen" mode: screen pixels per font-pixel. Default tuned so the
    /// compact 5x7 font reads small.
    pub text_size: f32,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            sni_endpoint: format!("http://127.0.0.1:{}", sni_client::DEFAULT_GRPC_PORT),
            poll_interval_ms: 16,   // ~60 logical poll cycles/sec target
            frame_budget_ms: 16,    // adaptive budget keeps bulk reads ≤ 1 frame
            demand_window_ms: 1000, // unread ~1s -> dormant
            capture_mode: "composited".to_string(),
            capture_device: 0,
            capture_width: 0,
            capture_height: 0,
            capture_fps: 0,
            capture_crop_left: 0,
            capture_crop_top: 0,
            capture_crop_right: 0,
            capture_crop_bottom: 0,
            capture_crop_mode: "aspect".to_string(),
            stream_key_color: [255, 0, 255],
            stream_detached_window: true,
            stream_show_in_app_canvas: true,
            stream_auto_scale: true,
            stream_scale: 3,
            last_script: None,
            canvas_mode: "script".to_string(),
            text_sizing_mode: "game".to_string(),
            text_size: 1.0,
        }
    }
}

impl Config {
    fn path() -> PathBuf {
        std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.join("sni-lua.config.json")))
            .unwrap_or_else(|| PathBuf::from("sni-lua.config.json"))
    }

    pub fn load() -> Self {
        match std::fs::read_to_string(Self::path()) {
            Ok(s) => serde_json::from_str(&s).unwrap_or_else(|e| {
                tracing::warn!("config parse failed ({e}); using defaults");
                Config::default()
            }),
            Err(_) => Config::default(),
        }
    }

    pub fn save(&self) {
        if let Ok(s) = serde_json::to_string_pretty(self) {
            if let Err(e) = std::fs::write(Self::path(), s) {
                tracing::warn!("could not save config: {e}");
            }
        }
    }

    /// Per-script persistent-store file, kept in a `store/` dir next to the
    /// config. Keyed by a hash of the script's absolute path so two scripts
    /// with the same file name don't collide, and renaming the app dir keeps
    /// each script's data with it. Best-effort: returns `None` if we can't
    /// resolve a base dir (store then silently disables).
    pub fn store_path_for(script: &std::path::Path) -> Option<PathBuf> {
        let base = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.join("store")))?;
        let _ = std::fs::create_dir_all(&base);
        let abs = std::fs::canonicalize(script).unwrap_or_else(|_| script.to_path_buf());
        // Cheap stable hash (FNV-1a) of the absolute path — no extra dep.
        let mut h: u64 = 0xcbf29ce484222325;
        for b in abs.to_string_lossy().as_bytes() {
            h ^= *b as u64;
            h = h.wrapping_mul(0x100000001b3);
        }
        let stem = script
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "script".into());
        Some(base.join(format!("{stem}.{h:016x}.json")))
    }
}
