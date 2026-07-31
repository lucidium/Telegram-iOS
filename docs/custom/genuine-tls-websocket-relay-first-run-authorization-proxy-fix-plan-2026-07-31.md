# Genuine TLS/WebSocket Relay — First-Run Authorization Proxy Fix Plan

**Date:** 2026-07-31

**Status:** investigation complete; implementation intentionally deferred to a
separate session

**Telegram-iOS branch:** `build/release-12.9.2`

**Base revision before the existing local WSS startup fix:** `ca9d3a7312`

**Related investigation:**

- `docs/custom/genuine-tls-websocket-relay-first-run-authorization-proxy-follow-up-2026-07-31.md`
- `docs/custom/genuine-tls-websocket-relay-socks5-prefix-root-cause-and-fix-plan-2026-07-29.md`

**Private captures used during investigation:**

- `docs/custom/debug_logs2/TelegramClientLog.txt`
- `docs/custom/debug_logs2/ServerNginxMtgLog.txt`

The private captures contain credentials and identifying data. Do not copy raw
values from them into source, tests, commits, tickets, or distributable logs.

## 1. Goal

Make an already-created `UnauthorizedAccount` network react immediately when
the user enables, replaces, or disables proxy settings from the first-run
authorization UI.

After the user enables a genuine TLS/WebSocket relay, the existing
unauthorized `MTContext` must adopt the selected `MTSocksProxySettings`, reset
its old direct transports, and retry pending authorization RPCs through WSS.
The app must not require a successful login, relaunch, or complete recreation
of the unauthorized account before the new proxy takes effect.

## 2. Investigation conclusion

### 2.1 Root cause

The current source has a live proxy-settings propagation asymmetry:

1. `accountWithId` reads `SharedDataKeys.proxySettings` when it initially
   constructs either an authorized or unauthorized network.
2. `initializedNetwork` applies the effective proxy from that creation-time
   snapshot to `MTApiEnvironment`.
3. Authorized `Account.init` subsequently subscribes to shared proxy settings.
   A meaningful proxy change updates its existing `MTContext` and drops the
   network's displayed connection status.
4. `UnauthorizedAccount.init` installs no corresponding subscription.
5. Therefore, an unauthorized network created before the user configures a
   proxy retains its original nil proxy environment and continues direct
   connection attempts.

`UnauthorizedAccount.changedMasterDatacenterId` rereads proxy settings while
building a replacement network, but this only helps if a separate master-DC
transition occurs. It does not handle an ordinary proxy toggle on the existing
unauthorized network.

The answer to the investigation's narrow question is consequently:

> No object currently updates an already-created `UnauthorizedAccount` network
> when `SharedDataKeys.proxySettings` changes.

### 2.2 Confidence

**Confidence: high.**

The client capture identifies one persistent unauthorized `MTContext` that:

- is created before proxy configuration;
- queues the initial `help.*` and `auth.*` requests;
- repeatedly selects direct Telegram TCP schemes;
- continues using direct TCP after the WSS connectivity check succeeds; and
- never logs a proxy-environment-triggered transport replacement.

The short WSS pair in the first-run interval successfully upgrades, sends
application data only after WebSocket open, receives a response on one stream,
and closes normally. The matching server events parse valid relay traffic and
select a Telegram datacenter. This is consistent with the isolated proxy
connectivity probe, which creates a temporary explicitly proxy-configured
`MTContext`; it is not evidence that the main authorization context migrated.

The server capture also includes a later burst of successful WSS traffic. That
burst is outside the supplied client-log interval and belongs to a separate
successful phase. It must not be attributed to the stalled first-run
authorization context.

### 2.3 Why updating the existing context is sufficient

`MTContext.updateApiEnvironment` propagates the new environment to registered
`MTProto` instances. `MTProto.contextApiEnvironmentUpdated` compares old and
new `socksProxySettings` and resets its transport when they differ.

The production fix therefore only needs to update the existing context with a
meaningfully different proxy setting. Recreating `UnauthorizedAccount` or its
entire `Network` should not be necessary.

## 3. Scope

### 3.1 In scope

- Live proxy propagation for an existing `UnauthorizedAccount`.
- Enable, replace, and disable transitions.
- SOCKS5, MTProxy, and genuine TLS/WebSocket relay settings.
- Reuse of the existing MtProtoKit environment-update and transport-reset path.
- Preservation of current authorized-account behavior.
- Focused automated regression coverage.
- Physical-device validation of first-run authorization through WSS.

### 3.2 Out of scope

- Changes to the WSS relay protocol, server, Nginx, or mtg.
- Reopening the previously fixed SOCKS5-prefix/WSS-startup investigation.
- Recreating the unauthorized account on every proxy toggle.
- Changing intentionally direct backup-address discovery.
- Adding production logs containing endpoint or authorization data.
- Broad account/network lifecycle refactoring unrelated to proxy propagation.

## 4. Primary source locations

### `submodules/TelegramCore/Sources/Account/Account.swift`

Relevant areas:

- `accountWithId`
- `UnauthorizedAccount.init`
- `UnauthorizedAccount.deinit`
- `UnauthorizedAccount.changedMasterDatacenterId`
- `Account.init`, specifically the existing
  `SharedDataKeys.proxySettings` subscription

This should be the primary production file for the fix.

### `submodules/TelegramCore/Sources/Network/Network.swift`

Relevant areas:

- `initializedNetwork`
- `Network.dropConnectionStatus()`
- `Network.contextProxyId`
- initialization of `NetworkContextProxyId`

No production change is currently expected here. Inspect it to verify behavior
and test assertions.

### MtProtoKit environment-update path

Relevant concepts:

- `MTContext.updateApiEnvironment`
- `MTProto.contextApiEnvironmentUpdated`
- `MTProto.resetTransport`

No MtProtoKit change is currently expected. These are the existing mechanisms
that make an in-place `MTContext` update restart direct transports with the new
proxy.

### Existing focused tests

- `submodules/TelegramCore/Tests/ProxyServerSettingsTests.swift`
- `submodules/TelegramCore/Tests/WebSocketTcpConnectionInterfaceTests.swift`

These already cover WSS settings conversion/equality and the corrected WSS
startup boundary. New propagation coverage should complement rather than
duplicate them.

## 5. Production design

### 5.1 Extract a shared proxy-settings binding

Extract the authorized account's existing subscription into a small,
lifetime-owned helper in `Account.swift`. Both account types should install the
same binding.

The helper should:

1. Observe:

   ```swift
   accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
   ```

2. Read `ProxySettings` and derive:

   ```swift
   settings.effectiveActiveServer?.mtProxySettings
   ```

3. Compare the candidate `MTSocksProxySettings?` with
   `network.context.apiEnvironment.socksProxySettings`.

4. Treat two non-nil settings as equal only when
   `MTSocksProxySettings.isEqual(_:)` returns true. This comparison already
   includes all WSS identity fields, including host, port, path, and token.

5. On a meaningful change:

   - call `network.dropConnectionStatus()`;
   - return an environment updated with
     `withUpdatedSocksProxySettings(updated)` from
     `network.context.updateApiEnvironment`.

6. On an equivalent emission, return the existing environment without a
   status drop or transport reset.

7. Capture `Network` weakly in the asynchronous subscriber so that the binding
   does not extend the account/network lifetime unexpectedly.

8. Return the subscription's `Disposable` to its owner.

The helper may conceptually resemble:

```swift
private func managedProxySettings(
    accountManager: AccountManager<TelegramAccountManagerTypes>,
    network: Network
) -> Disposable
```

The exact name and signature should follow local conventions discovered during
implementation. Do not expose it publicly unless testability genuinely
requires an internal seam.

### 5.2 Preserve the update ordering

The existing authorized implementation calls `dropConnectionStatus()` inside
the API-environment update only when the setting actually changes. Preserve
that behavior unless a focused test demonstrates a reason to alter it.

The expected sequence is:

1. shared settings emit a new effective proxy;
2. the binding detects a semantic difference;
3. the network status changes to `waitingForNetwork`;
4. the context publishes its updated API environment;
5. registered `MTProto` instances detect changed proxy settings;
6. old direct transports reset;
7. pending authorization requests retry through the selected proxy.

### 5.3 Install the binding in authorized `Account`

Replace the current inline subscription in `Account.init` with the helper and
add its returned disposable to the existing `managedOperationsDisposable`.

This is intended to be a behavior-preserving extraction. Authorized account
proxy updates must continue to work exactly as before.

### 5.4 Install the binding in `UnauthorizedAccount`

Add one lifetime-owned disposable to `UnauthorizedAccount`, for example a
`MetaDisposable` or the concrete `Disposable` style most consistent with the
class's existing fields.

Install the binding after `self.network` is available. Dispose it in
`UnauthorizedAccount.deinit` with the class's other owned resources.

Important lifetime requirements:

- only one subscription exists per live unauthorized account;
- replacing/deallocating the account disposes the old subscription;
- no update is delivered to a dead network;
- a master-DC network replacement cannot leave the binding attached to the old
  network.

The last requirement needs explicit inspection during implementation.
`changedMasterDatacenterId` currently replaces `self.network`; if the binding
captures the network passed at initialization, it must be replaced along with
the network or instead dereference the current network safely. Prefer the
smallest design that makes ownership explicit and avoids duplicate observers.

### 5.5 Initial emission behavior

`accountWithId` already applies a creation-time proxy snapshot before the
binding is installed. The binding's first shared-data emission will normally
repeat the same setting.

The semantic comparison must suppress a redundant status drop and transport
reset in this case. This preserves the existing fast path where a persisted
proxy is active before unauthorized network creation.

### 5.6 No proxy-specific branches

Do not special-case WSS in the account binding. The shared settings conversion
must continue to produce `MTSocksProxySettings` for:

- SOCKS5;
- MTProxy; and
- WebSocket relay.

MtProtoKit remains responsible for selecting the appropriate connection
interface from the resulting settings.

## 6. Regression-test plan

### 6.1 Preferred focused unit test

The essential behavior is a live settings transition, not merely initial
network construction. Prefer extracting the binding so its state transitions
can be tested with a controllable settings signal and narrow closures for:

- reading/updating the API environment; and
- recording connection-status drops.

This avoids constructing the unusually large complete account fixture while
still exercising the exact production comparison/update logic.

Required cases:

1. **Initial nil emission**
   - current context proxy is nil;
   - shared settings emit no effective proxy;
   - no status drop and no effective environment change occur.

2. **Enable WSS**
   - current context proxy is nil;
   - shared settings emit an enabled synthetic WSS server;
   - the same context receives WSS settings;
   - exactly one status drop is requested.

3. **Equivalent repeat**
   - emit settings semantically equal to the current WSS settings;
   - no additional status drop or environment replacement occurs.

4. **Replace WSS**
   - change host, port, path, or token in separate/equivalent representative
     cases;
   - the change is detected and exactly one new drop/update occurs.

5. **Switch proxy type**
   - WSS to SOCKS5 or MTProxy, and optionally back;
   - the new settings are applied and transport reset is requested.

6. **Disable proxy**
   - shared settings emit no effective proxy;
   - context proxy settings become nil;
   - exactly one drop/update occurs.

7. **Dispose**
   - dispose the binding;
   - emit another settings change;
   - no update or status drop is delivered.

### 6.2 Integration proof for `UnauthorizedAccount`

At least one test must prove that `UnauthorizedAccount` installs and owns the
binding. Choose the least brittle practical option after inspecting the test
infrastructure:

1. **Preferred if affordable:** create a real temporary `AccountManager`, real
   `UnauthorizedAccount`, and real `Network`/`MTContext`; update
   `SharedDataKeys.proxySettings`; assert the same context changes.
2. **Otherwise:** expose a narrow internal installation seam and verify that
   the unauthorized initializer owns the returned disposable, supplemented by
   the focused binding test.

Do not settle for a test that only calls `initializedNetwork` with a proxy
already present. That does not regress the reported defect.

### 6.3 Real-context assertions

If a real integration fixture is practical, assert:

```swift
XCTAssertNil(unauthorizedAccount.network.context.apiEnvironment.socksProxySettings)
```

after initial creation, then update shared settings and eventually assert:

```swift
XCTAssertTrue(
    unauthorizedAccount.network.context.apiEnvironment.socksProxySettings
        .isEqual(expectedWssSettings)
)
```

Also observe `network.connectionStatus` or a focused drop hook to prove that a
reconnect was requested. Avoid tests that rely only on timing or private log
text.

### 6.4 Existing tests to rerun

Run at least:

- proxy settings conversion and WSS equality tests;
- WSS/Obfuscated2 startup-boundary tests;
- the new live propagation tests; and
- any existing account/network tests selected by the affected Bazel target.

## 7. Implementation sequence

1. Reinspect `Account.swift` fields, initializer ordering, deinitializers, and
   `changedMasterDatacenterId` on the implementation branch.
2. Identify how the unauthorized binding should follow a replaced network
   without retaining the old one or creating duplicate subscriptions.
3. Add the focused binding regression first and demonstrate that the missing
   unauthorized installation is not covered by current behavior.
4. Extract the authorized inline subscription into the shared helper.
5. Install and own the helper from `UnauthorizedAccount`.
6. Run focused tests after each behaviorally meaningful change.
7. Review all captures/closures for lifetime and queue correctness.
8. Run formatting/diff checks and inspect the final patch for secrets.
9. Build the affected app target.
10. Validate on a physical device with a clean authorization state.

## 8. Physical-device validation

Use a network where direct Telegram access is blocked but the WSS endpoint is
reachable.

### Case A: proxy enabled after unauthorized network creation

1. Start with clean app/account state and no active proxy.
2. Launch to the phone-number screen.
3. Confirm the unauthorized network initially attempts direct transport.
4. Add and enable the WSS relay from the authorization UI.
5. Verify the same unauthorized context resets its direct transports and
   starts persistent WSS connections.
6. Submit the authorization flow.
7. Confirm `help.*` and `auth.*` requests complete and the UI advances.

### Case B: proxy persisted before unauthorized network creation

1. Preserve enabled proxy settings while safely removing only login/account
   authorization state.
2. Relaunch.
3. Confirm the first unauthorized transport uses WSS immediately.
4. Confirm the initial binding emission does not cause unnecessary reconnect
   churn.

### Case C: live replacement and disable

1. While unauthorized, replace the active proxy with another synthetic/test
   configuration.
2. Confirm exactly one environment transition and reconnect.
3. Disable the proxy and confirm the context returns to nil proxy settings.
4. Re-enable WSS and confirm authorization traffic resumes through it.

### Case D: transition to authorized account

1. Complete login through WSS.
2. Confirm the resulting authorized account continues to use the relay.
3. Toggle or replace the proxy once while authorized.
4. Verify behavior remains unchanged from the pre-fix authorized path.

## 9. Expected observable behavior

Temporary credential-safe diagnostics may be used during physical validation
only if automated assertions and existing logs are insufficient. If added,
they should show a progression equivalent to:

```text
shared proxy settings changed: owner=unauthorized, type=wss, enabled=1
network proxy environment updated: owner=unauthorized, changed=1, drop=1
WSS transport selected
WSS open with no pre-open application bytes
WSS first application write
WSS first response
authorization request completed
```

The server should show:

```text
HTTP 101 upgrade
WSS stream started
datacenter selected
bidirectional relay traffic
stream completed normally
```

There should be no continuing direct-connect timeout loop for the primary
authorization context after the settings update.

All temporary propagation diagnostics must be removed before the production
patch is finalized.

## 10. Risks and safeguards

### Duplicate subscriptions

Risk: account/network replacement installs multiple observers, causing repeated
status drops and updates.

Safeguard: use one clearly owned disposable and replace/dispose it atomically
with the network it targets.

### Retaining obsolete networks

Risk: the shared-data subscription captures a network strongly after a
master-DC replacement or account deallocation.

Safeguard: weak capture plus explicit owner disposal; test that post-disposal
emissions do nothing.

### Redundant initial reconnect

Risk: the first settings emission repeats the creation-time snapshot and
unnecessarily resets a healthy proxied network.

Safeguard: semantic comparison against the current context environment before
calling `dropConnectionStatus()`.

### Incomplete WSS equality

Risk: changing relay path or token is ignored.

Safeguard: compare through `MTSocksProxySettings.isEqual(_:)`; keep the
existing WSS equality tests that cover all relay identity fields.

### Accidental change to authorized behavior

Risk: helper extraction changes ordering, queueing, or disposal for `Account`.

Safeguard: preserve the existing closure's logic and ownership, then rerun
authorized proxy update coverage and physical smoke tests.

### Intentional direct traffic mistaken for failure

Risk: backup-address discovery can intentionally clear proxy settings and
still generate direct-looking traffic.

Safeguard: correlate validation with the primary unauthorized context and its
authorization requests rather than requiring that all process traffic be
proxied.

## 11. Security requirements

The implementation and tests must not contain:

- the real relay hostname, port, path, or bearer token;
- phone numbers, login tokens, auth codes, push tokens, or API hashes;
- client IP addresses;
- account identifiers or local container paths;
- raw MTProto payloads or Obfuscated2 headers;
- key/IV material or Authorization headers; or
- persistent identifiers copied from private logs.

Use synthetic values such as `relay.example.com`, `/relay/test`, and
`synthetic-token` in tests. Ensure object descriptions continue to redact WSS
tokens.

## 12. Validation commands and checks

The exact Bazel labels should be confirmed from the current test `BUILD` files
before execution. The implementation session should complete these checks:

1. focused new propagation test;
2. existing TelegramCore proxy/WSS tests;
3. affected TelegramCore build target;
4. affected application build target;
5. `git diff --check`;
6. `git status --short` and a manual final diff review; and
7. a secret scan of the final diff for values from the private captures.

Do not broaden the patch merely to make unrelated repository-wide tests pass.
Record pre-existing failures separately.

## 13. Completion criteria

The fix is complete only when all of the following are true:

1. Enabling a proxy updates the existing unauthorized context without login,
   relaunch, or account recreation.
2. Replacing and disabling the proxy update that same context correctly.
3. A meaningful change drops connection status and causes old direct
   transports to reset.
4. Pending first-run `help.*` and `auth.*` requests progress through WSS when
   direct Telegram access is unavailable.
5. A proxy present at initial network construction is used immediately without
   a redundant reconnect from the binding's initial emission.
6. WSS host, port, path, and token changes are all detected.
7. SOCKS5 and MTProxy live updates continue to work.
8. Authorized-account proxy behavior remains unchanged.
9. Unauthorized master-DC replacement does not retain the old network or
   duplicate the settings subscription.
10. Disposal prevents all later settings delivery.
11. The prior WSS startup invariant remains intact: no application bytes are
    written before WebSocket open, and no SOCKS5 greeting prefixes the
    Obfuscated2 stream.
12. Intentional direct backup discovery remains functional.
13. Focused tests, affected builds, and `git diff --check` pass.
14. Physical-device first-run login succeeds through the relay.
15. No temporary diagnostics or sensitive values remain in the final patch.

## 14. Recommended first action in the implementation session

Begin in `Account.swift` by inspecting the exact lifetime relationship between
`UnauthorizedAccount.network`, `changedMasterDatacenterId`, and deallocation.
Then write the focused live-update test and extract the authorized subscription
without changing its behavior. Only after that extraction is covered should
the same binding be installed for `UnauthorizedAccount`.

No server, Nginx, mtg, Obfuscated2 builder, or WSS FIFO change should be made
unless new evidence contradicts the current captures.