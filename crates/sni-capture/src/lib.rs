//! Capture-device background.
//!
//! Two modes (both selectable, per the original design):
//!
//! * [`CaptureMode::Composited`] — the app grabs the capture feed and draws
//!   the overlay on top inside its own window.
//! * [`CaptureMode::TransparentOverlay`] — the app renders only the overlay
//!   in a transparent, click-through, always-on-top window placed over the
//!   user's own capture software (OBS, etc.). No device is opened in this
//!   mode; the window manager / Win32 layer handles transparency (the app
//!   crate owns that since it owns the eframe window).
//!
//! Pipeline philosophy mirrors the SNI side: a background thread always holds
//! only the *newest* decoded frame in an [`ArcSwap`]; the UI thread loads the
//! latest each repaint and uploads it as a texture. Stale frames are dropped,
//! so a slow device read never stalls the overlay.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;

use arc_swap::ArcSwap;
use nokhwa::pixel_format::RgbAFormat;
use nokhwa::utils::{
    ApiBackend, CameraIndex, RequestedFormat, RequestedFormatType,
};
use nokhwa::Camera;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureMode {
    Composited,
    TransparentOverlay,
}

impl Default for CaptureMode {
    fn default() -> Self {
        CaptureMode::Composited
    }
}

impl CaptureMode {
    pub fn parse(s: &str) -> CaptureMode {
        match s {
            "transparent" => CaptureMode::TransparentOverlay,
            _ => CaptureMode::Composited,
        }
    }
}

/// A decoded RGBA frame ready to upload as a texture. `pixels` is
/// `width*height*4`, row-major, no padding.
#[derive(Clone)]
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub pixels: Arc<Vec<u8>>,
    /// Monotonic counter so the UI can tell if the frame actually changed
    /// (skip re-uploading an identical texture).
    pub seq: u64,
}

/// An available capture device the user can pick from the UI.
#[derive(Debug, Clone)]
pub struct DeviceDesc {
    pub index: u32,
    pub name: String,
}

/// Enumerate capture devices (capture cards show up as webcam-class).
pub fn list_devices() -> Vec<DeviceDesc> {
    match nokhwa::query(ApiBackend::Auto) {
        Ok(list) => list
            .into_iter()
            .map(|info| DeviceDesc {
                index: device_index_u32(info.index()),
                name: info.human_name(),
            })
            .collect(),
        Err(e) => {
            tracing::warn!("capture device query failed: {e}");
            Vec::new()
        }
    }
}

fn device_index_u32(idx: &CameraIndex) -> u32 {
    match idx {
        CameraIndex::Index(i) => *i,
        // String indices (rare on Windows MSMF) — fall back to 0; the user
        // can still pick by position in the list.
        CameraIndex::String(_) => 0,
    }
}

/// Owns the background capture thread. Drop to stop it.
pub struct CaptureSource {
    latest: Arc<ArcSwap<Option<Frame>>>,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
    device_index: u32,
}

impl CaptureSource {
    /// Open `device_index` and start capturing on a background thread. Errors
    /// from the device are logged; the source simply yields no frames until
    /// the device works (the overlay still runs).
    pub fn open(device_index: u32) -> Self {
        let latest: Arc<ArcSwap<Option<Frame>>> =
            Arc::new(ArcSwap::from_pointee(None));
        let stop = Arc::new(AtomicBool::new(false));

        let thread_latest = latest.clone();
        let thread_stop = stop.clone();
        let handle = std::thread::Builder::new()
            .name("sni-capture".into())
            .spawn(move || {
                capture_loop(device_index, thread_latest, thread_stop);
            })
            .expect("spawn capture thread");

        Self {
            latest,
            stop,
            handle: Some(handle),
            device_index,
        }
    }

    pub fn device_index(&self) -> u32 {
        self.device_index
    }

    /// The most recent decoded frame, or `None` if the device hasn't
    /// produced one yet. Lock-free; safe to call every repaint.
    pub fn latest(&self) -> Option<Frame> {
        self.latest.load_full().as_ref().clone()
    }
}

impl Drop for CaptureSource {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            // The capture call can block briefly; give the thread a moment.
            let _ = h.join();
        }
    }
}

fn capture_loop(
    device_index: u32,
    latest: Arc<ArcSwap<Option<Frame>>>,
    stop: Arc<AtomicBool>,
) {
    // Ask for the highest-rate format the device offers; we decode to RGBA.
    let requested = RequestedFormat::new::<RgbAFormat>(
        RequestedFormatType::AbsoluteHighestFrameRate,
    );
    let mut camera = match Camera::new(CameraIndex::Index(device_index), requested)
    {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("cannot open capture device {device_index}: {e}");
            return;
        }
    };
    if let Err(e) = camera.open_stream() {
        tracing::warn!("cannot start capture stream: {e}");
        return;
    }
    tracing::info!(
        "capture device {device_index} streaming at {:?}",
        camera.resolution()
    );

    let mut seq: u64 = 0;
    while !stop.load(Ordering::Relaxed) {
        match camera.frame() {
            Ok(buf) => match buf.decode_image::<RgbAFormat>() {
                Ok(img) => {
                    seq += 1;
                    let frame = Frame {
                        width: img.width(),
                        height: img.height(),
                        pixels: Arc::new(img.into_raw()),
                        seq,
                    };
                    // Latest-wins: replace whatever was there. A slow UI
                    // simply skips intermediate frames.
                    latest.store(Arc::new(Some(frame)));
                }
                Err(e) => tracing::debug!("frame decode failed: {e}"),
            },
            Err(e) => {
                tracing::debug!("frame grab failed: {e}");
                // Brief backoff so a disconnected device doesn't spin a core.
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
        }
    }
    let _ = camera.stop_stream();
    tracing::info!("capture device {device_index} stopped");
}
