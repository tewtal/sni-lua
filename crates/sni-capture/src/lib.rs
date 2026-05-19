//! Capture-device background.
//!
//! Three modes (all selectable):
//!
//! * [`CaptureMode::Composited`] — the app grabs the capture feed and draws
//!   the overlay on top inside its own window.
//! * [`CaptureMode::TransparentOverlay`] — the app renders only the overlay
//!   in a transparent, click-through, always-on-top window placed over the
//!   user's own capture software (OBS, etc.). No device is opened in this
//!   mode; the window manager / Win32 layer handles transparency (the app
//!   crate owns that since it owns the eframe window).
//! * [`CaptureMode::StreamingOverlay`] — the app renders only the overlay in
//!   a separate opaque window with a solid chroma-key background so it can be
//!   captured directly as a normal window and keyed in streaming software.
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
    ApiBackend, CameraFormat, CameraIndex, RequestedFormat, RequestedFormatType, Resolution,
};
use nokhwa::{Camera, FormatDecoder};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CaptureMode {
    #[default]
    Composited,
    TransparentOverlay,
    StreamingOverlay,
}

impl CaptureMode {
    pub fn parse(s: &str) -> CaptureMode {
        match s {
            "transparent" => CaptureMode::TransparentOverlay,
            "stream" | "streaming" => CaptureMode::StreamingOverlay,
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

/// Capture format preferences. A zero value means "auto".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CaptureSettings {
    pub width: u32,
    pub height: u32,
    pub fps: u32,
}

impl CaptureSettings {
    fn wants_format(self) -> bool {
        self.width > 0 || self.height > 0 || self.fps > 0
    }

    fn wants_resolution(self) -> bool {
        self.width > 0 || self.height > 0
    }
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
    settings: CaptureSettings,
}

impl CaptureSource {
    /// Open `device_index` and start capturing on a background thread. Errors
    /// from the device are logged; the source simply yields no frames until
    /// the device works (the overlay still runs).
    pub fn open(device_index: u32, settings: CaptureSettings) -> Self {
        let latest: Arc<ArcSwap<Option<Frame>>> = Arc::new(ArcSwap::from_pointee(None));
        let stop = Arc::new(AtomicBool::new(false));

        let thread_latest = latest.clone();
        let thread_stop = stop.clone();
        let handle = std::thread::Builder::new()
            .name("sni-capture".into())
            .spawn(move || {
                capture_loop(device_index, settings, thread_latest, thread_stop);
            })
            .expect("spawn capture thread");

        Self {
            latest,
            stop,
            handle: Some(handle),
            device_index,
            settings,
        }
    }

    pub fn device_index(&self) -> u32 {
        self.device_index
    }

    pub fn settings(&self) -> CaptureSettings {
        self.settings
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
    settings: CaptureSettings,
    latest: Arc<ArcSwap<Option<Frame>>>,
    stop: Arc<AtomicBool>,
) {
    // Ask for the highest-rate format the device offers; we decode to RGBA.
    let requested =
        RequestedFormat::new::<RgbAFormat>(RequestedFormatType::AbsoluteHighestFrameRate);
    let mut camera = match Camera::new(CameraIndex::Index(device_index), requested) {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("cannot open capture device {device_index}: {e}");
            return;
        }
    };

    apply_requested_format(&mut camera, device_index, settings);

    if let Err(e) = camera.open_stream() {
        tracing::warn!("cannot start capture stream: {e}");
        return;
    }
    tracing::info!(
        "capture device {device_index} streaming at {}",
        camera.camera_format()
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

fn apply_requested_format(camera: &mut Camera, device_index: u32, settings: CaptureSettings) {
    if !settings.wants_format() {
        return;
    }

    match camera.compatible_camera_formats() {
        Ok(formats) => {
            if let Some(format) = choose_format(&formats, settings) {
                tracing::info!(
                    "capture device {device_index} requested {:?}, selected {}",
                    settings,
                    format
                );
                let wanted_formats = [format.format()];
                let request = RequestedFormat::with_formats(
                    RequestedFormatType::Exact(format),
                    &wanted_formats,
                );
                if let Err(e) = camera.set_camera_requset(request) {
                    tracing::warn!(
                        "capture device {device_index} rejected selected format \
                         {format}: {e}"
                    );
                }
            } else {
                tracing::warn!(
                    "capture device {device_index} has no compatible decoded \
                     formats for {:?}; using backend default",
                    settings
                );
            }
        }
        Err(e) => {
            tracing::warn!(
                "capture device {device_index} format query failed ({e}); \
                 trying direct format setters"
            );
            if settings.width > 0 && settings.height > 0 {
                let res = Resolution::new(settings.width, settings.height);
                if let Err(e) = camera.set_resolution(res) {
                    tracing::warn!(
                        "capture device {device_index} rejected resolution \
                         {res}: {e}"
                    );
                }
            }
            if settings.fps > 0 {
                if let Err(e) = camera.set_frame_rate(settings.fps) {
                    tracing::warn!(
                        "capture device {device_index} rejected {} FPS: {e}",
                        settings.fps
                    );
                }
            }
        }
    }
}

fn choose_format(formats: &[CameraFormat], settings: CaptureSettings) -> Option<CameraFormat> {
    let mut formats = formats
        .iter()
        .copied()
        .filter(|format| <RgbAFormat as FormatDecoder>::FORMATS.contains(&format.format()))
        .collect::<Vec<_>>();

    formats.sort_by_key(|format| {
        (
            resolution_score(*format, settings),
            fps_score(*format, settings),
            std::cmp::Reverse(format.frame_rate()),
            std::cmp::Reverse(format_area(*format)),
        )
    });
    formats.into_iter().next()
}

fn resolution_score(format: CameraFormat, settings: CaptureSettings) -> u64 {
    if !settings.wants_resolution() {
        return 0;
    }
    let dx = if settings.width > 0 {
        format.width().abs_diff(settings.width) as u64
    } else {
        0
    };
    let dy = if settings.height > 0 {
        format.height().abs_diff(settings.height) as u64
    } else {
        0
    };
    dx * dx + dy * dy
}

fn fps_score(format: CameraFormat, settings: CaptureSettings) -> u32 {
    if settings.fps == 0 {
        return 0;
    }
    format.frame_rate().abs_diff(settings.fps)
}

fn format_area(format: CameraFormat) -> u64 {
    u64::from(format.width()) * u64::from(format.height())
}
