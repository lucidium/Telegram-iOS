# MTProxy DPI Research Handoff

- **Status:** Initial investigation complete; no implementation changes made
- **Last updated:** 2026-07-23
- **Project:** Official Telegram iOS source tree with local research/customization work
- **Branch at investigation time:** `build/release-12.9.2`
- **Commit at investigation time:** `fcdd44b0b85c84fa483510614836a3e9c220c1c3` (`Serena and Semble setup`)
- **Original proposition:** [`docs/custom/initial_idea.md`](initial_idea.md)

## 1. Purpose of This Document

This is a durable handoff for continuing research into restoring MTProxy connectivity on a country-wide network where DPI began blocking Telegram's official MTProxy transport after June 5, 2026.

It records:

- the user's observations and operational constraints;
- the relevant Telegram-iOS transport architecture and code paths;
- what was learned about the current fake-TLS implementation;
- an assessment of ClientHello profiles and fragmentation;
- the stronger long-term transport option;
- unresolved hypotheses;
- the recommended next experiments and a precise resume point.

This document contains no proxy addresses, secrets, packet captures, or other deployment credentials.

## 2. User's Goal and Current Environment

### Goal

Make Telegram's MTProxy transport usable again on the affected network and improve its resistance to the current DPI filtering system.

The original proposal consists of:

1. selectable fake-TLS ClientHello profiles resembling recent Safari, Chrome, or Firefox traffic;
2. adjustable fragmentation of the fake-TLS ClientHello, including fragment sizes and delays between fragments.

The longer-term goal is more important than retaining compatibility with every existing MTProxy server. Client compatibility with ordinary MTProxy servers remains desirable where it does not prevent a stronger design.

### Confirmed operational facts

The user provided the following answers after the initial code investigation:

1. **The tested MTProxy secrets begin with `ee`.** Therefore, Telegram-iOS uses its fake-TLS MTProxy path rather than plain obfuscated MTProxy or the `dd` random-padding mode.
2. **The same Telegram client and MTProxy configuration work when an unrelated VPN connection is active.** Telegram also works through that VPN with MTProxy disabled. This is strong evidence of on-path classification or interference in the direct country network rather than a broken proxy deployment or invalid secret.
3. **The user controls several proxy servers in different countries.** They currently run the open-source [`9seconds/mtg`](https://github.com/9seconds/mtg) server and can deploy server-side modifications if needed.
4. **The failure affects the country network broadly, on both cellular and Wi-Fi.** The specific country and operators were not recorded in this phase.
5. **No packet captures have been collected yet.** The known symptom is that ordinary official-app MTProxy connectivity no longer works directly, while it works through a VPN.
6. **The Telegram-iOS fork builds successfully and produces an installable device IPA.** The working command recorded in the original proposition is:

   ```sh
   ./build-input/bazel-8.4.2-darwin-arm64 build Telegram/Telegram \
     --//Telegram:disableExtensions \
     --announce_rc \
     --features=swift.use_global_module_cache \
     --verbose_failures \
     --remote_cache_async \
     --define=buildNumber=1 \
     --disk_cache="$HOME/telegram-bazel-cache" \
     -c dbg \
     --ios_multi_cpus=arm64 \
     --watchos_cpus=arm64_32 \
     '--@build_bazel_rules_swift//swift:copt="-j"' \
     '--@build_bazel_rules_swift//swift:copt="6"'
   ```

## 3. Relevant Telegram-iOS Architecture

The app-side MTProxy implementation is primarily in `MtProtoKit`, with the socket backend optionally supplied by `TelegramCore`.

### Main files

| File | Relevant responsibility |
| --- | --- |
| `submodules/MtProtoKit/Sources/MTApiEnvironment.m` | Parses MTProxy secrets into plain, `dd`, and `ee` variants. |
| `submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTApiEnvironment.h` | Declares `MTProxySecret`, `MTProxySecretType0`, `MTProxySecretType1`, `MTProxySecretType2`, and proxy settings. |
| `submodules/MtProtoKit/Sources/MTTcpConnection.m` | Generates the fake ClientHello, performs the fake-TLS handshake, creates obfuscated MTProto framing, and wraps subsequent payloads in TLS-looking records. |
| `submodules/MtProtoKit/Sources/MTTcpConnection.h` | Declares the TCP connection interface and delegate surface. |
| `submodules/TelegramCore/Sources/Network/NetworkFrameworkTcpConnectionInterface.swift` | Optional `Network.framework` implementation of `MTTcpConnectionInterface`. |
| `submodules/TelegramCore/Sources/Network/Network.swift` | Selects the optional `Network.framework` backend through `context.makeTcpConnectionInterface`. |
| `submodules/TelegramCore/Sources/SyncCore/SyncCore_NetworkSettings.swift` | Persists the `useNetworkFramework` setting. |
| `submodules/DebugSettingsUI/Sources/DebugController.swift` | Exposes the `Network X [Restart App]` debug switch. |

### Secret variants

`+[MTProxySecret parseData:]` in `MTApiEnvironment.m` distinguishes:

| Serialized secret | Parsed type | Transport behavior |
| --- | --- | --- |
| exactly 16 bytes | `MTProxySecretType0` | Ordinary obfuscated MTProxy. |
| `0xdd` + 16 bytes | `MTProxySecretType1` | Obfuscated MTProxy with randomized/extended padding. |
| `0xee` + 16 bytes + UTF-8 domain | `MTProxySecretType2` | Fake-TLS MTProxy. |

Only `MTProxySecretType2` invokes the fake ClientHello path discussed here.

### Socket backends

`MTTcpConnection` writes through the `MTTcpConnectionInterface` abstraction.

Two implementations matter:

1. **Default backend:** `MTGcdAsyncSocketTcpConnectionInterface` in `MTTcpConnection.m`, backed by `GCDAsyncSocket`.
2. **Optional backend:** `NetworkFrameworkTcpConnectionInterface` in TelegramCore, backed by `NWConnection`.

`Network.swift` installs the second backend through `MTContext.makeTcpConnectionInterface` when the `useNetworkFramework` setting or beta-feature default enables it.

Any ClientHello write strategy intended to work reliably in all app configurations should therefore live at the `MTTcpConnection` protocol layer or in a shared interface abstraction, not only inside one concrete socket implementation.

## 4. Current `ee` Fake-TLS Flow

The fake-TLS implementation is not a real TLS connection. It synthesizes bytes resembling TLS and authenticates them with the MTProxy secret.

### Connection startup

`-[MTTcpConnection start]` in `MTTcpConnection.m`:

1. resolves and connects to the MTProxy endpoint;
2. recognizes `MTProxySecretType2`;
3. calls `MTCreateSafariClientHello(secret.domain, encryptionProvider)`;
4. computes an HMAC-SHA256 over the generated ClientHello using the 16-byte MTProxy secret;
5. XORs the current adjusted Unix timestamp into the final four HMAC bytes;
6. writes this 32-byte value into the ClientHello random field at byte offset 11;
7. stores the value in `_helloRandom` for validating the response;
8. sends the complete ClientHello through one `writeData:` call;
9. starts reading and validating a TLS-looking ServerHello response.

### ClientHello generator

The relevant symbols in `MTTcpConnection.m` are:

- `MTGenerateGreaseValues`
- `executeGenerationCodeRecursive`
- `executeGenerationCode`
- `MTCreateSafariClientHello`

The generator is driven by an embedded command string. It can emit:

- fixed byte strings;
- zero-filled and random fields;
- the secret's domain for SNI;
- GREASE values;
- generated public-key-shaped values;
- ML-KEM-shaped key material;
- nested two-byte lengths;
- randomized alternatives for selected fields.

The generated ClientHello currently includes Safari-like choices, GREASE, SNI, ALPN alternatives, key-share material, and padding to a minimum size. It is already more than a single static byte array, although it remains one hard-coded, hand-maintained family of profiles.

### ServerHello validation

`-[MTTcpConnection connectionInterfaceDidReadData:withTag:networkType:]` handles:

- `MTTcpSocksReceiveHelloResponse`
- `MTTcpSocksReceiveHelloResponse1`
- `MTTcpSocksReceiveHelloResponse2`

The response parser checks expected TLS-looking record markers, reconstructs the complete response, zeroes its random field, and validates an HMAC derived from `_helloRandom`, the response, and the shared secret. Only then does normal MTProto data transmission begin.

### Post-handshake traffic

`-[MTTcpConnection sendDataIfNeeded]` creates the normal obfuscated MTProto control header and encrypted packets. For an `ee` secret, it additionally:

- emits a TLS-looking change-cipher-spec prefix once;
- divides encrypted MTProto bytes into chunks of up to 16,408 bytes;
- prefixes each chunk with a TLS application-data-looking header `17 03 03 <length>`.

Incoming data is likewise unwrapped from TLS-looking application-data records before normal MTProto packet parsing.

This full-flow behavior is important: a DPI system may identify fake TLS from the handshake response or later record sequence even when the initial ClientHello closely resembles a browser.

## 5. Existing Upstream Work and the Linked Desktop Commit

### Linked Telegram Desktop commit

The original proposition references:

- [`telegramdesktop/tdesktop@407bf196417b80c903f6ae65d4c3202be72286d5`](https://github.com/telegramdesktop/tdesktop/commit/407bf196417b80c903f6ae65d4c3202be72286d5)

That commit, titled **“Fix parts of client hello generation”**, modifies two values in Desktop's `mtproto_tls_socket.cpp`:

1. an ECH-GREASE extension type from `0xfe02` to `0xfe0d`;
2. an associated random field from 20 bytes to 32 bytes.

It improves the validity/fidelity of one Desktop ClientHello profile. It does not add profile selection, transport fragmentation, or a fundamentally new anti-DPI protocol.

### Current Desktop behavior inspected during research

The current Telegram Desktop source:

- generates a Chrome-like ClientHello from structured block rules;
- randomizes extension order;
- authenticates fake ClientHello and ServerHello values with the shared MTProxy secret;
- wraps later data in TLS-looking application-data records;
- sends the ClientHello with one socket write;
- does not implement the adjustable delayed ClientHello fragmentation proposed here.

### Relevant iOS history

The local Telegram-iOS history contains:

- `3d6fabea33 Update safari` dated 2026-04-07.

This commit substantially refreshed `MTTcpConnection.m`'s Safari-like generator, adding newer key material and randomized alternatives. It postdates the linked Desktop fix and represents a separate iOS-oriented profile. The Desktop commit's two byte-level changes should not be copied blindly into iOS because the two generators do not contain the same extension layout.

## 6. Assessment of the Original Proposal

## 6.1 Selectable ClientHello profiles

### Feasibility

**Technically feasible with moderate implementation effort.**

The embedded generation rules can be refactored into explicit, versioned profiles, for example:

- `safari-ios-26.0-2026-07`
- `chrome-desktop-138-2026-07`
- `firefox-desktop-140-2026-07`

Profiles should include validation metadata and should be versioned by browser/platform release and capture date. Permanent names such as just `Safari` or `Chrome` would age quickly and become ambiguous.

### Limitations

A ClientHello fingerprint is only one part of an observable connection. A stateful classifier may correlate:

- cipher suites, extensions, groups, ALPN, GREASE, key-share shapes, and extension order;
- TLS-record sizing and sequence;
- TCP/IP behavior and timing;
- whether the fake ServerHello is plausible for the advertised ClientHello;
- the lack of a genuine certificate and normal TLS handshake continuation;
- immediate transition to MTProto carried in TLS-looking records;
- destination-IP reputation;
- repeated active probes and the endpoint's fallback behavior.

Using a Desktop Chrome or Firefox fingerprint from an iPhone can create a cross-layer mismatch with the iOS TCP stack. The first additional profile should therefore be captured from **real Safari traffic on the same iOS version and preferably the same test device**, not selected merely because a public JA3/JA4 value is popular.

ClientHello profile rotation alone is unlikely to be a durable answer if the current DPI performs full-flow classification.

### Initial recommendation

- Keep the existing Safari-like generator as the baseline.
- Add a profile abstraction only after capturing the failing flow.
- Initially add no more than one profile derived from real same-device Safari traffic.
- Keep selection behind a debug/research configuration until evidence supports a production behavior.
- Validate each generated ClientHello structurally and with offline fingerprint tooling.

## 6.2 ClientHello fragmentation

The word “fragmentation” covers several materially different techniques.

### A. Multiple application-level socket writes

Split the existing ClientHello byte stream into chunks and issue multiple writes, optionally with delays.

**Advantages:**

- client-only prototype;
- compatible in principle with an unmodified MTProxy server because TCP remains a byte stream;
- does not change the fake-TLS HMAC input bytes;
- may evade a simple classifier that inspects only one TCP segment.

**Limitations:**

- multiple writes do not guarantee multiple TCP packets;
- `GCDAsyncSocket`, `Network.framework`, the kernel, and network offload may coalesce writes;
- even delayed segments can be reassembled by stateful DPI;
- excessive delay increases connection latency and can amplify reconnect/battery costs;
- tiny or fixed-pattern writes can become a new fingerprint.

Implementation must be asynchronous and cancellable. Calling `sleep`, `usleep`, or otherwise blocking `MTTcpConnection`'s serial network queue would be incorrect.

### B. TLS-record fragmentation

Split the ClientHello handshake message across multiple syntactically valid TLS records, each with its own record header and corrected lengths.

**Advantages:**

- record boundaries remain meaningful even if TCP writes are coalesced;
- can affect a DPI that reassembles TCP but incompletely handles handshake messages spanning TLS records.

**Limitations:**

- changes the exact bytes authenticated by the fake-TLS protocol;
- may not be accepted by the stock `mtg` parser;
- may require coordinated client and server changes;
- remains vulnerable to a correct TLS reassembler.

This is a more meaningful protocol-layer experiment than merely issuing several writes, but it should follow—not precede—the baseline capture and transparent write-chunking experiment.

### C. Raw TCP/IP desynchronization

Examples include out-of-order delivery, overlapping TCP sequence ranges, invalid-checksum decoys, low-TTL packets, and IP fragmentation.

A normal iOS application socket does not provide the raw packet control required for these methods. Implementing them would generally require a privileged Network Extension or packet tunnel, with entitlement and App Store distribution constraints. This is not a practical first direction for the Telegram application itself.

### Configuration recommendation

Do not begin with arbitrary user-facing sliders. Use a bounded experiment model:

- strategy: single write, chunked writes, or TLS-record fragmentation;
- minimum and maximum chunk size;
- minimum and maximum inter-write delay;
- maximum chunk count;
- maximum total added handshake latency;
- deterministic strategy identifier in redacted diagnostics.

The implementation should clamp invalid ranges and use cryptographically or system-supplied random values only where randomization is part of the selected strategy.

## 7. Stronger Long-Term Option: Genuine TLS/HTTP Transport

If packet captures show that the DPI recognizes the fake-TLS flow after the ClientHello, continued manual profile tuning is unlikely to be durable.

A stronger architecture is:

```text
Telegram-iOS fork
    -> genuine system TLS
    -> ordinary HTTPS or WebSocket-like request
    -> valid certificate and plausible domain/front service
    -> custom relay under the user's control
    -> MTProxy or Telegram backend
```

### Advantages

- genuine Apple TLS implementation and fingerprint;
- real certificate and complete TLS state machine;
- automatic adaptation when iOS updates its TLS stack;
- encrypted post-handshake transport rather than recognizable fake-TLS records;
- ability to return an ordinary website or other benign service to unauthenticated probes;
- better resistance to active probing and semantic TLS validation.

### Costs and constraints

- requires coordinated client and server software;
- is not automatically compatible with arbitrary stock MTProxy deployments;
- adds certificate, domain, relay, and deployment operations;
- still cannot prevent direct IP/domain blocking;
- requires protocol design, security review, and failure/fallback behavior.

Because the user can modify and deploy `mtg`, this path is operationally possible. It should be considered the likely long-term direction if the censor has moved beyond shallow ClientHello matching.

## 8. Current Evidence and Working Hypotheses

### Strongest current inference

The same `ee` MTProxy setup works when carried through an unrelated VPN but fails directly on both cellular and Wi-Fi. This strongly supports **country-network on-path interference**.

### What is not yet known

The current evidence does not reveal which phase triggers blocking:

1. destination IP or port before any payload;
2. first bytes or fingerprint of the ClientHello;
3. SNI/domain matching;
4. fake ServerHello semantics or reverse-path filtering;
5. the post-handshake TLS-looking application records;
6. active probing and subsequent endpoint/IP classification;
7. timing or other flow metadata.

This uncertainty is why packet capture has higher research value than immediately adding multiple browser profiles.

### Failure-stage interpretation guide

| Capture observation | Likely implication | Product direction |
| --- | --- | --- |
| No SYN reaches the server | IP/port/routing block. | ClientHello changes cannot help; test a fresh endpoint and transport architecture. |
| TCP handshake completes, but only a ClientHello prefix arrives before reset/stall | Early payload classifier. | Chunked writes or record fragmentation are worth testing. |
| Complete ClientHello arrives and ServerHello leaves, but no normal acknowledgment/response follows | Reverse-path filtering or injected interference. | Compare packet traces and sequence/reset origin. |
| Fake-TLS handshake completes, then the connection is disrupted after application-data records begin | Full-flow fake-TLS/MTProxy classification. | Prioritize genuine TLS/HTTP transport over ClientHello tuning. |
| A fresh server IP works briefly and later stops after probes | Endpoint discovery or active probing. | Add normal fallback behavior and authenticated genuine transport. |

## 9. Recommended Next Research Phase

## 9.1 Establish a controlled test endpoint

- Use one dedicated `mtg` instance, IP, and port for research.
- Preserve one existing known-good deployment as a control.
- Record the exact `mtg` version/commit and configuration, excluding secrets.
- Avoid unrelated reverse proxies or load balancers during the first capture unless they are part of the failing production path.

## 9.2 Capture paired direct and VPN attempts

Collect two short server-side captures using the same:

- iPhone;
- Telegram build;
- MTProxy host, port, and `ee` secret;
- app procedure and approximate time window.

Test cases:

1. direct connection over the restricted network;
2. connection over the known-working unrelated VPN.

A possible server-side command is:

```sh
sudo tcpdump -i any -nn -s0 -w mtproxy-direct.pcap 'tcp port <MTPROXY_PORT>'
```

Repeat with a separate output file for the VPN test. Narrow the filter by the expected source address where practical. Stop each capture promptly after one or a small number of connection attempts.

Treat captures as sensitive: they contain endpoint, address, and timing metadata. Do not commit them to this repository.

## 9.3 Add redacted client-stage diagnostics

Before transport experiments, add debug-only events for:

- DNS resolution complete;
- TCP connect started/completed/failed;
- generated ClientHello profile identifier and byte count;
- ClientHello write strategy, chunk count, and total scheduling duration;
- first ServerHello bytes received;
- fake ServerHello structural validation result;
- HMAC validation result;
- transition to MTProto application data;
- disconnect/error category and elapsed time.

Do not log the proxy secret, complete HMAC/random values, full domain where sensitive, message payloads, or raw packet data.

## 9.4 Inspect `9seconds/mtg`

This investigation did **not yet inspect the `mtg` source code**. The next session should locate:

- `ee` secret parsing;
- fake ClientHello parsing and read buffering;
- assumptions about a single TLS record or single socket read;
- ServerHello generation and HMAC rules;
- post-handshake TLS-record framing;
- active-probe/fallback behavior;
- extension points for a genuine TLS/HTTP transport.

This server inspection is required before designing TLS-record fragmentation or a coordinated replacement transport.

## 9.5 Run a minimal client-only experiment matrix

Only if the captures indicate that early ClientHello inspection is involved:

1. baseline: current profile, one write;
2. current profile, a small bounded number of delayed writes;
3. same strategy with several cut positions, including around but not exclusively inside SNI;
4. repeat on affected cellular and Wi-Fi paths;
5. compare success rate, handshake time, reconnect count, and server-observed segmentation.

Do not infer success from one connection. Use repeated trials and retain a no-fragmentation control.

## 9.6 Decision gate

- **If delayed writes consistently restore connectivity:** harden the asynchronous implementation, test both socket backends, and then consider a limited strategy selector.
- **If writes are coalesced or do not help but the ClientHello is the trigger:** investigate TLS-record fragmentation with coordinated `mtg` support.
- **If blocking occurs after fake TLS completes:** stop spending time on ClientHello profiles and design a genuine TLS/HTTPS/WebSocket relay.
- **If no TCP connection reaches the server:** focus on endpoint discovery/blocking, fresh IP controls, and a new outer transport rather than byte-level ClientHello changes.

## 10. Implementation Constraints for Future Work

1. Preserve ordinary MTProxy behavior for 16-byte and `dd` secrets.
2. Gate experimental behavior to `ee` fake-TLS connections or an explicit new transport/configuration.
3. Do not block the `MTTcpConnection` queue with sleeps.
4. Ensure delayed work is cancelled on disconnect, stop, retry, and deallocation.
5. Prevent bytes from later protocol stages from overtaking scheduled ClientHello fragments.
6. Support both `GCDAsyncSocket` and `Network.framework`, or explicitly disable unsupported experimental combinations.
7. Bound total handshake delay to avoid reconnect storms and excessive battery/network use.
8. Keep profile generation separate from write scheduling and separate again from settings/UI.
9. Use versioned profile identifiers and deterministic validation fixtures.
10. Avoid logging secrets or sensitive wire values.
11. Validate on a physical iPhone and affected real networks; simulator-only testing is insufficient.
12. Build the full app target as required by the repository's Bazel workflow.

## 11. Suggested Test Layers

The repository has limited app-side unit test coverage, so the research should introduce small testable seams rather than relying only on full-device trials.

### Offline ClientHello tests

- generated lengths are internally consistent;
- HMAC/random injection occurs at the expected offset;
- SNI contains the configured domain;
- profile output parses as the intended TLS ClientHello shape;
- fixed test entropy can produce deterministic structural fixtures;
- invalid profile definitions fail closed.

### Write scheduler tests

- chunks reconstruct the exact original byte stream;
- min/max ranges are clamped and cannot create zero-length loops;
- completion occurs once;
- disconnect cancels pending chunks;
- no subsequent payload is sent before the final ClientHello chunk;
- added delay stays within the configured maximum.

### Server compatibility tests

- stock `mtg` accepts the baseline and client-only chunked stream;
- modified `mtg`, if introduced, remains compatible with the agreed legacy mode;
- TLS-record-fragmented handshakes are accepted only when explicitly enabled;
- malformed handshakes and unauthenticated probes fail safely.

### Network validation

- unrestricted direct baseline;
- restricted direct path;
- restricted path through VPN control;
- affected Wi-Fi and cellular;
- repeated trials rather than a single anecdotal connection.

## 12. Proposed Architectural Separation

If implementation begins, keep four concerns distinct:

1. **ClientHello profile model/generator**
   - profile identifier;
   - structured rules or captured template;
   - entropy and domain injection;
   - structural validation.
2. **Fake-TLS handshake state machine**
   - HMAC/timestamp injection;
   - response authentication;
   - state transitions and timeout handling.
3. **Write strategy**
   - immediate single write;
   - asynchronous chunked writes;
   - eventually, TLS-record fragmentation if negotiated/supported.
4. **Research configuration and diagnostics**
   - bounded options;
   - debug UI or local configuration;
   - redacted result metrics.

This separation allows experiments without duplicating cryptographic logic or coupling transport behavior to Settings UI.

## 13. Current Recommendation

### Near term

Do **not** begin by implementing Safari/Chrome/Firefox selection and broad fragmentation sliders.

First:

1. capture direct and VPN control attempts;
2. identify the failure stage;
3. inspect `mtg`'s fake-TLS parser and fallback behavior;
4. add redacted stage diagnostics;
5. run the smallest client-only chunked-write experiment if the evidence supports it.

### Long term

Because the user controls the server and values durability over universal stock-server compatibility, be prepared to move to a genuine TLS/HTTP transport. Retain the existing stock-compatible `ee` path as a fallback where possible, but do not let that compatibility requirement constrain the stronger transport if full-flow DPI is confirmed.

## 14. Resume Here in a Future Session

Start the next session with the following checklist:

1. Read this document and `docs/custom/initial_idea.md`.
2. Confirm no new upstream changes have altered:
   - `MTProxySecret/+parseData:`;
   - `MTCreateSafariClientHello` / `executeGenerationCode`;
   - `MTTcpConnection/-start`;
   - `MTTcpConnection/-sendDataIfNeeded`;
   - the fake ServerHello response tags;
   - `NetworkFrameworkTcpConnectionInterface` selection.
3. Record the deployed `9seconds/mtg` version and inspect its `ee` fake-TLS implementation with Semble or repository-aware search, followed by symbol-level reading.
4. Plan and collect paired server-side PCAPs for direct and VPN attempts.
5. Classify the failure using the table in Section 8.
6. Choose one next branch:
   - early ClientHello trigger -> minimal nonblocking write-chunking prototype;
   - TLS parser limitation -> coordinated TLS-record fragmentation research;
   - post-handshake/full-flow trigger -> genuine TLS/HTTP relay design;
   - pre-payload endpoint block -> endpoint/fallback/new-transport research.

### Open questions to answer next

- Which country and operators are involved, if this can be recorded safely?
- Does the server receive a SYN, a partial ClientHello, a full ClientHello, or post-handshake data during a direct failed attempt?
- Are injected TCP RST packets visible, and from which direction/TTL/IP-ID characteristics?
- Does a fresh server IP exhibit the same immediate behavior?
- What exact `mtg` version and fake-TLS parser assumptions are deployed?
- Does `mtg` already support a real TLS, HTTP, WebSocket, or fallback mode suitable for extension?
- Does the current iOS build use the default GCD socket backend or `Network.framework` during the tests?

## 15. Sources Consulted

### Local project

- `CLAUDE.md`
- `docs/custom/initial_idea.md`
- `submodules/MtProtoKit/Sources/MTApiEnvironment.m`
- `submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTApiEnvironment.h`
- `submodules/MtProtoKit/Sources/MTTcpConnection.m`
- `submodules/MtProtoKit/Sources/MTTcpConnection.h`
- `submodules/TelegramCore/Sources/Network/NetworkFrameworkTcpConnectionInterface.swift`
- `submodules/TelegramCore/Sources/Network/Network.swift`
- `submodules/TelegramCore/Sources/SyncCore/SyncCore_NetworkSettings.swift`
- `submodules/DebugSettingsUI/Sources/DebugController.swift`
- local Git history for `MTTcpConnection.m`, especially `3d6fabea33 Update safari`

### External references

- Telegram Desktop fake-TLS source: [`Telegram/SourceFiles/mtproto/details/mtproto_tls_socket.cpp`](https://github.com/telegramdesktop/tdesktop/blob/master/Telegram/SourceFiles/mtproto/details/mtproto_tls_socket.cpp)
- Telegram Desktop commit: [`407bf196417b80c903f6ae65d4c3202be72286d5`](https://github.com/telegramdesktop/tdesktop/commit/407bf196417b80c903f6ae65d4c3202be72286d5)
- User's server implementation: [`9seconds/mtg`](https://github.com/9seconds/mtg)
- Background research located during investigation: [Circumventing the GFW with TLS Record Fragmentation](https://upb-syssec.github.io/blog/2023/record-fragmentation/)
- JA4 technical background: [`FoxIO-LLC/ja4`](https://github.com/FoxIO-LLC/ja4/blob/main/technical_details/JA4.md)

External fragmentation research is useful background, not proof that a particular strategy will work against the affected country's current DPI. The paired captures and controlled experiments remain authoritative for this project.
