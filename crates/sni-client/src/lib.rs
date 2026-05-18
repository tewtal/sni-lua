//! Thin, ergonomic async wrapper around the SNI gRPC API.
//!
//! The generated protobuf code lives in [`pb`]. Everything else here is a
//! convenience layer the rest of the app talks to so we never hand-roll
//! protobuf messages at call sites.

pub mod pb {
    //! Generated SNI protobuf + tonic client code.
    //!
    //! SNI's proto has no `package`, so tonic-build emits the default-package
    //! file (`_.rs`). We include it here under our own module name; this keeps
    //! the on-wire gRPC service paths exactly `/Devices/...`, `/DeviceMemory/...`
    //! — adding a proto package would make the server reject calls with
    //! `unknown service sni.Devices`.
    include!(concat!(env!("OUT_DIR"), "/_.rs"));
}

use std::time::Duration;

use thiserror::Error;
use tonic::transport::{Channel, Endpoint};

pub use pb::{AddressSpace, DeviceCapability, MemoryMapping};

/// SNI's default gRPC port.
pub const DEFAULT_GRPC_PORT: u16 = 8191;

#[derive(Debug, Error)]
pub enum SniError {
    #[error("transport: {0}")]
    Transport(#[from] tonic::transport::Error),
    #[error("rpc: {0}")]
    Status(#[from] tonic::Status),
    #[error("no devices connected to SNI")]
    NoDevices,
    #[error("device `{0}` not found")]
    DeviceNotFound(String),
    #[error("response was missing the expected payload")]
    EmptyResponse,
}

pub type Result<T> = std::result::Result<T, SniError>;

/// A described region of SNES memory to read or write.
///
/// We keep the address space + mapping with every region so that callers
/// (the cache engine, Lua API) don't have to thread mapping state around.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct MemRegion {
    pub address: u32,
    pub size: u32,
    pub space: AddressSpace,
    pub mapping: MemoryMapping,
}

impl MemRegion {
    /// A region in the FxPakPro address space (the SNI default). For Super
    /// Metroid WRAM watches you'll use e.g. `0xF50000 + offset`.
    pub fn fxpak(address: u32, size: u32) -> Self {
        Self {
            address,
            size,
            space: AddressSpace::FxPakPro,
            mapping: MemoryMapping::Unknown,
        }
    }

    /// WRAM offset helper: SNES `$7E0000..$7FFFFF` maps to FxPakPro
    /// `$F5_0000..$F6_FFFF`. `wram(0x0954, 2)` reads Samus X position.
    pub fn wram(offset: u32, size: u32) -> Self {
        Self::fxpak(0xF5_0000 + offset, size)
    }

    fn to_read_req(self) -> pb::ReadMemoryRequest {
        pb::ReadMemoryRequest {
            request_address: self.address,
            request_address_space: self.space as i32,
            request_memory_mapping: self.mapping as i32,
            size: self.size,
        }
    }
}

/// A connected device as reported by SNI.
#[derive(Debug, Clone)]
pub struct DeviceInfo {
    pub uri: String,
    pub display_name: String,
    pub kind: String,
    pub capabilities: Vec<i32>,
    pub default_space: AddressSpace,
}

/// Connected SNI client. Cheap to clone (tonic channels are `Arc` internally),
/// so share one across the app and the poll task.
#[derive(Clone)]
pub struct SniClient {
    devices: pb::devices_client::DevicesClient<Channel>,
    memory: pb::device_memory_client::DeviceMemoryClient<Channel>,
    control: pb::device_control_client::DeviceControlClient<Channel>,
}

impl SniClient {
    /// Connect to a SNI server over plaintext gRPC (h2c). SNI listens on
    /// `127.0.0.1:8191` by default and does not use TLS locally.
    pub async fn connect(addr: impl Into<String>) -> Result<Self> {
        let endpoint = Endpoint::from_shared(addr.into())?
            .connect_timeout(Duration::from_secs(5))
            .tcp_nodelay(true) // latency matters more than throughput here
            .http2_keep_alive_interval(Duration::from_secs(15));
        let channel = endpoint.connect().await?;
        Ok(Self {
            devices: pb::devices_client::DevicesClient::new(channel.clone()),
            memory: pb::device_memory_client::DeviceMemoryClient::new(channel.clone()),
            control: pb::device_control_client::DeviceControlClient::new(channel),
        })
    }

    /// Connect using just a host (defaults to the SNI gRPC port).
    pub async fn connect_local() -> Result<Self> {
        Self::connect(format!("http://127.0.0.1:{DEFAULT_GRPC_PORT}")).await
    }

    pub async fn list_devices(&mut self) -> Result<Vec<DeviceInfo>> {
        let resp = self
            .devices
            .list_devices(pb::DevicesRequest { kinds: vec![] })
            .await?
            .into_inner();
        Ok(resp
            .devices
            .into_iter()
            .map(|d| DeviceInfo {
                uri: d.uri,
                display_name: d.display_name,
                kind: d.kind,
                capabilities: d.capabilities,
                default_space: AddressSpace::try_from(d.default_address_space)
                    .unwrap_or(AddressSpace::FxPakPro),
            })
            .collect())
    }

    /// Pick the first connected device, preferring an fxpakpro device since
    /// that's the bandwidth-constrained case this whole app is built around.
    pub async fn first_device(&mut self) -> Result<DeviceInfo> {
        let mut devices = self.list_devices().await?;
        if devices.is_empty() {
            return Err(SniError::NoDevices);
        }
        if let Some(idx) = devices.iter().position(|d| d.kind == "fxpakpro") {
            return Ok(devices.swap_remove(idx));
        }
        Ok(devices.swap_remove(0))
    }

    /// Read one region. Prefer [`Self::multi_read`] for multiple regions —
    /// every round trip costs latency on real hardware.
    pub async fn single_read(&mut self, uri: &str, region: MemRegion) -> Result<Vec<u8>> {
        let resp = self
            .memory
            .single_read(pb::SingleReadMemoryRequest {
                uri: uri.to_string(),
                request: Some(region.to_read_req()),
            })
            .await?
            .into_inner();
        Ok(resp.response.ok_or(SniError::EmptyResponse)?.data)
    }

    /// Batch-read many regions in one round trip. This is the workhorse the
    /// poll engine uses to amortize FXPAK latency across all active watches.
    pub async fn multi_read(
        &mut self,
        uri: &str,
        regions: &[MemRegion],
    ) -> Result<Vec<Vec<u8>>> {
        let requests = regions.iter().map(|r| r.to_read_req()).collect();
        let resp = self
            .memory
            .multi_read(pb::MultiReadMemoryRequest {
                uri: uri.to_string(),
                requests,
            })
            .await?
            .into_inner();
        Ok(resp.responses.into_iter().map(|r| r.data).collect())
    }

    /// Write a region (used by Lua `snes.write`).
    pub async fn single_write(
        &mut self,
        uri: &str,
        region: MemRegion,
        data: Vec<u8>,
    ) -> Result<()> {
        self.memory
            .single_write(pb::SingleWriteMemoryRequest {
                uri: uri.to_string(),
                request: Some(pb::WriteMemoryRequest {
                    request_address: region.address,
                    request_address_space: region.space as i32,
                    request_memory_mapping: region.mapping as i32,
                    data,
                }),
            })
            .await?;
        Ok(())
    }

    pub async fn detect_mapping(&mut self, uri: &str) -> Result<MemoryMapping> {
        let resp = self
            .memory
            .mapping_detect(pb::DetectMemoryMappingRequest {
                uri: uri.to_string(),
                fallback_memory_mapping: Some(MemoryMapping::LoRom as i32),
                rom_header00_ffb0: None,
            })
            .await?
            .into_inner();
        Ok(MemoryMapping::try_from(resp.memory_mapping).unwrap_or(MemoryMapping::Unknown))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wram_maps_into_fxpak_space() {
        // SNES WRAM $7E:0000 lives at FxPakPro $F5_0000. Super Metroid's
        // Samus X position is WRAM $7E:0AF6, so the helper must land at
        // $F5_0AF6 in the FxPakPro space.
        let r = MemRegion::wram(0x0AF6, 2);
        assert_eq!(r.address, 0xF5_0AF6);
        assert_eq!(r.size, 2);
        assert_eq!(r.space, AddressSpace::FxPakPro);
    }

    #[test]
    fn read_req_carries_space_and_mapping_discriminants() {
        // The protobuf wire form uses i32 enum discriminants; a mismatch here
        // would silently read the wrong device address space.
        let req = MemRegion::fxpak(0x00_FFB0, 0x30).to_read_req();
        assert_eq!(req.request_address, 0x00_FFB0);
        assert_eq!(req.size, 0x30);
        assert_eq!(req.request_address_space, AddressSpace::FxPakPro as i32);
        assert_eq!(req.request_address_space, 0); // FxPakPro = 0 in sni.proto
    }
}
