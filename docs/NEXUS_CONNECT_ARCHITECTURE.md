# Nexus Connect architecture

Status: implementation contract, protocol version `1`

Nexus Connect lets the existing Nexus app delegate expensive work to a trusted Mac Studio over Tailscale. It is an additive subsystem: the notch UI, dictation lifecycle, local Ollama and LM Studio managers, model persistence, Piper speech, and every current keyboard and hover interaction keep their existing behavior.

## Existing-code analysis

The current app has four useful boundaries that Nexus Connect must preserve:

1. `NotchController` owns the AppKit panel and the presentation state machine. Compute routing must not add network state to `NotchInteractionState` or change panel timing.
2. `ModelDownloadViewModel` is the single boundary used by the notch for model discovery, downloads, selection, and streamed inference. Remote placement belongs behind this boundary.
3. `OllamaManager` and `LMStudioManager` already use structured `Foundation.Process` calls and `URLSession` streaming. They remain the local executors and the offline fallback.
4. Tests import the app module directly and the Xcode project lists source files explicitly. New modules therefore remain small, Codable, dependency-injected, and independently testable.

Baseline on 2026-07-16: all 29 existing tests pass. The Air sees one online macOS peer named `vishays mac studio`; a Tailscale-layer probe upgraded to a direct path at roughly 11 ms.

## Compatibility contract

- Nexus Connect is disabled until a paired Studio host completes an authenticated handshake.
- Existing `UserDefaults` keys and encoded `LocalModel` values are not changed.
- A model without placement metadata is local, matching all prior releases.
- If discovery, authentication, health checks, or a remote request fail, the router selects the local executor when that executor can satisfy the request.
- A remote failure never terminates Nexus, changes notch interaction, deletes a model, or mutates a local download.
- Existing public method signatures remain available; new dependencies have defaults.
- Remote execution never uses `zsh -c`, `sh -c`, or model-generated shell text. Process requests contain an executable, argument array, working-directory token, limits, and an explicit policy decision.

## System shape

```text
Notch / Models UI
        |
ModelDownloadViewModel and future Nexus features
        |
NexusWorkloadRouter (one API, placement hidden)
   |                         |
LocalWorkloadExecutor        NexusConnectCoordinator
   |                         |
Ollama / LM Studio           Secure multiplexed connection
                             |
                       NexusConnectHost on Studio
                             |
        inference | OCR | indexing | process | files | downloads
```

The app talks only to `NexusWorkloadExecutor`. Requests declare capability, cost, retry safety, data locality, and optional placement preference. The router considers health, available RAM, queue depth, round-trip time, connection type, measured throughput, and whether required data or models already exist on each machine.

## Transport and discovery

- Tailscale provides the network path and WireGuard encryption.
- Discovery reads `tailscale status --json` through a direct `Process` invocation, tolerates unknown fields, keeps only online macOS peers, and prefers pinned Studio identity, then names containing `studio`.
- Each candidate is probed on the fixed Nexus Connect TCP port. A device is not considered a Studio until the app-level handshake succeeds and the peer advertises the host role.
- DNS names are preferred over stable Tailscale IPv4 addresses. IPv6 is retained as an alternate.
- The coordinator maintains one persistent multiplexed connection, sends health pings with jitter, and reconnects with capped exponential backoff.
- `tailscale ping` is sampled outside the request critical path to classify direct, peer-relay, or DERP connectivity. Failed classification affects scheduling, not availability.

Tailscale documents that direct connections normally give the lowest latency and highest throughput, while relays remain encrypted fallbacks. New tailnet policy should use deny-by-default Grants and expose only the Nexus Connect port between the Air and Studio.

## App-level security

Tailscale encryption is necessary but is not the only trust boundary.

### Pairing and keys

- Initial setup creates a random 256-bit pairing secret on the Air.
- Setup provisions the same secret to the Studio host once. Both copies live as non-synchronizing generic-password items in macOS Keychain, never in `UserDefaults`, logs, command arguments, or repository files.
- Each side also stores a persistent Ed25519 identity key used to pin the paired device identity.
- A new connection creates ephemeral X25519 keys. Both hello messages include device ID, role, protocol range, ephemeral public key, timestamp, random challenge, and an HMAC-SHA256 proof using the pairing secret.
- Each side verifies the pinned Ed25519 signature and the HMAC before deriving session material with X25519 plus HKDF-SHA256.

### Message protection

- Every post-handshake frame is sealed with ChaCha20-Poly1305.
- Additional authenticated data includes protocol version, session ID, direction, request ID, message kind, and monotonically increasing sequence number.
- Sequence numbers and a bounded nonce cache reject replay. Clock skew is checked only during the handshake so sleep/wake does not break an established session.
- Frames have strict maximum sizes before allocation. Large files use bounded chunks rather than oversized frames.
- Pairing mismatch, identity change, replay, malformed input, policy denial, or a non-tailnet source closes the connection without retrying credentials.

Apple documents CryptoKit support for X25519, Ed25519, HKDF, and ChaCha20-Poly1305. Keychain generic-password items provide encrypted storage for the bootstrap secret and serialized private keys.

## Protocol

The stream uses a four-byte big-endian length prefix around handshake or encrypted payload bytes. The maximum control frame is 1 MiB and the maximum data frame is 8 MiB.

After authentication, a `NexusConnectMessage` carries:

- protocol version and session ID
- request ID and per-direction sequence
- kind: request, event, response, cancel, ping, pong, or error
- capability and payload
- final-event marker

Requests are multiplexed by UUID. Events for different requests may interleave, while each request's event order remains stable. Cancellation is explicit and idempotent.

## Unified workloads

All operations use `NexusWorkloadRequest` and stream `NexusWorkloadEvent` values:

- `inference`: runtime, model, messages, generation settings; emits token deltas and usage.
- `modelList` and `modelPull`: enumerate or download Ollama/LM Studio models; emits byte progress.
- `ocr`: image bytes or a workspace file token; emits recognized text blocks.
- `index`: allowed root token, paths, and options; emits progress and index summary.
- `searchIndex`: query and limits; emits ranked matches.
- `process`: executable ID, argument array, environment allowlist, working-directory token, timeout, CPU/memory/output limits; emits stdout/stderr chunks and exit status.
- `fileStat`, `fileRead`, `fileWrite`, and `fileList`: operate only inside configured roots and use canonical path validation.
- `download`: HTTPS URL, expected digest, destination token, and range state; emits progress and final artifact metadata.

No workload accepts an arbitrary shell command string. The host maps executable IDs to absolute binaries and validates arguments against a capability policy. Agent-produced process requests require an explicit approval token issued by the Air UI.

## Files, downloads, and resumption

- File content is divided into independently authenticated chunks with transfer ID, offset, length, and SHA-256 digest.
- The receiver persists a compact transfer manifest next to a temporary file. Reconnect resumes from the first missing or invalid chunk.
- Finalization verifies size and whole-file SHA-256 before an atomic rename.
- Concurrent chunks are bounded by measured bandwidth and memory. Small control frames always have priority over bulk transfer frames.
- Remote URL downloads use HTTP range requests when the origin supports them and persist resume metadata. Nexus never claims that two internet connections are bonded; acceleration comes from using the Studio's connection, storage, and parallel range support when it is measurably advantageous.

## Health, bandwidth, and scheduling

Health reports include uptime, app/protocol version, capabilities, total/free RAM, disk availability, model inventory digest, queue depth, active jobs, thermal state, and load average.

The client maintains exponentially weighted moving averages for:

- handshake and ping round-trip time
- request time-to-first-byte
- upload/download throughput
- recent failure rate

Interactive inference and agent control traffic are latency-priority. Model downloads, indexing, and file replication are throughput-priority. Concurrency is bounded per capability so a 120B model download cannot starve token streaming or health traffic.

## Failure behavior

- Network loss: in-flight retry-safe operations resume or retry; non-idempotent execution returns an indeterminate-result error and is never silently replayed.
- Studio sleep/offline: status becomes unavailable, the local executor is selected, and background reconnect continues.
- App restart: pinned identity, placement, and transfer manifests restore; session keys never persist.
- Protocol mismatch: local mode continues and setup UI explains the required host upgrade.
- Low bandwidth or DERP: latency-sensitive work may remain remote if only the Studio can run it; bulk work pauses or lowers concurrency.
- Remote model unavailable: use the same model locally if installed, otherwise report placement clearly without changing the selected model.

## Reviewed implementation sequence

1. Shared models, framing, cryptographic handshake, Keychain storage abstraction, replay protection, policy types, and deterministic tests.
2. Tailscale discovery, peer scoring, persistent connection lifecycle, health telemetry, bandwidth estimator, reconnect state machine, and mocked transport tests.
3. Studio host listener and bounded service implementations for health, inference/model management, OCR, indexing, process execution, file access, and downloads.
4. Local and remote executors behind `NexusWorkloadRouter`; adapt `ModelDownloadViewModel` without removing its current managers or persistence.
5. Resumable transfer integration, setup/provisioning, lightweight status UI, operational docs, compatibility tests, and end-to-end Air/Studio validation.

## Plan review

The design was reviewed against the request and existing code before implementation:

- Backward compatibility: satisfied through default-local routing and unchanged persistence.
- Low latency: persistent multiplexed connection, direct-path preference, priority queues, and streamed events.
- Concurrency: actor-owned request tables and bounded per-capability limits.
- Security: tailnet restriction plus pinned identity, authenticated forward-secret handshake, AEAD frames, replay defense, Keychain storage, strict schemas, and execution policy.
- Offline behavior: local executor remains independent and available.
- Large models: placement uses Studio memory/disk telemetry and remote model inventory rather than the Air's RAM alone.
- Rollback: each numbered stage is a separate tested commit; removing Nexus Connect leaves existing local code intact.

## Primary references

- Tailscale connection types: <https://tailscale.com/docs/reference/connection-types>
- Tailscale Grants: <https://tailscale.com/docs/features/access-control/grants>
- Tailscale access control: <https://tailscale.com/docs/features/access-control>
- Apple Network framework: <https://developer.apple.com/documentation/network>
- Apple CryptoKit: <https://developer.apple.com/documentation/cryptokit>
- Apple Keychain generic passwords: <https://developer.apple.com/documentation/security/ksecclassgenericpassword>

