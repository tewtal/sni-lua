//! Side-effecting script services that must not block the frame: persistent
//! storage and HTTP.
//!
//! Both follow the same rule the rest of the API does — `on_frame` never
//! `.await`s and never touches the disk or network synchronously:
//!
//! * **Store.** A per-script JSON document held in memory. `store.get/set`
//!   mutate it; `store.save/load` expose the whole blob. Writes are debounced
//!   and flushed to disk on a background blocking task (and once on exit), so
//!   a chatty script can't stall the UI on `fsync`.
//! * **HTTP.** `http.get/post/...` spawn a `reqwest` future on the shared
//!   Tokio runtime and return immediately. Completed responses are drained
//!   into the Lua VM by [`ScriptHost::run_frame`] *before* `on_frame`, so the
//!   user's callback runs on the UI thread with no re-entrancy.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use parking_lot::Mutex;
use serde_json::Value as Json;
use tokio::sync::mpsc;

// ---------------------------------------------------------------------------
// Persistent key-value / blob store
// ---------------------------------------------------------------------------

/// The script-visible document. Always a JSON object at the top level so
/// `store.get/set` and `store.save/load` operate on the same value.
#[derive(Debug, Default)]
pub struct Store {
    /// Current in-memory document (a JSON object).
    data: Mutex<serde_json::Map<String, Json>>,
    /// Where it persists. `None` disables persistence (tests / no script).
    path: Mutex<Option<PathBuf>>,
    /// Set by any mutation, cleared by a flush. Lets the app skip disk I/O
    /// when nothing changed.
    dirty: Mutex<bool>,
}

impl Store {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Point the store at a script's file and load it (best-effort: a missing
    /// or corrupt file just starts empty, logged). Called on script (re)load.
    pub fn bind(&self, path: PathBuf) {
        let loaded = match std::fs::read_to_string(&path) {
            Ok(s) => match serde_json::from_str::<Json>(&s) {
                Ok(Json::Object(m)) => m,
                Ok(_) => {
                    tracing::warn!("store {path:?}: not a JSON object; starting empty");
                    Default::default()
                }
                Err(e) => {
                    tracing::warn!("store {path:?} parse failed ({e}); starting empty");
                    Default::default()
                }
            },
            Err(_) => Default::default(), // no file yet — normal on first run
        };
        *self.data.lock() = loaded;
        *self.path.lock() = Some(path);
        *self.dirty.lock() = false;
    }

    /// Drop the binding without writing (used when no script is loaded).
    pub fn unbind(&self) {
        *self.path.lock() = None;
    }

    pub fn get(&self, key: &str) -> Option<Json> {
        self.data.lock().get(key).cloned()
    }

    pub fn set(&self, key: String, value: Json) {
        self.data.lock().insert(key, value);
        *self.dirty.lock() = true;
    }

    pub fn remove(&self, key: &str) {
        if self.data.lock().remove(key).is_some() {
            *self.dirty.lock() = true;
        }
    }

    /// Replace the entire document (`store.save(table)`).
    pub fn replace(&self, obj: serde_json::Map<String, Json>) {
        *self.data.lock() = obj;
        *self.dirty.lock() = true;
    }

    /// Snapshot the whole document (`store.load()`).
    pub fn snapshot(&self) -> serde_json::Map<String, Json> {
        self.data.lock().clone()
    }

    /// Flush to disk if dirty. Cheap no-op when clean, so the app can call it
    /// every frame. Serialization happens under the lock (documents are small
    /// — a few KB of script state); the write itself is the only syscall.
    pub fn flush_if_dirty(&self) {
        if !*self.dirty.lock() {
            return;
        }
        let Some(path) = self.path.lock().clone() else {
            *self.dirty.lock() = false; // nowhere to go; don't spin
            return;
        };
        let text = serde_json::to_string_pretty(&Json::Object(self.data.lock().clone()));
        *self.dirty.lock() = false;
        if let Ok(text) = text {
            if let Err(e) = atomic_write(&path, text.as_bytes()) {
                tracing::warn!("store flush to {path:?} failed: {e}");
            }
        }
    }
}

/// Write via a temp file + rename so a crash mid-write can't truncate the
/// existing save. Same pattern the config uses, kept local to avoid a dep.
fn atomic_write(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path)
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

/// A request the script asked for, handed to the Tokio side to execute.
pub struct HttpRequest {
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    pub timeout_ms: u64,
    /// Correlates the eventual response back to the script's callback.
    pub id: u64,
}

/// The outcome, delivered back to the UI thread for the next `run_frame`.
pub struct HttpResponse {
    pub id: u64,
    /// `Ok` carries the HTTP exchange (any status, including 4xx/5xx — that's
    /// not a transport error). `Err` is a transport/timeout/DNS failure.
    pub result: Result<HttpOk, String>,
}

pub struct HttpOk {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

/// Channels bridging the single-threaded Lua host and the Tokio worker.
/// `reqwest::Client` is cheap to clone and pools connections, so one is shared.
pub struct HttpBridge {
    req_tx: mpsc::UnboundedSender<HttpRequest>,
    pub resp_rx: Mutex<mpsc::UnboundedReceiver<HttpResponse>>,
    next_id: Mutex<u64>,
    /// In-flight request count. Caps concurrency so a script looping
    /// `http.get` can't spawn unbounded tasks / sockets. Incremented in
    /// `submit`, decremented by the worker when the response is dispatched.
    in_flight: AtomicUsize,
    /// Pending Lua callbacks keyed by request id. `mlua` values aren't `Send`,
    /// so callbacks live here on the UI thread, never crossing to Tokio.
    pub pending: Mutex<HashMap<u64, mlua::RegistryKey>>,
}

/// Max simultaneous in-flight HTTP requests. Generous for REST polling,
/// low enough that a runaway script is bounded.
pub const HTTP_MAX_IN_FLIGHT: usize = 16;

impl HttpBridge {
    /// Spawn the HTTP worker on the *current* Tokio runtime. Must be called
    /// from within `rt.enter()` (the app already establishes one).
    pub fn spawn() -> Arc<Self> {
        let (req_tx, mut req_rx) = mpsc::unbounded_channel::<HttpRequest>();
        let (resp_tx, resp_rx) = mpsc::unbounded_channel::<HttpResponse>();

        let bridge = Arc::new(Self {
            req_tx,
            resp_rx: Mutex::new(resp_rx),
            next_id: Mutex::new(1),
            in_flight: AtomicUsize::new(0),
            pending: Mutex::new(HashMap::new()),
        });

        // The worker decrements the in-flight count as each request finishes;
        // give it a handle to do so.
        let counter = bridge.clone();
        tokio::spawn(async move {
            let client = match reqwest::Client::builder()
                .user_agent(concat!("sni-lua/", env!("CARGO_PKG_VERSION")))
                .build()
            {
                Ok(c) => c,
                Err(e) => {
                    tracing::error!("HTTP client init failed: {e}");
                    return;
                }
            };
            while let Some(req) = req_rx.recv().await {
                let client = client.clone();
                let resp_tx = resp_tx.clone();
                let counter = counter.clone();
                // One task per request so a slow endpoint can't head-of-line
                // block other in-flight calls.
                tokio::spawn(async move {
                    let resp = HttpResponse {
                        id: req.id,
                        result: execute(&client, req).await,
                    };
                    counter.in_flight.fetch_sub(1, Ordering::Relaxed);
                    let _ = resp_tx.send(resp);
                });
            }
        });

        bridge
    }

    /// Allocate an id and enqueue a request. Returns `None` (request dropped)
    /// if the concurrency cap is already reached, so the host can warn the
    /// script instead of growing tasks without bound. On success the id is
    /// returned so the host can stash the Lua callback under it before any
    /// response can arrive.
    pub fn submit(&self, mut req: HttpRequest) -> Option<u64> {
        // Reserve a slot atomically; back out if we'd exceed the cap.
        let prev = self.in_flight.fetch_add(1, Ordering::Relaxed);
        if prev >= HTTP_MAX_IN_FLIGHT {
            self.in_flight.fetch_sub(1, Ordering::Relaxed);
            return None;
        }
        let id = {
            let mut n = self.next_id.lock();
            let id = *n;
            *n += 1;
            id
        };
        req.id = id;
        if self.req_tx.send(req).is_err() {
            // Worker is gone; release the slot we reserved.
            self.in_flight.fetch_sub(1, Ordering::Relaxed);
            return None;
        }
        Some(id)
    }
}

async fn execute(client: &reqwest::Client, req: HttpRequest) -> Result<HttpOk, String> {
    let method = reqwest::Method::from_bytes(req.method.to_uppercase().as_bytes())
        .map_err(|_| format!("invalid HTTP method {:?}", req.method))?;
    let mut rb = client
        .request(method, &req.url)
        .timeout(std::time::Duration::from_millis(req.timeout_ms));
    for (k, v) in &req.headers {
        rb = rb.header(k.as_str(), v.as_str());
    }
    if let Some(body) = req.body {
        rb = rb.body(body);
    }
    let resp = rb.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let headers = resp
        .headers()
        .iter()
        .map(|(k, v)| {
            (
                k.as_str().to_string(),
                v.to_str().unwrap_or_default().to_string(),
            )
        })
        .collect();
    // `.text()` decodes per the response charset; lossy for non-text bodies,
    // which is fine — this API targets REST/JSON, not binary downloads.
    let body = resp.text().await.map_err(|e| e.to_string())?;
    Ok(HttpOk {
        status,
        headers,
        body,
    })
}
