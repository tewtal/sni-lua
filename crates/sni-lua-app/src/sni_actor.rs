//! Background SNI actor.
//!
//! The egui UI thread must never `.await` or block on the FXPAK. All SNI work
//! happens on this Tokio task; the UI talks to it over an mpsc command channel
//! and observes results through a shared, lock-light [`SniState`] snapshot.
//!
//! This is the seam the M3 poll engine plugs into: the actor already owns the
//! connected [`SniClient`] and the selected device URI.

use std::sync::Arc;

use arc_swap::ArcSwap;
use parking_lot::Mutex;
use sni_client::{DeviceInfo, MemRegion, MemoryMapping, SniClient};
use tokio::sync::mpsc;

/// The active `(client, device_uri)` the poll engine reads each cycle.
/// `None` whenever we're disconnected or no device is selected — the engine
/// idles instead of erroring, so reconnects don't restart polling.
pub type ClientSlot = Arc<ArcSwap<Option<(SniClient, String)>>>;

/// Connection lifecycle as observed by the UI.
#[derive(Debug, Clone, Default, PartialEq)]
pub enum ConnState {
    #[default]
    Disconnected,
    Connecting,
    /// Connected; may or may not have a device selected yet.
    Connected,
    Error(String),
}

/// A completed probe read, surfaced to the UI for the live memory inspector.
#[derive(Debug, Clone, Default)]
pub struct ProbeResult {
    pub region: Option<MemRegion>,
    pub bytes: Vec<u8>,
    pub error: Option<String>,
    /// Round-trip time in milliseconds — the number that tells you how much
    /// the poll engine has to hide.
    pub rtt_ms: u32,
}

/// Shared state the UI reads each egui frame. Kept coarse and copy-cheap;
/// guarded by a short-lived mutex (never held across `.await`).
#[derive(Debug, Default)]
pub struct SniState {
    pub conn: ConnState,
    pub devices: Vec<DeviceInfo>,
    pub selected_uri: Option<String>,
    pub mapping: Option<MemoryMapping>,
    pub last_probe: ProbeResult,
}

pub type SharedState = Arc<Mutex<SniState>>;

/// Commands the UI sends to the actor. Fire-and-forget; results land in
/// [`SharedState`] and the UI polls them (egui is an immediate-mode loop).
#[derive(Debug)]
pub enum Cmd {
    Connect { endpoint: String },
    Disconnect,
    RefreshDevices,
    SelectDevice { uri: String },
    /// One-shot read used by the live inspector to demonstrate latency.
    Probe { region: MemRegion },
    /// Fire-and-forget memory write from a script (`snes.write`). Never
    /// blocks the frame; failures are logged, not surfaced per-call.
    Write { region: MemRegion, data: Vec<u8> },
}

/// Handle the UI keeps. Dropping it stops the actor.
pub struct SniHandle {
    tx: mpsc::UnboundedSender<Cmd>,
    pub state: SharedState,
    /// Shared with the poll engine so it always sees the live client/device.
    pub client_slot: ClientSlot,
}

impl SniHandle {
    pub fn send(&self, cmd: Cmd) {
        // Unbounded + UI-driven: a full channel would mean the actor is wedged;
        // dropping the command is preferable to blocking the render thread.
        let _ = self.tx.send(cmd);
    }

    /// A cheap, cloneable sender for code that only needs to enqueue commands
    /// (e.g. the Lua write sink) without holding the whole handle.
    pub fn sender(&self) -> CmdSender {
        CmdSender {
            tx: self.tx.clone(),
        }
    }
}

/// Clone-and-send view of the actor's command channel.
#[derive(Clone)]
pub struct CmdSender {
    tx: mpsc::UnboundedSender<Cmd>,
}

impl CmdSender {
    pub fn send(&self, cmd: Cmd) {
        let _ = self.tx.send(cmd);
    }
}

/// Spawn the actor on the current Tokio runtime. Call inside `rt.enter()`.
pub fn spawn() -> SniHandle {
    let (tx, rx) = mpsc::unbounded_channel();
    let state: SharedState = Arc::new(Mutex::new(SniState::default()));
    let client_slot: ClientSlot = Arc::new(ArcSwap::from_pointee(None));
    let actor_state = state.clone();
    let actor_slot = client_slot.clone();
    tokio::spawn(async move {
        Actor {
            state: actor_state,
            client: None,
            slot: actor_slot,
        }
        .run(rx)
        .await;
    });
    SniHandle {
        tx,
        state,
        client_slot,
    }
}

struct Actor {
    state: SharedState,
    client: Option<SniClient>,
    slot: ClientSlot,
}

impl Actor {
    async fn run(mut self, mut rx: mpsc::UnboundedReceiver<Cmd>) {
        while let Some(cmd) = rx.recv().await {
            match cmd {
                Cmd::Connect { endpoint } => self.connect(endpoint).await,
                Cmd::Disconnect => {
                    self.client = None;
                    {
                        let mut s = self.state.lock();
                        *s = SniState::default();
                    }
                    self.republish_slot(); // -> None; poll engine idles
                }
                Cmd::RefreshDevices => self.refresh_devices().await,
                Cmd::SelectDevice { uri } => self.select_device(uri).await,
                Cmd::Probe { region } => self.probe(region).await,
                Cmd::Write { region, data } => self.write(region, data).await,
            }
        }
        tracing::info!("SNI actor stopped (handle dropped)");
    }

    fn set_conn(&self, conn: ConnState) {
        self.state.lock().conn = conn;
    }

    /// Republish the `(client, uri)` the poll engine reads. Called whenever
    /// the client or selected device changes. The poll engine picks this up
    /// on its next cycle with no restart.
    fn republish_slot(&self) {
        let uri = self.state.lock().selected_uri.clone();
        let next = match (self.client.clone(), uri) {
            (Some(c), Some(u)) => Some((c, u)),
            _ => None,
        };
        self.slot.store(Arc::new(next));
    }

    async fn connect(&mut self, endpoint: String) {
        self.set_conn(ConnState::Connecting);
        match SniClient::connect(endpoint.clone()).await {
            Ok(client) => {
                self.client = Some(client);
                self.set_conn(ConnState::Connected);
                tracing::info!("connected to SNI at {endpoint}");
                // Auto-list so the UI has something immediately.
                self.refresh_devices().await;
            }
            Err(e) => {
                tracing::warn!("SNI connect failed: {e}");
                self.set_conn(ConnState::Error(e.to_string()));
            }
        }
    }

    async fn refresh_devices(&mut self) {
        let Some(client) = self.client.as_mut() else {
            return;
        };
        match client.list_devices().await {
            Ok(devices) => {
                let mut s = self.state.lock();
                // Keep selection if the device is still present; else pick the
                // first device automatically (usually the only FXPAK).
                let keep = s
                    .selected_uri
                    .as_ref()
                    .filter(|u| devices.iter().any(|d| &d.uri == *u))
                    .cloned();
                s.selected_uri = keep.or_else(|| devices.first().map(|d| d.uri.clone()));
                s.devices = devices;
            }
            Err(e) => self.set_conn(ConnState::Error(format!("list devices: {e}"))),
        }
        // If we just auto-selected, detect its mapping.
        let sel = self.state.lock().selected_uri.clone();
        if let Some(uri) = sel {
            self.detect_mapping(&uri).await;
        }
        self.republish_slot();
    }

    async fn select_device(&mut self, uri: String) {
        self.state.lock().selected_uri = Some(uri.clone());
        self.detect_mapping(&uri).await;
        self.republish_slot();
    }

    async fn detect_mapping(&mut self, uri: &str) {
        let Some(client) = self.client.as_mut() else {
            return;
        };
        match client.detect_mapping(uri).await {
            Ok(m) => {
                self.state.lock().mapping = Some(m);
                tracing::info!("device {uri} mapping = {m:?}");
            }
            Err(e) => tracing::warn!("mapping detect failed for {uri}: {e}"),
        }
    }

    async fn probe(&mut self, region: MemRegion) {
        let uri = self.state.lock().selected_uri.clone();
        let (Some(client), Some(uri)) = (self.client.as_mut(), uri) else {
            self.state.lock().last_probe = ProbeResult {
                region: Some(region),
                error: Some("not connected / no device selected".into()),
                ..Default::default()
            };
            return;
        };
        let t0 = std::time::Instant::now();
        let result = client.single_read(&uri, region).await;
        let rtt_ms = t0.elapsed().as_millis() as u32;
        let probe = match result {
            Ok(bytes) => ProbeResult {
                region: Some(region),
                bytes,
                error: None,
                rtt_ms,
            },
            Err(e) => ProbeResult {
                region: Some(region),
                bytes: Vec::new(),
                error: Some(e.to_string()),
                rtt_ms,
            },
        };
        self.state.lock().last_probe = probe;
    }

    async fn write(&mut self, region: MemRegion, data: Vec<u8>) {
        let uri = self.state.lock().selected_uri.clone();
        let (Some(client), Some(uri)) = (self.client.as_mut(), uri) else {
            tracing::warn!("snes.write dropped: not connected / no device");
            return;
        };
        if let Err(e) = client.single_write(&uri, region, data).await {
            tracing::warn!(
                "snes.write to 0x{:06X} failed: {e}",
                region.address
            );
        }
    }
}
