# Genuine TLS/WebSocket Relay — Telegram-iOS Implementation Handoff

- **Status:** Commits A, B, and C implemented; focused tests and the iOS simulator app build pass
- **Last updated:** 2026-07-26
- **Repository:** `/Users/aulyanov/git/Telegram-iOS`
- **Implementation plan:** [`genuine-tls-websocket-relay-client-plan.md`](genuine-tls-websocket-relay-client-plan.md)
- **Server contract:** `/Users/aulyanov/git/mtg/docs/genuine-tls-websocket-relay-telegram-ios-handoff.md`
- **Session rule:** One implementation commit per coding session. Stop after the session commit and resume from this document.

## 1. Frozen Cross-Repository Contract

The client and server documents were reconciled before implementation. Preserve these choices unless both repositories and both documents are deliberately updated together:

- Network transport: genuine `wss://` using `URLSessionWebSocketTask` and normal platform trust/hostname validation.
- Endpoint fields: DNS `host`, `port`, absolute `path`, and bearer `token`.
- Authentication: `Authorization: Bearer <token>` in the encrypted WebSocket upgrade request; never put the token in the WSS URL.
- WebSocket subprotocol: `telegram-mtproto-relay.v1`, which the server must echo.
- Application messages: binary only; message boundaries have no stream meaning.
- First upstream bytes: ordinary secretless Obfuscated2 64-byte header.
- WSS-only framing: padded-intermediate, canonical connection type `0xdddddddd`.
- WSS mode keeps `_mtpSecret = nil`; the HTTP bearer token is not an MTProxy secret.
- No redirects, permissive trust handling, transport fallback, WebSocket compression, multiplexing, stream resumption, or VoIP proxying in version 1.
- Server maximum client binary message: 16 MiB. Client-side unread buffering is bounded to 16 MiB.
- Server close semantics: normal/going-away are clean; protocol/auth/policy/size/internal codes are failures. The client adapter notifies the MTProto delegate of disconnection at most once.

## 2. Coding Session 1 — Commit A: Model and Narrow Bridge

### 2.1 Implemented

#### Persisted model

File: `submodules/TelegramCore/Sources/SyncCore/SyncCore_ProxySettings.swift`

- Added `ProxyServerConnection.webSocketRelay(path:token:)`.
- Frozen discriminator and keys:
  - `_t = 0`: SOCKS5 (unchanged)
  - `_t = 1`: MTProxy (unchanged)
  - `_t = 2`: WebSocket relay
  - `webSocketPath`: relay path
  - `webSocketToken`: bearer token
- Unknown discriminators retain the previous safe fallback to empty SOCKS5 settings.

#### Centralized validation

File: `submodules/TelegramCore/Sources/SyncCore/SyncCore_ProxySettings.swift`

Added `ProxyServerWebSocketRelayValidation` with these frozen Commit A limits:

- Host: ASCII DNS name, at least two labels, maximum 253 bytes, labels maximum 63 bytes, no empty labels, no leading/trailing hyphens, no trailing dot, no IP-literal/numeric-only host.
- Port: `1...65535`.
- Path: absolute, maximum 2048 UTF-8 bytes, conservative unescaped RFC 3986 path characters only (`A-Z`, `a-z`, `0-9`, `-._~/`), no percent escapes, query, fragment, non-ASCII, or `.`/`..` path component.
- Token: canonical unpadded base64url, 32 through 64 decoded bytes, maximum 86 encoded bytes, and no CR/LF or non-base64url characters.
- `validatedURL(...)` constructs only `wss://host:port/path`, round-trips all endpoint fields, and never includes the token.

The deliberately conservative path grammar is compatible with the server's initial hidden-path deployment contract. If a future deployment requires percent-encoded or non-ASCII path data, change validation and URL/link tests together rather than silently normalizing input.

#### Objective-C bridge

Files:

- `submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTApiEnvironment.h`
- `submodules/MtProtoKit/Sources/MTApiEnvironment.m`
- `submodules/TelegramCore/Sources/Settings/ProxySettings.swift`

Changes:

- Added nullable readonly `webSocketPath` and `webSocketToken` fields to `MTSocksProxySettings`.
- Added the dedicated `initWithIp:port:webSocketPath:webSocketToken:` initializer.
- Existing SOCKS5/MTProxy initializer semantics and Swift mappings remain unchanged.
- WSS bridge data does not overload username, password, or MTProxy secret.
- `isEqual:` includes relay path and token so edits trigger existing environment/reset behavior.
- Relay descriptions contain the host, port, path, and literal `<redacted>`; they never contain the token.

#### Focused tests

Files:

- `submodules/TelegramCore/BUILD`
- `submodules/TelegramCore/Tests/ProxyServerSettingsTests.swift`

Added the focused Bazel target `//submodules/TelegramCore:TelegramCoreTests` and 10 tests covering legacy fixtures, WSS persistence/validation/bridge behavior, and token redaction.

## 3. Coding Session 2 — Commit B: WSS Transport

### 3.1 Implemented

#### Byte-stream adapter and helpers

File: `submodules/TelegramCore/Sources/Network/WebSocketTcpConnectionInterface.swift`

Added a `URLSessionWebSocketTask` implementation of `MTTcpConnectionInterface` with:

- ephemeral URLSession configuration with URL cache, cookies, and credential storage disabled;
- the credential-free validated `wss://host:port/path` URL;
- `Authorization: Bearer <token>` only on the `URLRequest` upgrade headers;
- required `telegram-mtproto-relay.v1` subprotocol and exact echo validation before connected notification;
- normal system trust and hostname validation, with no authentication-challenge override;
- all redirects rejected;
- bounded 1–30 second upgrade timeout;
- `maximumMessageSize = 16 MiB`;
- binary messages only; text and unknown message types fail closed;
- continuously re-armed receive calls;
- serial internal state queue and generation guards for late completions;
- idempotent shutdown, one disconnect notification, and no callbacks after `resetDelegate`;
- payload-byte network usage accounting, classified via a narrowly scoped `NWPathMonitor` only as cellular versus other;
- 64 KiB outbound binary messages, a 32 MiB queued-send bound, and exactly one WebSocket send in flight.

The internal `WebSocketByteStreamBuffer` provides queued exact-length reads independent of WebSocket message boundaries. The internal `WebSocketSendQueue` preserves FIFO write order, queues before upgrade completion, chunks large writes, and starts each send only after the previous completion.

#### Separate factory and temporary contexts

Files:

- `submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTContext.h`
- `submodules/TelegramCore/Sources/Network/Network.swift`
- `submodules/MtProtoKit/Sources/MTProxyConnectivity.m`
- `submodules/MtProtoKit/Sources/MTBackupAddressSignals.m`

Changes:

- Added nullable `makeWebSocketTcpConnectionInterface(settings, delegate, delegateQueue)` without altering the existing raw-TCP factory signature or fallback.
- Installed the WSS factory on supported Apple OS versions independently of the Network.framework debug setting.
- Copied the WSS factory into the saved-proxy connectivity-check and backup-address temporary contexts.
- Existing raw TCP continues to select GCDAsyncSocket or Network.framework exactly through its prior path.

#### Explicit MTTcpConnection branch

File: `submodules/MtProtoKit/Sources/MTTcpConnection.m`

- Dedicated relay fields select a separate `_webSocketSettings` mode; partial relay bridge data also selects WSS and fails closed in the adapter rather than being reinterpreted as SOCKS.
- WSS preserves the configured hostname and bypasses `MTDNS`, leaving URLSession responsible for DNS, SNI, and certificate hostname validation.
- WSS asks only the new factory for an interface and fails closed if unavailable; it never falls back to raw TCP, MTProxy, or fake TLS.
- `_mtpSecret` is explicitly nil and `_useIntermediateFormat` is set before generating the first Obfuscated2 control header.
- Existing Obfuscated2 code therefore writes canonical plaintext `0xdddddddd` at offsets 56–59 and derives keys without a proxy secret.
- The WSS branch begins the existing four-byte padded-intermediate read state only after a valid WebSocket upgrade callback.
- WSS bypasses SOCKS negotiation, synthetic ClientHello generation, fake ServerHello parsing, fake CCS, and TLS-looking record wrapping/unwrapping.
- Legacy direct, SOCKS5, 16-byte MTProxy, `dd`, and `ee` predicates/factories remain separate.
- Interface deinitialization now uses the protocol's `resetDelegate` method instead of reaching into a concrete socket delegate.

#### Connection identity

File: `submodules/TelegramCore/Sources/Network/Network.swift`

`NetworkContextProxyId` now has private mode-specific equality values:

- MTProxy: IP, port, secret;
- WSS: host, port, path, token.

Changing any relay endpoint or token field therefore uses the existing network-context reset path. The identity has no custom description or logging surface.

#### Focused tests

File: `submodules/TelegramCore/Tests/WebSocketTcpConnectionInterfaceTests.swift`

Added 10 transport tests, bringing the focused target to 20 tests total. They cover:

- one message satisfying multiple reads;
- one read spanning multiple messages;
- empty and partial input;
- buffered data consumed by later reads without loss/reordering;
- read and unread-buffer bounds plus reset;
- pre-upgrade writes, FIFO order, chunking, and one send in flight;
- queued-send bounds and reset;
- the frozen secretless padded-intermediate `0xdddddddd`/four-byte-read contract;
- fixed subprotocol/message-size constants and credential-free generated errors;
- WSS identity equality and separate raw/WSS factory selectors.

### 3.2 Verification

Passing command on this machine:

```sh
python3 build-system/Make/Make.py \
  --overrideXcodeVersion \
  --cacheDir ~/telegram-bazel-cache \
  test \
  --configurationPath build-system/appstore-configuration.json \
  --xcodeManagedCodesigning \
  --target //submodules/TelegramCore:TelegramCoreTests
```

Result on 2026-07-26:

- `MtProtoKit`, `TelegramCore`, and the focused test bundle compiled successfully.
- 20 tests executed and passed on an iPhone 17 / iOS 26.3 simulator.
- A source-invariant audit confirmed bearer-header placement, token-free URL construction, subprotocol enforcement, redirect/text rejection, absence of custom trust handling, 16 MiB limits, secretless intermediate mode, hostname preservation, fail-closed factory selection, unchanged raw factory fallback, and complete WSS identity fields.
- `git diff --check` passed.

Environment notes retained from Commit A:

- Simulator tests use `--xcodeManagedCodesigning` because the private signing-repository password is unavailable; no secret was requested or stored.
- The focused runner uses the installed iOS 26.3 runtime.
- A full Telegram app build was not run in Commit B; the focused target compiled all changed production modules. Reserve the full app build for Commit C/integration validation.

### 3.3 Intentional boundaries and remaining runtime validation

- No UI, custom links, QR/clipboard handling, VoIP behavior changes, or localization were added.
- No live relay endpoint or server fixture was available in this session, so genuine upgrade, certificate failure, close-code propagation, and end-to-end Telegram traffic remain physical/integration tests.
- The adapter counts WebSocket payload bytes for usage accounting; it intentionally does not estimate HTTP/WebSocket/TLS overhead.
- Outbound payloads are chunked to 64 KiB even though the accepted inbound/client-message safety limit is 16 MiB, reducing server buffering while preserving stream semantics.
- URLSession ordinary trust handling is deliberately untouched.
- No endpoint, token, traffic capture, or private deployment detail was committed.

## 4. Coding Session 3 — Commit C: Explicit UI and Custom Links

### 4.1 Implemented

#### Explicit HTTPS Relay editor and display

Files:

- `submodules/SettingsUI/Sources/Data and Storage/ProxyServerSettingsController.swift`
- `submodules/SettingsUI/Sources/Data and Storage/ProxyListSettingsController.swift`
- `submodules/SettingsUI/Sources/Data and Storage/DataAndStorageSettingsController.swift`
- `submodules/TelegramUI/Components/ProxyServerPreviewScreen/Sources/ProxyServerPreviewScreen.swift`
- `submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift`
- `submodules/TelegramVoip/Sources/OngoingCallContext.swift`

Changes:

- Added **HTTPS Relay** as a third explicit editor mode next to SOCKS5 and MTProto.
- Reused the server and port fields and added path plus masked access-token inputs.
- Save/share remains disabled until `ProxyServerWebSocketRelayValidation` accepts all four relay fields.
- Existing relay values populate the editor, and valid relay links on the clipboard populate all fields.
- Proxy list, data settings, peer-info settings, and preview screens label the type as HTTPS Relay.
- The preview shows host, port, path, and a fixed bullet placeholder for the token; the credential is never displayed.
- “Use for Calls” remains SOCKS5-only. `OngoingCallContext` handles WSS like MTProxy and creates no VoIP proxy.

#### Sensitive custom configuration links

Files:

- `submodules/TelegramCore/Sources/SyncCore/SyncCore_ProxySettings.swift`
- `submodules/AccountContext/Sources/AccountContext.swift`
- `submodules/UrlHandling/Sources/UrlHandling.swift`
- `submodules/TelegramUI/Sources/OpenResolvedUrl.swift`
- `submodules/TelegramUI/Sources/OpenUrl.swift`
- `submodules/TelegramUI/Sources/ChatControllerOpenAttachmentMenu.swift`
- `submodules/QrCodeUI/Sources/QrCodeScreen.swift`

Added the frozen fork-specific codec:

```text
tg://wssproxy?server=relay.example.com&port=443&path=%2Frelay%2Fv1%2F...&token=<base64url>
```

Behavior:

- Serialization is available only for a valid `.webSocketRelay` setting.
- Parsing requires the exact `tg` scheme, `wssproxy` host, and exactly one each of `server`, `port`, `path`, and `token`.
- Missing, duplicate, unknown, mixed-mode, noncanonical-port, or centrally invalid values fail closed.
- Stock `tg://proxy`, `tg://socks`, and `https://t.me/...` parsing remains routed through the existing internal parser.
- `ResolvedUrl.proxy` now carries a `ProxyServerSettings`, allowing the same narrow preview flow to represent all three proxy modes without a new top-level resolved URL case.
- Direct custom-link opening, app/auth URL handling, clipboard import, both in-app QR recognition paths, and QR generation use the same centralized codec.
- WSS sharing emits only `tg://wssproxy`; the QR selector is intentionally hidden because there is no compatible `t.me` representation.
- Configuration links and QR codes contain the token by necessity. The actual `wss://` transport URL remains token-free and unchanged from Commit B.

#### Minimal localization and tests

Files:

- `Telegram/Telegram-iOS/en.lproj/Localizable.strings`
- `submodules/TelegramCore/Tests/ProxyServerSettingsTests.swift`

Added only:

- HTTPS Relay;
- Path;
- Access Token.

The focused test target now contains 23 tests. The three new tests cover valid encoded-path round-trip, strict rejection of malformed/mixed links, mode-specific serialization, and preservation of a token-free network URL.

### 4.2 Verification

Passing focused command on 2026-07-26:

```sh
python3 build-system/Make/Make.py \
  --overrideXcodeVersion \
  --cacheDir ~/telegram-bazel-cache \
  test \
  --configurationPath build-system/appstore-configuration.json \
  --xcodeManagedCodesigning \
  --target //submodules/TelegramCore:TelegramCoreTests
```

Result:

- 23 focused tests executed and passed on the iOS simulator runner.
- The target compiled `MtProtoKit`, `TelegramCore`, the transport adapter, and all model/link tests.

The normal full app build could not analyze with locally unavailable extension provisioning profiles. The same iOS app graph was therefore built with only extension/provisioning packaging disabled:

```sh
build-input/bazel-8.4.2-darwin-arm64 build //Telegram:Telegram \
  --keep_going --announce_rc \
  --features=swift.use_global_module_cache --verbose_failures --remote_cache_async \
  --define=buildNumber=1 --disk_cache="$HOME/telegram-bazel-cache" \
  -c dbg --ios_multi_cpus=sim_arm64 --watchos_cpus=arm64_32 \
  --//Telegram:disableExtensions --//Telegram:disableProvisioningProfiles \
  '--@build_bazel_rules_swift//swift:copt="-j"' \
  '--@build_bazel_rules_swift//swift:copt="6"'
```

Result:

- The complete iOS simulator app dependency graph compiled successfully.
- `bazel-bin/Telegram/Telegram.ipa` was produced.
- Generated PresentationStrings compiled from the updated source localization.
- The final cached build completed in 51.729 seconds after one typo in a localization accessor was corrected.
- `git diff --check` passed.

### 4.3 Security and regression audit

Confirmed:

- The token input is masked.
- Ordinary list/data/peer-info UI never shows the token.
- Preview displays only bullets and path.
- No token was added to logs, descriptions, or transport errors.
- The custom configuration link is the only new URL containing the token.
- The actual WSS network URL construction is still centralized in `ProxyServerWebSocketRelayValidation.validatedURL` and remains query/credential-free.
- Existing SOCKS5 and MTProxy URL parsing still use the prior `ParsedInternalUrl` logic and preserve their existing mode mapping.
- WSS remains excluded from call routing.
- No transport internals, trust behavior, fake-TLS behavior, or fallback policy changed in Commit C.

## 5. Remaining Work — Integration and Physical Validation

All three planned client implementation commits are complete. Continue in a new session only for server-backed integration and physical-device validation; do not fold that work into Commit C.

Remaining checks:

1. Deploy or start the companion server fixture using the frozen contract.
2. Validate a genuine WebSocket upgrade with the required subprotocol and bearer header.
3. Confirm the first upstream stream bytes are the secretless `0xdddddddd` Obfuscated2 header.
4. Exercise invalid token, path, certificate, hostname, subprotocol, redirect, text-frame, oversize, and close-code behavior.
5. Validate clipboard and QR flows interactively on simulator/device with non-production credentials.
6. Test unrestricted and restricted Wi-Fi/cellular paths, background/foreground transitions, reconnects, and large transfers on a physical iPhone.
7. Capture only redacted evidence; never commit deployment endpoints, tokens, or traffic captures.

When resuming, re-read this handoff and the server handoff, verify the three implementation commits are present, and keep integration evidence separate from source commits.