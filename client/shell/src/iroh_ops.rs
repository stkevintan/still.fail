//! Iroh mesh endpoints, connections, relays, and DHT/path inspection (`iroh.*`, `conn.*`, `dht.said`).

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::{Arc, Mutex, RwLock};

use iroh::endpoint::{Connection, QuicTransportConfig, presets::Minimal};
use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey, Watcher};
use serde_json::{Value, json};

use crate::istream::Halves;
use crate::{Answer, Done, Handle, Inner, err, id_of, keep, mesh, str_of};

const MDNS_SERVICE: &str = "stillfail";

/// The nodes a DHT starts from: n0-mainline's defaults, with ours (cloud/dht-node, on the relays' machines) in place of relay.pkarr.org.
fn dht() -> n0_mainline::DhtBuilder {
    let mut dht = n0_mainline::DhtBuilder::default();
    dht.bootstrap(&[
        "router.bittorrent.com:6881",
        "dht.transmissionbt.com:6881",
        "dht.libtorrent.org:25401",
        "39.105.157.122:6881",
        "47.79.40.84:6881",
        "120.24.233.158:6881",
    ]);
    dht
}

/// The connections coming to an endpoint whose handshakes are done, as each finishes (`iroh.accept`), once one was
/// first asked for.
pub(crate) type Accepted = Arc<tokio::sync::Mutex<Option<tokio::sync::mpsc::UnboundedReceiver<Connection>>>>;

/// What an endpoint keeps beside iroh's own: the connections whose handshakes are done (`iroh.accept`); a station's
/// keepers on relays it is not home on (`iroh.keep`), and those it is home on (bound with); the next connections to come
/// held unanswered, not even their handshake (`iroh.holdIncoming`), and those held.
#[derive(Default)]
pub(crate) struct Kept {
    pub(crate) mesh: mesh::Scopes,
    pub(crate) accepted: Accepted,
    pub(crate) keepers: Mutex<HashMap<String, tokio::task::JoinHandle<()>>>,
    /// The relays it was bound with, and those of them it is home on now (one removed is home no more: a keeper is
    /// wanted there once it is kept on it again, unless it is inserted again first, home again).
    pub(crate) bound: Vec<RelayUrl>,
    pub(crate) homes: Mutex<Vec<RelayUrl>>,
    pub(crate) held: Mutex<(u32, Vec<iroh::endpoint::Incoming>)>,
    /// Relay URLs permitted in DHT/mDNS address lookup responses for `lookup: true` client endpoints.
    pub(crate) lookup_relays: Option<Arc<RwLock<BTreeSet<RelayUrl>>>>,
}

/// Which of a connection's ways it goes by now (an index into them, each said as whether iroh selected it, whether it
/// is a relay's, and the datagrams sent on it): the one iroh selected; where it selected none while the connection
/// carries on (two connections of one endpoint to the same other, a way moved between a machine's interfaces: Windows to
/// Windows on several networks), the way the packets go, a direct one before a relay's and the busiest first; with none
/// sent yet, the only way there is, or the first where every way is direct. None only where it may still be a relay's.
/// (station/native/mesh's `chosen_way`, the same.)
fn chosen_way(ways: &[(bool, bool, u64)]) -> Option<usize> {
    if let Some(i) = ways.iter().position(|w| w.0) {
        return Some(i);
    }
    let busiest = ways.iter().enumerate().filter(|(_, w)| w.2 > 0).max_by_key(|(i, w)| (!w.1, w.2, std::cmp::Reverse(*i)));
    if let Some((i, _)) = busiest {
        return Some(i);
    }
    (ways.len() == 1 || (!ways.is_empty() && ways.iter().all(|w| !w.1))).then_some(0)
}

/// The connections' transport (the station's addon's `transport`): the congestion controller named, Cubic or BBR (opt
/// in; noq-proto includes fixes for n0-computer/noq#852 idle max_bw collapse and n0-computer/noq#802 initial startup
/// pacing rate, and BBR uses `loss_thresh(0.30)` + `gate_lower_bounds_on_loss_thresh(true)` so cross-border 10–25%
/// random loss does not collapse long-lived connections to `min_pipe_cwnd` while keeping steady-state zero
/// retransmissions under shallow-buffer congestion), each with a 256 KiB initial window; a 4 MiB per-stream receive
/// window matching 4 MiB transfer chunks; each path kept alive each second and given up after 3 s of silence, so one
/// connection goes on through another relay as one goes; a link kept 10 minutes in silence (an app frozen in the
/// background past iroh's 30 s came back to every link timed out).
fn transport(congestion: &str) -> Result<QuicTransportConfig, String> {
    let controller: Arc<dyn noq_proto::congestion::ControllerFactory + Send + Sync> = match congestion {
        "cubic" => {
            let mut config = noq_proto::congestion::CubicConfig::default();
            config.initial_window(256 * 1024);
            Arc::new(config)
        }
        "bbr" => {
            let mut config = noq_proto::congestion::Bbr3Config::default();
            config
                .initial_window(256 * 1024)
                .loss_thresh(0.30)
                .gate_lower_bounds_on_loss_thresh(true);
            Arc::new(config)
        }
        _ => return Err("congestion: expected cubic or bbr".into()),
    };
    Ok(QuicTransportConfig::builder()
        .congestion_controller_factory(controller)
        .stream_receive_window(iroh::endpoint::VarInt::from_u32(4 * 1024 * 1024))
        .datagram_send_buffer_size(4 * 1024 * 1024)
        .datagram_receive_buffer_size(Some(4 * 1024 * 1024))
        .default_path_keep_alive_interval(std::time::Duration::from_secs(1))
        .default_path_max_idle_timeout(std::time::Duration::from_secs(3))
        .max_idle_timeout(Some(iroh::endpoint::VarInt::from_u32(10 * 60_000).into()))
        .build())
}

/// How long a connection coming in may take over its handshake, as the station's addon has it (station/native/mesh
/// HANDSHAKE_TIMEOUT, which says why): unbounded, the idle timeout above kept the station's half of a handshake whose
/// device let go of it sending through the relay for ten minutes, all dropped there.
const HANDSHAKE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// A connection's handshake as it comes in, given up after `limit` (dropped, so it sends no more); one that fails or
/// is given up is said, where it came from and how long it took (the station's addon's `handshake`).
async fn handshake<C, E: std::fmt::Display>(
    from: impl std::fmt::Debug,
    incoming: impl std::future::IntoFuture<Output = Result<C, E>>,
    limit: std::time::Duration,
) -> Option<C> {
    let started = tokio::time::Instant::now();
    match tokio::time::timeout(limit, incoming).await {
        Ok(Ok(conn)) => Some(conn),
        Ok(Err(error)) => {
            crate::log::info(&format!("mesh: a connection's handshake failed from {from:?} after {} ms: {error:#}", started.elapsed().as_millis()));
            None
        }
        Err(_) => {
            crate::log::info(&format!("mesh: a connection's handshake failed from {from:?} after {} ms: given up, not done in {} s", started.elapsed().as_millis(), limit.as_secs()));
            None
        }
    }
}

/// A way of finding stations (mDNS, the DHT) that could not be made leaves a station's endpoint without it, said, as
/// the station's addon has it: mDNS binds UDP 5353, which fails with no network up yet or the port held by another
/// program, and the endpoint failing left the station off the mesh until it was restarted.
#[derive(Debug)]
struct Optional<B>(&'static str, B);

#[derive(Debug)]
struct Unmade<L>(Option<L>);

impl<B: iroh::address_lookup::AddressLookupBuilder> iroh::address_lookup::AddressLookupBuilder for Optional<B> {
    fn into_address_lookup(self, endpoint: &Endpoint) -> Result<impl iroh::address_lookup::AddressLookup, iroh::address_lookup::AddressLookupBuilderError> {
        Ok(Unmade(match self.1.into_address_lookup(endpoint) {
            Ok(lookup) => Some(lookup),
            Err(error) => {
                crate::log::info(&format!("mesh: stations not found through {}: {error:#}", self.0));
                None
            }
        }))
    }
}

impl<L: iroh::address_lookup::AddressLookup> iroh::address_lookup::AddressLookup for Unmade<L> {
    fn publish(&self, data: &iroh::address_lookup::EndpointData) {
        if let Some(lookup) = &self.0 {
            lookup.publish(data);
        }
    }

    fn resolve(&self, endpoint_id: EndpointId) -> Option<n0_future::boxed::BoxStream<Result<iroh::address_lookup::Item, iroh::address_lookup::Error>>> {
        self.0.as_ref().and_then(|lookup| lookup.resolve(endpoint_id))
    }
}

/// Strips relay URLs outside `allowed` from DHT/mDNS address lookup responses while keeping IP and custom transports.
#[derive(Debug)]
struct FilteredLookup<B>(Arc<RwLock<BTreeSet<RelayUrl>>>, B);

#[derive(Debug)]
struct Filtered<L>(Arc<RwLock<BTreeSet<RelayUrl>>>, L);

fn filter_lookup_item(item: iroh::address_lookup::Item, allowed: &BTreeSet<RelayUrl>) -> iroh::address_lookup::Item {
    let provenance = item.provenance();
    let last_updated = item.last_updated();
    let old = item.endpoint_info();
    let addrs = old.data.addrs().filter(|a| match a {
        iroh::TransportAddr::Relay(url) => allowed.contains(url),
        _ => true,
    }).cloned();
    let mut data = iroh::address_lookup::EndpointData::new(addrs.collect());
    if let Some(user_data) = old.data.user_data() {
        data = data.with_user_data(user_data.clone());
    }
    let info = iroh::address_lookup::EndpointInfo::from_parts(old.endpoint_id, data);
    iroh::address_lookup::Item::new(info, provenance, last_updated)
}

impl<B: iroh::address_lookup::AddressLookupBuilder> iroh::address_lookup::AddressLookupBuilder for FilteredLookup<B> {
    fn into_address_lookup(self, endpoint: &Endpoint) -> Result<impl iroh::address_lookup::AddressLookup, iroh::address_lookup::AddressLookupBuilderError> {
        Ok(Filtered(self.0, self.1.into_address_lookup(endpoint)?))
    }
}

impl<L: iroh::address_lookup::AddressLookup> iroh::address_lookup::AddressLookup for Filtered<L> {
    fn publish(&self, data: &iroh::address_lookup::EndpointData) {
        self.1.publish(data);
    }

    fn resolve(&self, endpoint_id: EndpointId) -> Option<n0_future::boxed::BoxStream<Result<iroh::address_lookup::Item, iroh::address_lookup::Error>>> {
        let allowed = self.0.clone();
        self.1.resolve(endpoint_id).map(|stream| {
            use n0_future::StreamExt;
            Box::pin(stream.map(move |res| res.map(|item| filter_lookup_item(item, &allowed.read().unwrap())))) as n0_future::boxed::BoxStream<_>
        })
    }
}

fn bytes_of(b: &'static [u8]) -> bytes::Bytes {
    bytes::Bytes::from_static(b)
}

/// The DSCP (1 to 63) every iroh packet of this process is marked with from a bind on: a station's front's
/// (`STILLFAIL_MESH_DSCP`; station/native/mesh/src/dscp.rs says why), never an app's, whose packets stay as they were.
/// One out of range, or on a system where packets cannot be marked, fails the bind: never silently unmarked.
fn mark_with_dscp(dscp: Option<&Value>) -> Result<(), String> {
    let Some(dscp) = dscp.filter(|v| !v.is_null()) else { return Ok(()) };
    let dscp = dscp.as_u64().and_then(|d| u8::try_from(d).ok()).filter(|d| (1..=63).contains(d)).ok_or_else(|| format!("the DSCP to mark the mesh's packets with must be 1 to 63, not {dscp}"))?;
    if !cfg!(any(target_os = "linux", target_os = "android", target_os = "macos")) {
        return Err(format!("the mesh's packets cannot be marked with a DSCP ({dscp}) on this system"));
    }
    noq_udp::set_dscp(dscp);
    iroh::set_relay_dscp(dscp);
    Ok(())
}

fn relay_url(url: &str) -> Result<RelayUrl, String> {
    url.parse().map_err(err)
}

fn build_relay_allowlist(
    explicit: Option<Vec<RelayUrl>>,
    lookup: bool,
    allow_public: bool,
    relays: &[RelayUrl],
    entries: &[(RelayUrl, RelayUrl)],
) -> Option<Vec<RelayUrl>> {
    if let Some(mut list) = explicit {
        if lookup {
            list.extend(relays.iter().cloned());
        }
        list.extend(entries.iter().flat_map(|(entry, relay)| [entry.clone(), relay.clone()]));
        if allow_public {
            list.extend(iroh::defaults::prod::default_relay_map().relays::<Vec<_>>().into_iter().map(|c| c.url.clone()));
        }
        Some(list)
    } else if lookup && !relays.is_empty() {
        let mut list = relays.to_vec();
        list.extend(entries.iter().flat_map(|(entry, relay)| [entry.clone(), relay.clone()]));
        list.extend(iroh::defaults::prod::default_relay_map().relays::<Vec<_>>().into_iter().map(|c| c.url.clone()));
        Some(list)
    } else {
        None
    }
}

pub(crate) fn endpoint_addr(addr: &Value) -> Result<EndpointAddr, String> {
    let id = str_of(addr, "id")?;
    let bytes: [u8; 32] = hex::decode(id).map_err(err)?.try_into().map_err(|_| "the id is not 32 bytes".to_string())?;
    let mut out = EndpointAddr::new(EndpointId::from_bytes(&bytes).map_err(err)?);
    for url in addr.get("relays").and_then(Value::as_array).into_iter().flatten() {
        out = out.with_relay_url(relay_url(url.as_str().unwrap_or_default())?);
    }
    for ip in addr.get("ips").and_then(Value::as_array).into_iter().flatten() {
        out = out.with_ip_addr(ip.as_str().unwrap_or_default().parse::<std::net::SocketAddr>().map_err(err)?);
    }
    Ok(out)
}

fn close_info(error: &iroh::endpoint::ConnectionError) -> Value {
    use iroh::endpoint::ConnectionError;
    let mut info = match error {
        ConnectionError::ApplicationClosed(close) => json!({ "kind": "application", "reason": String::from_utf8_lossy(&close.reason) }),
        ConnectionError::LocallyClosed => json!({ "kind": "local", "reason": "" }),
        ConnectionError::TimedOut => json!({ "kind": "timeout", "reason": "" }),
        other => json!({ "kind": "other", "reason": other.to_string() }),
    };
    // (and in words, as the station's addon says it: its `closed`)
    info["text"] = json!(error.to_string());
    info
}

impl Inner {
    /// A connection kept for the core, and let go once it closes, however it does (closed here, by the other end, timed
    /// out): kept, a closed connection and the streams opened on it stayed in memory, iroh's tasks still going over
    /// them, and a phone whose links were replaced often held hundreds and grew gigabytes a minute (2026-10-19).
    pub(crate) fn keep_conn(self: &Arc<Self>, conn: Connection) -> u64 {
        let id = self.keep(Handle::Conn(conn.clone()));
        let inner = self.clone();
        tokio::spawn(async move {
            let reason = conn.closed().await;
            inner.release_conn(id, &reason);
        });
        id
    }

    /// A closed connection let go: what the core may still ask (`remoteId`, `alpn`, `closeReason`, `stats`) is kept, and its
    /// streams go, a read still waiting on one woken.
    fn release_conn(&self, id: u64, reason: &iroh::endpoint::ConnectionError) {
        let mut handles = self.handles.lock().unwrap();
        let gone = match handles.get(&id) {
            Some(Handle::Conn(conn)) => {
                let s = conn.stats();
                Handle::Gone {
                    remote: hex::encode(conn.remote_id().as_bytes()),
                    alpn: hex::encode(conn.alpn()),
                    reason: close_info(reason),
                    stats: json!({ "rxBytes": s.udp_rx.bytes, "txBytes": s.udp_tx.bytes }),
                }
            }
            _ => return,
        };
        handles.insert(id, gone);
        Self::release_streams(&mut handles, id);
    }

    /// Lets go of the streams of connection `id`, each reset for whoever still reads or writes it.
    fn release_streams(handles: &mut HashMap<u64, Handle>, id: u64) {
        let streams: Vec<u64> = handles.iter().filter_map(|(k, h)| matches!(h, Handle::IStream(halves) if halves.conn == id).then_some(*k)).collect();
        for k in streams {
            if let Some(Handle::IStream(halves)) = handles.remove(&k) {
                let _ = halves.reset.send(true);
            }
        }
    }

    async fn bind(self: &Arc<Self>, a: &Value, key: Vec<u8>) -> Done {
        let bytes: [u8; 32] = key.as_slice().try_into().map_err(|_| "the key is not 32 bytes".to_string())?;
        let key = SecretKey::from_bytes(&bytes);
        let key_again = key.clone();
        let relays: Vec<RelayUrl> = a.get("relayUrls").and_then(Value::as_array).into_iter().flatten().map(|u| relay_url(u.as_str().unwrap_or_default())).collect::<Result<_, _>>()?;
        let entries: Vec<(RelayUrl, RelayUrl)> = a.get("relayEntries").and_then(Value::as_array).into_iter().flatten().map(|e| Ok((relay_url(str_of(e, "entry")?)?, relay_url(str_of(e, "relay")?)?))).collect::<Result<_, String>>()?;
        let explicit_allowlist: Option<Vec<RelayUrl>> = a
            .get("relayAllowlist")
            .and_then(Value::as_array)
            .map(|urls| urls.iter().map(|u| relay_url(u.as_str().unwrap_or_default())).collect::<Result<_, _>>())
            .transpose()?;
        let allow_public = a.get("allowPublicRelays").and_then(Value::as_bool).unwrap_or(false);
        let lookup = a.get("lookup").and_then(Value::as_bool).unwrap_or(false);
        let lookup_active = lookup && !relays.is_empty();
        let allowlist = build_relay_allowlist(explicit_allowlist, lookup, allow_public, &relays, &entries);
        let lookup_relays = if lookup_active {
            allowlist.as_ref().map(|list| Arc::new(RwLock::new(list.iter().cloned().collect::<BTreeSet<_>>())))
        } else {
            None
        };
        let relay_map = iroh::RelayMap::from_iter(relays.iter().map(|relay| {
            iroh::RelayConfig::from(relay.clone()).with_entries(entries.iter().filter(|(_, target)| target == relay).map(|(entry, _)| entry.clone()))
        }));
        let alpns: Vec<Vec<u8>> = a.get("alpns").and_then(Value::as_array).into_iter().flatten().map(|x| hex::decode(x.as_str().unwrap_or_default()).map_err(err)).collect::<Result<_, _>>()?;
        mark_with_dscp(a.get("dscp"))?;
        let kept = Arc::new(Kept { homes: Mutex::new(relays.clone()), bound: relays.clone(), lookup_relays: lookup_relays.clone(), ..Kept::default() });
        let mut builder = Endpoint::builder(Minimal)
            .add_custom_transport(kept.mesh.hub.clone())
            .path_selector(Arc::new(mesh_transport::selection::Selector::new(kept.mesh.hub.clone())))
            .secret_key(key)
            .alpns(alpns)
            .relay_mode(if relays.is_empty() { RelayMode::Disabled } else { RelayMode::Custom(relay_map) })
            // Home on every relay at once, each path kept alive each second and given up after 3 s of silence: one
            // connection to a station goes through every relay it is on, and on through another as one goes (the
            // station's mesh addon: PATH_KEEP_ALIVE, PATH_IDLE).
            .home_on_every_relay()
            .transport_config(transport(a.get("congestion").and_then(Value::as_str).unwrap_or("cubic"))?);
        if !lookup_active {
            if let Some(allowlist) = allowlist {
                builder = builder.relay_allowlist(allowlist);
            }
        }
        // Where a station listens (its config's fixed port); any free port when not said.
        if let Some(addr) = a.get("bindAddr").and_then(Value::as_str) {
            builder = builder.bind_addr(addr.parse::<std::net::SocketAddr>().map_err(err)?).map_err(err)?;
        }
        if a.get("relayOnly").and_then(Value::as_bool).unwrap_or(false) {
            builder = builder.clear_ip_transports();
        }
        // The DHT unless `dht: false` (a company's filter marking the Mainline DHT as risky), mDNS either way: the
        // station's addon's `dht`.
        let with_dht = a.get("dht").and_then(Value::as_bool).unwrap_or(true);
        // Stations on the LAN (mDNS, never announced itself) and which relay they are on (the DHT), as client/core-ts's.
        if lookup_active {
            let mdns = iroh_mdns_address_lookup::MdnsAddressLookup::builder().service_name(MDNS_SERVICE).advertise(false);
            let dht_lookup = with_dht.then(|| iroh_mainline_address_lookup::DhtAddressLookup::builder().dht_builder(dht()).no_publish());
            if let Some(allowed) = lookup_relays {
                builder = builder.address_lookup(FilteredLookup(allowed.clone(), mdns));
                if let Some(dht_lookup) = dht_lookup {
                    builder = builder.address_lookup(FilteredLookup(allowed, dht_lookup));
                }
            } else {
                builder = builder.address_lookup(mdns);
                if let Some(dht_lookup) = dht_lookup {
                    builder = builder.address_lookup(dht_lookup);
                }
            }
        } else if a.get("discovery").and_then(Value::as_bool).unwrap_or(false) {
            // A station's: found on the LAN by mDNS and by its relay through the DHT, both announced (the station's
            // addon's `bind`), each left out, said, where it cannot be made (mDNS's port held, no network yet).
            builder = builder.address_lookup(Optional("mDNS", iroh_mdns_address_lookup::MdnsAddressLookup::builder().service_name(MDNS_SERVICE)));
            if with_dht {
                builder = builder.address_lookup(Optional("the DHT", iroh_mainline_address_lookup::DhtAddressLookup::builder().dht_builder(dht()).secret_key(key_again)));
            }
        }
        let endpoint = builder.bind().await.map_err(err)?;
        Ok(Answer::json(json!({ "id": self.keep(Handle::Endpoint(endpoint, kept)) })))
    }

    pub(crate) async fn run_iroh(self: &Arc<Self>, op: &str, a: &Value, bytes: Option<Vec<u8>>) -> Done {
        match op {
            "iroh.bind" => self.bind(a, bytes.unwrap_or_default()).await,
            "iroh.meshSubscribe" | "iroh.meshUnsubscribe" => {
                let Handle::Endpoint(_, kept) = self.handle(id_of(a)?)? else { return Err("not an endpoint".into()) };
                let socket = a.get("socket").and_then(Value::as_u64).ok_or("missing subscription socket")?;
                if op == "iroh.meshUnsubscribe" { kept.mesh.unsubscribe(socket); }
                else {
                    let Handle::Tcp { write, .. } = self.handle(socket)? else { return Err("not a control socket".into()) };
                    kept.mesh.subscribe(socket, write)?;
                }
                Ok(Answer::json(json!({})))
            }
            "iroh.meshAttachLeaf" | "iroh.meshUseLeaf" | "iroh.meshDetachLeaf" => {
                let Handle::Endpoint(endpoint, kept) = self.handle(id_of(a)?)? else { return Err("not an endpoint".into()) };
                if op == "iroh.meshAttachLeaf" {
                    let connection = a.get("connection").and_then(Value::as_u64).ok_or("missing leaf connection")?;
                    let Handle::Conn(connection) = self.handle(connection)? else { return Err("not a connection".into()) };
                    Ok(Answer::json(kept.mesh.attach_leaf(&endpoint, connection, a).await?))
                } else {
                    if op == "iroh.meshUseLeaf" { kept.mesh.use_leaf(&endpoint, a).await?; } else { kept.mesh.detach_leaf(a).await?; }
                    Ok(Answer::json(json!({})))
                }
            }
            "iroh.meshConfigure" | "iroh.meshRemove" => {
                let (endpoint, kept) = match self.handle(id_of(a)?)? {
                    Handle::Endpoint(endpoint, kept) => (endpoint, kept),
                    _ => return Err("not an endpoint".into()),
                };
                if op == "iroh.meshRemove" {
                    kept.mesh.remove(a).await?;
                    Ok(Answer::json(json!({})))
                } else {
                    Ok(Answer::json(kept.mesh.configure_root(&endpoint, a).await?))
                }
            }
            "iroh.connect" => {
                let (endpoint, kept) = match self.handle(id_of(a)?)? {
                    Handle::Endpoint(endpoint, kept) => (endpoint, kept),
                    Handle::Unbound { .. } => return Err("the endpoint is closed".into()),
                    _ => return Err("not an endpoint".into()),
                };
                let additional: Vec<Vec<u8>> = a.get("additional").and_then(Value::as_array).into_iter().flatten().filter_map(|x| hex::decode(x.as_str()?).ok()).collect();
                let mut options = iroh::endpoint::ConnectOptions::new().with_additional_alpns(additional);
                let said = a.get("addr").ok_or("missing addr")?;
                // Relays it is not to be reached through, though Address Lookup names them (a station's workspaces
                // turned them off: station/src/mesh/relays.ts `stationAddr`).
                if let Some(disabled) = said.get("disabledRelays").and_then(Value::as_array) {
                    let disabled: Vec<RelayUrl> = disabled.iter().map(|u| relay_url(u.as_str().unwrap_or_default())).collect::<Result<_, _>>()?;
                    options = options.with_disabled_relays(disabled);
                }
                let mut addr = endpoint_addr(said)?;
                if let Some(scope) = said.get("meshScope").and_then(Value::as_str) {
                    addr.addrs.insert(kept.mesh.address(scope, addr.id).await?);
                }
                let connecting = endpoint.connect_with_opts(addr, &bytes.unwrap_or_default(), options).await.map_err(err)?;
                let conn = connecting.await.map_err(err)?;
                Ok(Answer::json(json!({ "id": self.keep_conn(conn) })))
            }
            // As the station's addon takes them: handshakes side by side, each on its own, so one never finished (a
            // device gone half way) holds up no other; one that fails is skipped.
            "iroh.accept" => {
                let (endpoint, kept) = match self.handle(id_of(a)?)? {
                    Handle::Endpoint(endpoint, kept) => (endpoint, kept),
                    Handle::Unbound { .. } => return Ok(Answer::json(json!({ "end": true }))),
                    _ => return Err("not an endpoint".into()),
                };
                let mut accepted = kept.accepted.lock().await;
                let done = accepted.get_or_insert_with(|| {
                    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
                    let kept = kept.clone();
                    tokio::spawn(async move {
                        while let Some(incoming) = endpoint.accept().await {
                            {
                                let mut held = kept.held.lock().unwrap();
                                if held.0 > 0 {
                                    held.0 -= 1;
                                    held.1.push(incoming);
                                    continue;
                                }
                            }
                            let tx = tx.clone();
                            tokio::spawn(async move {
                                let from = incoming.remote_addr();
                                if let Some(conn) = handshake(from, incoming, HANDSHAKE_TIMEOUT).await {
                                    let _ = tx.send(conn);
                                }
                            });
                        }
                    });
                    rx
                });
                match done.recv().await {
                    Some(conn) => {
                        let alpn = hex::encode(conn.alpn());
                        Ok(Answer::json(json!({ "id": self.keep_conn(conn), "alpn": alpn })))
                    }
                    None => Ok(Answer::json(json!({ "end": true }))),
                }
            }
            "iroh.setRelayEntries" => {
                let (endpoint, kept) = match self.handle(id_of(a)?)? {
                    Handle::Endpoint(endpoint, kept) => (endpoint, kept),
                    Handle::Unbound { .. } => return Ok(Answer::json(json!({}))),
                    _ => return Err("not an endpoint".into()),
                };
                let mut entries = BTreeMap::<RelayUrl, Vec<RelayUrl>>::new();
                for entry in a.get("entries").and_then(Value::as_array).into_iter().flatten() {
                    entries.entry(relay_url(str_of(entry, "relay")?)?).or_default().push(relay_url(str_of(entry, "entry")?)?);
                }
                if let Some(allowed) = &kept.lookup_relays {
                    let mut guard = allowed.write().unwrap();
                    for (relay, list) in &entries {
                        guard.insert(relay.clone());
                        guard.extend(list.iter().cloned());
                    }
                }
                endpoint.set_relay_entries(entries.into_iter().collect()).await;
                Ok(Answer::json(json!({})))
            }
            "iroh.networkChange" => {
                let endpoint = match self.handle(id_of(a)?)? {
                    Handle::Endpoint(endpoint, _) => endpoint,
                    Handle::Unbound { .. } => return Ok(Answer::json(json!({}))),
                    _ => return Err("not an endpoint".into()),
                };
                endpoint.network_change().await;
                Ok(Answer::json(json!({})))
            }
            "iroh.close" => {
                let id = id_of(a)?;
                if let Ok(Handle::Endpoint(_, kept)) = self.handle(id) { kept.mesh.clear().await; }
                let forget = a.get("forget").and_then(Value::as_bool).unwrap_or(false);
                let endpoint = {
                    let mut handles = self.handles.lock().unwrap();
                    match handles.get(&id) {
                        // Let go entirely: nothing of it is asked after (the core's own endpoints, not a dial's).
                        Some(Handle::Endpoint(..)) if forget => {
                            let Some(Handle::Endpoint(endpoint, kept)) = handles.remove(&id) else { unreachable!() };
                            for (_, task) in kept.keepers.lock().unwrap().drain() {
                                task.abort();
                            }
                            Some(endpoint)
                        }
                        Some(Handle::Unbound { .. }) if forget => {
                            handles.remove(&id);
                            None
                        }
                        Some(Handle::Endpoint(endpoint, kept)) => {
                            for (_, task) in kept.keepers.lock().unwrap().drain() {
                                task.abort();
                            }
                            let endpoint = endpoint.clone();
                            handles.insert(id, Handle::Unbound { id: hex::encode(endpoint.id().as_bytes()) });
                            Some(endpoint)
                        }
                        _ => None,
                    }
                };
                if let Some(endpoint) = endpoint {
                    endpoint.close().await;
                }
                Ok(Answer::json(json!({})))
            }
            "conn.openBi" | "conn.openUni" | "conn.acceptBi" => {
                let on = id_of(a)?;
                let conn = match self.handle(on)? {
                    Handle::Conn(conn) => conn,
                    Handle::Gone { .. } if op == "conn.acceptBi" => return Ok(Answer::json(json!({ "end": true }))),
                    Handle::Gone { reason, .. } => return Err(format!("connection closed: {}", reason["reason"].as_str().unwrap_or(""))),
                    _ => return Err("not a connection".into()),
                };
                let (send, recv) = match op {
                    "conn.openBi" => {
                        let (s, r) = conn.open_bi().await.map_err(err)?;
                        (Some(s), Some(r))
                    }
                    "conn.openUni" => (Some(conn.open_uni().await.map_err(err)?), None),
                    _ => match conn.accept_bi().await {
                        Ok((s, r)) => (Some(s), Some(r)),
                        Err(_) => return Ok(Answer::json(json!({ "end": true }))),
                    },
                };
                let halves = Halves {
                    conn: on,
                    ended: (recv.is_none()).into(),
                    finished: false.into(),
                    send: tokio::sync::Mutex::new(send),
                    recv: tokio::sync::Mutex::new(recv),
                    reset: tokio::sync::watch::channel(false).0,
                    tap: Mutex::default(),
                    media_out: Default::default(),
                    media_in: Default::default(),
                    ack_dgram: Mutex::default(),
                    ack_in: Default::default(),
                    ack_ready: tokio::sync::watch::channel(false).0,
                };
                Ok(Answer::json(json!({ "id": self.keep(Handle::IStream(Arc::new(halves))) })))
            }
            "conn.closed" => match self.handle(id_of(a)?)? {
                Handle::Conn(conn) => Ok(Answer::json(close_info(&conn.closed().await))),
                Handle::Gone { reason, .. } => Ok(Answer::json(reason)),
                _ => Err("not a connection".into()),
            },
            "conn.close" => {
                let id = id_of(a)?;
                let forget = a.get("forget").and_then(Value::as_bool).unwrap_or(false);
                let conn = if forget {
                    // Let go entirely, its streams with it: `keep_conn`'s wait on its close then finds nothing to keep.
                    let mut handles = self.handles.lock().unwrap();
                    match handles.get(&id) {
                        None => return Err(format!("no handle {id}")),
                        Some(Handle::Conn(_)) => {
                            let Some(Handle::Conn(conn)) = handles.remove(&id) else { unreachable!() };
                            Self::release_streams(&mut handles, id);
                            conn
                        }
                        Some(Handle::Gone { .. }) => {
                            handles.remove(&id);
                            Self::release_streams(&mut handles, id);
                            return Ok(Answer::json(json!({})));
                        }
                        Some(_) => return Err("not a connection".into()),
                    }
                } else {
                    match self.handle(id)? {
                        Handle::Conn(conn) => conn,
                        Handle::Gone { .. } => return Ok(Answer::json(json!({}))),
                        _ => return Err("not a connection".into()),
                    }
                };
                let code = a.get("code").and_then(Value::as_u64).unwrap_or(0) as u32;
                conn.close(code.into(), a.get("reason").and_then(Value::as_str).unwrap_or("").as_bytes());
                Ok(Answer::json(json!({})))
            }
            // A station's endpoint (station/mb's front, which keeps it for the station's Node: the addon's `Endpoint`).
            // A station's peer's relays it is not to be reached through (`peer`, hex; `relays`; `public`: iroh's own
            // public relays too), in force once answered (iroh's `set_disabled_relays`): the addon's `disabled_relays`.
            "iroh.disabledRelays" => {
                let endpoint = match self.handle(id_of(a)?)? {
                    Handle::Endpoint(endpoint, _) => endpoint,
                    Handle::Unbound { .. } => return Err("the endpoint is closed".into()),
                    _ => return Err("not an endpoint".into()),
                };
                let bytes: [u8; 32] = hex::decode(str_of(a, "peer")?).map_err(err)?.try_into().map_err(|_| "the id is not 32 bytes".to_string())?;
                let peer = EndpointId::from_bytes(&bytes).map_err(err)?;
                let mut disabled: std::collections::BTreeSet<RelayUrl> = a.get("relays").and_then(Value::as_array).into_iter().flatten().map(|u| relay_url(u.as_str().unwrap_or_default())).collect::<Result<_, _>>()?;
                if a.get("public").and_then(Value::as_bool).unwrap_or(false) {
                    disabled.extend(iroh::defaults::prod::default_relay_map().relays::<Vec<_>>().iter().map(|c| c.url.clone()));
                }
                endpoint.set_disabled_relays(peer, disabled).await;
                Ok(Answer::json(json!({})))
            }
            // Whether the endpoint is reached through relay `url` now, end to end (keep.rs `probe`): `{ok: true}`, or
            // `{ok: false, stage}`, `probe_offline` where the relay is out of this machine's reach and `endpoint_failed`
            // where it is not but the endpoint is. The station's relays' watch asks it (station/src/mesh/relays.ts).
            "iroh.probeRelay" => {
                let endpoint = match self.handle(id_of(a)?)? {
                    Handle::Endpoint(endpoint, _) => endpoint,
                    Handle::Unbound { .. } => return Err("the endpoint is closed".into()),
                    _ => return Err("not an endpoint".into()),
                };
                let relay = relay_url(str_of(a, "url")?)?;
                let said = match keep::probe(&endpoint, &relay).await.stage() {
                    None => json!({ "ok": true }),
                    Some(stage) => json!({ "ok": false, "stage": stage }),
                };
                Ok(Answer::json(said))
            }
            "iroh.online" | "iroh.insertRelay" | "iroh.removeRelay" | "iroh.publicRelays" | "iroh.keep" | "iroh.setCongestion" | "iroh.setAlpns" | "iroh.holdIncoming" => {
                let (endpoint, kept) = match self.handle(id_of(a)?)? {
                    Handle::Endpoint(endpoint, kept) => (endpoint, kept),
                    Handle::Unbound { .. } => return Err("the endpoint is closed".into()),
                    _ => return Err("not an endpoint".into()),
                };
                match op {
                    // Once it is on its home relay (at once with relays off).
                    "iroh.online" => endpoint.online().await,
                    "iroh.insertRelay" => {
                        let url = relay_url(str_of(a, "url")?)?;
                        endpoint.insert_relay(url.clone(), Arc::new(iroh::RelayConfig::from(url.clone()))).await;
                        let mut homes = kept.homes.lock().unwrap();
                        if kept.bound.contains(&url) && !homes.contains(&url) {
                            homes.push(url);
                        }
                    }
                    // The protocols it takes from now on (`alpns`, hex), the connections it has kept: a binding that
                    // changes only these needs no endpoint of its own beside it (two of one key on the relays at once,
                    // the one closing refusing what comes to it).
                    "iroh.setAlpns" => {
                        let alpns: Vec<Vec<u8>> = a.get("alpns").and_then(Value::as_array).into_iter().flatten().map(|x| hex::decode(x.as_str().unwrap_or_default()).map_err(err)).collect::<Result<_, _>>()?;
                        endpoint.set_alpns(alpns);
                    }
                    // Off every relay transport: its connection there ended, no longer home there nor in its address.
                    "iroh.removeRelay" => {
                        let url = relay_url(str_of(a, "url")?)?;
                        endpoint.remove_relay(&url).await;
                        kept.homes.lock().unwrap().retain(|r| r != &url);
                    }
                    // iroh's own public relays: added while none of still.fail's answers, removed once one does.
                    "iroh.publicRelays" => {
                        let on = a.get("on").and_then(Value::as_bool).unwrap_or(false);
                        for config in iroh::defaults::prod::default_relay_map().relays::<Vec<_>>() {
                            if on {
                                endpoint.insert_relay(config.url.clone(), config.clone()).await;
                            } else {
                                endpoint.remove_relay(&config.url).await;
                            }
                        }
                    }
                    // On exactly these relays besides those it is home on: a keeper for each new one, those of relays no
                    // longer named stopped.
                    "iroh.keep" => {
                        let mut relays: Vec<RelayUrl> = a.get("urls").and_then(Value::as_array).into_iter().flatten().map(|u| relay_url(u.as_str().unwrap_or_default())).collect::<Result<_, _>>()?;
                        let homes = kept.homes.lock().unwrap().clone();
                        relays.retain(|r| !homes.contains(r));
                        let urls: Vec<String> = relays.iter().map(ToString::to_string).collect();
                        let mut keepers = kept.keepers.lock().unwrap();
                        keepers.retain(|url, task| {
                            let named = urls.contains(url);
                            if !named {
                                task.abort();
                            }
                            named
                        });
                        for relay in relays {
                            let endpoint = endpoint.clone();
                            keepers.entry(relay.to_string()).or_insert_with(|| tokio::spawn(keep::keep(endpoint, relay)));
                        }
                    }
                    // The controller of the connections made from now on.
                    "iroh.setCongestion" => endpoint.set_transport_config(transport(str_of(a, "congestion")?)?),
                    // The next `n` connections coming never answered, not even their handshake (tests: a device whose way
                    // here is gone).
                    _ => kept.held.lock().unwrap().0 = a.get("n").and_then(Value::as_u64).unwrap_or(0) as u32,
                }
                Ok(Answer::json(json!({})))
            }
            // Whether the other end is still there: asked with a datagram (which a live end acknowledges at once) a few
            // times within `within` ms, true as soon as anything is heard from it (the addon's `answers`, which says why).
            "conn.answers" => {
                let conn = match self.handle(id_of(a)?)? {
                    Handle::Conn(conn) => conn,
                    Handle::Gone { .. } => return Ok(Answer::json(json!(false))),
                    _ => return Err("not a connection".into()),
                };
                let within = std::time::Duration::from_millis(a.get("within").and_then(Value::as_u64).unwrap_or(0));
                let heard = conn.stats().udp_rx.datagrams;
                let deadline = std::time::Instant::now() + within;
                let mut ask = std::time::Instant::now();
                let answers = loop {
                    if conn.close_reason().is_some() {
                        break false;
                    }
                    if conn.stats().udp_rx.datagrams > heard {
                        break true;
                    }
                    let now = std::time::Instant::now();
                    if now >= deadline {
                        break false;
                    }
                    if now >= ask {
                        match conn.send_datagram(bytes_of(&[0])) {
                            Ok(()) => {}
                            Err(iroh::endpoint::SendDatagramError::ConnectionLost(_)) => break false,
                            Err(_) => break true,
                        }
                        ask = now + within / 3;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
                };
                Ok(Answer::json(json!(answers)))
            }
            other => Err(format!("no operation {other}")),
        }
    }

    pub(crate) fn run_iroh_sync(&self, op: &str, a: &Value) -> Result<Value, String> {
        // What the DHT lookup's socket and lookups went through since the last take, while the core records (`keep`;
        // false: none kept from now on): the record's `dht:` lines (client/core-ts mesh.ts, vendor/n0-mainline's `stillfail`).
        if op == "dht.said" {
            let (lines, dropped) = n0_mainline::stillfail::said(a.get("keep").and_then(Value::as_bool).unwrap_or(false));
            return Ok(json!({ "lines": lines.into_iter().map(|s| json!({ "at": s.at_ms, "text": s.text })).collect::<Vec<_>>(), "dropped": dropped }));
        }
        let handle = self.handle(id_of(a)?)?;
        match (op, handle) {
            ("iroh.endpointId", Handle::Endpoint(e, _)) => Ok(json!(hex::encode(e.id().as_bytes()))),
            ("iroh.addAddr", Handle::Endpoint(e, _)) => {
                let addr = endpoint_addr(a.get("addr").ok_or("missing addr")?)?;
                e.address_lookup().map_err(err)?.add(iroh::address_lookup::MemoryLookup::from_endpoint_info([addr]));
                Ok(Value::Null)
            }
            ("iroh.sockets", Handle::Endpoint(e, _)) => Ok(json!(e.bound_sockets().iter().map(ToString::to_string).collect::<Vec<_>>())),
            ("iroh.sockets", Handle::Unbound { .. }) => Ok(json!([])),
            // How it runs now: "relay", "direct", or null while none is chosen.
            ("conn.via", Handle::Conn(c)) => {
                let paths = c.paths();
                let ways: Vec<_> = paths.iter().collect();
                let chosen = chosen_way(&ways.iter().map(|p| (p.is_selected(), p.is_relay(), p.stats().udp_tx.datagrams)).collect::<Vec<_>>());
                Ok(chosen.map(|i| json!(if ways[i].is_relay() { "relay" } else { "direct" })).unwrap_or(Value::Null))
            }
            ("conn.via", Handle::Gone { .. }) => Ok(Value::Null),
            ("iroh.relayStatus", Handle::Endpoint(e, _)) => Ok(Value::Array(e.home_relay_status().get().iter().map(|s| json!({ "url": s.url().to_string(), "connected": s.is_connected(), "access": s.access_url().to_string(), "conflict": s.same_endpoint_id_connected() })).collect())),
            ("conn.alpn", Handle::Conn(c)) => Ok(json!(hex::encode(c.alpn()))),
            ("conn.remoteId", Handle::Conn(c)) => Ok(json!(hex::encode(c.remote_id().as_bytes()))),
            ("conn.closeReason", Handle::Conn(c)) => Ok(c.close_reason().map(|e| close_info(&e)).unwrap_or(Value::Null)),
            ("conn.paths", Handle::Conn(c)) => {
                let paths = c.paths();
                let ways: Vec<_> = paths.iter().collect();
                // `selected`: the way it goes by (chosen_way), which iroh may leave unmarked while it carries on.
                let chosen = chosen_way(&ways.iter().map(|p| (p.is_selected(), p.is_relay(), p.stats().udp_tx.datagrams)).collect::<Vec<_>>());
                Ok(Value::Array(
                ways
                    .iter()
                    .enumerate()
                    .map(|(i, p)| {
                        let (relay, ip) = match p.remote_addr() {
                            iroh::TransportAddr::Relay(url) => (Some(url.to_string()), None),
                            iroh::TransportAddr::Ip(addr) => (None, Some(addr.to_string())),
                            _ => (None, None),
                        };
                        // Packets sent and lost on this way alone: the connection's counts take in every way it tried.
                        let stats = p.stats();
                        json!({ "id": p.id().to_string(), "selected": chosen == Some(i), "relay": relay, "ip": ip, "rttMs": stats.same_path_rtt.map(|rtt| rtt.as_secs_f64() * 1000.0), "txPackets": stats.udp_tx.datagrams, "lostPackets": stats.lost_packets, "cwnd": stats.cwnd, "congestionEvents": stats.congestion_events })
                    })
                    .collect(),
                ))
            }
            // What went over it since it opened (the addon's `stats`, which says what each is for).
            ("conn.stats", Handle::Conn(c)) => {
                let s = c.stats();
                let data = |f: &iroh::endpoint::FrameStats| f.stream + f.datagram + f.crypto;
                Ok(json!({
                    "rxBytes": s.udp_rx.bytes, "txBytes": s.udp_tx.bytes, "rxPackets": s.udp_rx.datagrams, "txPackets": s.udp_tx.datagrams,
                    "rxPings": s.frame_rx.ping, "txPings": s.frame_tx.ping, "rxAckRequests": s.frame_rx.immediate_ack, "txAckRequests": s.frame_tx.immediate_ack,
                    "rxAcks": s.frame_rx.acks + s.frame_rx.path_acks, "txAcks": s.frame_tx.acks + s.frame_tx.path_acks, "rxData": data(&s.frame_rx), "txData": data(&s.frame_tx),
                }))
            }
            ("conn.remoteId", Handle::Gone { remote, .. }) => Ok(json!(remote)),
            ("conn.alpn", Handle::Gone { alpn, .. }) => Ok(json!(alpn)),
            ("conn.closeReason", Handle::Gone { reason, .. }) => Ok(reason),
            ("conn.paths", Handle::Gone { .. }) => Ok(json!([])),
            ("conn.stats", Handle::Gone { stats, .. }) => Ok(stats),
            ("iroh.endpointId", Handle::Unbound { id }) => Ok(json!(id)),
            ("iroh.addAddr", Handle::Unbound { .. }) => Ok(Value::Null),
            ("iroh.relayStatus", Handle::Unbound { .. }) => Ok(json!([])),
            (op, _) => Err(format!("no operation {op} on that handle")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The way a connection goes by where iroh marked none: the busiest direct one, a relay's only where no direct one
    /// carried anything, the only way or the first of direct ways before anything was sent, and none where a relay's may
    /// still be it.
    #[test]
    fn the_way_a_connection_goes_by_is_found_where_iroh_marks_none() {
        assert_eq!(chosen_way(&[(false, true, 3), (true, false, 0)]), Some(1));
        assert_eq!(chosen_way(&[(false, false, 12)]), Some(0));
        assert_eq!(chosen_way(&[(false, true, 0), (false, false, 12)]), Some(1));
        assert_eq!(chosen_way(&[(false, true, 40), (false, false, 2), (false, false, 9)]), Some(2));
        assert_eq!(chosen_way(&[(false, true, 5), (false, false, 0)]), Some(0));
        assert_eq!(chosen_way(&[(false, false, 0)]), Some(0));
        assert_eq!(chosen_way(&[(false, false, 0), (false, false, 0)]), Some(0));
        assert_eq!(chosen_way(&[(false, true, 0), (false, false, 0)]), None);
        assert_eq!(chosen_way(&[]), None);
    }

    /// A handshake that never ends (the device gone half way) is given up at its limit and dropped, which closes it;
    /// one that fails is said, and one that ends is taken. On the test's clock (paused: it moves when nothing else can).
    #[tokio::test(start_paused = true)]
    async fn a_handshake_never_done_is_given_up() {
        use std::sync::atomic::{AtomicBool, Ordering as O};
        struct Dropped(Arc<AtomicBool>);
        impl Drop for Dropped {
            fn drop(&mut self) {
                self.0.store(true, O::SeqCst);
            }
        }
        let dropped = Arc::new(AtomicBool::new(false));
        let never = {
            let dropped = Dropped(dropped.clone());
            async move {
                let _held = dropped;
                std::future::pending::<Result<(), String>>().await
            }
        };
        let started = tokio::time::Instant::now();
        assert!(handshake("nowhere", never, HANDSHAKE_TIMEOUT).await.is_none());
        assert_eq!(started.elapsed(), HANDSHAKE_TIMEOUT);
        assert!(dropped.load(O::SeqCst), "the handshake given up was kept");
        assert_eq!(handshake::<u8, String>("here", async { Ok(1) }, HANDSHAKE_TIMEOUT).await, Some(1));
        assert!(handshake::<u8, String>("here", async { Err("refused".into()) }, HANDSHAKE_TIMEOUT).await.is_none());
    }

    #[test]
    fn build_relay_allowlist_covers_explicit_empty_entries_public_lookup_and_discovery() {
        let r1 = relay_url("https://relay-a.example.test/").unwrap();
        let e1 = relay_url("https://entry-a.example.test:8443/").unwrap();
        let unlisted = relay_url("https://relay.pvg-office-4.monoid-afk.dev/").unwrap();
        let prod: Vec<RelayUrl> = iroh::defaults::prod::default_relay_map().relays::<Vec<_>>().into_iter().map(|c| c.url.clone()).collect();
        assert!(!prod.is_empty());

        // Explicit allowlist with forwarding entry and allow_public = false.
        let list = build_relay_allowlist(Some(vec![r1.clone()]), false, false, &[r1.clone()], &[(e1.clone(), r1.clone())]).unwrap();
        assert!(list.contains(&r1));
        assert!(list.contains(&e1));
        assert!(!list.contains(&unlisted));
        assert!(prod.iter().all(|p| !list.contains(p)));

        // Empty explicit allowlist (LAN / Tailnet pinned endpoint).
        let empty = build_relay_allowlist(Some(vec![]), false, false, &[], &[]).unwrap();
        assert!(empty.is_empty());

        // Explicit allowlist with allow_public = true admits default prod relays.
        let with_pub = build_relay_allowlist(Some(vec![r1.clone()]), true, true, &[r1.clone()], &[]).unwrap();
        assert!(with_pub.contains(&r1));
        assert!(prod.iter().all(|p| with_pub.contains(p)));
        assert!(!with_pub.contains(&unlisted));

        // Defense-in-depth fallback when lookup = true without explicit allowlist.
        let lookup_fallback = build_relay_allowlist(None, true, false, &[r1.clone()], &[(e1.clone(), r1.clone())]).unwrap();
        assert!(lookup_fallback.contains(&r1));
        assert!(lookup_fallback.contains(&e1));
        assert!(prod.iter().all(|p| lookup_fallback.contains(p)));
        assert!(!lookup_fallback.contains(&unlisted));

        // Unrestricted endpoint (station discovery or lookup = false without explicit allowlist).
        assert!(build_relay_allowlist(None, false, false, &[r1.clone()], &[]).is_none());
        assert!(build_relay_allowlist(None, true, false, &[], &[]).is_none());
    }

    #[tokio::test]
    async fn endpoint_relay_allowlist_rejects_unlisted_relays_and_accepts_allowed_and_public() {
        let allowed = relay_url("https://relay-a.example.test/").unwrap();
        let entry = relay_url("https://entry-a.example.test:8443/").unwrap();
        let unlisted = relay_url("https://relay.pvg-office-4.monoid-afk.dev/").unwrap();
        let prod = iroh::defaults::prod::default_relay_map().relays::<Vec<_>>().into_iter().next().unwrap().url.clone();

        // Explicit allowlist + entry + allow_public = true: rejects unlisted, admits entry and prod.
        let allowlist = build_relay_allowlist(Some(vec![allowed.clone()]), true, true, &[allowed.clone()], &[(entry.clone(), allowed.clone())]).unwrap();
        let ep = Endpoint::builder(Minimal)
            .relay_mode(RelayMode::Custom(iroh::RelayMap::from_iter([allowed.clone()])))
            .relay_allowlist(allowlist)
            .bind()
            .await
            .unwrap();
        ep.insert_relay(unlisted.clone(), Arc::new(iroh::RelayConfig::from(unlisted.clone()))).await;
        assert!(ep.remove_relay(&unlisted).await.is_none(), "unlisted relay must be rejected by relay_allowlist");
        assert!(!ep.home_relay_status().get().iter().any(|s| s.url() == &unlisted));
        ep.insert_relay(entry.clone(), Arc::new(iroh::RelayConfig::from(entry.clone()))).await;
        assert!(ep.remove_relay(&entry).await.is_some(), "forwarding entry in allowlist must be accepted");
        ep.insert_relay(prod.clone(), Arc::new(iroh::RelayConfig::from(prod.clone()))).await;
        assert!(ep.remove_relay(&prod).await.is_some(), "prod relay must be accepted when allow_public is true");
        ep.close().await;

        // Empty allowlist (LAN / Tailnet): rejects any relay.
        let lan = Endpoint::builder(Minimal)
            .relay_mode(RelayMode::Disabled)
            .relay_allowlist(Vec::<RelayUrl>::new())
            .bind()
            .await
            .unwrap();
        lan.insert_relay(allowed.clone(), Arc::new(iroh::RelayConfig::from(allowed.clone()))).await;
        assert!(lan.remove_relay(&allowed).await.is_none(), "empty allowlist must reject all relays");
        lan.close().await;
    }

    #[tokio::test]
    async fn filtered_lookup_strips_unlisted_relays_keeps_ip_and_admits_dynamic_entries() {
        use iroh::address_lookup::{AddressLookup, EndpointInfo, Item};
        use n0_future::StreamExt;

        #[derive(Debug)]
        struct FakeLookup(Item);
        impl AddressLookup for FakeLookup {
            fn resolve(&self, _endpoint_id: EndpointId) -> Option<n0_future::boxed::BoxStream<Result<Item, iroh::address_lookup::Error>>> {
                Some(Box::pin(n0_future::stream::iter([Ok(self.0.clone())])))
            }
        }

        let peer_id = SecretKey::from_bytes(&[9; 32]).public();
        let ip: std::net::SocketAddr = "127.0.0.1:4321".parse().unwrap();
        let allowed_relay = relay_url("https://relay-a.example.test/").unwrap();
        let dynamic_entry = relay_url("https://entry-b.example.test:8443/").unwrap();
        let stale_dht = relay_url("https://relay.pvg-office-4.monoid-afk.dev/").unwrap();

        let info = EndpointInfo::new(peer_id)
            .with_ip_addrs(vec![ip])
            .with_relay_url(allowed_relay.clone())
            .with_relay_url(dynamic_entry.clone())
            .with_relay_url(stale_dht.clone());
        let item = Item::new(info, "dht", None);

        let allowed = Arc::new(RwLock::new(BTreeSet::from([allowed_relay.clone()])));
        let filtered = Filtered(allowed.clone(), FakeLookup(item));

        // Initial resolve: keeps IP and allowed_relay, strips stale_dht and not-yet-added dynamic_entry.
        let first = filtered.resolve(peer_id).unwrap().next().await.unwrap().unwrap();
        let addrs: Vec<_> = first.endpoint_info().data.addrs().cloned().collect();
        assert!(addrs.contains(&iroh::TransportAddr::Ip(ip)));
        assert!(addrs.contains(&iroh::TransportAddr::Relay(allowed_relay.clone())));
        assert!(!addrs.contains(&iroh::TransportAddr::Relay(stale_dht.clone())));
        assert!(!addrs.contains(&iroh::TransportAddr::Relay(dynamic_entry.clone())));

        // After dynamic entry is added (as in iroh.setRelayEntries): dynamic_entry passes, stale_dht stays stripped.
        allowed.write().unwrap().insert(dynamic_entry.clone());
        let second = filtered.resolve(peer_id).unwrap().next().await.unwrap().unwrap();
        let addrs2: Vec<_> = second.endpoint_info().data.addrs().cloned().collect();
        assert!(addrs2.contains(&iroh::TransportAddr::Ip(ip)));
        assert!(addrs2.contains(&iroh::TransportAddr::Relay(allowed_relay)));
        assert!(addrs2.contains(&iroh::TransportAddr::Relay(dynamic_entry)));
        assert!(!addrs2.contains(&iroh::TransportAddr::Relay(stale_dht)));
    }
}
