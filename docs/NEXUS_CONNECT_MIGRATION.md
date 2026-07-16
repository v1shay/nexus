# Nexus Connect v2 migration and rollback

This migration is additive. It preserves local-only Nexus, existing `LocalModel` values, notch behavior, and legacy Connect credentials while replacing the single-peer controller behind them.

## Automatic migration

On first v2 launch:

1. Existing local model records remain unchanged.
2. A legacy pinned client pairing is imported into `NexusPairedNodeStore` when its peer identity is known.
3. The old pairing account is retained until the new roster connection succeeds, keeping rollback possible.
4. Saved nodes are marked reconnecting and checked independently.
5. Existing model installations are reconciled from the local runtimes and each authenticated host inventory.
6. The old `shouldUseStudio` property remains as a source-compatibility shim; new code uses `NexusModelRoute` and `NexusDownloadTarget`.

No migration deletes models or pairing material automatically.

## Rolling upgrades

Upgrade hosts and the MacBook in any order. Version and feature negotiation allows protocol overlap instead of comparing Git commits.

- An older compatible host can continue inference and existing pulls.
- The UI disables remote runtime provisioning/deletion when the host did not negotiate those capabilities.
- A new host accepts early-v2 clients that lack the signed pairing selector by safely matching their HMAC against active per-client secrets.
- An incompatible host remains saved and is shown incompatible until upgraded.

The background helper is intentionally not killed merely because the UI was rebuilt: it may own a multi-hour download. A normal host restart launches the updated executable through launchd and saved clients reconnect without pairing again.

## Checkpoints

| Commit | State |
| --- | --- |
| `ac8a5c4` | Last pre-Connect app |
| `585bea2` | Original secure protocol foundation |
| `2385798` | Discovery and reconnect lifecycle |
| `05d0ed2` | Persistent LaunchAgent host and host-owned downloads |
| `3fda246` | Durable paired-node roster and protocol negotiation |
| `17448b3` | Concurrent multi-node routing |
| `984e2b8` | Per-node runtime management and multi-target model placement |
| `79dc9fa` | Per-client host trust and revocation |

## Rollback

To inspect a checkpoint without changing the main branch:

```bash
git switch --detach <commit>
```

Return with:

```bash
git switch main
```

Disabling Nexus Connect is sufficient to retain local-only behavior. Do not delete `UserDefaults`, Keychain items, or model directories as part of rollback.

If deliberately returning to an old single-peer build, it can use its legacy Keychain pairing but cannot display or route the additional v2 nodes. Returning to the current build restores the durable roster.

## Validation gates

Every v2 checkpoint must pass:

1. `git diff --check`.
2. App target build for macOS 14.2.
3. Complete `nexusTests` regression suite.
4. Pairing persistence and selective-revocation tests.
5. Studio+iMac concurrent reconnect and exact endpoint matching tests.
6. Compatible/incompatible protocol-negotiation tests.
7. Persistent-host and host-owned remote-download tests.
8. Per-node inventory, routing, runtime-confirmation, and deletion tests.
