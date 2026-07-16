# Nexus Connect migration and rollback plan

Nexus Connect is introduced in opt-in stages. No stage rewrites existing model records or requires a Studio to keep using Nexus locally.

## Stage 0: current release

- Record the clean regression baseline.
- Preserve all current `UserDefaults` keys and the `LocalModel` Codable layout.
- Treat every existing installed model as local.

Rollback: checkout the baseline commit. No data conversion is involved.

## Stage 1: dormant foundation

- Ship protocol, security, framing, policy, and router types without starting discovery.
- Keep `ModelDownloadViewModel` constructed with its existing local managers.

Rollback: remove the new source files. Existing code and data are untouched.

## Stage 2: discovery and health

- Start read-only Tailscale peer discovery when Nexus opens.
- Do not route work until a paired host authenticates and reports healthy.
- Persist only the pinned Studio ID and user-visible connection preferences.

Rollback: disable Nexus Connect through its feature setting or return to Stage 1. Local execution is unaffected.

## Stage 3: paired Studio host

- Install the version-matched host and launch agent on the Studio after one explicit setup confirmation.
- Store pairing and private key material in each machine's Keychain.
- Bind the host to the Nexus Connect port and reject non-tailnet or unauthenticated clients.

Rollback: unload the Studio launch agent and remove its executable. Retain or delete the Keychain pairing item independently.

## Stage 4: remote placement

- Record placement separately from `LocalModel` so old decoders remain valid.
- Prefer Studio for workloads it alone can satisfy or when scoring predicts a material win.
- Keep the local executor as the retry/fallback path.

Rollback: set all placements to local or disable remote routing. Model metadata remains readable by old releases.

## Stage 5: transfers and expanded capabilities

- Enable resumable files, remote downloads, OCR, indexing, and explicitly authorized structured processes.
- Keep each capability independently switchable and deny-by-default.

Rollback: revoke individual capabilities without disabling inference or local Nexus.

## Versioning rules

- The client and host advertise a supported protocol range.
- Additive fields use Codable defaults and are ignored by older compatible peers.
- Breaking wire changes require a new protocol major version and a side-by-side migration period.
- The app never silently downgrades cryptography, pairing requirements, path restrictions, or process policy.

## Validation gates for every stage

1. `git diff --check` passes.
2. New deterministic unit tests pass.
3. The complete existing `nexusTests` suite passes.
4. The app target builds for macOS 14.2 with code signing disabled.
5. Security-negative tests cover malformed frames, authentication failure, replay, path escape, policy denial, and oversized input as applicable.
6. The stage is committed and pushed before the next stage begins.

