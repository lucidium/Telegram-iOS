# Genuine TLS/WebSocket Relay — Telegram-iOS Client Plan

- **Status:** Design complete and reconciled with the server plan; no implementation changes made
- **Last updated:** 2026-07-24
- **Project:** Official Telegram iOS source tree with local transport research/customization
- **Scope of this document:** Telegram-iOS client only
- **Server-side implementation:** Planned in the companion `mtg` document linked below
- **Related research:**
  - [`mtproxy-research-handoff.md`](mtproxy-research-handoff.md)
  - [`mtproxy-research-findings-2026-07-24.md`](mtproxy-research-findings-2026-07-24.md)
  - [`mtg` genuine TLS/WebSocket relay server plan](../../../mtg/docs/genuine-tls-websocket-relay-server-plan.md)

## 1. Decision and Rationale

The paired direct/VPN captures show behavior consistent with stateful on-path classification rather than a shallow, static ClientHello fingerprint block:

- complete fake ClientHellos initially reached `mtg`;
- the fake ServerHello response was then silently suppressed;
- later connections consistently lost the ClientHello tail after the first 1,448 TCP payload bytes;
- the same endpoint, client, and `ee` secret worked through an unrelated VPN.

This makes continued fake-TLS profile tuning or fragmentation likely to be short-lived. The selected long-term client direction is therefore a new, explicit proxy transport:

```text
Telegram-iOS
    -> URLSessionWebSocketTask
    -> genuine system TLS with normal certificate validation
    -> authenticated WSS endpoint on a user-controlled domain
    -> custom relay
    -> Telegram datacenter
```

This follows the same broad principle as NaiveProxy—carry the real protocol inside a genuine standards-compliant TLS/HTTP connection—but it is **not wire-compatible with NaiveProxy** and does not initially implement HTTP/2 CONNECT.

`URLSessionWebSocketTask` is the minimal suitable Apple API because it provides RFC 6455 message transport over real TCP/TLS, supports asynchronous binary sends and receives, and is available from iOS 13.0. Telegram-iOS currently declares iOS 13.0 as its minimum deployment version.

## 2. Goals, Deliverables, and Constraints

### 2.1 Goal

Add a durable relay transport that uses Apple's genuine TLS stack and carries a secretless padded-intermediate Obfuscated2 MTProto byte stream inside binary WebSocket messages.

### 2.2 Client deliverables

1. A new explicit persisted proxy type for the HTTPS/WebSocket relay.
2. A narrow Objective-C bridge carrying relay settings through the existing `MTApiEnvironment` path.
3. A `URLSessionWebSocketTask` implementation of the existing `MTTcpConnectionInterface` byte-stream contract.
4. A separate optional connection-interface factory for WSS, leaving the existing raw-TCP factory unchanged.
5. A small WSS-specific branch in `MTTcpConnection` that bypasses fake TLS while reusing the existing secretless Obfuscated2 implementation with padded-intermediate framing.
6. Minimal settings, preview, list, QR, clipboard, and custom-link support.
7. Focused model, URL-codec, buffering, ordering, and cancellation tests where practical.
8. Full-project Bazel build verification and physical-device validation after the server exists.

### 2.3 Required invariants

- Existing SOCKS5 behavior remains unchanged.
- Existing 16-byte MTProxy behavior remains unchanged.
- Existing `dd` MTProxy behavior remains unchanged.
- Existing `ee` fake-TLS MTProxy behavior remains unchanged.
- WSS is selected only by a new explicit proxy type.
- WSS keeps `_mtpSecret` nil and explicitly uses padded-intermediate framing; it must not reuse the saved `ee` MTProxy secret.
- WSS uses normal platform trust and hostname validation.
- No custom CA, certificate pinning, or manually generated TLS fingerprint is introduced.
- The bearer token is carried in the encrypted HTTP upgrade request, not in the actual network URL.
- WSS failures do not fall back to fake TLS, plain MTProxy, or raw TCP.
- No Network Extension, packet tunnel, raw packet access, entitlement, or third-party dependency is added.
- Retry and reconnect policy remains owned by the existing MTProto connection machinery.
- Changes are split into small, cherry-pick-friendly commits.

### 2.4 Success criteria

The client work is complete when all of the following are true:

1. Selecting any existing proxy type produces the same transport behavior as before.
2. Selecting a WSS relay produces a real TLS handshake and WebSocket upgrade.
3. No synthetic ClientHello, fake ServerHello, fake CCS, or fake TLS ApplicationData wrapper is used for WSS.
4. Concatenating outbound WebSocket binary messages yields the agreed secretless padded-intermediate Obfuscated2 byte stream, beginning with its standard 64-byte header.
5. Incoming bytes are delivered to `MTTcpConnection` exactly once, in order, independent of WebSocket message boundaries.
6. Invalid certificate, hostname, path, token, redirect, text frame, oversized message, or subprotocol mismatch fails closed.
7. Credentials are redacted from transport logs, object descriptions, and new diagnostics.
8. Existing proxy status checks work through the WSS transport.
9. The full Telegram app target builds successfully.
10. A physical iPhone connects through the relay on unrestricted and restricted Wi-Fi/cellular test paths once the server is implemented.

## 3. Frozen Client/Server Protocol Contract

Server-side source inspection and planning are complete. This section is the shared version 1 wire contract and is mirrored by the companion [`mtg` server plan](../../../mtg/docs/genuine-tls-websocket-relay-server-plan.md).

### 3.1 Saved endpoint configuration

A relay entry contains:

```text
host:  relay.example.com
port:  443
path:  /relay/v1/<deployment-specific-path>
token: high-entropy base64url bearer token
```

Rules:

- `host` is a DNS hostname used for DNS resolution, SNI, and certificate validation.
- Only `wss://` is supported.
- `path` is absolute and begins with `/`.
- Credentials must not be embedded in the path.
- The token should contain at least 32 random bytes encoded as unpadded base64url.
- Port must be in `1...65535`.

The network URL is:

```text
wss://relay.example.com:443/relay/v1/...
```

The bearer token is sent only in the upgrade request:

```http
Authorization: Bearer <token>
```

The versioned WebSocket subprotocol is:

```http
Sec-WebSocket-Protocol: telegram-mtproto-relay.v1
```

The client requires the server to echo the same subprotocol. A mismatch is a protocol error.

### 3.2 Stream semantics

- WebSocket binary messages are the only accepted application messages.
- WebSocket message boundaries have **no protocol meaning**.
- Concatenating all client binary messages reconstructs one ordered upstream byte stream.
- Concatenating all server binary messages reconstructs one ordered downstream byte stream.
- One WSS connection corresponds to one `MTTcpConnection`.
- There is no multiplexing in version 1.
- The first upstream bytes are Telegram-iOS's standard 64-byte Obfuscated2 transport header, generated without an MTProxy secret.
- The WSS branch uses padded-intermediate framing: the canonical plaintext connection-type bytes at offsets 56–59 are `0xdd 0xdd 0xdd 0xdd` (`0xdddddddd`).
- The datacenter tag remains in the standard signed little-endian field at offsets 60–61.
- Packet framing after the header is the existing padded-intermediate format, including its existing bounded random padding behavior.
- There is no additional custom application handshake in version 1.
- The relay derives the Telegram datacenter tag from the standard obfuscated header.
- The relay must permit only known Telegram DC destinations and must not become an arbitrary open CONNECT proxy.
- Closing either side closes the other side.
- There is no stream resumption in version 1.
- WebSocket compression is not negotiated in version 1.

The client should set a bounded `maximumMessageSize`, initially 16 MiB. The server should normally send substantially smaller messages, for example 16–64 KiB, to bound buffering and latency.

### 3.3 Probe and fallback behavior

- `/` and unrelated paths remain ordinary website routes.
- A wrong path or missing/invalid token receives ordinary website content before upgrade through the Nginx fallback deployment.
- The WSS endpoint must not reveal Telegram-specific behavior to unauthenticated requests.
- Redirects are rejected, including same-origin redirects, to keep endpoint and credential handling deterministic.
- The client never retries a failed WSS connection as stock `ee` fake TLS.

## 4. Existing Client Architecture and Chosen Seam

The relevant existing flow is:

```text
ProxyServerSettings
    -> ProxyServerSettings.mtProxySettings
    -> MTSocksProxySettings
    -> MTApiEnvironment.socksProxySettings
    -> MTTcpConnection
    -> MTTcpConnectionInterface
```

`MTTcpConnectionInterface` already provides the necessary narrow stream-like operations:

- connect;
- ordered writes;
- exact-length reads;
- disconnect;
- delegate reset;
- connected/read/disconnected delegate callbacks.

Two current implementations exist:

1. `MTGcdAsyncSocketTcpConnectionInterface`, backed by `GCDAsyncSocket`;
2. `NetworkFrameworkTcpConnectionInterface`, backed by `NWConnection`.

The WSS implementation should conform to the same interface so the MTProto packet state machine remains unchanged. It should use a **separate optional factory**, however, so the signature and selection logic of the existing raw-TCP factory do not change.

## 5. Staged Client Implementation

## Commit 1 — Explicit Model and Narrow Objective-C Bridge

### 5.1 Add a persisted proxy type

Modify:

- `submodules/TelegramCore/Sources/SyncCore/SyncCore_ProxySettings.swift`

Add a new enum case:

```swift
case webSocketRelay(path: String, token: String)
```

Serialization plan:

- `_t = 0`: existing SOCKS5;
- `_t = 1`: existing MTProxy;
- `_t = 2`: WSS relay.

Store `path` and `token` under explicit new keys. Existing fixtures and saved settings must decode without migration or behavioral change. Preserve the current safe behavior for unknown discriminators unless a separate project-wide migration policy requires otherwise.

Continue using `ProxyServerSettings.host` and `.port` as the relay TLS hostname and port. Do not add a second top-level endpoint object.

### 5.2 Extend the existing API-environment bridge

Modify:

- `submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTApiEnvironment.h`
- `submodules/MtProtoKit/Sources/MTApiEnvironment.m`
- `submodules/TelegramCore/Sources/Settings/ProxySettings.swift`

Keep `MTSocksProxySettings` as the existing umbrella bridge, but add nullable read-only relay fields and a dedicated initializer, conceptually:

```objc
@property (nonatomic, readonly, nullable) NSString *webSocketPath;
@property (nonatomic, readonly, nullable) NSString *webSocketToken;

- (instancetype)initWithIp:(NSString *)ip
                       port:(uint16_t)port
              webSocketPath:(NSString *)path
             webSocketToken:(NSString *)token;
```

Do not overload `username`, `password`, or `secret` with relay data. The dedicated fields keep the mode explicit at the Objective-C boundary.

Update `MTSocksProxySettings`:

- `isEqual:` includes relay path and token so edits force a reconnect;
- `description` always redacts the relay token;
- existing initializer semantics remain unchanged.

Update `ProxyServerSettings.mtProxySettings` to map `.webSocketRelay` to the dedicated initializer. Existing SOCKS5 and MTProxy mappings stay byte-for-byte equivalent where possible.

### 5.3 Centralize relay validation

Add one small validation helper in the model/settings layer and reuse it in URL parsing and the editor.

Validate:

- nonempty DNS hostname;
- port in `1...65535`;
- absolute path beginning with `/`;
- no `\r` or `\n` in path or token;
- conservative path and token length limits;
- unpadded base64url token syntax;
- minimum decoded token length of 32 bytes;
- URL construction produces exactly `wss` with the expected host/port/path.

Malformed settings must not reach the transport factory.

### 5.4 Commit boundary

This commit contains only the persisted model, bridge, validation, and their tests. It does not connect to a server and does not alter `MTTcpConnection` behavior.

## Commit 2 — WSS Byte-Stream Backend and Transport Selection

### 5.5 Add the WSS interface

Add:

- `submodules/TelegramCore/Sources/Network/WebSocketTcpConnectionInterface.swift`

The class conforms to `MTTcpConnectionInterface` and is backed by `URLSessionWebSocketTask`.

Use:

- an ephemeral `URLSessionConfiguration`;
- disabled URL cache;
- disabled cookie storage;
- no shared credential storage where configurable;
- a request constructed from a `wss://` URL;
- `Authorization: Bearer ...` on `URLRequest`;
- the required `telegram-mtproto-relay.v1` subprotocol;
- normal system trust handling, with no custom server-trust acceptance;
- a bounded connect/upgrade timeout;
- a serial internal state queue;
- one in-flight WebSocket send at a time;
- a continuously re-armed receive call;
- a FIFO exact-length read-request queue;
- one receive byte buffer;
- disconnect notification exactly once.

### 5.6 Preserve byte-stream semantics

`URLSessionWebSocketTask` is message-oriented while `MTTcpConnectionInterface` is stream-oriented. The adapter must bridge them explicitly.

Outbound behavior:

1. Append each `writeData:` call to a FIFO queue.
2. Do not send application bytes before the WebSocket upgrade succeeds.
3. Maintain only one in-flight `.data` send.
4. Start the next send from the previous send completion.
5. A send error closes the adapter and reports disconnection once.

Inbound behavior:

1. Arm `receive` after the WebSocket opens.
2. Accept `.data` messages only.
3. Append received bytes to the internal buffer.
4. Satisfy queued exact-length reads in order.
5. One WebSocket message may satisfy multiple reads.
6. One read may span multiple WebSocket messages.
7. Deliver partial-read callbacks consistently with existing interfaces where useful.
8. Re-arm `receive` after each successful message.
9. Reject text messages and oversized buffered input.

Cancellation behavior:

- cancellation is idempotent;
- close/cancel session and task resources;
- discard queued sends and reads;
- ignore late URLSession completions;
- notify the delegate at most once;
- after `resetDelegate`, invoke no delegate callbacks.

### 5.7 Reject redirects and protocol mismatches

Use URLSession delegate methods to:

- reject every redirect;
- confirm the final WebSocket protocol is `telegram-mtproto-relay.v1`;
- treat an open callback without the expected protocol as failure;
- leave ordinary certificate and hostname evaluation to the system;
- never implement permissive trust handling.

### 5.8 Network usage accounting

Match existing behavior by feeding outgoing and incoming byte counts to `MTNetworkUsageManager` when usage information is supplied.

Use a narrowly scoped `NWPathMonitor` only to classify the current path as cellular versus other for accounting. It must not participate in DNS, connection establishment, TLS, or fallback behavior.

Document whether accounting counts WebSocket payload bytes or estimated wire bytes. For the minimal implementation, count payload bytes consistently and avoid pretending to know TLS/WebSocket overhead precisely.

### 5.9 Add a separate optional factory

Modify:

- `submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTContext.h`
- `submodules/TelegramCore/Sources/Network/Network.swift`

Add a separate optional factory, conceptually:

```objc
makeWebSocketTcpConnectionInterface(settings, delegate, delegateQueue)
```

Do not change the existing `makeTcpConnectionInterface` signature or behavior. This preserves both current raw-TCP backends and reduces future upstream merge conflicts.

`Network.swift` installs the WSS factory on supported Apple OS versions. The existing debug setting that selects `Network.framework` continues to affect only ordinary raw TCP. WSS always uses `URLSessionWebSocketTask`.

Copy the new factory whenever a temporary `MTContext` copies the raw-TCP factory:

- `submodules/MtProtoKit/Sources/MTProxyConnectivity.m`
- `submodules/MtProtoKit/Sources/MTBackupAddressSignals.m`

This is required for saved-proxy status checks and temporary network contexts.

### 5.10 Select WSS only for explicit relay settings

Modify:

- `submodules/MtProtoKit/Sources/MTTcpConnection.m`

During initialization, detect dedicated WSS relay fields and record a WSS mode/settings object. Keep this mode separate from `_mtpSecret` and SOCKS5 state.

During start:

1. If WSS mode is active, do not resolve the relay hostname through `MTDNS` to an IP address.
2. Preserve the hostname for URLSession DNS, SNI, and certificate validation.
3. Ask the new WSS factory for the connection interface.
4. If the factory is unavailable, fail closed.
5. Call the interface using the relay hostname and port.
6. Let the WSS interface report connected only after a valid WebSocket upgrade.
7. Mark `_readyToSendData` and start the normal MTProto read state only through the explicit WSS branch.

For WSS mode, skip:

- SOCKS5 negotiation;
- `MTCreateSafariClientHello`;
- fake ClientHello HMAC/timestamp injection;
- fake ServerHello parsing and HMAC validation;
- fake CCS generation;
- TLS-looking ApplicationData record wrapping and unwrapping.

Inside WSS, reuse the existing Obfuscated2 implementation, including its standard 64-byte control header and AES-CTR stream, but freeze the framing mode to **secretless padded-intermediate** for compatibility with the planned `mtg` relay:

1. Keep `_mtpSecret = nil`; the WSS bearer token is HTTP authentication and is never an MTProxy obfuscation secret.
2. Set `_useIntermediateFormat = true` only in the explicit WSS branch before the first control header and packet are generated.
3. This writes `0xdddddddd` into the canonical plaintext connection-type field, uses the existing four-byte padded-intermediate packet lengths and random padding, and keeps key derivation secretless.
4. Start the receive state with the existing four-byte full-length path used for padded-intermediate packets.
5. Do not alter how `_useIntermediateFormat` is selected for existing `dd`, `ee`, SOCKS5, direct, or legacy MTProxy branches.

The current `mtg` core accepts padded-intermediate framing and opens the corresponding padded-intermediate connection to Telegram without translating packet framing. Telegram-iOS's ordinary non-secret default would instead produce abridged `0xefefefef`, which this server does not accept. Adding abridged support or a framing translator is explicitly outside version 1.

The branch matrix should remain explicit:

```text
SOCKS5               -> existing SOCKS negotiation
16-byte MTProxy      -> existing obfuscated MTProxy
`dd` MTProxy         -> existing padded/intermediate MTProxy
`ee` MTProxy         -> existing fake-TLS MTProxy
WSS relay            -> new URLSession WSS interface + secretless padded-intermediate Obfuscated2
```

### 5.11 Preserve connection identity and resets

Modify the proxy identity logic in:

- `submodules/TelegramCore/Sources/Network/Network.swift`

Extend `NetworkContextProxyId` so WSS identity includes host, port, path, and token. It is an internal equality value and must not add credential logging.

Changing any WSS endpoint or credential field must cause the same existing connection reset path used when proxy settings change.

### 5.12 Commit boundary

This commit contains the new source file, factory seam, temporary-context propagation, `MTTcpConnection` branch, and transport-focused tests. It does not add broad settings UI or deep-link changes.

## Commit 3 — Minimal Explicit UI and Custom Configuration Links

This layer is mechanically broader because adding a Swift enum case makes existing switches exhaustive. Keep it separate from the transport commit to simplify cherry-picking and future conflict resolution.

### 5.13 Add a third editor mode

Modify:

- `submodules/SettingsUI/Sources/Data and Storage/ProxyServerSettingsController.swift`

Add **HTTPS Relay** next to SOCKS5 and MTProxy.

Reuse the existing:

- Hostname field;
- Port field.

Add only:

- Path;
- Access Token.

Requirements:

- token input is masked;
- host, port, path, and token use the centralized validation helper;
- save/share is enabled only for valid settings;
- editing an existing relay populates all fields;
- clipboard import recognizes the custom relay link;
- no advanced TLS or fallback controls are exposed.

### 5.14 Update type labels and previews

Update exhaustive connection switches in:

- `submodules/SettingsUI/Sources/Data and Storage/ProxyListSettingsController.swift`
- `submodules/SettingsUI/Sources/Data and Storage/DataAndStorageSettingsController.swift`
- `submodules/TelegramUI/Components/ProxyServerPreviewScreen/Sources/ProxyServerPreviewScreen.swift`
- `submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift`
- `submodules/TelegramVoip/Sources/OngoingCallContext.swift`

Behavior:

- display the type as “HTTPS Relay”;
- preview hostname, port, and path;
- display the token as bullets only;
- keep “Use for Calls” limited to SOCKS5;
- treat WSS like MTProxy for call routing: no VoIP proxy forwarding in version 1.

Add only the localization keys required for:

- HTTPS Relay;
- Path;
- Access Token;
- optionally one short explanatory sentence.

Keep generated localization changes in this UI-only commit.

### 5.15 Add a custom configuration URL

Do not overload Telegram's stock `t.me/proxy` format. Use a fork-specific custom scheme:

```text
tg://wssproxy?server=relay.example.com&port=443&path=%2Frelay%2Fv1%2Fabc&token=<base64url>
```

Modify the narrow existing proxy URL flow in:

- `submodules/AccountContext/Sources/AccountContext.swift`
- `submodules/UrlHandling/Sources/UrlHandling.swift`
- `submodules/TelegramUI/Sources/OpenResolvedUrl.swift`
- `submodules/TelegramUI/Sources/OpenUrl.swift`
- `submodules/TelegramUI/Sources/ChatControllerOpenAttachmentMenu.swift`
- `submodules/QrCodeUI/Sources/QrCodeScreen.swift`

Prefer extending the existing `ResolvedUrl.proxy` payload with optional WSS fields rather than adding a new top-level `ResolvedUrl` case. This avoids unrelated changes to every exhaustive `ResolvedUrl` switch.

Rules:

- existing `tg://proxy`, `tg://socks`, and `https://t.me/...` parsing remains unchanged;
- WSS sharing emits only `tg://wssproxy`;
- do not imply that stock Telegram clients or `t.me` understand the link;
- clipboard import and QR scanning recognize the custom link;
- malformed or mixed-mode parameters fail parsing;
- the configuration URL/QR contains the token by necessity and must be treated as sensitive;
- the actual WSS network URL never contains the token.

### 5.16 Commit boundary

This commit contains UI, generated strings, preview/list behavior, URL codec, QR generation, clipboard import, and related tests. It should not modify transport internals except for compile-required enum handling.

## 6. Test Plan

The repository has limited app-side unit-test infrastructure. Introduce small testable seams rather than attempting to instantiate the complete account/network stack.

### 6.1 Model and persistence tests

Verify:

- old SOCKS5 fixture decodes unchanged;
- old MTProxy fixture decodes unchanged;
- WSS settings encode/decode round-trip;
- equality changes when host, port, path, or token changes;
- unknown discriminators retain the current safe behavior;
- relay validation accepts valid settings;
- validation rejects invalid ports, hosts, paths, CR/LF, malformed base64url, short tokens, and excessive lengths.

### 6.2 Custom URL codec tests

Verify:

- valid `tg://wssproxy` parse/serialize round-trip;
- percent-encoded paths round-trip exactly;
- existing SOCKS5 and MTProxy links are unchanged;
- missing or duplicate required parameters fail;
- mixed SOCKS/MTProxy/WSS fields fail;
- invalid host, port, path, and token fail;
- token is not accidentally added to a `wss://` network URL.

### 6.3 Byte-stream adapter tests

Factor receive buffering and exact-length read scheduling into a small internal helper that can be tested without a live WebSocket.

Verify:

- one WebSocket message satisfies multiple exact-length reads;
- one exact-length read spans multiple messages;
- empty and partial inputs do not create zero-length loops;
- bytes are not lost, duplicated, or reordered;
- queued writes remain FIFO;
- only one send is in flight;
- disconnect/cancel is idempotent;
- pending work is discarded or failed exactly once;
- text messages fail closed;
- oversized message/buffer fails closed;
- no callback occurs after delegate reset;
- generated errors and logs do not contain the bearer token.

### 6.4 Integration tests with the companion server

Verify:

- valid WSS connection opens and carries MTProto;
- the first upstream stream is a secretless 64-byte Obfuscated2 header whose connection type is `0xdddddddd`;
- WSS uses four-byte padded-intermediate packet lengths in both directions and does not derive AES keys from the bearer token or saved MTProxy secret;
- invalid bearer token fails before upgrade;
- wrong path fails before upgrade;
- wrong/missing subprotocol fails;
- invalid/expired certificate fails through normal platform trust;
- hostname mismatch fails;
- redirects fail;
- server close propagates to `MTTcpConnection`;
- client close terminates the relay's upstream connection;
- large uploads/downloads do not violate buffering limits;
- repeated reconnects do not leak URLSession tasks or delegates.

### 6.5 Regression matrix

Before accepting the client patch, verify:

- direct connection without a proxy;
- SOCKS5 proxy;
- ordinary 16-byte MTProxy;
- `dd` MTProxy;
- `ee` fake-TLS MTProxy;
- WSS relay;
- saved-proxy status checks for every type;
- WSS behavior with the “Network X” debug setting both enabled and disabled.

WSS behavior should be independent of the raw-TCP backend setting.

## 7. Build and Runtime Verification

The project supports only a full app build for production-module verification. Use the command documented in `CLAUDE.md`:

```sh
source ~/.zshrc 2>/dev/null
python3 build-system/Make/Make.py --overrideXcodeVersion \
  --cacheDir ~/telegram-bazel-cache \
  build --continueOnError \
  --configurationPath build-system/appstore-configuration.json \
  --gitCodesigningRepository git@gitlab.com:peter-iakovlev/fastlanematch.git \
  --gitCodesigningType development \
  --gitCodesigningUseCurrent \
  --buildNumber=1 \
  --configuration=debug_sim_arm64
```

If focused unit-test targets are added, invoke each with `Make.py test --target <label>` and a valid explicit iOS test runner. Do not rely on the current default `Tests/AllTests` suite because it contains a dangling target documented in `CLAUDE.md`.

### 7.1 Physical-device validation after server implementation

1. Verify valid relay connectivity on an unrestricted network first.
2. Test invalid certificate, hostname, token, path, and subprotocol.
3. Test server close, client stop, timeout, and repeated reconnect.
4. Test Wi-Fi/cellular transitions.
5. Test background/foreground behavior.
6. Test large media download and upload.
7. Test the restricted physical-iPhone Wi-Fi path.
8. Test the restricted physical-iPhone cellular path.
9. Use repeated trials rather than a single successful connection.
10. Capture server-side traffic and confirm:
    - a genuine complete TLS handshake;
    - a valid certificate chain;
    - a successful WebSocket upgrade;
    - secretless padded-intermediate relay establishment to the requested known Telegram DC;
    - no fake TLS record sequence;
    - stable bidirectional MTProto traffic.

Treat captures and logs as sensitive. Never commit bearer tokens, endpoint details that should remain private, or unredacted traffic captures.

## 8. Security and Privacy Requirements

1. Use at least 32 bytes of random token entropy.
2. Never place the bearer token in the actual `wss://` URL.
3. Never log the `Authorization` header.
4. Redact the token in `MTSocksProxySettings.description` and all new diagnostics.
5. Do not override server trust evaluation.
6. Reject redirects to avoid credential forwarding ambiguity.
7. Require the versioned WebSocket subprotocol.
8. Reject text messages and unexpected protocol states.
9. Bound message size and buffered unread data.
10. Fail closed if the WSS factory is unavailable.
11. Do not fall back to a more recognizable transport.
12. The server must not expose an arbitrary TCP tunnel.
13. Unauthenticated probes should receive normal generic HTTP behavior.
14. Configuration links and QR codes contain credentials and must be handled like MTProxy secret links.

## 9. Explicit Non-Goals for Version 1

To keep the client patch small and portable, do not include:

- Safari/Chrome/Firefox fake ClientHello profiles;
- fake-TLS ClientHello fragmentation;
- HTTP/2 CONNECT;
- QUIC, HTTP/3, MASQUE, or actual NaiveProxy protocol compatibility;
- domain fronting;
- separate connect-host and SNI-host fields;
- custom trust roots;
- certificate/public-key pinning;
- automatic WSS-to-MTProxy fallback;
- WebSocket stream multiplexing;
- stream resumption;
- WebSocket compression;
- Telegram call proxying;
- arbitrary destination tunneling;
- abridged `0xefefefef` framing on WSS or a server-side framing translator;
- server implementation in the client task.

A direct domain, IP, or SNI block can still defeat this design. Its durability improvement is that the observer sees a genuine Apple TLS connection with a valid certificate, complete TLS state machine, and encrypted post-handshake HTTP/WebSocket traffic instead of Telegram's recognizable fake-TLS semantics.

## 10. Expected Patch Shape and Cherry-Pick Strategy

### Commit A — Model and bridge

Expected files:

- `submodules/TelegramCore/Sources/SyncCore/SyncCore_ProxySettings.swift`
- `submodules/TelegramCore/Sources/Settings/ProxySettings.swift`
- `submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTApiEnvironment.h`
- `submodules/MtProtoKit/Sources/MTApiEnvironment.m`
- focused model/validation tests

### Commit B — Transport

Expected files:

- new `submodules/TelegramCore/Sources/Network/WebSocketTcpConnectionInterface.swift`
- `submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTContext.h`
- `submodules/MtProtoKit/Sources/MTTcpConnection.m`
- `submodules/MtProtoKit/Sources/MTProxyConnectivity.m`
- `submodules/MtProtoKit/Sources/MTBackupAddressSignals.m`
- `submodules/TelegramCore/Sources/Network/Network.swift`
- focused buffering/ordering tests

### Commit C — UI and links

Expected files:

- `submodules/SettingsUI/Sources/Data and Storage/ProxyServerSettingsController.swift`
- `submodules/SettingsUI/Sources/Data and Storage/ProxyListSettingsController.swift`
- `submodules/SettingsUI/Sources/Data and Storage/DataAndStorageSettingsController.swift`
- `submodules/TelegramUI/Components/ProxyServerPreviewScreen/Sources/ProxyServerPreviewScreen.swift`
- `submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift`
- `submodules/TelegramVoip/Sources/OngoingCallContext.swift`
- `submodules/AccountContext/Sources/AccountContext.swift`
- `submodules/UrlHandling/Sources/UrlHandling.swift`
- `submodules/TelegramUI/Sources/OpenResolvedUrl.swift`
- `submodules/TelegramUI/Sources/OpenUrl.swift`
- `submodules/TelegramUI/Sources/ChatControllerOpenAttachmentMenu.swift`
- `submodules/QrCodeUI/Sources/QrCodeScreen.swift`
- minimal localization source/generated files
- focused URL-codec tests

### Portability rules

- Do not reformat unrelated code.
- Do not refactor the existing fake-TLS generator.
- Do not rename existing proxy enum cases or serialization keys.
- Prefer one new source file over moving existing implementations.
- Keep raw-TCP and WSS factory seams separate.
- Keep generated localization changes isolated in the UI commit.
- Record upstream conflict resolutions when cherry-picking to a later Telegram-iOS release.
- Re-run Semble/Serena discovery against the target release before applying each commit because exhaustive switches and temporary `MTContext` creation sites may have changed.

## 11. Companion Server Plan and Frozen Deployment

The server research and architecture decision are complete. The implementation-ready plan is:

- [`/Users/aulyanov/git/mtg/docs/genuine-tls-websocket-relay-server-plan.md`](../../../mtg/docs/genuine-tls-websocket-relay-server-plan.md)

The frozen deployment topology is:

```text
Nginx with a genuine certificate and ordinary website
    -> exact hidden relay path
    -> authenticated WebSocket upgrade proxied over loopback
    -> WebSocket ingress integrated into the mtg fork
    -> secretless padded-intermediate Obfuscated2
    -> Telegram datacenter selected from the obfuscated header
```

The server plan covers:

- Nginx TLS termination, certificate renewal, and ordinary-site fallback;
- WebSocket subprotocol enforcement;
- independent rotating bearer tokens and constant-time validation;
- uniform internal rejection with Nginx interception to real site content;
- secretless padded-intermediate Obfuscated2 parsing;
- strict Telegram DC allowlisting;
- bidirectional backpressure and limits;
- timeouts and connection quotas;
- replay/abuse considerations;
- redacted logging and configuration rendering;
- deployment behind the user's existing proper domains and certificates;
- integration fixtures shared with the client.

Client implementation must remain consistent with that contract, especially the WSS-only `_useIntermediateFormat = true` and `_mtpSecret = nil` combination. Changes to the subprotocol, framing, credential location, or close semantics require coordinated updates to both documents and both implementations.

## 12. Resume Point for the Client Implementation Session

1. Read this document, the two related research documents, and the companion `mtg` server plan.
2. Confirm upstream has not materially changed:
   - `ProxyServerConnection` persistence;
   - `ProxyServerSettings.mtProxySettings`;
   - `MTSocksProxySettings`;
   - `MTContext.makeTcpConnectionInterface`;
   - `MTTcpConnection` initialization/start/send/receive branches;
   - temporary `MTContext` factory propagation;
   - proxy editor/list/preview/link switches.
3. Freeze the exact Codable field names, custom URL parameter names, token validation limits, WebSocket subprotocol string, and secretless padded-intermediate WSS framing contract.
4. Implement Commit 1 only.
5. Build/test and review its diff before starting Commit 2.
6. Implement the WSS adapter with testable buffering and send-serialization helpers.
7. Build/test and review its diff before starting Commit 3.
8. Add the minimal UI and custom link support.
9. Build the full app.
10. Validate against the server fixture and frozen contract; keep server source changes out of the client commits.
