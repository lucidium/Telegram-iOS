# Genuine TLS/WebSocket Relay — Physical-Device Debug Findings and Client Fix Plan

**Date:** 2026-07-28  
**Status:** root-cause boundary established; client wire-format investigation required  
**Telegram-iOS branch inspected:** `build/release-12.9.2`  
**Telegram-iOS revision inspected:** `07f98271ae`  
**Server repository:** `~/git/mtg`  
**Server diagnostic revision:** `fb5c0684ba130e3cb0fedfa3665188eebe4f8d88`  
**Related client plan:** `docs/custom/genuine-tls-websocket-relay-client-plan.md`  
**Related client handoff:** `docs/custom/genuine-tls-websocket-relay-client-handoff.md`

## 1. Purpose

This document records the first physical-device integration failure after the
genuine TLS/WebSocket relay was deployed, the evidence collected from the
server, the conclusions that can safely be drawn from that evidence, and a
test-first plan for fixing the Telegram-iOS side in a separate coding session.

The most important result is that the public WSS transport succeeds through the
HTTP upgrade. The failure is inside the first 64 bytes of the inner secretless
Obfuscated2 stream.

## 2. Expected protocol at the failure boundary

After a successful WebSocket upgrade, Telegram-iOS must send one ordered byte
stream with this prefix:

```text
64-byte secretless Obfuscated2 header
    -> padded-intermediate connection type (0xdddddddd)
    -> signed Telegram DC tag
    -> first encrypted padded-intermediate packet
    -> subsequent encrypted padded-intermediate packets
```

The canonical plaintext Obfuscated2 header is:

| Offset | Length | Meaning |
| ---: | ---: | --- |
| 0 | 8 | random, subject to the standard forbidden-prefix checks |
| 8 | 32 | client-to-server AES key |
| 40 | 16 | client-to-server AES IV |
| 56 | 4 | `dd dd dd dd` |
| 60 | 2 | signed Telegram DC tag, little-endian `int16` |
| 62 | 2 | random |

The outbound AES-CTR stream is initialized from plaintext bytes 8–55 and is
advanced across all 64 plaintext header bytes. The transmitted header retains
plaintext bytes 0–55 and uses ciphertext bytes 56–63. Application encryption
continues from AES-CTR offset 64.

The WSS bearer token authenticates only the HTTP upgrade. It is not an MTProxy
secret and must not participate in this AES derivation.

## 3. Initial public observation

Nginx repeatedly logged successful upgrades from the physical iPhone:

```text
GET /relay/v1/<hidden-path> HTTP/1.1 -> 101
```

However, Telegram-iOS reported the proxy as unavailable and no Telegram DC
connection appeared in the server logs. A `101` alone proved that requests
reached the hidden endpoint, but did not identify whether failure occurred
during the inner header read, header parsing, DC selection, Telegram dialing,
or subsequent relay.

## 4. Temporary server diagnostic

The server received a credential-safe diagnostic in mtg commit `fb5c068`.
For WSS sessions only, it records:

- how many inner-stream bytes were read while parsing the Obfuscated2 header;
- a bounded failure category;
- the four-byte decrypted connection type only when parsing reaches that
  field.

It does not record the bearer token, token digest, Authorization field, raw
header, AES key, AES IV, DC bytes, WebSocket messages, or peer-supplied close
reason.

The relevant categories are:

```text
read-timeout
peer-closed
unsupported-connection-type
invalid-dc
read-or-parse-error
```

The server patch was validated with focused tests, WSS race tests, the
deterministic `mtglib` suite, `go vet`, and `git diff --check` before deployment.

## 5. Physical-device evidence

One Telegram-iOS connection check created two nearly simultaneous WSS
connections. Both Nginx requests upgraded successfully:

```text
HTTP/1.1 101 Switching Protocols
```

For both streams, mtg then reported:

```text
bytes-read: 64
failure-category: unsupported-connection-type
connection-type: 9501a011
```

and:

```text
bytes-read: 64
failure-category: unsupported-connection-type
connection-type: 7754d9bc
```

Each stream then finished immediately. There was no successful DC selection,
Telegram dial, or relay traffic.

The two concurrent streams are expected behavior for Telegram connection or
proxy-status machinery and are not themselves evidence of duplication inside
one WebSocket stream.

## 6. Conclusions established by the evidence

### 6.1 The genuine public transport works

The following stages succeeded on the physical device:

- DNS and TCP connection to the public endpoint;
- Apple/system TLS handshake;
- certificate chain and hostname validation;
- exact relay path;
- bearer-token authentication;
- required WebSocket subprotocol offer and selection;
- Nginx forwarding to the loopback mtg ingress;
- WebSocket binary application-data delivery.

The failure is therefore not currently in TLS, certificate deployment, Nginx
routing, token rotation, endpoint serialization, or the HTTP upgrade.

### 6.2 A complete first 64-byte unit reaches mtg

`bytes-read: 64` rules out these immediate failure classes for the observed
attempt:

- client upgrades but sends no inner bytes;
- a partial header is followed by timeout;
- the WebSocket closes before the server obtains 64 stream bytes;
- a text WebSocket message is rejected before header parsing completes;
- a message-size limit rejects the first data before parsing.

### 6.3 The server cannot decrypt the connection type with the key/IV carried in the received header

The server derives the secretless outbound key and IV from received wire bytes
8–55, advances AES-CTR across the full 64-byte frame, and decrypts bytes 56–63.
The resulting bytes at plaintext offsets 56–59 were neither the required
`dddddddd` nor another stable transport marker.

The values `9501a011` and `7754d9bc` differ across fresh connections and look
random. This makes a simple, stable abridged-marker mistake (`efefefef`) less
likely for these attempts.

### 6.4 The mismatch is before DC routing

Because connection-type validation fails first, the server has not established
whether the decrypted DC tag is correct. There is no basis yet for changing DC
routing or server fallback behavior.

### 6.5 No server-side compatibility relaxation should be added

The server must continue to require secretless padded-intermediate
Obfuscated2. Accepting arbitrary connection types, attempting alternate
secrets, guessing AES offsets, or adding an abridged translator would hide a
client wire bug and weaken the frozen protocol contract.

## 7. Telegram-iOS code inspected

### 7.1 `MTTcpConnection` mode selection appears correct

File:

```text
submodules/MtProtoKit/Sources/MTTcpConnection.m
```

The WSS branch sets:

```objc
_webSocketSettings = proxySettings;
_mtpIp = nil;
_mtpPort = 0;
_mtpSecret = nil;
_useIntermediateFormat = true;
```

This is the intended high-level state.

### 7.2 The existing header generator appears correct in source

`sendDataIfNeeded`:

- generates 64 random control bytes;
- writes `0xdddddddd` at offset 56 when `_useIntermediateFormat` is true;
- writes the signed DC tag at offset 60;
- derives the outbound key/IV from bytes 8–55;
- keeps `effectiveSecret` nil when `_mtpSecret` is nil;
- advances `MTAesCtr` across all 64 control bytes;
- transmits plaintext control bytes 0–55 and encrypted bytes 56–63;
- continues the same CTR instance when encrypting the first framed packet.

On static inspection, this matches the server contract.

### 7.3 The WebSocket adapter is an ordered byte-stream adapter in intent

File:

```text
submodules/TelegramCore/Sources/Network/WebSocketTcpConnectionInterface.swift
```

The adapter:

- queues writes before the WebSocket open callback;
- opens the send queue only after the exact subprotocol is selected;
- chunks large writes into bounded binary messages;
- allows only one WebSocket send in flight;
- appends received binary messages into an ordered read buffer;
- rejects text input;
- bounds queued and buffered bytes.

WebSocket message boundaries are not meaningful to the server, so merely
splitting `header + first packet` at a 64 KiB boundary is valid if all bytes are
preserved in FIFO order. The current server result does **not** by itself prove
that chunking is the defect.

### 7.4 Existing tests verify declared contract, not emitted Obfuscated2 bytes

`WebSocketTcpConnectionInterfaceTests.swift` verifies constants such as:

```swift
WebSocketRelayTransportContract.connectionType == 0xdddddddd
```

and exercises generic queue/buffer ordering. It does not instantiate the real
`MTTcpConnection` header path, capture its first bytes, decrypt them using the
wire-carried key/IV, and assert the canonical header fields and continuous CTR
state.

That missing wire-level test is the main coverage gap.

## 8. What is not yet proven

Do not begin the next session by assuming one of these hypotheses is already
confirmed:

- the first WebSocket message is reordered;
- the 64 KiB chunking logic corrupts the header;
- `_useIntermediateFormat` is false at runtime;
- `_mtpSecret` is non-nil at runtime;
- the client encrypts from the wrong CTR offset;
- key/IV bytes are modified in the WebSocket adapter;
- the installed app differs from the inspected revision;
- an object-lifecycle or factory-copy path creates a non-WSS `MTTcpConnection`.

The diagnostics establish the wire mismatch but do not distinguish these
causes. The next step must capture and validate the client-produced first
64 bytes at the boundary between `MTTcpConnection` and the WSS adapter.

## 9. Detailed Telegram-iOS fix plan

### Phase 1 — Reproduce with a deterministic wire-header test

#### Goal

Create a test that fails exactly as the physical-device server fails, without
logging or embedding deployment credentials.

#### Preferred seam

Refactor only enough of the existing private `sendDataIfNeeded` setup to expose
a testable internal helper in MtProtoKit. The helper should construct the first
secretless Obfuscated2 stream prefix from:

```text
transport format: padded intermediate
MTProxy secret: nil
DC tag: explicit test value
random 64-byte source: injected deterministic bytes
first packet bytes: explicit fixture
```

It should return or write:

```text
wire header (64 bytes)
encrypted first padded-intermediate frame
outbound and inbound CTR objects/state as needed by MTTcpConnection
```

Do not implement a second production algorithm in Swift. Extract and test the
algorithm already used by `MTTcpConnection`, or provide a narrow test hook
around it.

#### Assertions

Given the first 64 emitted wire bytes:

1. Assert the wire prefix has exactly 64 bytes before any application bytes.
2. Read key = bytes 8–39 and IV = bytes 40–55.
3. Initialize a fresh AES-CTR decoder from those wire-carried values.
4. Advance/decrypt the full 64-byte header exactly as mtg does.
5. Assert decrypted bytes 56–59 are `dd dd dd dd`.
6. Assert decrypted bytes 60–61 equal the explicit signed little-endian DC tag.
7. Continue the same CTR state over the first encrypted frame.
8. Assert the decrypted frame is a four-byte little-endian padded-intermediate
   length followed by the fixture packet and valid bounded padding.

Also assert that no bearer token or MTProxy secret is supplied to the helper.

### Phase 2 — Capture the actual boundary used by WSS

Use a fake `MTTcpConnectionInterface` or a narrow capturing WSS-interface test
factory so a real `MTTcpConnection` writes into a deterministic in-memory sink.

The test should drive this sequence:

```text
create MTContext with explicit WSS settings
create MTTcpConnection for a known DC
install the capturing WSS interface factory
start connection
signal connectionInterfaceDidConnect
queue one known MTProto payload
concatenate every captured write in order
validate the first 64 bytes using the decoder from Phase 1
```

This test is more valuable than checking `WebSocketRelayTransportContract`
constants because it proves the live branch state and the exact bytes delivered
to `WebSocketTcpConnectionInterface.write`.

If constructing a complete `MTTcpConnection` test fixture is too costly, add a
DEBUG/test-only callback immediately before `_socket writeData:` that receives
only a copy of the first 64 bytes. Do not add production logging of raw header
material.

### Phase 3 — Add a WSS adapter end-to-end byte-order test

Feed the captured real `header + first frame` bytes into `WebSocketSendQueue`.
Concatenate all messages returned by `open`, `didCompleteSend`, and subsequent
queue operations. Assert exact byte equality with the original input.

Cover at least:

- one write shorter than the configured message chunk;
- one write exactly at the chunk boundary;
- one write crossing the chunk boundary;
- header and first packet in the same write;
- several writes while the WebSocket is still connecting;
- several writes after open while one send is in flight;
- reset/cancellation with pending data.

The protocol does not require the 64-byte header to occupy one WebSocket
message. Do not add header-specific message framing unless a test first proves
that the generic FIFO adapter is violating byte order.

### Phase 4 — Compare source-level and installed-build behavior

If the local wire tests pass before any fix, verify the physical app actually
contains the inspected revision:

- clean Bazel output/cache as appropriate;
- rebuild from `build/release-12.9.2` or the intended successor commit;
- verify the built app revision/build metadata;
- replace the installed app bundle using the established project workflow;
- remove stale builds from the device if necessary;
- repeat one connection attempt.

Two random decrypted connection types from the server are compatible with an
old or mixed binary whose runtime code does not match the inspected source.

### Phase 5 — Fix the first failing invariant

Apply the smallest fix indicated by the first failing wire-level assertion.
Likely branches are:

#### A. Wrong WSS mode state

If plaintext generation does not contain `dddddddd`:

- make WSS mode explicit at construction;
- require both WSS path and token to be present and valid;
- force `_useIntermediateFormat = true` only for WSS;
- clear `_mtpSecret` before header derivation;
- add assertions/tests that direct, SOCKS5, 16-byte, `dd`, and `ee` branches are
  unchanged.

#### B. Wrong key/IV derivation or transmitted key/IV window

If the plaintext marker is correct but independent decryption fails:

- ensure outbound key/IV are copied from the canonical plaintext header before
  encryption;
- ensure no bearer token or stale proxy secret is hashed into the keys;
- advance CTR across all 64 plaintext bytes;
- transmit plaintext bytes 0–55 and encrypted bytes 56–63;
- retain the same advanced CTR instance for the first packet.

#### C. First-stream-byte corruption between MtProtoKit and URLSession

If `MTTcpConnection` emits a valid header but concatenated WebSocket messages do
not preserve it:

- repair `WebSocketSendQueue` FIFO/chunking/state transitions;
- preserve one globally ordered stream across writes queued before and after
  open;
- keep at most one send in flight;
- do not drop the in-flight message during normal completion;
- use generation guards only to reject callbacks from a terminated connection;
- retain bounded memory and binary-only messages.

#### D. Installed binary mismatch

If all source tests pass and the rebuilt app works, document the stale-build
cause rather than making an unnecessary protocol change.

### Phase 6 — Client regression validation

Run focused tests for:

- canonical WSS header decryption;
- requested positive DC tag;
- media/negative DC tag;
- continuous CTR state into the first packet;
- generic WebSocket byte-stream ordering;
- text/size/queue-bound failures;
- cancellation and reconnect;
- token redaction.

Then build the app using the repository's Bazel/Make workflow. At minimum,
compile the full affected app target because `MTTcpConnection.m` is Objective-C
inside MtProtoKit while the adapter and tests are Swift inside TelegramCore.

Re-run direct, SOCKS5, 16-byte MTProxy, `dd`, and `ee` smoke tests. The fix must
not alter their header generation, framing, TLS camouflage, or connection
factories.

### Phase 7 — Physical-device verification

Keep server diagnostic commit `fb5c068` deployed during the first retest.

For exactly one proxy connection attempt, collect server logs from a few
seconds before the attempt through approximately ten seconds afterward.

Expected success progression:

```text
Nginx: HTTP 101
mtg: Stream has been started
mtg: no WebSocket obfuscated handshake diagnostic
mtg: connected-to-DC event/log
mtg: traffic events or nonzero relayed byte counts
```

If the attempt still fails, classify it using the next boundary:

- `unsupported-connection-type`: first 64 bytes remain incompatible;
- `invalid-dc`: marker/key/IV now work, but the DC tag is wrong;
- `cannot dial to telegram`: header works; investigate server egress/address;
- connected then immediate relay failure: inspect first padded-intermediate
  frame and continuous CTR state;
- sustained traffic: protocol fix is successful.

After one successful connection, test:

- repeated reconnects;
- proxy status checks;
- foreground/background transition;
- Wi-Fi/cellular transition;
- unrestricted control network;
- the originally affected restricted network;
- normal message and media transfer.

## 10. Security and logging constraints for the fix session

- Never log the WSS bearer token or Authorization header.
- Never log the raw 64-byte Obfuscated2 header in production.
- Never log bytes 8–55, because they contain key and IV material.
- Do not put endpoint credentials in test fixtures, source, screenshots, shell
  arguments, or issue text.
- Use deterministic synthetic key/IV/header bytes only in unit tests.
- If a temporary DEBUG assertion reports a marker or DC, report only those
  bounded decoded values; remove the hook before production rollout.
- Do not use the bearer token as an MTProxy secret or AES input.

## 11. Recommended commit structure

Keep the client repair reviewable:

1. **Wire-level regression fixture**
   - extract or expose the existing first-header builder;
   - add canonical header and continuous-CTR tests;
   - demonstrate the current failure where possible.
2. **Targeted transport fix**
   - change only the first failing invariant;
   - add branch-specific regression coverage.
3. **Integration hardening and handoff update**
   - add real `MTTcpConnection` to capturing-interface coverage;
   - record build and physical-device results;
   - update the existing client handoff.

If Phase 1 proves the current source emits correct bytes and a clean rebuild
fixes the device, replace commits 1–2 with a documentation/build-provenance
update rather than manufacturing a code change.

## 12. Completion criteria

The issue is resolved when all of the following are true:

1. A deterministic client test independently decrypts the actual emitted first
   64 bytes to `dddddddd` and the requested DC.
2. The same AES-CTR state decrypts the first padded-intermediate frame.
3. Concatenated outbound WebSocket messages exactly equal the MtProtoKit byte
   stream for all chunking cases.
4. A rebuilt physical-device client produces `101`, passes mtg's Obfuscated2
   header parser, and connects to the requested Telegram DC.
5. Relayed traffic is sustained rather than closing immediately after upgrade.
6. Direct, SOCKS5, legacy MTProxy, `dd`, and `ee` behavior remains unchanged.
7. No bearer token, raw header, key, IV, or Authorization value appears in
   client/server logs or diagnostics.

## 13. Current handoff summary

The deployment is healthy through genuine TLS and WebSocket upgrade. The
physical client sends 64 bytes, but mtg cannot decrypt the required
padded-intermediate marker using the key/IV carried in those bytes. Static
inspection of the intended Telegram-iOS WSS branch looks correct, so the next
session should not guess at queueing or framing changes. It should first create
a wire-level regression test at the `MTTcpConnection -> WSS interface` boundary,
then fix whichever invariant that test proves is broken, and finally retest the
cleanly rebuilt app against the already-instrumented server.


## 14. Follow-up client investigation — 2026-07-28

### 14.1 Implemented test seam

The existing Obfuscated2 setup used by `MTTcpConnection.sendDataIfNeeded` was
extracted into `MTMakeObfuscated2ConnectionState` in MtProtoKit. The helper
accepts injected 64-byte random data, the existing transport-format flag, a
signed DC tag, and the existing optional MTProxy secret. It returns the exact
64-byte wire header plus the already-advanced inbound and outbound CTR objects.

`MTTcpConnection` now calls this helper from the original retry loop and uses
its outbound CTR for the first framed packet. The extraction preserves the
secret-based forbidden encrypted-prefix retry, including the original final
retry/assert behavior, and the existing secretless, 16-byte, `dd`, and `ee`
derivation behavior. No WSS-specific alternate
algorithm, logging hook, bearer-token input, or server compatibility fallback
was added.

### 14.2 Deterministic results

Focused client tests now prove all of the following with synthetic data only:

- the WSS/secretless padded-intermediate wire prefix is exactly 64 bytes;
- wire bytes 0–55 retain the injected plaintext bytes;
- independently generated OpenSSL AES-256-CTR vectors match the emitted wire
  header and encrypted first frame;
- decrypting from wire-carried bytes 8–55 produces `dddddddd` and the requested
  positive signed little-endian DC tag;
- a negative media DC tag is encoded as the expected signed `int16`;
- one continuous CTR stream decrypts the first four-byte padded-intermediate
  length, fixture payload, and bounded fixture padding;
- the extracted builder preserves deterministic vectors for the legacy
  secretless abridged branch and 16-byte MTProxy key derivation;
- concatenating `WebSocketSendQueue` output reproduces the exact generated
  Obfuscated2 stream before open, after open, at a message boundary, and across
  message boundaries.

The deployed mtg diagnostic revision was also rechecked locally. Its
`ReadHandshake` implementation derives AES-CTR from received bytes 8–55,
advances across the full 64-byte frame, and requires `dddddddd`, matching the
new independent client fixture.

### 14.3 Validation

The following focused target passes after the extraction and new regression
coverage:

```sh
python3 build-system/Make/Make.py \
  --overrideXcodeVersion \
  --cacheDir ~/telegram-bazel-cache \
  test \
  --configurationPath build-system/appstore-configuration.json \
  --xcodeManagedCodesigning \
  --target //submodules/TelegramCore:TelegramCoreTests
```

Latest result in this session:

```text
//submodules/TelegramCore:TelegramCoreTests PASSED
Executed 1 out of 1 Bazel test target: 1 target passes.
```

`git diff --check` also passed before this documentation update. The added code
contains no token, Authorization, endpoint, raw-header, key, IV, or production
logging statement.

### 14.4 Updated conclusion and required next boundary

No client wire-format or WebSocket FIFO defect is reproduced by the inspected
source at revision `07f98271ae`. The canonical production algorithm now has a
direct deterministic regression seam, and both that algorithm and the generic
send queue pass.

Accordingly, no speculative protocol change was made. The physical-device
failure remains most consistent with either an installed-build/source mismatch
or a runtime construction/boundary difference not exercised by the prior
binary. The next necessary step is Phase 4 of this document:

1. run a clean full app build separately from the focused test command;
2. verify the built app revision/build metadata;
3. replace the installed device app using the established workflow;
4. make one proxy connection attempt while mtg revision `fb5c068` remains
   deployed;
5. classify the first server boundary before changing any further code.

A full simulator app build was intentionally left for a separate user-run
command because it may take more than ten minutes:

```sh
build-input/bazel-8.4.2-darwin-arm64 build //Telegram:Telegram \
  --keep_going --announce_rc \
  --features=swift.use_global_module_cache --verbose_failures \
  --remote_cache_async --define=buildNumber=1 \
  --disk_cache="$HOME/telegram-bazel-cache" -c dbg \
  --ios_multi_cpus=sim_arm64 --watchos_cpus=arm64_32 \
  --//Telegram:disableExtensions \
  --//Telegram:disableProvisioningProfiles \
  '--@build_bazel_rules_swift//swift:copt="-j"' \
  '--@build_bazel_rules_swift//swift:copt="6"'
```


## 15. Temporary physical-device client diagnostics

A credential-safe client diagnostic was added before the next IPA build so one
physical-device attempt can be correlated across the MtProtoKit boundary, the
URLSession WebSocket lifecycle, Nginx, and mtg without recording deployment or
cryptographic material.

### 15.1 Diagnostic events

At the first `MTTcpConnection -> WSS interface` write, MtProtoKit records one
bounded line containing only:

- the existing MT connection log prefix;
- `headerBytes=64` and the total first write byte count;
- whether intermediate format is selected;
- whether an MTProxy secret is present;
- the decoded four-byte plaintext marker;
- the signed DC tag;
- whether marker/DC match the runtime mode and requested DC.

The WSS adapter records:

- connect start and bounded timeout;
- whether the required subprotocol was selected;
- first write size and queued-byte count;
- first binary send start and completion size;
- first binary receive size;
- redirects by HTTP status code only;
- peer WebSocket close code only;
- send/receive/task failures by allowlisted error domain and numeric code;
- one termination summary with state, close code, byte/message counters, and
  whether the first send completion and first receive were reached.

Unknown/custom error domains are reduced to `other`. The adapter does not log
localized error descriptions or `NSError.userInfo`.

### 15.2 Explicit exclusions

The temporary diagnostic does not log:

- host, port, WSS URL, hidden path, bearer token, Authorization, or request and
  response headers;
- raw Obfuscated2 header bytes, AES key/IV, ciphertext, payload, padding, or a
  digest of any of those values;
- WebSocket text contents, peer close reason, localized error description, or
  error `userInfo`.

The first-write diagnostic may inspect the canonical plaintext control fields
already held by `MTTcpConnection`, but persists only the bounded marker, signed
DC, booleans, and counts listed above.

### 15.3 Device capture procedure

Before the attempt:

1. Record the Git revision, dirty status, app version/build number, and SHA-256
   of the final IPA.
2. Confirm the installed iPhone build/version matches the new IPA.
3. Open Telegram Debug Settings, enable **Log to File**, and keep
   **Redact Sensitive Data** enabled. **Log to Console** is optional when the
   device is attached to Xcode.
4. Attach Xcode to the installed Telegram process and retain console output.
5. Record the exact attempt time, timezone, and whether the device is using
   Wi-Fi or cellular.

For the first capture:

1. Start Nginx/mtg log capture about five seconds before the client action.
2. Perform exactly one proxy connection/status check.
3. Leave Telegram foregrounded for about ten seconds afterward.
4. Do not switch networks or repeat the check during this first window.

Afterward, collect together:

- Telegram Debug Settings -> **Send Logs** output (main app logs are sufficient
  unless an extension participated);
- Xcode console output from app launch through ten seconds after the attempt;
- Nginx and mtg logs for the same time window;
- build provenance, timestamp/timezone, and network type;
- screenshots of proxy status and the installed build/version.

If the failing proxy prevents log export, disable it or switch to a working
network only after the captured attempt, then export the already-persisted
files.

Do not use a TLS-intercepting proxy or broad `CFNETWORK_DIAGNOSTICS` for the
first run. A packet capture cannot expose the inner WSS stream, and an iOS
sysdiagnose is not needed while the public upgrade continues to return `101`.

### 15.4 Interpretation and removal

- Boundary log `marker=dddddddd`, expected signed DC, `match=1`, followed by
  `first-send-complete`, while mtg still reports random
  `unsupported-connection-type`: focus on bytes after the MtProtoKit boundary
  and the URLSession/WebSocket send path.
- Boundary `match=0`, wrong marker, unexpected `intermediate=0`, or
  `secretPresent=1`: runtime construction/mode differs from the tested WSS
  source path.
- No `first-send-complete`: classify the WSS lifecycle using the preceding
  stage and bounded error domain/code.
- mtg reaches `invalid-dc`: marker/key/IV now work; inspect DC selection.
- mtg connects to the DC but relay fails: move the next diagnostic boundary to
  the first padded-intermediate frame/continuous CTR state.
- Sustained traffic after a clean install: record stale/mixed build provenance
  as the cause and remove these temporary client diagnostics.

The diagnostic should also be removed after it identifies the next failing
boundary; subsequent logging should be narrowed to that boundary rather than
left enabled permanently.

The focused test and non-test validation commands were intentionally not run
after adding this temporary diagnostic at the user's request. They remain
recommended before distributing the IPA.
