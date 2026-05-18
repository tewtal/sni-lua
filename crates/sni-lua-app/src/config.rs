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
    /// Capture mode: "composited" or "transparent".
    pub capture_mode: String,
    /// Last loaded script path, restored on launch.
    pub last_script: Option<PathBuf>,
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
            poll_interval_ms: 16, // ~60 logical poll cycles/sec target
            capture_mode: "composited".to_string(),
            last_script: None,
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
}
