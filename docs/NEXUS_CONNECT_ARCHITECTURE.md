# Nexus Connect architecture

Status: implementation contract, protocol range `1...2`

Nexus Connect adds multi-Mac compute placement without changing the notch, dictation, pet, Markdown, Piper, or local-only model paths. This change does not add an agent harness, workflow engine, planner, or distributed-memory system.

## Existing-code analysis and preserved boundaries

1. `NotchController` and `NotchInteractionState` continue to own presentation and input timing. Network state does not enter that state machine.
2. `ModelDownloadViewModel` remains the notch's model/download/inference boundary. It now records model placement separately per destination.
3. `OllamaManager` and `LMStudioManager` remain the local runtime implementations and use structured APIs or `Foundation.Process`, never shell command strings.
4. `NexusUnifiedWorkloadAPI` remains the typed boundary for existing remote capabilities. Feature code does not open sockets or inspect Tailscale peers.

## Process and data shape

```text
MacBook Nexus UI
  ModelDownloadViewModel
    NexusMultiNodeWorkloadRouter
      This Mac executor
      Studio authenticated session
      iMac authenticated session

Studio / iMac
  launchd (per user)
    Nexus executable --nexus-connect-host
      NexusConnectHostListener
      NexusHostRuntimeManager
      background model/download jobs
```

The helper is deliberately narrow: it hosts Nexus Connect services and runtime operations. It is not a general autonomous-agent process. Its LaunchAgent has `RunAtLoad` and `KeepAlive`, so closing the visible app does not remove the listener.

## Durable pairing and trust

The MacBook stores a `NexusPairedNode` roster in Keychain. Every node retains:

- stable node ID and pinned Ed25519 public key;
- display name and exact Tailscale MagicDNS/FQDN endpoint;
- role, capabilities, app version, and supported protocol range;
- last successful health check and honest connection status;
- available memory/disk, installed runtimes, and model inventory.

Each node's 256-bit pairing secret is a separate non-synchronizing Keychain item. Forgetting Studio does not affect iMac.

Hosts keep a separate `NexusHostTrustStore`. Every invitation has a signed pairing selector, an independent Keychain secret, and a client identity pinned on first authenticated use. Older v2 clients without the selector are matched by their HMAC against active secrets; identity pinning still applies. Revocation deletes that invitation's secret and leaves unrelated clients authorized.

## Authentication and encrypted transport

Tailscale provides reachability and WireGuard transport encryption. Nexus adds its own security layer:

- persistent Ed25519 device identities;
- ephemeral X25519 key agreement for each session;
- HMAC-SHA256 proof of the per-device pairing secret;
- signed role, protocol range, nonce, timestamp, features, and optional pairing selector;
- HKDF-SHA256 session derivation;
- ChaCha20-Poly1305 frames with direction and sequence binding;
- replay, clock-skew, frame-size, non-tailnet-source, and identity-mismatch rejection.

No identity mismatch or incompatible protocol is silently downgraded.

## Compatibility

The handshake advertises app version, minimum/maximum protocol version, and feature set. The highest overlapping protocol is selected. Features are intersected and filtered by the protocol version that introduced them.

Protocol-v1 peers retain streaming inference and resumable pulls. Protocol-v2 adds persistent background hosts, per-node inventories, runtime provisioning, and model deletion. A peer that lacks a v2 feature remains connected for supported work; no overlap produces an explicit incompatible state while retaining pairing records.

Codable message fields are additive and optional where rolling upgrades require it. Compatibility never bypasses authentication, encryption, identity pinning, or execution policy.

## Multi-node lifecycle

`NexusPairedNodeCoordinator` creates one independent session controller per saved node. On launch it marks non-revoked nodes reconnecting, then discovers only exact saved endpoints/IDs. It does not search for arbitrary names containing “Studio.”

Each session performs an authenticated health check and reconnects with bounded exponential backoff. One offline host does not prevent another from staying online. The roster distinguishes offline, reconnecting, incompatible, revoked, and online states.

## Model routing and runtime management

Routing is explicit:

- **This Mac** uses only the local executor.
- A named paired node must be authenticated and online before inference begins.
- **Automatic** prefers an online node that already has the model, then considers reported free memory/disk for placement. Safe idempotent inference may fall back locally before remote output begins; explicit remote pulls never do.

`NexusHostRuntimeManager` provides a uniform host API for runtime inventory, model list, pull, delete, and streamed inference. It detects Ollama and LM Studio. With one client-side confirmation it can install Nexus's supported default Ollama runtime directly on the host. Pull bytes go provider-to-host, not provider-to-MacBook-to-host.

Ollama deletion uses its HTTP API. LM Studio currently exposes model discovery/download through `lms` but no documented delete command, so Nexus resolves an exact `lms ls --json` record and deletes only a verified path beneath `~/.lmstudio/models`.

## Background work and failure behavior

Host-owned model pulls, URL downloads, and runtime provisioning enter `NexusHostBackgroundJobRegistry`. A dropped client stream or closed MacBook UI does not cancel them. An explicit cancel request does.

- Powered-off/sleeping/offline host: shown offline; explicit remote work fails clearly.
- Host restarts: LaunchAgent returns, saved clients reconnect without a code.
- MacBook UI closes during a remote pull: host job continues and inventory reconciles on reconnect.
- Remote model absent: Automatic may use another online owner; an explicitly selected host reports the error.
- Local Connect disabled: existing local Ollama/LM Studio behavior remains available.

## Security scope

Existing structured process, file, OCR, indexing, and HTTPS-download capabilities remain typed and policy checked. No request accepts `zsh -c`, `sh -c`, an arbitrary command string, or model-generated shell commands. This refactor changes pairing, hosting, model runtime placement, and routing only.
