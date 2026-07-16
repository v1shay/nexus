# Nexus Connect migration and rollback plan

Nexus Connect is introduced in opt-in stages. No stage rewrites existing model records or requires a Studio to keep using Nexus locally.

Implementation baseline: `ac8a5c4` (`Add battery status and quick notch dismiss`). Each stage below was committed and pushed before the next stage.

## Stage 0: pre-Connect baseline

- Record the clean regression baseline.
- Preserve all current `UserDefaults` keys and the `LocalModel` Codable layout.
- Treat every existing installed model as local.

Rollback: checkout the baseline commit. No data conversion is involved.

## Stage 1: dormant foundation

- Ship protocol, security, framing, policy, and router types without starting discovery.
- Keep `ModelDownloadViewModel` constructed with its existing local managers.

Rollback: remove the new source files. Existing code and data are untouched.

Implementation: architecture review `193fa97`; secure dormant foundation `585bea2`.

## Stage 2: discovery and health

- Start read-only Tailscale peer discovery when Nexus opens.
- Do not route work until a paired host authenticates and reports healthy.
- Persist only the pinned Studio ID and user-visible connection preferences.

Rollback: disable Nexus Connect through its feature setting or return to Stage 1. Local execution is unaffected.

Implementation: `2385798`.

## Stage 3: paired Studio host

- Run the version-matched Nexus app on the Studio and select its Studio host role after one explicit setup confirmation.
- Store pairing and private key material in each machine's Keychain.
- Bind the host to the Nexus Connect port and reject non-tailnet or unauthenticated clients.

Rollback: disable Connect or quit Nexus on the Studio. Press **Unpair** to remove the role-specific Keychain pairing secret; no local model data is deleted.

Implementation: host services `19e7695`; authenticated sessions `ba3ede3`.

## Stage 4: remote placement

- Record placement separately from `LocalModel` so old decoders remain valid.
- Prefer Studio for workloads it alone can satisfy or when scoring predicts a material win.
- Keep the local executor as the retry/fallback path.

Rollback: set all placements to local or disable remote routing. Model metadata remains readable by old releases.

Implementation: `2c8188d`. Studio model IDs use the additive `nexus.connect.studio-model-ids` preference; the existing `LocalModel` Codable layout and local keys remain unchanged.

## Stage 5: transfers and expanded capabilities

- Enable resumable files, remote downloads, OCR, indexing, and explicitly authorized structured processes.
- Keep each capability independently switchable and deny-by-default.

Rollback: revoke individual capabilities without disabling inference or local Nexus.

Implementation: bounded/resumable unified API `da4418a`; single-use structured-process approval `69b0767`; route-aware transfer concurrency `d729747`; operational setup follows as the final checkpoint.

## Commit-level rollback

For inspection without changing your working branch:

```bash
git switch --detach <commit>
```

Useful checkpoints:

| Commit | State |
| --- | --- |
| `ac8a5c4` | Last pre-Connect app |
| `585bea2` | Security/protocol types only |
| `2385798` | Discovery and reconnect lifecycle |
| `19e7695` | Studio host services |
| `ba3ede3` | Authenticated multiplexed sessions/router |
| `2c8188d` | Model UI and app lifecycle integration |
| `da4418a` | Resumable transfers and unified workload API |
| `69b0767` | Single-use approval for structured remote tasks |
| `d729747` | Route-aware bulk-transfer concurrency |

Return to the current branch with `git switch main`. Do not delete `UserDefaults` or model directories to roll back; disabling Nexus Connect is sufficient.

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
