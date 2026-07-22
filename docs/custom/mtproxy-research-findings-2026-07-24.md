# MTProxy DPI Capture Findings — 2026-07-24

This is a concise addendum to [`mtproxy-research-handoff.md`](mtproxy-research-handoff.md). It records the first paired server-side direct/VPN capture analysis. The captures and logs remain outside this repository.

## Test environment

- Server: Ubuntu 24.04.3 LTS, `9seconds/mtg` 2.2.8, direct TCP listener with no reverse proxy or load balancer.
- Client: official Telegram for macOS 12.9.2 from the App Store on macOS 26.5.2.
- Restricted-path test: direct Wi-Fi connection; failed.
- Control: same client, endpoint, port, and `ee` secret through NaiveProxy with a Czech exit; connected.
- Server capture used `tcpdump -i any -nn -s0`; no kernel packet drops were reported.

## Verified observations

### Direct path

1. The endpoint and TCP port are reachable. All 50 observed attempts completed the TCP handshake, and the server acknowledged client payload. This rules out a simple IP-, port-, routing-, or SYN-level block for this test.
2. The generated fake ClientHello records were 1,514–1,531 bytes and crossed the path as two TCP payload segments: 1,448 bytes followed by 66–83 bytes.
3. In the first 5 attempts, the complete ClientHello reached `mtg`. The server authenticated it and sent its fake ServerHello + CCS + one noise ApplicationData record. The client never acknowledged any ServerHello payload and sent no post-handshake application data. The server retransmitted and timed out; `mtg` logged five obfuscated-handshake timeouts.
4. In the next 45 attempts, the server received and acknowledged exactly the first 1,448 bytes of ClientHello, but never received the final 66–83 bytes. `mtg` logged 45 ClientHello read timeouts.
5. No forged TCP RST was visible at the server. The server-side manifestation was silent payload loss followed by normal retransmission and timeout behavior.

### VPN control

All 15 observed VPN connections progressed through:

```text
TCP handshake
-> complete ClientHello
-> fake ServerHello + CCS + noise
-> client CCS + TLS-looking ApplicationData
-> bidirectional MTProto relay to Telegram DC 2
```

The VPN log contained normal relay sessions and no ClientHello or fake-TLS handshake errors. This confirms that the client, secret, proxy, and server implementation were functional during the experiment.

## Interpretation

The evidence is inconsistent with a purely static ClientHello-fingerprint block:

- several complete ClientHellos initially reached the server;
- their fake ServerHello responses were blackholed on the return path;
- subsequent connections were truncated consistently after the first 1,448 ClientHello bytes.

The best current hypothesis is stateful on-path classification: the system initially observes enough of the fake-TLS exchange to classify it, suppresses the reverse fake ServerHello, and then applies a short-lived flow/source/destination rule that suppresses the ClientHello tail on later connections. A server-only capture cannot determine whether packets are simply dropped or whether interference visible only near the client is also present.

Consequences:

- ClientHello profile rotation alone is unlikely to be durable.
- The existing connection already spans two TCP segments, so merely issuing multiple socket writes is not by itself a materially new wire strategy.
- ClientHello fragmentation remains useful as a diagnostic/bypass experiment, but the fake ServerHello or later flow may still trigger classification.
- Genuine TLS carrying an HTTPS/WebSocket-like relay remains the likely durable direction if record fragmentation does not let the connection progress into stable application data.

## `mtg` 2.2.8 findings

Source inspection of the deployed tag established that:

- `mtg` reads ClientHello data as a stream rather than assuming one socket read;
- it accepts a ClientHello handshake split across multiple TLS handshake records, bounded to at most 10 fragments;
- failed ClientHello validation/read is rewound and relayed to the configured fronting domain;
- its fake ServerHello must contain exactly one noise ApplicationData record because the Telegram client authenticates the complete response.

Therefore, a bounded TLS-record-fragmentation experiment can be client-only and remain compatible with this deployed server version.

## Recommended next experiment

Do not add broad profile selectors or user-facing fragmentation sliders. Implement fixed, versioned research strategies for `ee` connections only:

1. baseline: current single TLS record;
2. two TLS records with an early cut after a small handshake prefix;
3. two TLS records with a middle cut;
4. three TLS records with small first and final records;
5. for one two-record strategy, an asynchronous bounded 20–40 ms inter-write delay.

Construct and authenticate the canonical single-record ClientHello exactly as today, then split only its handshake payload across additional TLS record headers. `mtg` 2.2.8 reassembles the fragments into that canonical form before validation. Do not block the connection queue, and prevent later protocol bytes from overtaking scheduled fragments.

Run at least five direct restricted-Wi-Fi trials per strategy, with VPN controls before and after. Record success, time to connected, server-observed record/segment sizes, whether ServerHello payload is acknowledged, whether client CCS/ApplicationData follows, and whether any success persists beyond the first few connections.

### Decision gate

- If the client acknowledges ServerHello and sends application data, harden the best bounded strategy and repeat on physical-iPhone Wi-Fi and cellular.
- If a complete fragmented ClientHello arrives but ServerHello is still blackholed, stop ClientHello tuning and design a genuine TLS/HTTPS/WebSocket relay.
- If only the first TCP segment arrives regardless of record layout, use pacing only as a narrow diagnostic, then prioritize genuine TLS.
- If a strategy works briefly and then fails, treat it as adaptive/stateful classification rather than a durable bypass.

## Security note

The collected `mtg` debug logs include the proxy secret in a startup/configuration line. They must not be committed, uploaded, or pasted unredacted. Rotate the secret if those logs were shared outside the trusted research environment. PCAPs also remain sensitive because they contain endpoint, SNI, address, and timing metadata.

## Remaining metadata

Useful but non-blocking details still to record are the restricted-network country/operator, immutable Docker image ID or full `mtg --version` revision string, and anti-replay configuration. Anti-replay is not implicated in this trace: the direct failures were read/handshake timeouts, not replay detections.
