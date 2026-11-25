//! The station's iroh for the station in TypeScript (docs/station-ts-native.md §3): its endpoint as
//! mesh/station/src/main.rs `serve_mesh` makes it (the station's key, its relays, found on the LAN by mDNS and by relay
//! through the Mainline DHT, Cubic by default with a 256 KiB initial window), home on every one of its relays at once
//! (one connection to it has a path through each, PATH_IDLE), keepers on relays added since (keep.rs), connections both
//! ways and their streams. Which relays, when to add iroh's public ones, who may connect and what is said: the
//! TypeScript's. And the image codecs of the thumbnails (thumbs.rs).

#[path = "../../../../client/shell/src/mesh.rs"]
mod mesh;
#[path = "../../../../client/shell/src/screen_dgram.rs"]
mod screen_dgram;
mod dscp;
mod keep;
mod log;
mod thumbs;
mod local;
mod usage;
mod verify;

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::{Arc, Mutex as StdMutex, RwLock as StdRwLock};
use std::time::{Duration, Instant};

use iroh::address_lookup::{AddressLookup, AddressLookupBuilder, AddressLookupBuilderError, EndpointData, Error as AddressLookupError, Item as AddressLookupItem};
use iroh::endpoint::{Connection as IrohConnection, QuicTransportConfig, RecvStream, SendStream, presets::Minimal};
use iroh::{Endpoint as IrohEndpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey, Watcher};
use n0_future::boxed::BoxStream;
use napi::bindgen_prelude::{Buffer, Promise};
use napi_derive::napi;
use tokio::sync::Mutex;

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

/// What screen_dgram.rs counts (the shell's `tally`): nothing kept here.
pub(crate) fn tally(_what: &str) {}

fn failed(error: impl std::fmt::Display) -> napi::Error {
    napi::Error::from_reason(error.to_string())
}

/// How often each path of a connection is kept alive, and how long one may hear nothing before it is given up: its
/// packets go on on another path meanwhile (another relay, direct), and a relay's is opened again as it comes back.
/// iroh's own (5 s, 15 s; 30 s for a relay's) held a connection on a way that was gone that long (a relay down, a path
/// punched through that stopped answering), every stream on it waiting.
const PATH_KEEP_ALIVE: Duration = Duration::from_secs(1);
const PATH_IDLE: Duration = Duration::from_secs(3);
/// How long a connection may hear nothing before it is given up: with iroh's 30 s, a phone's app frozen in the background
/// that long came back to every link timed out and dialled each anew (2026-11-08). The peers take the lower of theirs.
const CONNECTION_IDLE_MS: u32 = 10 * 60_000;

fn relay_url(url: &str) -> napi::Result<RelayUrl> {
    url.parse().map_err(failed)
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

#[napi(object)]
pub struct Options {
    /// The station's 32-byte key (<data>/mesh/secret.key).
    pub secret_key: Buffer,
    pub alpns: Vec<Buffer>,
    /// still.fail's relays, ours first; none: relays off (tests on one machine).
    pub relay_urls: Vec<String>,
    /// Alternative addresses into the same relays, used by client endpoints.
    pub relay_entries: Option<Vec<RelayEntry>>,
    /// Immutable ceiling of relay and entry URLs this endpoint may ever use; none: unrestricted.
    pub relay_allowlist: Option<Vec<String>>,
    /// When true with `relay_allowlist`, also admit iroh's built-in default relays for emergency fallback.
    pub allow_public_relays: Option<bool>,
    /// Found on the LAN and through the DHT, as a station is. Off for tests.
    pub discovery: Option<bool>,
    /// The DHT among those ways, on by default: off where a company's filter marks the Mainline DHT (its bootstrap
    /// names, its BitTorrent UDP) as risky, mDNS left as it is (`STILLFAIL_NO_DHT`).
    pub dht: Option<bool>,
    /// Where to listen; any free port when not said.
    pub bind_addr: Option<String>,
    /// A client's endpoint (the core in TypeScript, client/core-ts): it looks stations up on the LAN and in the DHT
    /// without being announced itself (a device is never dialed).
    pub lookup: Option<bool>,
    /// Relays alone, no IP transports: what measures the way through a relay must not go direct.
    pub relay_only: Option<bool>,
    /// Advanced choice, cubic by default; read when the endpoint is created.
    pub congestion: Option<String>,
    /// The DSCP (1 to 63) every iroh packet of this process is marked with from this bind on (dscp.rs); none: unmarked.
    pub dscp: Option<u32>,
}

#[napi(object)]
pub struct RelayEntry {
    pub entry: String,
    pub relay: String,
}

#[napi]
pub struct Endpoint {
    inner: IrohEndpoint,
    mesh: mesh::Scopes,
    keepers: Arc<StdMutex<HashMap<String, tokio::task::JoinHandle<()>>>>,
    /// The relays it was bound with: home on each, no keeper wanted there.
    bound: Vec<RelayUrl>,
    /// Those of them it is home on now: one removed is home no more (a keeper is wanted there once it is kept on it
    /// again, unless it is inserted again first, home again).
    homes: StdMutex<Vec<RelayUrl>>,
    /// Connections coming that are held unanswered, not even their handshake (`hold_incoming`), and those held.
    held: Arc<StdMutex<(u32, Vec<iroh::endpoint::Incoming>)>>,
    /// The connections whose handshakes are done, as each finishes (`accept`), once one was first asked for.
    accepted: Arc<Mutex<Option<tokio::sync::mpsc::UnboundedReceiver<IrohConnection>>>>,
    /// Relay URLs permitted in DHT/mDNS address lookup responses for `lookup: true` client endpoints.
    lookup_relays: Option<Arc<StdRwLock<BTreeSet<RelayUrl>>>>,
}

/// The connections' transport: the congestion controller named (BBR is opt-in; noq-proto includes fixes for
/// n0-computer/noq#852 idle max_bw collapse and n0-computer/noq#802 initial startup pacing rate, and BBR uses
/// `loss_thresh(0.30)` + `gate_lower_bounds_on_loss_thresh(true)` so cross-border 10–25% random loss does not collapse
/// long-lived connections to `min_pipe_cwnd` while keeping steady-state zero retransmissions under shallow-buffer
/// congestion), a 4 MiB per-stream receive window matching 4 MiB transfer chunks, and the paths kept alive and given
/// up as PATH_KEEP_ALIVE and PATH_IDLE say.
fn transport(congestion: &str) -> napi::Result<QuicTransportConfig> {
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
        _ => return Err(failed("congestion: expected cubic or bbr")),
    };
    Ok(QuicTransportConfig::builder()
        .congestion_controller_factory(controller)
        .stream_receive_window(iroh::endpoint::VarInt::from_u32(4 * 1024 * 1024))
        .datagram_send_buffer_size(4 * 1024 * 1024)
        .datagram_receive_buffer_size(Some(4 * 1024 * 1024))
        .default_path_keep_alive_interval(PATH_KEEP_ALIVE)
        .default_path_max_idle_timeout(PATH_IDLE)
        .max_idle_timeout(Some(iroh::endpoint::VarInt::from_u32(CONNECTION_IDLE_MS).into()))
        .build())
}

/// A way of finding stations (mDNS on the LAN, the DHT) that could not be made leaves the endpoint without it, said,
/// instead of failing the endpoint: mDNS binds UDP 5353 on the machine's networks, which fails with none up yet (a
/// Windows station started at logon before its network) or the port held by another program, and the endpoint failing
/// left the station off the mesh, and offline, until it was restarted.
#[derive(Debug)]
struct Optional<B>(&'static str, B);

#[derive(Debug)]
struct Unmade<L>(Option<L>);

impl<B: AddressLookupBuilder> AddressLookupBuilder for Optional<B> {
    fn into_address_lookup(self, endpoint: &IrohEndpoint) -> Result<impl AddressLookup, AddressLookupBuilderError> {
        Ok(Unmade(match self.1.into_address_lookup(endpoint) {
            Ok(lookup) => Some(lookup),
            Err(error) => {
                crate::log::info(&format!("mesh: stations not found through {}: {error:#}", self.0));
                None
            }
        }))
    }
}

impl<L: AddressLookup> AddressLookup for Unmade<L> {
    fn publish(&self, data: &EndpointData) {
        if let Some(lookup) = &self.0 {
            lookup.publish(data);
        }
    }

    fn resolve(&self, endpoint_id: EndpointId) -> Option<BoxStream<Result<AddressLookupItem, AddressLookupError>>> {
        self.0.as_ref().and_then(|lookup| lookup.resolve(endpoint_id))
    }
}

/// Strips relay URLs outside `allowed` from DHT/mDNS address lookup responses while keeping IP and custom transports.
#[derive(Debug)]
struct FilteredLookup<B>(Arc<StdRwLock<BTreeSet<RelayUrl>>>, B);

#[derive(Debug)]
struct Filtered<L>(Arc<StdRwLock<BTreeSet<RelayUrl>>>, L);

fn filter_lookup_item(item: AddressLookupItem, allowed: &BTreeSet<RelayUrl>) -> AddressLookupItem {
    let provenance = item.provenance();
    let last_updated = item.last_updated();
    let old = item.endpoint_info();
    let addrs = old.data.addrs().filter(|a| match a {
        iroh::TransportAddr::Relay(url) => allowed.contains(url),
        _ => true,
    }).cloned();
    let mut data = EndpointData::new(addrs.collect());
    if let Some(user_data) = old.data.user_data() {
        data = data.with_user_data(user_data.clone());
    }
    let info = iroh::address_lookup::EndpointInfo::from_parts(old.endpoint_id, data);
    AddressLookupItem::new(info, provenance, last_updated)
}

impl<B: AddressLookupBuilder> AddressLookupBuilder for FilteredLookup<B> {
    fn into_address_lookup(self, endpoint: &IrohEndpoint) -> Result<impl AddressLookup, AddressLookupBuilderError> {
        Ok(Filtered(self.0, self.1.into_address_lookup(endpoint)?))
    }
}

impl<L: AddressLookup> AddressLookup for Filtered<L> {
    fn publish(&self, data: &EndpointData) {
        self.1.publish(data);
    }

    fn resolve(&self, endpoint_id: EndpointId) -> Option<BoxStream<Result<AddressLookupItem, AddressLookupError>>> {
        let allowed = self.0.clone();
        self.1.resolve(endpoint_id).map(|stream| {
            use n0_future::StreamExt;
            Box::pin(stream.map(move |res| res.map(|item| filter_lookup_item(item, &allowed.read().unwrap())))) as BoxStream<_>
        })
    }
}

#[napi]
pub async fn bind(options: Options) -> napi::Result<Endpoint> {
    bind_with(options, false).await
}

/// `insecure`: relays whose certificates are not checked (the tests' own, self-signed, on this machine).
async fn bind_with(options: Options, #[allow(unused_variables)] insecure: bool) -> napi::Result<Endpoint> {
    dscp::apply(options.dscp).map_err(failed)?;
    let bytes: [u8; 32] = options.secret_key.as_ref().try_into().map_err(|_| failed("the key is not 32 bytes"))?;
    let key = SecretKey::from_bytes(&bytes);
    let relays: Vec<RelayUrl> = options.relay_urls.iter().map(|u| relay_url(u)).collect::<Result<_, _>>()?;
    let entries: Vec<(RelayUrl, RelayUrl)> = options.relay_entries.unwrap_or_default().iter().map(|e| Ok((relay_url(&e.entry)?, relay_url(&e.relay)?))).collect::<napi::Result<_>>()?;
    let explicit_allowlist: Option<Vec<RelayUrl>> = options
        .relay_allowlist
        .as_ref()
        .map(|urls| urls.iter().map(|u| relay_url(u)).collect::<napi::Result<_>>())
        .transpose()?;
    let allow_public = options.allow_public_relays.unwrap_or(false);
    let lookup = options.lookup.unwrap_or(false);
    let lookup_active = lookup && !relays.is_empty();
    let allowlist = build_relay_allowlist(explicit_allowlist, lookup, allow_public, &relays, &entries);
    let lookup_relays = if lookup_active {
        allowlist.as_ref().map(|list| Arc::new(StdRwLock::new(list.iter().cloned().collect::<BTreeSet<_>>())))
    } else {
        None
    };
    let relay_map = iroh::RelayMap::from_iter(relays.iter().map(|relay| {
        iroh::RelayConfig::from(relay.clone()).with_entries(entries.iter().filter(|(_, target)| target == relay).map(|(entry, _)| entry.clone()))
    }));
    let transport = transport(options.congestion.as_deref().unwrap_or("cubic"))?;
    let mesh = mesh::Scopes::default();
    let mut builder = IrohEndpoint::builder(Minimal)
        .add_custom_transport(mesh.hub.clone())
        .path_selector(Arc::new(mesh_transport::selection::Selector::new(mesh.hub.clone())))
        .secret_key(key.clone())
        .alpns(options.alpns.iter().map(|a| a.to_vec()).collect())
        .relay_mode(if relays.is_empty() { RelayMode::Disabled } else { RelayMode::Custom(relay_map) })
        .home_on_every_relay()
        .transport_config(transport);
    if !lookup_active {
        if let Some(allowlist) = allowlist {
            builder = builder.relay_allowlist(allowlist);
        }
    }
    if let Some(addr) = &options.bind_addr {
        builder = builder.bind_addr(addr.parse::<std::net::SocketAddr>().map_err(failed)?).map_err(failed)?;
    }
    if options.relay_only.unwrap_or(false) {
        builder = builder.clear_ip_transports();
    }
    #[cfg(test)]
    if insecure {
        builder = builder.ca_tls_config(iroh::tls::CaTlsConfig::insecure_skip_verify());
    }
    let with_dht = options.dht.unwrap_or(true);
    if lookup_active {
        let mdns = Optional("mDNS", iroh_mdns_address_lookup::MdnsAddressLookup::builder().service_name(MDNS_SERVICE).advertise(false));
        let dht_lookup = with_dht.then(|| Optional("the DHT", iroh_mainline_address_lookup::DhtAddressLookup::builder().dht_builder(dht()).no_publish()));
        if let Some(allowed) = lookup_relays.clone() {
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
    } else if options.discovery.unwrap_or(true) {
        builder = builder.address_lookup(Optional("mDNS", iroh_mdns_address_lookup::MdnsAddressLookup::builder().service_name(MDNS_SERVICE)));
        if with_dht {
            builder = builder.address_lookup(Optional("the DHT", iroh_mainline_address_lookup::DhtAddressLookup::builder().dht_builder(dht()).secret_key(key)));
        }
    }
    Ok(Endpoint { inner: builder.bind().await.map_err(failed)?, mesh, keepers: Arc::default(), homes: StdMutex::new(relays.clone()), bound: relays, held: Arc::default(), accepted: Arc::default(), lookup_relays })
}

#[napi(object)]
pub struct Addr {
    /// The admitted scope through which this endpoint may be reached.
    pub mesh_scope: Option<String>,
    /// The endpoint's id (hex).
    pub id: String,
    pub relays: Option<Vec<String>>,
    /// `ip:port`, each.
    pub ips: Option<Vec<String>>,
    /// Relays it is not to be reached through, though Address Lookup names them (its workspaces turned them off).
    pub disabled_relays: Option<Vec<String>>,
}

/// The relays `addr` says the endpoint is not to be reached through, where it says them.
fn disabled_relays(addr: &Addr) -> napi::Result<Option<Vec<RelayUrl>>> {
    addr.disabled_relays.as_ref().map(|urls| urls.iter().map(|u| relay_url(u)).collect()).transpose()
}

fn endpoint_addr(addr: &Addr) -> napi::Result<EndpointAddr> {
    let bytes: [u8; 32] = hex::decode(&addr.id).map_err(failed)?.try_into().map_err(|_| failed("the id is not 32 bytes"))?;
    let id = EndpointId::from_bytes(&bytes).map_err(failed)?;
    let mut out = EndpointAddr::new(id);
    for url in addr.relays.iter().flatten() {
        out = out.with_relay_url(relay_url(url)?);
    }
    for ip in addr.ips.iter().flatten() {
        out = out.with_ip_addr(ip.parse::<std::net::SocketAddr>().map_err(failed)?);
    }
    Ok(out)
}

#[napi]
impl Endpoint {
    #[napi]
    pub async fn mesh_subscribe(&self, id: u32, callback: napi::threadsafe_function::ThreadsafeFunction<serde_json::Value, ()>) -> napi::Result<()> {
        let callback = Arc::new(callback);
        self.mesh.subscribe_updates(u64::from(id), move |snapshot| {
            let callback = callback.clone();
            async move { callback.call_async(Ok(serde_json::Value::Array(snapshot))).await.map_err(|e| e.to_string()) }
        }).map_err(failed)
    }

    #[napi]
    pub fn mesh_unsubscribe(&self, id: u32) { self.mesh.unsubscribe(u64::from(id)); }

    #[napi]
    pub async fn mesh_attach_leaf(&self, connection: &Connection, value: serde_json::Value) -> napi::Result<serde_json::Value> {
        self.mesh.attach_leaf(&self.inner,connection.inner.clone(),&value).await.map_err(failed)
    }
    #[napi]
    pub async fn mesh_use_leaf(&self, value: serde_json::Value) -> napi::Result<()> {
        self.mesh.use_leaf(&self.inner,&value).await.map_err(failed)
    }
    #[napi]
    pub async fn mesh_detach_leaf(&self, value: serde_json::Value) -> napi::Result<()> {
        self.mesh.detach_leaf(&value).await.map_err(failed)
    }
    #[napi]
    pub async fn mesh_configure(&self, scope: serde_json::Value) -> napi::Result<serde_json::Value> {
        self.mesh.configure_root(&self.inner, &scope).await.map_err(failed)
    }

    #[napi]
    pub async fn mesh_remove(&self, scope: String) -> napi::Result<()> {
        self.mesh.remove(&serde_json::json!({ "scope": scope })).await.map_err(failed)
    }

    /// Its id, as the station's (hex).
    #[napi]
    pub fn id(&self) -> String {
        hex::encode(self.inner.id().as_bytes())
    }

    /// Where it listens on this machine: `ip:port`, each.
    #[napi]
    pub fn sockets(&self) -> Vec<String> {
        self.inner.bound_sockets().iter().map(ToString::to_string).collect()
    }

    /// Resolves once it is on its home relay (at once with relays off).
    #[napi]
    pub async fn online(&self) {
        self.inner.online().await;
    }

    /// Its home relay now, if it has one.
    #[napi]
    pub fn home(&self) -> Option<String> {
        self.inner.home_relay_status().get().first().map(|s| s.url().to_string())
    }

    #[napi]
    pub async fn insert_relay(&self, url: String) -> napi::Result<()> {
        let url = relay_url(&url)?;
        self.inner.insert_relay(url.clone(), Arc::new(iroh::RelayConfig::from(url.clone()))).await;
        // (one it was bound with is home again: iroh's relay transport bound for it takes it back)
        let mut homes = self.homes.lock().unwrap();
        if self.bound.contains(&url) && !homes.contains(&url) {
            homes.push(url);
        }
        Ok(())
    }

    /// Off every relay transport: its connection there ended, no longer home there nor in its address.
    #[napi]
    pub async fn remove_relay(&self, url: String) -> napi::Result<()> {
        let url = relay_url(&url)?;
        self.inner.remove_relay(&url).await;
        self.homes.lock().unwrap().retain(|r| r != &url);
        Ok(())
    }

    /// The congestion controller of the connections made from now on, dialed and accepted (one made keeps its own):
    /// the advanced network setting changed while the station runs.
    #[napi]
    pub fn set_congestion(&self, congestion: String) -> napi::Result<()> {
        self.inner.set_transport_config(transport(&congestion)?);
        Ok(())
    }

    /// The relays the endpoint `id` is not to be reached through (`relays`), and whether iroh's own public relays are
    /// among them (`public`): in force once this resolves (iroh's `set_disabled_relays`), on what a connection to it
    /// has already as on what a dial after takes. None: any relay.
    #[napi]
    pub async fn disabled_relays(&self, id: String, relays: Vec<String>, public: Option<bool>) -> napi::Result<()> {
        let bytes: [u8; 32] = hex::decode(&id).map_err(failed)?.try_into().map_err(|_| failed("the id is not 32 bytes"))?;
        let peer = EndpointId::from_bytes(&bytes).map_err(failed)?;
        let mut disabled: std::collections::BTreeSet<RelayUrl> = relays.iter().map(|u| relay_url(u)).collect::<Result<_, _>>()?;
        if public.unwrap_or(false) {
            disabled.extend(iroh::defaults::prod::default_relay_map().relays::<Vec<_>>().iter().map(|c| c.url.clone()));
        }
        self.inner.set_disabled_relays(peer, disabled).await;
        Ok(())
    }

    /// iroh's own public relays: added while none of still.fail's answers, removed once one does (`keep_relays`).
    #[napi]
    pub async fn public_relays(&self, on: bool) {
        let public: Vec<Arc<iroh::RelayConfig>> = iroh::defaults::prod::default_relay_map().relays();
        for config in public {
            if on {
                self.inner.insert_relay(config.url.clone(), config.clone()).await;
            } else {
                self.inner.remove_relay(&config.url).await;
            }
        }
    }

    /// Keeps the station on exactly these relays, besides those it is home on (bound with): a keeper for each new one
    /// (keep.rs), those of relays no longer named stopped.
    #[napi]
    pub fn keep(&self, urls: Vec<String>) -> napi::Result<()> {
        let mut relays: Vec<RelayUrl> = urls.iter().map(|u| relay_url(u)).collect::<Result<_, _>>()?;
        let homes = self.homes.lock().unwrap().clone();
        relays.retain(|r| !homes.contains(r));
        let urls: Vec<String> = relays.iter().map(ToString::to_string).collect();
        let mut keepers = self.keepers.lock().unwrap();
        keepers.retain(|url, task| {
            let named = urls.contains(url);
            if !named {
                task.abort();
            }
            named
        });
        for relay in relays {
            let endpoint = self.inner.clone();
            keepers.entry(relay.to_string()).or_insert_with(|| napi::bindgen_prelude::spawn(keep::keep(endpoint, relay)));
        }
        Ok(())
    }

    /// The next `n` connections coming are never answered, not even their handshake: a device whose way here is gone,
    /// dialing (the client core's tests).
    #[napi]
    pub fn hold_incoming(&self, n: u32) {
        self.held.lock().unwrap().0 = n;
    }

    /// The next connection, its handshake done; null once the endpoint is closed. One that fails its handshake is
    /// skipped. Handshakes go on side by side, each on its own: one that is never finished (its device gone half way,
    /// as an app updating, a phone out of signal) holds up no other. Taken one at a time, every connection behind it
    /// waited until it timed out, half a minute in which the station took no one (2026-10-08: with devices dialling
    /// every way at once, stations were out of everyone's reach a minute or two at a time).
    #[napi]
    pub async fn accept(&self) -> Option<Connection> {
        let mut accepted = self.accepted.lock().await;
        let done = accepted.get_or_insert_with(|| {
            let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
            let endpoint = self.inner.clone();
            let held = self.held.clone();
            napi::bindgen_prelude::spawn(async move {
                while let Some(incoming) = endpoint.accept().await {
                    {
                        let mut held = held.lock().unwrap();
                        if held.0 > 0 {
                            held.0 -= 1;
                            held.1.push(incoming);
                            continue;
                        }
                    }
                    let tx = tx.clone();
                    napi::bindgen_prelude::spawn(async move {
                        let from = incoming.remote_addr();
                        if let Some(conn) = handshake(from, incoming, HANDSHAKE_TIMEOUT).await {
                            let _ = tx.send(conn);
                        }
                    });
                }
            });
            rx
        });
        done.recv().await.map(|inner| Connection { inner, demux: Arc::default() })
    }

    /// A connection to another endpoint (a peer station; a station, from a client), offering `alpn` and, for one from
    /// before a rename, the `additional` ones too. `given_up`: resolves once the caller no longer waits for it (its
    /// own deadline passed), and the handshake is given up then (`dial`).
    #[napi]
    pub async fn connect(&self, addr: Addr, alpn: Buffer, additional: Option<Vec<Buffer>>, given_up: Option<Promise<()>>) -> napi::Result<Connection> {
        let mut options = iroh::endpoint::ConnectOptions::new().with_additional_alpns(additional.unwrap_or_default().iter().map(|a| a.to_vec()).collect());
        if let Some(disabled) = disabled_relays(&addr)? {
            options = options.with_disabled_relays(disabled);
        }
        let given_up = async move {
            match given_up {
                Some(promise) => drop(promise.await),
                None => std::future::pending().await,
            }
        };
        let mut target = endpoint_addr(&addr)?;
        if let Some(scope) = &addr.mesh_scope {
            target.addrs.insert(self.mesh.address(scope, target.id).await.map_err(failed)?);
        }
        let conn = dial(&self.inner, target, &alpn, options, given_up).await.map_err(failed)?;
        Ok(Connection { inner: conn, demux: Arc::default() })
    }

    /// Tells it where an endpoint is without looking it up (tests, a LAN with no relay).
    #[napi]
    pub fn add_addr(&self, addr: Addr) -> napi::Result<()> {
        let addr = endpoint_addr(&addr)?;
        let lookup = self.inner.address_lookup().map_err(failed)?;
        lookup.add(iroh::address_lookup::MemoryLookup::from_endpoint_info([addr]));
        Ok(())
    }

    /// Replace forwarding entrances without closing the endpoint's existing connections.
    #[napi]
    pub async fn set_relay_entries(&self, entries: Vec<RelayEntry>) -> napi::Result<()> {
        let mut grouped = BTreeMap::<RelayUrl, Vec<RelayUrl>>::new();
        for entry in entries {
            grouped.entry(relay_url(&entry.relay)?).or_default().push(relay_url(&entry.entry)?);
        }
        if let Some(allowed) = &self.lookup_relays {
            let mut guard = allowed.write().unwrap();
            for (relay, list) in &grouped {
                guard.insert(relay.clone());
                guard.extend(list.iter().cloned());
            }
        }
        self.inner.set_relay_entries(grouped.into_iter().collect()).await;
        Ok(())
    }

    /// The network changed (a phone's, after it slept): its sockets and relay connection looked at anew.
    #[napi]
    pub async fn network_change(&self) {
        self.inner.network_change().await;
    }

    /// Its home relays, and whether it is connected to each now (and held inactive there for another endpoint of its id).
    #[napi]
    pub fn relay_status(&self) -> Vec<RelayState> {
        self.inner.home_relay_status().get().iter().map(|s| RelayState { url: s.url().to_string(), connected: s.is_connected(), access: s.access_url().to_string(), conflict: s.same_endpoint_id_connected() }).collect()
    }

    /// Whether it is reached through relay `url` now, end to end (keep.rs `probe`): `ok`, or what failed (`stage`:
    /// `probe_offline` where the relay is out of this machine's reach, `endpoint_failed` where it is not but this
    /// endpoint is). An addon from before has none.
    #[napi]
    pub async fn probe_relay(&self, url: String) -> napi::Result<ProbeRelayResult> {
        let relay = relay_url(&url)?;
        Ok(ProbeRelayResult::of(keep::probe(&self.inner, &relay).await))
    }

    /// Whether its streams take a view's frames as datagrams (`Stream.receiveMediaDatagrams`): an addon from before has
    /// no such call.
    #[napi]
    pub fn media_datagrams(&self) -> bool {
        true
    }

    #[napi]
    pub async fn close(&self) {
        self.mesh.clear().await;
        for (_, task) in self.keepers.lock().unwrap().drain() {
            task.abort();
        }
        self.inner.close().await;
    }
}

/// A dial's handshake, given up as `given_up` resolves: its `Connecting` dropped, which closes it, so it sends no more
/// Initials. The handshake is otherwise bounded only by the connection's idle timeout (CONNECTION_IDLE_MS): a dial its
/// caller stopped waiting for (the app's after CONNECT_TIMEOUT_MS) went on retransmitting to every relay and address of
/// the station for ten minutes, a dozen such filled the endpoint's queue of what it sends to that station and dropped
/// what the connections that did come up sent, one of them came up tens of seconds late over a relay that answered
/// once and stood dead for ten minutes, and the endpoint's close waited for all of them (2026-11-12, a station
/// restarted while a device viewed its screen).
async fn dial(
    endpoint: &IrohEndpoint,
    addr: EndpointAddr,
    alpn: &[u8],
    options: iroh::endpoint::ConnectOptions,
    given_up: impl std::future::Future<Output = ()>,
) -> anyhow::Result<IrohConnection> {
    let handshake = async {
        let connecting = endpoint.connect_with_opts(addr, alpn, options).await?;
        anyhow::Ok(connecting.await?)
    };
    tokio::select! {
        biased;
        conn = handshake => conn,
        () = given_up => Err(anyhow::anyhow!("given up")),
    }
}

/// How long a connection coming in may take over its handshake. Unbounded, it was bounded only by the connection's idle
/// timeout (CONNECTION_IDLE_MS): a device dials every relay at once and lets go of the endpoints it did not choose
/// (client/core-ts mesh.ts, after CONNECT_TIMEOUT_MS at most), and the station's half of each such handshake went on
/// sending to it through the relay for ten minutes, which the relay dropped, the device's endpoint gone from it
/// (2026-11-18: `handshake failed … after 600001 ms: timed out` in the logs, a relay's `send_packets_dropped` 4% to 25%
/// of what it was sent with nothing queued). Three times the device's own wait, for a handshake of several round trips
/// across continents.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);

/// A connection's handshake as it comes in, given up after `limit`: dropped then, which closes it, so it sends no
/// more. One that fails or is given up is said, where it came from and how long it took: a device whose dials to the
/// station never got through said nothing here, which way its packets came or whether any came at all (2026-10-29).
async fn handshake<C, E: std::fmt::Display>(
    from: impl std::fmt::Debug,
    incoming: impl std::future::IntoFuture<Output = Result<C, E>>,
    limit: Duration,
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

/// What `probe_relay` found.
#[napi(object)]
#[derive(Debug, PartialEq)]
pub struct ProbeRelayResult {
    pub ok: bool,
    /// What failed (`probe_offline`, `endpoint_failed`); none where nothing did.
    pub stage: Option<String>,
}

impl ProbeRelayResult {
    fn of(found: keep::ProbeResult) -> Self {
        ProbeRelayResult { ok: found == keep::ProbeResult::Ok, stage: found.stage().map(str::to_string) }
    }
}

#[napi(object)]
pub struct RelayState {
    pub url: String,
    pub connected: bool,
    pub access: String,
    /// The relay holds this endpoint's connection inactive: another endpoint with its secret key connected after it
    /// (a second station on the same key: another machine with a copy of its data, a front left from before).
    pub conflict: bool,
}

/// One way a connection can go: through a relay (its URL) or direct; the one chosen now, its round trip, and the
/// packets sent and lost on it alone (the connection's own counts take in every way it tried and dropped too).
#[napi(object)]
pub struct PathState {
    pub id: String,
    pub selected: bool,
    pub relay: Option<String>,
    /// A direct way's address at the other end (`ip:port`).
    pub ip: Option<String>,
    pub rtt_ms: Option<f64>,
    pub tx_packets: f64,
    pub lost_packets: f64,
    /// How much its sender may have unacknowledged on it now (bytes), and how many times it was cut for loss.
    pub cwnd: f64,
    pub congestion_events: f64,
}

/// What went over a connection since it opened, both ways: bytes, packets, and of the frames in them those that
/// carry nothing (pings, ACK requests, ACKs) and those that carry something (stream data, datagrams, the handshake's).
/// A connection that only trades the first kind, thousands of packets a second, is a storm (mesh/storms.ts).
#[napi(object)]
pub struct Stats {
    pub rx_bytes: f64,
    pub tx_bytes: f64,
    pub rx_packets: f64,
    pub tx_packets: f64,
    pub rx_pings: f64,
    pub tx_pings: f64,
    pub rx_ack_requests: f64,
    pub tx_ack_requests: f64,
    pub rx_acks: f64,
    pub tx_acks: f64,
    pub rx_data: f64,
    pub tx_data: f64,
}

/// Why a connection went: `application` (the other end closed it, saying `reason`), `local`, `timeout`, or `other`
/// (`reason` in words).
#[napi(object)]
pub struct CloseInfo {
    pub kind: String,
    pub reason: String,
}

/// Which of a connection's ways it goes by now (an index into them, each said as whether iroh selected it, whether it
/// is a relay's, and the datagrams sent on it): the one iroh selected; where it selected none while the connection
/// carries on (two connections of one endpoint to the same other, a way moved between a machine's interfaces: Windows to
/// Windows on several networks), the way the packets go, a direct one before a relay's and the busiest first; with none
/// sent yet, the only way there is, or the first where every way is direct. None only where it may still be a relay's.
/// (client/shell's `chosen_way`, the same.)
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

fn close_info(error: &iroh::endpoint::ConnectionError) -> CloseInfo {
    use iroh::endpoint::ConnectionError;
    match error {
        ConnectionError::ApplicationClosed(close) => CloseInfo { kind: "application".into(), reason: String::from_utf8_lossy(&close.reason).into_owned() },
        ConnectionError::LocallyClosed => CloseInfo { kind: "local".into(), reason: String::new() },
        ConnectionError::TimedOut => CloseInfo { kind: "timeout".into(), reason: String::new() },
        other => CloseInfo { kind: "other".into(), reason: other.to_string() },
    }
}

#[napi]
pub struct Connection {
    inner: IrohConnection,
    /// Its datagrams' reader while a view takes them (screen_dgram.rs `route`).
    demux: Arc<StdMutex<std::sync::Weak<screen_dgram::Demux>>>,
}

#[napi]
impl Connection {
    /// The device at the other end (hex).
    #[napi]
    pub fn remote_id(&self) -> String {
        hex::encode(self.inner.remote_id().as_bytes())
    }

    #[napi]
    pub fn alpn(&self) -> Buffer {
        self.inner.alpn().to_vec().into()
    }

    /// How it runs now: "relay", "direct", or null while none is chosen.
    #[napi]
    pub fn via(&self) -> Option<String> {
        let paths = self.inner.paths();
        let ways: Vec<_> = paths.iter().collect();
        let chosen = chosen_way(&ways.iter().map(|p| (p.is_selected(), p.is_relay(), p.stats().udp_tx.datagrams)).collect::<Vec<_>>());
        chosen.map(|i| if ways[i].is_relay() { "relay" } else { "direct" }.to_string())
    }

    /// The next stream the other end opened; null once the connection is gone.
    #[napi]
    pub async fn accept_bi(&self) -> Option<Stream> {
        let (send, recv) = self.inner.accept_bi().await.ok()?;
        Some(Stream::new(send, recv, self))
    }

    #[napi]
    pub async fn open_bi(&self) -> napi::Result<Stream> {
        let (send, recv) = self.inner.open_bi().await.map_err(failed)?;
        Ok(Stream::new(send, recv, self))
    }

    #[napi]
    pub fn close(&self, code: u32, reason: String) {
        self.inner.close(code.into(), reason.as_bytes());
    }

    /// Whether it is gone already.
    #[napi]
    pub fn is_closed(&self) -> bool {
        self.inner.close_reason().is_some()
    }

    /// Resolves when it is gone, with why.
    #[napi]
    pub async fn closed(&self) -> String {
        self.inner.closed().await.to_string()
    }

    /// Resolves when it is gone, with why, told apart (`CloseInfo`).
    #[napi]
    pub async fn closed_info(&self) -> CloseInfo {
        close_info(&self.inner.closed().await)
    }

    /// Why it is gone, if it is.
    #[napi]
    pub fn close_reason(&self) -> Option<CloseInfo> {
        self.inner.close_reason().map(|e| close_info(&e))
    }

    /// Every way it can go now.
    #[napi]
    pub fn paths(&self) -> Vec<PathState> {
        let paths = self.inner.paths();
        let ways: Vec<_> = paths.iter().collect();
        // `selected`: the way it goes by (chosen_way), which iroh may leave unmarked while it carries on.
        let chosen = chosen_way(&ways.iter().map(|p| (p.is_selected(), p.is_relay(), p.stats().udp_tx.datagrams)).collect::<Vec<_>>());
        ways.iter().enumerate().map(|(i, p)| {
            let stats = p.stats();
            PathState {
                id: p.id().to_string(),
                selected: chosen == Some(i),
                relay: match p.remote_addr() {
                    iroh::TransportAddr::Relay(url) => Some(url.to_string()),
                    _ => None,
                },
                ip: match p.remote_addr() {
                    iroh::TransportAddr::Ip(addr) => Some(addr.to_string()),
                    _ => None,
                },
                rtt_ms: stats.same_path_rtt.map(|rtt| rtt.as_secs_f64() * 1000.0),
                tx_packets: stats.udp_tx.datagrams as f64,
                lost_packets: stats.lost_packets as f64,
                cwnd: stats.cwnd as f64,
                congestion_events: stats.congestion_events as f64,
            }
        }).collect()
    }

    /// Whether the other end is still there: asked with a datagram (which a live end acknowledges at once) a few times
    /// within `within_ms`, true as soon as anything is heard from it. A process killed with the connection open says
    /// nothing, and the connection would only go at QUIC's idle timeout (CONNECTION_IDLE_MS). An end that takes no
    /// datagrams is not asked, and counts as there.
    #[napi]
    pub async fn answers(&self, within_ms: u32) -> bool {
        let heard = self.inner.stats().udp_rx.datagrams;
        let within = Duration::from_millis(within_ms.into());
        let deadline = Instant::now() + within;
        let mut ask = Instant::now();
        loop {
            if self.inner.close_reason().is_some() {
                return false;
            }
            if self.inner.stats().udp_rx.datagrams > heard {
                return true;
            }
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            if now >= ask {
                match self.inner.send_datagram(bytes::Bytes::from_static(&[0])) {
                    Ok(()) => {}
                    Err(iroh::endpoint::SendDatagramError::ConnectionLost(_)) => return false,
                    Err(_) => return true,
                }
                ask = now + within / 3;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    #[napi]
    pub fn stats(&self) -> Stats {
        let stats = self.inner.stats();
        let data = |f: &iroh::endpoint::FrameStats| (f.stream + f.datagram + f.crypto) as f64;
        Stats {
            rx_bytes: stats.udp_rx.bytes as f64,
            tx_bytes: stats.udp_tx.bytes as f64,
            rx_packets: stats.udp_rx.datagrams as f64,
            tx_packets: stats.udp_tx.datagrams as f64,
            rx_pings: stats.frame_rx.ping as f64,
            tx_pings: stats.frame_tx.ping as f64,
            rx_ack_requests: stats.frame_rx.immediate_ack as f64,
            tx_ack_requests: stats.frame_tx.immediate_ack as f64,
            rx_acks: (stats.frame_rx.acks + stats.frame_rx.path_acks) as f64,
            tx_acks: (stats.frame_tx.acks + stats.frame_tx.path_acks) as f64,
            rx_data: data(&stats.frame_rx),
            tx_data: data(&stats.frame_tx),
        }
    }

    /// A stream one way: what measures a round trip sends a byte on it (mesh.rs `sample_relay_rtt`).
    #[napi]
    pub async fn open_uni(&self) -> napi::Result<UniStream> {
        let send = self.inner.open_uni().await.map_err(failed)?;
        Ok(UniStream { send: Arc::new(Mutex::new(send)) })
    }
}

#[napi]
pub struct UniStream {
    send: Arc<Mutex<SendStream>>,
}

#[napi]
impl UniStream {
    #[napi]
    pub async fn write(&self, bytes: Buffer) -> napi::Result<()> {
        self.send.lock().await.write_all(&bytes).await.map_err(failed)
    }

    #[napi]
    pub async fn finish(&self) -> napi::Result<()> {
        self.send.lock().await.finish().map_err(failed)
    }

    /// Resolves once what was sent is acknowledged: null, or the code the other end stopped it with.
    #[napi]
    pub async fn stopped(&self) -> napi::Result<Option<u32>> {
        let stopped = self.send.lock().await.stopped();
        let code = stopped.await.map_err(failed)?;
        Ok(code.map(|c| u32::try_from(c.into_inner()).unwrap_or(u32::MAX)))
    }
}

#[napi]
pub struct Stream {
    send: Arc<Mutex<SendStream>>,
    recv: Arc<Mutex<RecvStream>>,
    /// Set by `reset`: a read waiting on the other end gives up (it holds the receiving half meanwhile).
    reset: tokio::sync::watch::Sender<bool>,
    conn: IrohConnection,
    demux: Arc<StdMutex<std::sync::Weak<screen_dgram::Demux>>>,
    /// A remote screen's view this end sends: its video and audio frames as datagrams (`mediaDatagrams`).
    media_out: Arc<Mutex<Option<screen_dgram::MediaOut>>>,
    /// One this end receives: its frames that come as datagrams, put back among the stream's (`receiveMediaDatagrams`).
    media_in: Arc<Mutex<Option<screen_dgram::MediaRx>>>,
    /// Datagram ACKs arriving for a view this end sends (`mediaDatagrams`), injected at stream frame boundaries.
    ack_in: Arc<Mutex<Option<screen_dgram::AckRx>>>,
    ack_ready: tokio::sync::watch::Sender<bool>,
    /// What a read took of the stream and of the datagrams and has not given yet (a frame of datagrams waits for the
    /// stream to be between two frames).
    pending: Arc<StdMutex<Vec<u8>>>,
}

impl Stream {
    fn new(send: SendStream, recv: RecvStream, conn: &Connection) -> Stream {
        Stream {
            send: Arc::new(Mutex::new(send)),
            recv: Arc::new(Mutex::new(recv)),
            reset: tokio::sync::watch::channel(false).0,
            conn: conn.inner.clone(),
            demux: conn.demux.clone(),
            media_out: Arc::default(),
            media_in: Arc::default(),
            ack_in: Arc::default(),
            ack_ready: tokio::sync::watch::channel(false).0,
            pending: Arc::default(),
        }
    }

    /// `read` of a view's stream that sends media datagrams: reads client frames from the stream and injects
    /// unreliable datagram ACKs (`KIND_ACK`) at frame boundaries without splitting any stream frame.
    async fn read_with_acks(&self, acks: &mut screen_dgram::AckRx, mut reset: tokio::sync::watch::Receiver<bool>) -> napi::Result<Option<Buffer>> {
        let mut buf = vec![0u8; 64 * 1024];
        let mut out = std::mem::take(&mut *self.pending.lock().unwrap());
        loop {
            if acks.at_boundary() {
                acks.drain_into(&mut out);
            }
            if !out.is_empty() {
                return Ok(Some(out.into()));
            }
            let mut recv = self.recv.lock().await;
            tokio::select! {
                read = recv.read(&mut buf) => match read.map_err(failed)? {
                    Some(n) => {
                        let chunk = &buf[..n];
                        match acks.stream(chunk) {
                            Some(b) => {
                                out.extend_from_slice(&chunk[..b]);
                                acks.drain_into(&mut out);
                                out.extend_from_slice(&chunk[b..]);
                            }
                            None => out.extend_from_slice(chunk),
                        }
                    }
                    None => return Ok(None),
                },
                d = acks.next() => acks.take_waiting(d),
                _ = reset.changed() => {
                    *self.pending.lock().unwrap() = out;
                    return Ok(None);
                }
            }
        }
    }

    /// `read` of a view's stream whose frames come as datagrams too (screen_dgram.rs): the stream's bytes, with the
    /// frames made whole put in between two of its frames; the station asked for a key frame where one could not be had.
    async fn read_with_datagrams(&self, media: &mut screen_dgram::MediaRx, mut reset: tokio::sync::watch::Receiver<bool>) -> napi::Result<Option<Buffer>> {
        use tokio::time::Instant as Now;
        let mut buf = vec![0u8; 64 * 1024];
        let mut out = std::mem::take(&mut *self.pending.lock().unwrap());
        loop {
            if media.media.at_boundary() {
                media.media.drain_into(&mut out);
            }
            if !out.is_empty() {
                return Ok(Some(out.into()));
            }
            if media.media.take_keyframe(Now::now()) {
                let send = self.send.clone();
                tokio::spawn(async move {
                    let _ = send.lock().await.write_all(&screen_dgram::KEYFRAME_FRAME).await;
                });
            }
            let mut recv = self.recv.lock().await;
            let deadline = media.media.deadline();
            tokio::select! {
                read = recv.read(&mut buf) => match read.map_err(failed)? {
                    Some(n) => {
                        let chunk = &buf[..n];
                        match media.media.stream(chunk, tokio::time::Instant::now()) {
                            Some(b) => {
                                out.extend_from_slice(&chunk[..b]);
                                media.media.drain_into(&mut out);
                                out.extend_from_slice(&chunk[b..]);
                            }
                            None => out.extend_from_slice(chunk),
                        }
                    }
                    None => return Ok(None),
                },
                d = media.next() => media.take_waiting(d, Now::now()),
                _ = screen_dgram::until(deadline) => media.media.tick(Now::now()),
                _ = reset.changed() => {
                    *self.pending.lock().unwrap() = out;
                    return Ok(None);
                }
            }
        }
    }
}

#[napi]
impl Stream {
    /// What came next, up to 64 KiB; null at its end (or once it was reset).
    #[napi]
    pub async fn read(&self) -> napi::Result<Option<Buffer>> {
        let mut reset = self.reset.subscribe();
        if *reset.borrow() {
            return Ok(None);
        }
        {
            let mut media = self.media_in.lock().await;
            if let Some(media) = media.as_mut() {
                return self.read_with_datagrams(media, reset).await;
            }
        }
        {
            let mut acks = self.ack_in.lock().await;
            if let Some(acks) = acks.as_mut() {
                return self.read_with_acks(acks, reset).await;
            }
        }
        let mut ack_ready = self.ack_ready.subscribe();
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            if *ack_ready.borrow() {
                let mut acks = self.ack_in.lock().await;
                if let Some(acks) = acks.as_mut() {
                    return self.read_with_acks(acks, reset).await;
                }
            }
            let read = {
                let mut recv = self.recv.lock().await;
                tokio::select! {
                    read = recv.read(&mut buf) => Some(read.map_err(failed)?),
                    _ = ack_ready.changed() => None,
                    _ = reset.changed() => return Ok(None),
                }
            };
            let Some(read) = read else { continue };
            match read {
                Some(n) => {
                    buf.truncate(n);
                    return Ok(Some(buf.into()));
                }
                None => return Ok(None),
            }
        }
    }

    #[napi]
    pub async fn write(&self, bytes: Buffer) -> napi::Result<()> {
        let mut send = self.send.lock().await;
        match self.media_out.lock().await.as_mut() {
            Some(media) => media.write(&mut *send, &bytes).await.map_err(failed),
            None => send.write_all(&bytes).await.map_err(failed),
        }
    }

    /// A remote screen's view this end sends (a station's): its video and audio frames sent from now on as datagrams
    /// on its connection under `token`, written before its reply's head line (screen_dgram.rs). False where the
    /// connection's datagrams will not do: they go on the stream as before.
    #[napi]
    pub async fn media_datagrams(&self, token: u32) -> bool {
        match screen_dgram::MediaOut::new(self.conn.clone(), token) {
            Some(mut media) => {
                if let Some(acks) = media.take_ack_rx() {
                    *self.ack_in.lock().await = Some(acks);
                    let _ = self.ack_ready.send(true);
                }
                *self.media_out.lock().await = Some(media);
                true
            }
            None => false,
        }
    }

    /// A remote screen's view this end asks for (a client's), before its head goes: what comes as datagrams under
    /// `token` on its connection given from now on among what `read` gives, as if it came on the stream. False where
    /// another view on the connection has that token.
    #[napi]
    pub async fn receive_media_datagrams(&self, token: u32) -> bool {
        let Some((route, rx)) = screen_dgram::route(&self.demux, &self.conn, token) else { return false };
        *self.media_in.lock().await = Some(screen_dgram::MediaRx { media: screen_dgram::MediaIn::new(token, true), rx, rx_done: false, _route: route });
        true
    }

    #[napi]
    pub async fn finish(&self) -> napi::Result<()> {
        self.send.lock().await.finish().map_err(failed)
    }

    /// Resolves once what was sent is acknowledged: null; or the code the other end stopped reading with; or null once
    /// the stream is gone.
    #[napi]
    pub async fn stopped(&self) -> Option<u32> {
        // The future owns what it waits on: taken under the lock and awaited without it, so writes go on meanwhile.
        let stopped = self.send.lock().await.stopped();
        stopped.await.ok().flatten().map(|c| u32::try_from(c.into_inner()).unwrap_or(u32::MAX))
    }

    /// Ends it at once, both ways: a read waiting gives up first, so the receiving half can be stopped.
    #[napi]
    pub async fn reset(&self, code: u32) {
        let _ = self.reset.send(true);
        let _ = self.send.lock().await.reset(code.into());
        let _ = self.recv.lock().await.stop(code.into());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use n0_future::StreamExt;

    /// A probe's finding as the station's Node reads it (relays.ts): `ok`, or what failed.
    #[test]
    fn a_probe_says_what_failed() {
        assert_eq!(ProbeRelayResult::of(keep::ProbeResult::Ok), ProbeRelayResult { ok: true, stage: None });
        assert_eq!(ProbeRelayResult::of(keep::ProbeResult::ProbeOffline), ProbeRelayResult { ok: false, stage: Some("probe_offline".into()) });
        assert_eq!(ProbeRelayResult::of(keep::ProbeResult::EndpointFailed), ProbeRelayResult { ok: false, stage: Some("endpoint_failed".into()) });
    }

    /// A way of finding stations that cannot be made, as mDNS is with UDP 5353 unavailable.
    #[derive(Debug)]
    struct Unavailable;

    #[derive(Debug)]
    struct Nothing;

    impl AddressLookup for Nothing {}

    impl AddressLookupBuilder for Unavailable {
        fn into_address_lookup(self, _endpoint: &IrohEndpoint) -> Result<impl AddressLookup, AddressLookupBuilderError> {
            Err::<Nothing, _>(AddressLookupBuilderError::from_err("mdns", std::io::Error::other("no network")))
        }
    }

    /// What came to `socket` since it was last asked: datagrams, counted.
    fn arrived(socket: &tokio::net::UdpSocket) -> usize {
        let mut buf = [0u8; 2048];
        let mut n = 0;
        while socket.try_recv(&mut buf).is_ok() {
            n += 1;
        }
        n
    }

    /// A dial whose caller gave up sends nothing more to the station, and the endpoint closes at once; one nobody gives
    /// up goes on retransmitting its Initial until the connection's idle timeout (CONNECTION_IDLE_MS), and the endpoint's
    /// close waits that long for it. On the test's clock (paused: it moves when nothing else can), a socket that takes
    /// every datagram and answers none in place of the station.
    #[tokio::test(start_paused = true)]
    async fn a_dial_given_up_sends_no_more() {
        let quiet = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let station = EndpointAddr::new(SecretKey::from_bytes(&[7; 32]).public()).with_ip_addr(quiet.local_addr().unwrap());
        let endpoint = IrohEndpoint::builder(Minimal).relay_mode(RelayMode::Disabled).bind().await.unwrap();
        let (give_up, given_up) = tokio::sync::oneshot::channel::<()>();
        let dialing = tokio::spawn({
            let endpoint = endpoint.clone();
            async move { dial(&endpoint, station, b"test", iroh::endpoint::ConnectOptions::new(), async { drop(given_up.await) }).await }
        });
        // The app's CONNECT_TIMEOUT_MS: its Initial sent, and again as nothing answers.
        tokio::time::sleep(Duration::from_secs(10)).await;
        assert!(arrived(&quiet) >= 2, "the dial sent its Initial and retransmitted it");
        give_up.send(()).unwrap();
        assert_eq!(dialing.await.unwrap().unwrap_err().to_string(), "given up");
        // What its close sends, then nothing for the rest of the ten minutes.
        tokio::time::sleep(Duration::from_secs(1)).await;
        arrived(&quiet);
        tokio::time::sleep(Duration::from_millis(CONNECTION_IDLE_MS.into())).await;
        assert_eq!(arrived(&quiet), 0, "a dial given up went on sending");
        let closing = tokio::time::Instant::now();
        endpoint.close().await;
        assert!(closing.elapsed() < Duration::from_secs(5), "the endpoint's close waited {:?}", closing.elapsed());
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

    /// What the station sends its device through the way between them (a socket in place of a relay: what the device
    /// sends goes on to the station until the device is gone, what the station sends back is counted and goes nowhere)
    /// in the 5 s after a handshake the device let go of half way was given up after `limit`, or, with none, kept.
    async fn sent_after_half_way(limit: Option<Duration>) -> usize {
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering as O};
        let local = std::net::SocketAddr::from(([127, 0, 0, 1], 0));
        let station = IrohEndpoint::builder(Minimal).alpns(vec![b"test".to_vec()]).relay_mode(RelayMode::Disabled).transport_config(transport("cubic").unwrap()).bind_addr(local).unwrap().bind().await.unwrap();
        let at = std::net::SocketAddr::from(([127, 0, 0, 1], station.bound_sockets().iter().find(|s| s.is_ipv4()).unwrap().port()));
        let between = Arc::new(tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap());
        let gone = Arc::new(AtomicBool::new(false));
        let back = Arc::new(AtomicUsize::new(0));
        let passing = tokio::spawn({
            let (between, gone, back) = (between.clone(), gone.clone(), back.clone());
            async move {
                let mut buf = [0u8; 2048];
                while let Ok((n, from)) = between.recv_from(&mut buf).await {
                    if from == at {
                        back.fetch_add(1, O::SeqCst);
                    } else if !gone.load(O::SeqCst) {
                        let _ = between.send_to(&buf[..n], at).await;
                    }
                }
            }
        });
        let device = IrohEndpoint::builder(Minimal).relay_mode(RelayMode::Disabled).bind_addr(local).unwrap().bind().await.unwrap();
        let dialing = tokio::spawn({
            let device = device.clone();
            let to = EndpointAddr::new(station.id()).with_ip_addr(between.local_addr().unwrap());
            async move { device.connect(to, b"test").await }
        });
        let incoming = station.accept().await.expect("the device's Initial came in");
        gone.store(true, O::SeqCst);
        dialing.abort();
        let kept = match limit {
            Some(limit) => {
                let started = tokio::time::Instant::now();
                assert!(handshake(incoming.remote_addr(), incoming, limit).await.is_none(), "a handshake with nobody at the other end was done");
                assert!(started.elapsed() >= limit, "given up after {:?}", started.elapsed());
                None
            }
            None => Some(tokio::spawn(async move { incoming.await.is_ok() })),
        };
        // What a close sends, and the station's first answers, then what it sends on.
        tokio::time::sleep(Duration::from_secs(1)).await;
        back.store(0, O::SeqCst);
        tokio::time::sleep(Duration::from_secs(5)).await;
        let sent = back.load(O::SeqCst);
        kept.map(|k| k.abort());
        passing.abort();
        station.close().await;
        device.close().await;
        sent
    }

    /// A handshake given up sends nothing more, where one kept goes on sending (to the station's idle timeout, ten
    /// minutes). On real time, the machine's: iroh's timers are not the test's clock (paused, a handshake failed of
    /// iroh's own idle timeout after 30 s of the machine's while the test's had moved 226 ms).
    #[tokio::test]
    #[ignore = "side: real sockets on this machine, and their time"]
    async fn a_handshake_given_up_sends_no_more() {
        let kept = sent_after_half_way(None).await;
        assert!(kept > 0, "a handshake kept sent nothing in 5 s: the window shows nothing");
        assert_eq!(sent_after_half_way(Some(Duration::from_millis(200))).await, 0, "a handshake given up went on sending");
    }

    #[tokio::test]
    async fn an_unmade_lookup_leaves_the_endpoint_up() {
        let failing = IrohEndpoint::builder(Minimal).relay_mode(RelayMode::Disabled).address_lookup(Unavailable).bind().await;
        assert!(failing.is_err(), "iroh fails an endpoint whose lookup is not made");
        let endpoint = IrohEndpoint::builder(Minimal).relay_mode(RelayMode::Disabled).address_lookup(Optional("mDNS", Unavailable)).bind().await;
        assert!(endpoint.is_ok(), "{:?}", endpoint.err());
        endpoint.unwrap().close().await;
    }

    /// Two relays on this machine (`r` standing for one of still.fail's, `own` for the workspace's), each with what it
    /// was sent counted, a station on both and a peer on both answering each stream with what it read.
    struct TwoRelays {
        r: RelayUrl,
        own: RelayUrl,
        r_server: iroh_relay::server::Server,
        own_server: iroh_relay::server::Server,
        station: Endpoint,
        peer: IrohEndpoint,
    }

    const TEST_ALPN: &[u8] = b"stillfail/test/1";

    impl TwoRelays {
        async fn new() -> TwoRelays {
            let (_, r, r_server) = iroh::test_utils::run_relay_server_with(false).await.unwrap();
            let (_, own, own_server) = iroh::test_utils::run_relay_server_with(false).await.unwrap();
            let options = Options {
                secret_key: vec![11u8; 32].into(),
                alpns: vec![TEST_ALPN.to_vec().into()],
                relay_urls: vec![r.to_string(), own.to_string()],
                relay_entries: None,
                relay_allowlist: None,
                allow_public_relays: None,
                discovery: Some(false),
                dht: None,
                bind_addr: Some("127.0.0.1:0".into()),
                lookup: None,
                relay_only: None,
                congestion: None,
                dscp: None,
            };
            let station = bind_with(options, true).await.unwrap();
            let peer = IrohEndpoint::builder(Minimal)
                .secret_key(SecretKey::from_bytes(&[12; 32]))
                .alpns(vec![TEST_ALPN.to_vec()])
                .relay_mode(RelayMode::Custom(iroh::RelayMap::from_iter([r.clone(), own.clone()])))
                .home_on_every_relay()
                .ca_tls_config(iroh::tls::CaTlsConfig::insecure_skip_verify())
                .bind_addr(std::net::SocketAddr::from(([127, 0, 0, 1], 0)))
                .unwrap()
                .bind()
                .await
                .unwrap();
            tokio::spawn({
                let peer = peer.clone();
                async move {
                    while let Some(incoming) = peer.accept().await {
                        tokio::spawn(async move {
                            let Ok(conn) = incoming.await else { return };
                            while let Ok((mut send, mut recv)) = conn.accept_bi().await {
                                let got = recv.read_to_end(1 << 16).await.unwrap_or_default();
                                let _ = send.write_all(&got).await;
                                let _ = send.finish();
                            }
                        });
                    }
                }
            });
            let here = station.inner.clone();
            tokio::time::timeout(Duration::from_secs(20), async { tokio::join!(here.online(), peer.online()) }).await.expect("both on their relays in time");
            TwoRelays { r, own, r_server, own_server, station, peer }
        }

        /// What a relay was sent by its clients to pass on (datagrams), so far.
        fn sent(server: &iroh_relay::server::Server) -> u64 {
            server.metrics().server.send_packets_recv.get()
        }

        /// The peer as the station dials it: by `relays`, and by its address on this machine.
        fn addr(&self, relays: &[&RelayUrl]) -> Addr {
            let port = self.peer.bound_sockets().iter().find(|s| s.is_ipv4()).unwrap().port();
            Addr { mesh_scope: None, disabled_relays: None, id: hex::encode(self.peer.id().as_bytes()), relays: Some(relays.iter().map(|r| r.to_string()).collect()), ips: Some(vec![format!("127.0.0.1:{port}")]) }
        }

        async fn dial(&self, relays: &[&RelayUrl]) -> Connection {
            tokio::time::timeout(Duration::from_secs(20), self.station.connect(self.addr(relays), TEST_ALPN.to_vec().into(), None, None)).await.expect("dialed in time").unwrap()
        }
    }

    /// Until `conn` has a path through `relay` (each change of its paths looked at as it comes; given up after 30 s).
    async fn path_through(conn: &Connection, relay: &RelayUrl) {
        let through = |conn: &Connection| conn.inner.paths().iter().any(|p| matches!(p.remote_addr(), iroh::TransportAddr::Relay(u) if u == relay));
        let mut changes = conn.inner.paths_stream();
        tokio::time::timeout(Duration::from_secs(30), async {
            while !through(conn) {
                if changes.next().await.is_none() {
                    break;
                }
            }
        })
        .await
        .expect("a path through the relay in time");
        assert!(through(conn), "the connection ended with no path through {relay}");
    }

    /// Until `server` was sent `more` datagrams past `from`: the time it takes paths to be kept alive through it some
    /// rounds, counted, not slept (given up after 60 s).
    async fn sent_past(server: &iroh_relay::server::Server, from: u64, more: u64) {
        tokio::time::timeout(Duration::from_secs(60), async {
            while TwoRelays::sent(server) < from + more {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await
        .expect("the relay passed datagrams on in time");
    }

    /// A stream both ways on `conn`: what went came back.
    async fn echoes(conn: &Connection) {
        let (mut send, mut recv) = conn.inner.open_bi().await.unwrap();
        send.write_all(b"still there").await.unwrap();
        send.finish().unwrap();
        assert_eq!(recv.read_to_end(64).await.unwrap(), b"still there");
    }

    /// What the station handed to relay `relay` for the peer so far (iroh's count where datagrams go to the relay
    /// transports: the station's own, to that peer alone).
    fn handed(t: &TwoRelays, relay: &RelayUrl) -> u64 {
        t.station.inner.relay_datagrams(relay, &t.peer.id()).sent
    }

    /// A connection kept (the direct path chosen, a backup path through each relay) while `r` is turned off for its peer
    /// (`disabled_relays`, as a workspace turning it off has the station hold it, no dial): once that resolves the path
    /// through `r` is given up, nothing more is handed to `r` for the peer, and `r` passes nothing on in a window after
    /// one that lets what was on its way pass, the connection going on over its direct path. Before the endpoint held
    /// what a connection had (#6692 on zzj3720/iroh#17), `r` passed on 14, then 4 in such windows. Real relays and
    /// their time: the side run's.
    #[tokio::test]
    #[ignore = "side: real relays on this machine, and their time"]
    async fn a_connection_kept_while_its_peer_is_narrowed_drops_the_backup_through_the_relay_turned_off() {
        let t = TwoRelays::new().await;
        let peer = hex::encode(t.peer.id().as_bytes());
        let conn = t.dial(&[&t.r, &t.own]).await;
        path_through(&conn, &t.r).await;
        path_through(&conn, &t.own).await;
        echoes(&conn).await;
        let chosen_direct = |c: &Connection| c.inner.paths().iter().any(|p| p.is_ip() && p.is_selected());
        tokio::time::timeout(Duration::from_secs(30), async {
            while !chosen_direct(&conn) {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await
        .expect("the direct path chosen in time");
        assert!(conn.inner.paths().iter().any(|p| !p.is_selected() && matches!(p.remote_addr(), iroh::TransportAddr::Relay(u) if u == &t.r)), "a backup path through r");
        t.station.disabled_relays(peer, vec![t.r.to_string()], Some(false)).await.unwrap();
        let (r_before, handed_before) = (TwoRelays::sent(&t.r_server), handed(&t, &t.r));
        assert!(!conn.inner.paths().iter().any(|p| matches!(p.remote_addr(), iroh::TransportAddr::Relay(u) if u == &t.r)), "the path through r given up as it took hold");
        let own_from = TwoRelays::sent(&t.own_server);
        sent_past(&t.own_server, own_from, 4).await;
        let r_settled = TwoRelays::sent(&t.r_server);
        sent_past(&t.own_server, own_from, 12).await;
        let (r_after, handed_after) = (TwoRelays::sent(&t.r_server), handed(&t, &t.r));
        echoes(&conn).await;
        eprintln!("after r was turned off for the kept connection's peer: handed to r for it {}, r sent {} then {} (own sent {})", handed_after - handed_before, r_settled - r_before, r_after - r_settled, TwoRelays::sent(&t.own_server) - own_from);
        assert_eq!(handed_after, handed_before, "the station handed r datagrams for the peer after it was turned off for it");
        assert_eq!(r_after, r_settled, "r passed datagrams on in the second window");
        assert!(conn.inner.paths().iter().any(|p| p.is_ip()), "the direct path kept");
        assert!(conn.inner.close_reason().is_none(), "the connection goes on");
        t.station.close().await;
        t.peer.close().await;
    }

    #[test]
    fn build_relay_allowlist_covers_explicit_empty_entries_public_lookup_and_discovery() {
        let r1 = relay_url("https://relay-a.example.test/").unwrap();
        let e1 = relay_url("https://entry-a.example.test:8443/").unwrap();
        let unlisted = relay_url("https://relay.pvg-office-4.monoid-afk.dev/").unwrap();
        let prod: Vec<RelayUrl> = iroh::defaults::prod::default_relay_map().relays::<Vec<_>>().into_iter().map(|c| c.url.clone()).collect();
        assert!(!prod.is_empty());

        let list = build_relay_allowlist(Some(vec![r1.clone()]), false, false, &[r1.clone()], &[(e1.clone(), r1.clone())]).unwrap();
        assert!(list.contains(&r1));
        assert!(list.contains(&e1));
        assert!(!list.contains(&unlisted));
        assert!(prod.iter().all(|p| !list.contains(p)));

        let empty = build_relay_allowlist(Some(vec![]), false, false, &[], &[]).unwrap();
        assert!(empty.is_empty());

        let with_pub = build_relay_allowlist(Some(vec![r1.clone()]), true, true, &[r1.clone()], &[]).unwrap();
        assert!(with_pub.contains(&r1));
        assert!(prod.iter().all(|p| with_pub.contains(p)));
        assert!(!with_pub.contains(&unlisted));

        let lookup_fallback = build_relay_allowlist(None, true, false, &[r1.clone()], &[(e1.clone(), r1.clone())]).unwrap();
        assert!(lookup_fallback.contains(&r1));
        assert!(lookup_fallback.contains(&e1));
        assert!(prod.iter().all(|p| lookup_fallback.contains(p)));
        assert!(!lookup_fallback.contains(&unlisted));

        assert!(build_relay_allowlist(None, false, false, &[r1.clone()], &[]).is_none());
        assert!(build_relay_allowlist(None, true, false, &[], &[]).is_none());
    }

    #[tokio::test]
    async fn bind_with_enforces_relay_allowlist_and_keeps_unrestricted_station_open() {
        let allowed = relay_url("https://relay-a.example.test/").unwrap();
        let entry = relay_url("https://entry-a.example.test:8443/").unwrap();
        let unlisted = relay_url("https://relay.pvg-office-4.monoid-afk.dev/").unwrap();
        let prod = iroh::defaults::prod::default_relay_map().relays::<Vec<_>>().into_iter().next().unwrap().url.clone();

        // Client endpoint with explicit allowlist + entry + allow_public_relays: rejects unlisted, admits entry & prod.
        let client = bind_with(
            Options {
                secret_key: vec![21u8; 32].into(),
                alpns: vec![],
                relay_urls: vec![allowed.to_string()],
                relay_entries: Some(vec![RelayEntry { entry: entry.to_string(), relay: allowed.to_string() }]),
                relay_allowlist: Some(vec![allowed.to_string()]),
                allow_public_relays: Some(true),
                discovery: Some(false),
                dht: None,
                bind_addr: Some("127.0.0.1:0".into()),
                lookup: Some(false),
                relay_only: Some(false),
                congestion: None,
                dscp: None,
            },
            true,
        )
        .await
        .unwrap();
        client.inner.insert_relay(unlisted.clone(), Arc::new(iroh::RelayConfig::from(unlisted.clone()))).await;
        assert!(client.inner.remove_relay(&unlisted).await.is_none(), "unlisted relay must be rejected");
        client.inner.insert_relay(entry.clone(), Arc::new(iroh::RelayConfig::from(entry.clone()))).await;
        assert!(client.inner.remove_relay(&entry).await.is_some(), "entry relay must be accepted");
        client.inner.insert_relay(prod.clone(), Arc::new(iroh::RelayConfig::from(prod.clone()))).await;
        assert!(client.inner.remove_relay(&prod).await.is_some(), "prod relay must be accepted when allow_public_relays is true");
        client.close().await;

        // Station endpoint with no allowlist (unrestricted): insert_relay still works for any relay.
        let station = bind_with(
            Options {
                secret_key: vec![22u8; 32].into(),
                alpns: vec![],
                relay_urls: vec![allowed.to_string()],
                relay_entries: None,
                relay_allowlist: None,
                allow_public_relays: None,
                discovery: Some(false),
                dht: None,
                bind_addr: Some("127.0.0.1:0".into()),
                lookup: Some(false),
                relay_only: Some(false),
                congestion: None,
                dscp: None,
            },
            true,
        )
        .await
        .unwrap();
        station.inner.insert_relay(unlisted.clone(), Arc::new(iroh::RelayConfig::from(unlisted.clone()))).await;
        assert!(station.inner.remove_relay(&unlisted).await.is_some(), "unrestricted station endpoint must still admit inserted relays");
        station.close().await;
    }

    #[tokio::test]
    async fn filtered_lookup_strips_unlisted_relays_keeps_ip_and_admits_dynamic_entries() {
        use iroh::address_lookup::{EndpointInfo, Item};

        #[derive(Debug)]
        struct FakeLookup(Item);
        impl AddressLookup for FakeLookup {
            fn resolve(&self, _endpoint_id: EndpointId) -> Option<BoxStream<Result<Item, AddressLookupError>>> {
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

        let allowed = Arc::new(StdRwLock::new(BTreeSet::from([allowed_relay.clone()])));
        let filtered = Filtered(allowed.clone(), FakeLookup(item));

        let first = filtered.resolve(peer_id).unwrap().next().await.unwrap().unwrap();
        let addrs: Vec<_> = first.endpoint_info().data.addrs().cloned().collect();
        assert!(addrs.contains(&iroh::TransportAddr::Ip(ip)));
        assert!(addrs.contains(&iroh::TransportAddr::Relay(allowed_relay.clone())));
        assert!(!addrs.contains(&iroh::TransportAddr::Relay(stale_dht.clone())));
        assert!(!addrs.contains(&iroh::TransportAddr::Relay(dynamic_entry.clone())));

        allowed.write().unwrap().insert(dynamic_entry.clone());
        let second = filtered.resolve(peer_id).unwrap().next().await.unwrap().unwrap();
        let addrs2: Vec<_> = second.endpoint_info().data.addrs().cloned().collect();
        assert!(addrs2.contains(&iroh::TransportAddr::Ip(ip)));
        assert!(addrs2.contains(&iroh::TransportAddr::Relay(allowed_relay)));
        assert!(addrs2.contains(&iroh::TransportAddr::Relay(dynamic_entry)));
        assert!(!addrs2.contains(&iroh::TransportAddr::Relay(stale_dht)));
    }

}
