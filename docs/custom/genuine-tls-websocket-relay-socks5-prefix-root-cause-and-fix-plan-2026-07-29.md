# Genuine TLS/WebSocket Relay — SOCKS5 Prefix Root Cause and Client Fix Plan

**Date:** 2026-07-29

**Status:** root cause identified from correlated device/server logs and source; fix not yet applied

**Telegram-iOS revision inspected:** `21fcb51d2772`

**Primary prior findings:** `docs/custom/genuine-tls-websocket-relay-debug-findings-2026-07-28.md`

## 1. Executive summary

The genuine TLS/WebSocket relay fails because `MTTcpConnection.start` writes a
three-byte SOCKS5 method-negotiation request into the WebSocket byte stream
before it writes the 64-byte secretless Obfuscated2 header.

The first WebSocket binary message is therefore:

```text
05 01 00
```

instead of the first three bytes of the Obfuscated2 header. The relay treats
WebSocket messages as one ordered byte stream and reads the first 64 bytes as
the Obfuscated2 header. Those 64 bytes are consequently:

```text
3-byte SOCKS5 greeting + first 61 bytes of the genuine Obfuscated2 header
```

Every Obfuscated2 field is shifted by three bytes at the server. In particular,
server wire offsets 8–55 no longer contain the key and IV selected by the
client, so AES-CTR decryption produces a random-looking connection type and the
server rejects the stream as `unsupported-connection-type`.

This is not a TLS, Nginx, authentication, WebSocket subprotocol, URLSession
FIFO, Obfuscated2 builder, DC-routing, or installed-build mismatch. It is a
source-level transport startup control-flow bug in
`submodules/MtProtoKit/Sources/MTTcpConnection.m`.

## 2. Evidence from the physical-device logs

### 2.1 The public WSS transport succeeds

For each connection, the client records a successful WebSocket open with the
required subprotocol:

```text
[WSS relay open selectedProtocolMatches=1 queuedBytes=3]
```

Nginx records `101 Switching Protocols`. This confirms that DNS, TCP, TLS,
certificate validation, relay routing, bearer authentication, and WebSocket
upgrade all succeed.

### 2.2 Three bytes are queued before WebSocket open

Before each open callback, the adapter records:

```text
[WSS relay first-write state=connecting bytes=3 queuedBefore=0]
```

At open, it still reports exactly three queued bytes and sends them as the
first binary message:

```text
[WSS relay open selectedProtocolMatches=1 queuedBytes=3]
[WSS relay first-send-start bytes=3 queuedBytes=3]
[WSS relay first-send-complete bytes=3]
```

Only after the open callback does `MTTcpConnection` construct and write the
Obfuscated2 header plus the first padded-intermediate frame. The diagnostic
then reports a larger write, for example:

```text
[WSS relay boundary first-write headerBytes=64 writeBytes=121 intermediate=1 secretPresent=0 ...]
```

The adapter termination totals prove that both writes are delivered in FIFO
order. In the same example:

```text
writtenBytes=124 sentMessages=2 sentBytes=124
```

and:

```text
3 + 121 = 124
```

The same invariant appears throughout the capture: a 3-byte first message,
then one or more Obfuscated2/application writes, with sent byte totals matching
the client writes.

### 2.3 The server consumes the shifted stream

The corresponding mtg sessions all report:

```text
bytes-read: 64
failure-category: unsupported-connection-type
```

with a different random-looking connection type on each connection. This is
the exact expected result when a 3-byte prefix shifts the Obfuscated2 header:

| Server interpretation | Actual bytes received |
| --- | --- |
| wire 0–2 | `05 01 00` SOCKS5 greeting |
| wire 3–63 | client Obfuscated2 header bytes 0–60 |
| key at wire 8–39 | client header bytes 5–36 |
| IV at wire 40–55 | client header bytes 37–52 |
| encrypted marker at wire 56–59 | client header bytes 53–56 |

Because the server derives a different key/IV window than the client, its
decrypted marker is effectively random. The WebSocket adapter then observes no
application response, followed by the server-initiated close; the later POSIX
error is a consequence of rejection, not the initiating fault.

## 3. Source-level root cause

### 3.1 WSS is represented by non-nil WebSocket settings

In `MTTcpConnection` initialization, WSS settings select secretless padded
intermediate mode:

```objc
if (proxySettings.webSocketPath != nil || proxySettings.webSocketToken != nil) {
    _webSocketSettings = proxySettings;
    _mtpIp = nil;
    _mtpPort = 0;
    _mtpSecret = nil;
    _useIntermediateFormat = true;
}
```

That mode selection is correct.

### 3.2 The successful-connect branch conflates WSS with SOCKS5

After `connectToHost` returns, `MTTcpConnection.start` currently uses this
high-level branch shape:

```objc
if (connect failed) {
    close;
} else if (_webSocketSettings == nil && _socksIp == nil) {
    start direct/MTProxy transport;
} else {
    send SOCKS5 identification request;
}
```

For WSS:

```text
_webSocketSettings != nil
_socksIp == nil
```

so the direct/MTProxy condition is false and execution incorrectly enters the
final `else`, which builds:

```objc
struct socks5_ident_req req;
req.Version = 5;
req.NumberOfMethods = 1;
req.Methods[0] = 0x00;
```

and writes `2 + NumberOfMethods` bytes. With no SOCKS username, this is exactly:

```text
05 01 00
```

It also requests a two-byte `socks5_ident_resp`, which is inappropriate for a
WSS relay.

### 3.3 Why the Obfuscated2 write follows immediately afterward

`WebSocketTcpConnectionInterface.connectToHost` starts the URLSession
WebSocket task and returns before the HTTP upgrade completes. The erroneous
SOCKS greeting is therefore queued while the adapter is in `.connecting`.

When URLSession reports a successful WebSocket open, the adapter:

1. marks itself open;
2. invokes `connectionInterfaceDidConnect` on `MTTcpConnection`;
3. opens its send queue, causing the already queued SOCKS greeting to be sent.

The connect callback makes `MTTcpConnection` ready and calls
`sendDataIfNeeded`, which writes the genuine Obfuscated2 header and first frame
as the next stream bytes. This explains the exact device ordering without any
queue reordering or corruption.

### 3.4 The boundary diagnostic was inspecting the correct generated header

The temporary `MTTcpConnection` diagnostic inspects plaintext `controlBytes`
from the Obfuscated2 builder, but its label says `first-write`. In this failing
path, that is the first **Obfuscated2** write, not the first write to the WSS
adapter. The adapter-level 3-byte write occurred earlier.

This distinction reconciles the prior deterministic tests with the server
failure: the canonical header builder is correct, but it is not at stream
offset zero.

## 4. Minimal production fix

Change only the post-`connectToHost` startup dispatch in
`submodules/MtProtoKit/Sources/MTTcpConnection.m` so the modes are explicit and
mutually exclusive:

```text
WSS
  -> wait for WebSocket open / connectionInterfaceDidConnect
  -> write nothing from the synchronous post-connect branch

SOCKS5
  -> send SOCKS5 method negotiation
  -> wait for SOCKS5 negotiation and CONNECT response

direct or MTProxy
  -> preserve the existing direct / fake-TLS / Obfuscated2 startup
```

One suitable branch shape is:

```objc
if (connect failed) {
    close;
} else if (_webSocketSettings != nil) {
    // URLSession WebSocket open callback will make the connection ready.
} else if (_socksIp != nil) {
    // Existing SOCKS5 greeting and response-read setup.
} else {
    // Existing direct/MTProxy startup.
}
```

The exact patch should preserve the current callback ownership: WSS should
become ready only from `connectionInterfaceDidConnect`, not synchronously from
`connectToHost`. Do not send the Obfuscated2 header before subprotocol
validation, and do not create a second WSS-specific header algorithm.

Do **not** fix this in `WebSocketSendQueue` by dropping arbitrary 3-byte writes.
The queue is correctly preserving its input and cannot safely infer that a
particular write is an accidental SOCKS greeting. Do not add a server-side
three-byte stripping compatibility path either.

## 5. Regression tests

### 5.1 Required integration invariant

Add a focused test around a real `MTTcpConnection` with WSS settings and a
capturing/fake `MTTcpConnectionInterface`. Drive the interface through the same
two stages as production:

1. `connectToHost` returns success while the WebSocket is still logically
   connecting;
2. the fake later invokes `connectionInterfaceDidConnect`.

Assert:

- no write occurs between successful `connectToHost` return and the simulated
  WSS-open callback;
- no SOCKS response read is scheduled in that interval;
- after open and one queued fixture payload, the concatenated stream begins
  with exactly the 64-byte Obfuscated2 wire header;
- independently decrypting it yields `dddddddd` and the requested signed DC;
- the same CTR state decrypts the first padded-intermediate frame;
- there is no `05 01 00` prefix.

This test is the key missing coverage. Existing builder and queue tests prove
their local contracts but do not prove that `MTTcpConnection.start` selects the
correct startup protocol before the builder is reached.

### 5.2 Preserve SOCKS5 behavior

Add or retain a branch-specific test showing that a genuine SOCKS5 connection
still sends its method-negotiation request and schedules the matching response
read. Cover both no-auth and username/password configurations if the existing
fixture permits it.

### 5.3 Preserve other transport modes

Keep the existing deterministic coverage for:

- secretless abridged;
- secretless padded intermediate;
- 16-byte MTProxy secret derivation;
- `dd` and `ee` MTProxy paths;
- continuous AES-CTR state into the first packet;
- WebSocket FIFO and chunk-boundary behavior.

## 6. Validation sequence

1. Run the focused `TelegramCoreTests` target that contains the existing
   Obfuscated2 and WebSocket queue tests plus the new startup regression.
2. Run `git diff --check`.
3. Build the full affected app target because the control-flow change is in
   Objective-C MtProtoKit and is exercised through the Swift WSS adapter.
4. Install the resulting IPA and verify build provenance using the established
   project workflow.
5. Keep the bounded mtg diagnostic deployed for one physical-device attempt.
6. Collect a short correlated client/server window.

Expected successful client progression:

```text
WSS relay connect-start
WSS relay open ... queuedBytes=0
WSS relay boundary ... marker=dddddddd ... match=1
WSS relay first-write state=open bytes>=64 queuedBefore=0
WSS relay first-send-start bytes>=64
WSS relay first-send-complete bytes>=64
WSS relay first-receive ...
```

The exact first Obfuscated2 write size varies with the first framed packet; the
invariant is that the first WSS application-data bytes are the 64-byte header,
not that the first WebSocket message has a fixed total size.

Expected server progression:

```text
Nginx: HTTP 101
mtg: Stream has been started
mtg: no unsupported-connection-type diagnostic
mtg: DC selected / Telegram connection established
mtg: sustained relayed traffic
```

## 7. Security and cleanup

- Do not log raw WebSocket messages, the raw 64-byte header, key/IV bytes,
  bearer token, Authorization header, relay URL, or endpoint credentials.
- Keep tests deterministic and synthetic.
- After a successful physical-device validation, remove the temporary client
  boundary/lifecycle diagnostics as already planned.
- Consider renaming the temporary boundary event before removal if it is used
  for another build; `first-obfuscated-write` is less ambiguous than
  `first-write`.

## 8. Completion criteria

The fix is complete when all of the following are true:

1. WSS schedules no SOCKS5 greeting or SOCKS5 response read.
2. The first concatenated WSS application bytes are the canonical 64-byte
   secretless padded-intermediate Obfuscated2 header.
3. Independent decryption yields `dddddddd` and the requested signed DC.
4. Continuous CTR decryption validates the first padded-intermediate frame.
5. The physical device progresses beyond mtg handshake parsing and sustains
   relay traffic.
6. Direct, SOCKS5, legacy MTProxy, `dd`, and `ee` behavior remains unchanged.
7. Temporary diagnostics and sensitive deployment values are absent from the
   final production patch and logs.

## 9. Final diagnosis

The failure is caused by a SOCKS5 greeting emitted on the WSS transport due to
an over-broad fallback `else` in `MTTcpConnection.start`. The WebSocket adapter
correctly sends that three-byte greeting first, and mtg correctly attempts to
parse the resulting shifted byte stream as Obfuscated2. The smallest correct
repair is to make WSS an explicit startup branch that writes nothing until the
validated WebSocket-open callback initiates the normal Obfuscated2 path.
