# Genuine TLS/WebSocket Relay — First-Run Authorization Proxy Follow-Up

**Date:** 2026-07-31

**Status:** physical-device relay fix validated; first-run authorization issue
reproduced; likely proxy-settings propagation gap identified; no follow-up code
change applied yet

**Telegram-iOS branch:** `build/release-12.9.2`

**Telegram-iOS revision before the local fix:** `ca9d3a7312`

**Local production fix under validation:** explicit WSS startup branch in
`submodules/MtProtoKit/Sources/MTTcpConnection.m`, with focused coverage in
`submodules/TelegramCore/Tests/WebSocketTcpConnectionInterfaceTests.swift`

**Primary prior diagnosis:**
`docs/custom/genuine-tls-websocket-relay-socks5-prefix-root-cause-and-fix-plan-2026-07-29.md`

**New correlated captures:**

- `docs/custom/debug_logs2/TelegramClientLog.txt`
- `docs/custom/debug_logs2/ServerNginxMtgLog.txt`

## 1. Executive summary

The SOCKS5-prefix fix is validated on a physical iPhone. After login, the
genuine TLS/WebSocket relay connects successfully and sustains Telegram
traffic. The server now accepts the secretless padded-intermediate Obfuscated2
stream and relays traffic to DC1/DC2. There are no
`unsupported-connection-type` failures in the new server capture.

A separate first-run problem remains. On a clean application state, the app
creates an `UnauthorizedApplicationContext` and its `UnauthorizedAccount`
network before the relay is enabled from the authorization UI. That network
continues trying direct Telegram addresses, which time out on the test network.
`auth.sendCode` is queued on this still-direct network and does not complete.

The strongest current source-level hypothesis is that live proxy-setting
changes are propagated to authorized `Account` networks but not to an already
created `UnauthorizedAccount` network:

- `accountWithId` snapshots `SharedDataKeys.proxySettings` when either network
  is initially constructed;
- `Account.init` later subscribes to shared proxy settings and updates its
  `MTContext` dynamically;
- `UnauthorizedAccount.init` has no corresponding subscription;
- the proxy UI writes the new settings to the shared account-manager store;
- the existing unauthorized network therefore retains the nil proxy from its
  creation-time snapshot.

The healthy WSS pair near the end of the client capture does not contradict
this hypothesis. Its short request/response/close lifecycle is consistent with
the separate proxy-connectivity check, which constructs a temporary
proxy-configured `MTContext` directly. It proves that the relay and the earlier
WSS startup fix work in the new build; it does not yet prove that the main
authorization network adopted the proxy.

This is a strong working diagnosis, not yet a completed root-cause proof. The
next session should add bounded settings-propagation diagnostics or a focused
test before applying the likely fix.

## 2. Confirmed result from the previous fix

### 2.1 Physical-device success after login

The user built and installed the IPA containing the `MTTcpConnection.start`
dispatch fix and confirmed that the relay works after a successful account
login.

The new server capture independently confirms successful relay operation:

- Nginx records successful `101 Switching Protocols` upgrades;
- mtg starts and finishes WSS streams normally;
- relay events contain selected DC1 and DC2 values;
- sustained sessions transfer nontrivial response bodies;
- the capture contains no `unsupported-connection-type` category.

The server capture totals include 115 WSS stream starts, 115 matching stream
finishes, and 115 Nginx `101` responses. It also contains many completed
relay-direction events for DC1 and DC2. Fifteen `peer-closed` diagnostics have
`bytes-read: 0` and occur amid a burst of concurrent connection churn; unlike
the old failure, they do not show a malformed 64-byte Obfuscated2 header.

### 2.2 Correct client WSS boundary in the first-run capture

At approximately `15:51:04` device-local time, two WSS connections appear.
For both, the open callback reports:

```text
queuedBytes=0
```

The first writes occur only after open and are 120 and 119 bytes respectively:

```text
first-write state=open ... queuedBefore=0
```

One connection receives 163 bytes, and both close normally with WebSocket
close code 1000. There is no three-byte pre-open write and no `05 01 00`
symptom. This is the expected outcome of the previous fix.

The temporary `MTTcpConnection` boundary diagnostic still prints random-looking
`marker` and `dc` values with `match=0` because it inspects already encrypted
wire bytes as though they were plaintext. Do not use that field as evidence of
a current header failure. The integration regression test and successful mtg
relay parsing are the authoritative checks.

## 3. First-run reproduction timeline

The following timeline is intentionally sanitized. Do not copy the phone
number, API hash, login token, relay hostname, hidden path, bearer token,
client IP, container paths, or account identifiers from the raw logs into
future documents or tickets.

### 3.1 Unauthorized network is created without the relay

At `15:50:15.106`, the app initially has no auth context. At `15:50:15.135`, it
publishes an `UnauthorizedApplicationContext` with an `UnauthorizedAccount`
network.

The new `MTContext` reports an empty persistent datacenter-auth map and chooses
ordinary Telegram seed addresses for DC1, DC2, and DC4. Its connections are
logged as direct TCP connections; they do not say `via WebSocket relay`.

The authorization layer queues these requests on that network:

```text
15:50:15  help.getConfig
15:50:16  help.getCountriesList
15:50:16  auth.initPasskeyLogin
15:50:21  auth.sendCode
```

### 3.2 Direct attempts time out repeatedly

Beginning at `15:50:27`, the direct IPv4 attempts hit the 12-second connect
timeout. IPv6 alternatives fail immediately with `No route to host`. The
network repeatedly cycles through Telegram seed addresses and discovered
addresses on ports 443, 80, and 5222.

No WSS client event exists during the initial `auth.sendCode` window. The first
`via WebSocket relay` line does not occur until approximately `15:51:04`, about
49 seconds after the unauthorized network was created and about 43 seconds
after `auth.sendCode` was queued.

### 3.3 A late WSS connectivity check succeeds but does not migrate auth traffic

At `15:51:04`, two WSS attempts start. They open with zero queued bytes, write
valid Obfuscated2/application data after open, and one receives a response.
Both then close normally.

Direct authorization-network retries continue after this healthy WSS pair.
There is no logged authorization RPC completion, no transition to an entered
code state, and no evidence that the outstanding `auth.sendCode` request was
reissued on a persistent WSS-backed authorization transport.

## 4. Source-level propagation asymmetry

### 4.1 Both account types receive a creation-time snapshot

File:

```text
submodules/TelegramCore/Sources/Account/Account.swift
```

`accountWithId` reads `SharedDataKeys.proxySettings` from `AccountManager` and
passes that value to `initializedNetwork` for both unauthorized and authorized
account states.

File:

```text
submodules/TelegramCore/Sources/Network/Network.swift
```

`initializedNetwork` applies only the effective active server present in that
snapshot:

```swift
if let effectiveActiveServer = proxySettings?.effectiveActiveServer {
    apiEnvironment = apiEnvironment.withUpdatedSocksProxySettings(
        effectiveActiveServer.mtProxySettings
    )
}
```

Therefore, a relay already enabled before `accountWithId` runs should be used
by either account type. This specific capture instead begins with a nil proxy,
as demonstrated by direct connection logs.

### 4.2 Authorized `Account` observes subsequent changes

Later in `Account.init`, the code subscribes to:

```swift
accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
```

It maps the current effective server to `MTSocksProxySettings`, calls
`network.context.updateApiEnvironment`, drops connection status when the
setting changes, and returns an environment updated with
`withUpdatedSocksProxySettings`.

This explains why the relay behaves correctly once the user is logged in: an
authorized account can adopt proxy changes made after its network was created.

### 4.3 `UnauthorizedAccount` does not observe subsequent changes

`UnauthorizedAccount.init` configures state management, connection retention,
ephemeral auth-key discovery, and explicit backup-address discovery, but it has
no proxy-settings disposable and no call to update the network's API
environment when shared proxy settings change.

`UnauthorizedAccount.changedMasterDatacenterId` rereads proxy settings while
constructing a replacement network. That may eventually create a proxy-aware
unauthorized network after an auth migration, but it does not update the
existing network merely because the user enabled a proxy.

### 4.4 The proxy UI updates shared settings

The proxy preview/connect flow writes the selected server into
`SharedDataKeys.proxySettings`, makes it active, and sets `enabled = true`.
The proxy list UI also observes that shared-data stream.

This update reaches authorized `Account` because of its subscription. The
current source provides no equivalent consumer in `UnauthorizedAccount`.

### 4.5 Why the successful short WSS pair is probably the status probe

File:

```text
submodules/MtProtoKit/Sources/MTProxyConnectivity.m
```

`MTProxyConnectivity.pingWithAddress` creates a temporary `MTContext` whose API
environment is explicitly updated with the candidate proxy settings. It copies
both TCP-interface factories, starts a real `MTTcpConnection`, sends a bounded
discovery payload after open, validates a response, and completes.

The observed late WSS pair has exactly the qualitative properties expected of
that kind of check:

- it appears after the user has had time to open/confirm proxy settings;
- it uses the relay even though the main unauthorized network remains direct;
- it sends one small write;
- one connection receives one small response;
- it closes normally immediately afterward.

The logs do not contain an explicit correlation identifier proving that these
objects came from `MTProxyConnectivity`, so retain the word “consistent” rather
than calling this established fact.

## 5. Working diagnosis and alternatives

### 5.1 Primary hypothesis: missing live update in `UnauthorizedAccount`

**Confidence: high, pending a focused test or diagnostic.**

Sequence:

1. First launch creates the unauthorized network while proxy settings are
   absent or disabled.
2. That network snapshots nil proxy settings and starts direct transports.
3. The user enables the WSS relay from the authorization UI.
4. Shared settings update successfully; the proxy status check uses the relay
   and succeeds.
5. The existing unauthorized network has no settings subscription, so it keeps
   its old nil `socksProxySettings` and continues direct attempts.
6. Authorization RPCs remain pending because direct Telegram access is blocked.

### 5.2 Alternative: settings transaction timing or rollback

The preview flow can restore previous settings if its 15-second online check
fails. It is possible that the WSS probe succeeds at the transport level but
the higher-level status filter does not observe the expected proxy address and
rolls settings back.

This is less consistent with the user's report that the same proxy subsequently
works for an authorized account, but the next session should record bounded
`enabled / effective-type / change-applied` state transitions to rule it out.

### 5.3 Alternative: unauthorized account object is recreated too late

A later account-state or master-DC transition may recreate the unauthorized
network with current proxy settings, but only after the first authorization
requests have already stalled. Inspect account-object replacement events and
whether pending requests migrate to the replacement network.

### 5.4 Alternative: direct backup discovery is expected but main traffic is not

`MTBackupAddressSignals` deliberately copies the current API environment and
clears `socksProxySettings` for some backup-address fetches. Direct-looking
discovery traffic alone would therefore not prove the main auth transport is
unproxied.

In this capture, however, the direct logs belong to the main unauthorized
`MTContext` and include its selected schemes and repeated auth-network
connection attempts. Still, diagnostics should correlate context identity,
purpose, and current proxy type so this distinction is explicit.

### 5.5 Not a recurrence of the SOCKS5-prefix defect

The late WSS attempts have `queuedBytes=0`, first write only after open, a
successful response, and normal close. The new server logs also show valid DC
relay traffic and no `unsupported-connection-type` failures. Do not reopen the
Obfuscated2 builder, WebSocket FIFO, or server parser investigation unless new
wire evidence contradicts these facts.

## 6. Next-session investigation plan

### 6.1 Reproduce with a controlled settings sequence

Use a clean application/account-manager state and a network where direct
Telegram access is blocked but the WSS endpoint is reachable.

Capture these two cases separately:

1. **Proxy enabled after unauthorized network creation**
   - launch to the phone-number screen;
   - confirm the unauthorized network first attempts direct transport;
   - enable the WSS relay from the authorization UI;
   - submit a synthetic/test phone-number flow as appropriate;
   - observe whether the same `MTContext` updates and reconnects via WSS.
2. **Proxy already persisted before unauthorized network creation**
   - preserve enabled relay settings while removing only the account/login
     state, if the test workflow permits this safely;
   - relaunch;
   - confirm whether the first unauthorized connection is WSS immediately.

If case 2 works while case 1 fails, it strongly isolates the defect to live
settings propagation rather than unauthorized transport compatibility.

### 6.2 Add bounded, credential-safe diagnostics

Do not log server host, port, path, token, phone number, API hash, auth code,
login token, account ID, or raw request data.

Add temporary events with opaque per-process context identifiers and only these
bounded fields:

```text
unauthorized-network-created
  proxyPresent=0|1
  proxyType=none|socks5|mtp|wss

shared-proxy-settings-changed
  owner=authorized|unauthorized|proxy-probe
  previousType=...
  updatedType=...
  enabled=0|1

network-proxy-environment-update
  owner=...
  changed=0|1
  connectionDropRequested=0|1

transport-selected
  owner=...
  proxyType=...
  dc=<bounded signed integer>
```

Also add an opaque correlation ID to the proxy-connectivity probe so its WSS
connection can be distinguished from the primary authorization `MTContext`.

### 6.3 Add a focused regression before the production change

The key test should model a real live update, not only initial construction:

1. create an `AccountManager` with default/disabled proxy settings;
2. create or obtain an `UnauthorizedAccount` and its real `Network`/`MTContext`;
3. assert `context.apiEnvironment.socksProxySettings == nil` initially;
4. update `SharedDataKeys.proxySettings` to an enabled synthetic WSS server;
5. wait on the relevant queues/signals;
6. assert the same unauthorized network context now contains WSS settings;
7. assert connection status was dropped or the active transport was restarted;
8. disable the proxy and assert the environment returns to nil;
9. dispose/deallocate the account and verify no further updates are delivered.

If constructing the full account fixture is too expensive, first extract a
small reusable proxy-settings binding owned by both account classes and unit
test it with a fake environment-update closure. Keep at least one integration
test proving it is installed by `UnauthorizedAccount`.

### 6.4 Likely minimal production fix

If the hypothesis is confirmed, give `UnauthorizedAccount` the same live
proxy-settings binding used by `Account`:

- subscribe to `accountManager.sharedData(keys: [SharedDataKeys.proxySettings])`;
- map to `effectiveActiveServer?.mtProxySettings`;
- use `distinctUntilChanged`;
- update `network.context.apiEnvironment` only when the setting actually
  changes;
- call `network.dropConnectionStatus()` before returning the updated
  environment so pending authorization traffic reconnects;
- retain and dispose the subscription with the unauthorized account lifetime.

Prefer extracting the duplicated binding into a small helper rather than
copying a long closure into both initializers, provided that doing so does not
broaden the patch or alter authorized behavior.

Do not recreate the entire unauthorized account for every proxy toggle unless
testing proves the MTContext update path is insufficient. `MTProto` already
resets its connection when `socksProxySettings` changes.

### 6.5 Preserve surrounding behavior

Regression coverage should preserve:

- proxy present at initial unauthorized-network construction;
- enable, replace, and disable transitions;
- SOCKS5, MTProxy, and WSS setting conversion;
- authorized-account live updates;
- unauthorized master-DC changes;
- pending authorization RPC retry after transport reset;
- no duplicate settings subscriptions after account replacement;
- proxy-connectivity status checks;
- direct backup-address discovery behavior where intentionally proxy-free.

## 7. Validation sequence for the eventual fix

1. Run the focused settings-propagation regression.
2. Run the existing TelegramCore WSS/Obfuscated2 startup tests.
3. Run `git diff --check`.
4. Build the affected app target.
5. Install on a physical device with a genuinely clean authorization state.
6. Enable the WSS relay from the phone-number flow.
7. Confirm the unauthorized network changes from direct/nil proxy to WSS
   without waiting for account authorization or app restart.
8. Confirm `help.getConfig`, countries/passkey requests, and `auth.sendCode`
   receive responses through the relay.
9. Complete login and confirm the authorized account continues through WSS.
10. Disable/re-enable the proxy and verify both account states update cleanly.
11. Remove all temporary propagation/correlation diagnostics.

Expected client progression after enabling the relay:

```text
shared-proxy-settings-changed owner=unauthorized updatedType=wss enabled=1
network-proxy-environment-update owner=unauthorized changed=1 connectionDropRequested=1
WSS relay connect-start
WSS relay open ... queuedBytes=0
WSS relay first-write state=open ... queuedBefore=0
WSS relay first-receive ...
auth request completed / authorization state advanced
```

Expected server progression:

```text
Nginx: HTTP 101
mtg: Stream has been started
mtg: DC selected / relay traffic
no unsupported-connection-type
no repeated auth-path direct-connect timeout loop
```

## 8. Security and log hygiene

The raw client capture contains highly sensitive values, including a phone
number, API hash, login token, relay endpoint details, local container paths,
and account identifiers. The raw server capture contains client IP, hidden
relay path, and stream identifiers.

Before sharing or committing logs outside the private investigation workflow:

- redact phone numbers and authentication/login tokens;
- redact API hashes even if they are application-scoped rather than user-scoped;
- redact relay host, port, hidden path, and bearer token;
- redact client IP and local container UUIDs/paths;
- redact account IDs and persistent stream/correlation IDs;
- do not log raw MTProto payloads, Obfuscated2 headers, key/IV material, or
  Authorization headers.

The follow-up production patch must not include test endpoint values or any
raw-log credential.

## 9. Completion criteria

The first-run follow-up is complete when all of the following are true:

1. Enabling/changing/disabling proxy settings updates an existing
   `UnauthorizedAccount` network without login or app restart.
2. The update forces the old direct transport to reconnect using the selected
   proxy.
3. First-run `help.*` and `auth.*` requests progress through WSS when direct
   Telegram access is unavailable.
4. The first WSS application bytes remain the canonical 64-byte secretless
   padded-intermediate Obfuscated2 header, with no SOCKS5 prefix.
5. A persisted enabled relay is used from the first unauthorized connection on
   relaunch.
6. Authorized-account proxy updates remain unchanged.
7. SOCKS5, MTProxy, proxy status checks, master-DC migration, and intentional
   direct backup discovery remain functional.
8. Physical-device login completes and the resulting authorized session
   sustains relay traffic.
9. Temporary diagnostics and all sensitive values are absent from the final
   production patch and distributable logs.

## 10. Recommended starting point for the next session

Begin with these source locations:

```text
submodules/TelegramCore/Sources/Account/Account.swift
  - accountWithId
  - UnauthorizedAccount.init
  - UnauthorizedAccount.changedMasterDatacenterId
  - Account.init proxy-settings subscription near the managed disposables

submodules/TelegramCore/Sources/Network/Network.swift
  - initializedNetwork

submodules/TelegramCore/Sources/Settings/ProxySettings.swift
  - effectiveActiveServer conversion/update helpers

submodules/MtProtoKit/Sources/MTProxyConnectivity.m
  - pingWithAddress:datacenterId:settings:context:

submodules/TelegramUI/Components/ProxyServerPreviewScreen/Sources/ProxyServerPreviewScreen.swift
  - proxy connect/rollback flow
```

The first question to answer is narrow:

> When `SharedDataKeys.proxySettings` changes after an `UnauthorizedAccount`
> has been created, which object updates that account's existing
> `MTContext.apiEnvironment.socksProxySettings` and drops its direct transport?

In the currently inspected source, the answer appears to be “none.” Confirm
that with a focused test or bounded diagnostic, then implement the smallest
lifetime-safe shared binding.
