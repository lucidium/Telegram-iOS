# Genuine TLS/WebSocket Relay — Telegram-iOS Implementation Handoff

- **Status:** Commit A implemented and focused tests passing; Commit B not started
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
- Server maximum client binary message: 16 MiB. Client-side unread buffering must be bounded compatibly.
- Server close semantics: normal/going-away are clean; protocol/auth/policy/size/internal codes are failures. The client adapter must still notify the MTProto delegate of disconnection at most once.

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

Added the focused Bazel target `//submodules/TelegramCore:TelegramCoreTests` and 10 tests covering:

- unchanged legacy SOCKS5 fixture decoding;
- unchanged legacy MTProxy fixture decoding;
- unknown discriminator fallback;
- WSS Codable round-trip and exact persisted keys;
- dedicated bridge fields with nil legacy credentials/secret;
- bridge equality changes for path/token;
- description token redaction;
- canonical credential-free WSS URL creation;
- invalid host/port/path/token and length rejection.

### 2.2 Verification

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

- `TelegramCore`, `MtProtoKit`, and the test bundle compiled successfully.
- 10 tests executed and passed on an iPhone 17 / iOS 26.3 simulator.
- `git diff --check` passed after preserving unrelated legacy whitespace.

Environment notes:

- The documented private signing-repository command could not run because `TELEGRAM_CODESIGNING_GIT_PASSWORD` was absent. Simulator tests succeeded with `--xcodeManagedCodesigning`; no secret was requested or stored.
- The existing nearby `TextFormatTestRunner` uses iOS 26.5, but this machine currently provides iOS 26.3. The new focused runner therefore uses 26.3.
- Standalone Serena/SourceKit diagnostics cannot resolve Bazel Objective-C include paths or XCTest SDK context; the authoritative Bazel compile/test passed.
- A full Telegram app build was not run in Commit A; reserve it for the planned integration stage or run it when session budget allows.

## 3. Review Notes and Intentional Boundaries

- Commit A does not instantiate `URLSessionWebSocketTask` and cannot connect to the server.
- Commit A does not alter `MTTcpConnection`, fake TLS, SOCKS5, 16-byte MTProxy, `dd`, or `ee` transport behavior.
- Commit A does not add UI, custom links, QR support, clipboard import, or localization.
- The new enum case will require exhaustive-switch updates in later modules. Keep broad UI/link fallout in Commit C unless a production compile requires a minimal non-UI handling branch earlier.
- The bearer token necessarily exists in persisted settings and bridge memory, but new descriptions/tests avoid logging it.
- No real endpoint, bearer token, capture, or private deployment detail was committed.

## 4. Next Coding Session — Commit B Resume Point

Start a new session and make exactly one implementation commit for the WSS transport. Before editing, read this handoff, the client plan, and the server contract, then re-run Semble/Serena discovery because upstream files may move.

### 4.1 First inspection targets

1. `submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTTcpConnectionInterface.h`
2. `submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTContext.h`
3. `submodules/MtProtoKit/Sources/MTTcpConnection.m`
4. `submodules/MtProtoKit/Sources/MTProxyConnectivity.m`
5. `submodules/MtProtoKit/Sources/MTBackupAddressSignals.m`
6. `submodules/TelegramCore/Sources/Network/Network.swift`
7. Existing raw interfaces:
   - `submodules/TelegramCore/Sources/Network/MTGcdAsyncSocketTcpConnectionInterface.swift`
   - `submodules/TelegramCore/Sources/Network/NetworkFrameworkTcpConnectionInterface.swift`

### 4.2 Commit B implementation order

1. Add small internal, testable FIFO helpers for exact-length receive buffering and one-at-a-time send serialization.
2. Add `WebSocketTcpConnectionInterface.swift`, conforming to `MTTcpConnectionInterface`.
3. Use ephemeral URLSession settings, disabled cookies/cache/credential storage where configurable, the validated token-free URL, bearer request header, required subprotocol, bounded upgrade timeout, and 16 MiB `maximumMessageSize`.
4. Reject all redirects and fail an open callback unless `task.protocol == "telegram-mtproto-relay.v1"`.
5. Accept binary messages only; continuously re-arm receive; bound unread bytes; preserve exact stream ordering across message boundaries.
6. Make cancellation idempotent, ignore late completions, suppress callbacks after delegate reset, and notify disconnection once.
7. Add the separate optional WSS factory to `MTContext`; do not alter the raw TCP factory signature or selection behavior.
8. Install the factory in `Network.swift` and copy it into every temporary `MTContext` used by connectivity checks/backup-address flows.
9. Add an explicit WSS branch in `MTTcpConnection`:
   - preserve hostname for URLSession DNS/SNI/certificate validation;
   - keep `_mtpSecret = nil`;
   - set `_useIntermediateFormat = true` only for WSS before generating the Obfuscated2 header;
   - bypass SOCKS negotiation and every fake-TLS generation/parsing/wrapping path;
   - fail closed when the WSS factory is unavailable.
10. Extend `NetworkContextProxyId` with host, port, path, and token without adding credential descriptions/logging.
11. Add adapter tests to the focused TelegramCore test target, run them, inspect the full diff, update this handoff, and create exactly one Commit B commit.

### 4.3 Transport tests required before Commit B closes

- One WebSocket message satisfies multiple exact-length reads.
- One exact-length read spans multiple WebSocket messages.
- Empty/partial input does not loop or lose bytes.
- Writes stay FIFO with only one send in flight.
- Text messages and oversized input fail closed.
- Cancel/disconnect is idempotent and reports at most once.
- No callback occurs after delegate reset.
- Generated errors/descriptions do not contain the bearer token.
- WSS mode generates secretless padded-intermediate Obfuscated2 (`0xdddddddd`) and never enters fake TLS.
- Existing raw TCP factory behavior remains unchanged.

## 5. Later Session — Commit C

After Commit B is independently reviewed and committed, use a separate session/commit for the explicit HTTPS Relay editor, type labels/previews, VoIP exclusion, custom `tg://wssproxy` codec, QR/clipboard flow, localization, and URL tests described in the client plan.
