# Unified Memory migration and rollback

## Preserved architecture

The implementation first retained the existing boundaries: `NotchController` remains the AppKit/SwiftUI state owner, `NotchInteractionState` remains the presentation state machine, `ModelDownloadViewModel` remains the local/remote model adapter, and `ResponseSpeaker` remains the streaming Piper pipeline. Memory was added beside those parts rather than replacing them.

Existing local-only behavior requires no migration. Previous Nexus builds did not have a canonical long-term-memory store, so the first memory-enabled launch creates an empty vault and local index. It does not import or permanently save old transient prompts.

## Incremental checkpoints

| Commit | State |
| --- | --- |
| `ef7d028` | Stable pre-memory signed build |
| `dbf82e7` | Active ordered conversation continuity |
| `b24ce54` | Canonical Obsidian storage and local hybrid index |
| `2d0814c` | Tool registry, lifecycle UI, explicit save/resume, iCloud ingestion, and model context integration |

## Schema migrations

- Obsidian documents currently use `nex_schema: 1`.
- The local database currently uses SQLite `user_version = 1`.
- Newer unsupported Markdown/database schemas fail clearly instead of being rewritten.
- Changing embedding providers triggers a rebuild from the canonical Markdown.
- Generation-model changes require no memory migration.

Future schema changes must add a deterministic migration before increasing either version. Never synchronize the SQLite file.

## Rollback

Inspect a checkpoint without rewriting main:

```bash
git switch --detach <commit>
```

Return with:

```bash
git switch main
```

Rolling back does not delete the vault. Older builds simply ignore it. Returning to a memory-enabled commit reingests the Markdown. If needed, delete only the local `~/Library/Application Support/Nexus/Memory/index.sqlite*` files and restart.

## Current limitations

- The vault root follows the deterministic default-location policy; a preferences UI for choosing a different existing vault is not yet exposed.
- Conflicts are detected and shown, but there is not yet an in-app three-way conflict editor. Resolve conflicting Markdown in Obsidian, retain the stable ID, and save a new revision.
- Apple Natural Language word vectors (or the deterministic feature-hash fallback) are intentionally lightweight. The replaceable provider boundary is ready for a stronger local embedding model without changing canonical data.
- iCloud controls delivery time. Nexus can detect and ingest available changes but cannot force an offline/sleeping Mac to synchronize.
- Unsaved chats are intentionally session-only. A process crash cannot recover them by design; a normal quit warns before discarding a valuable unsaved conversation.

## Validation gates

1. `git diff --check`.
2. macOS app build with signing disabled for deterministic CI compilation.
3. Complete `nexusTests` regression target.
4. Focused save/update/resume, direct-edit/delete, tombstone, rebuild, hybrid retrieval, schema-validation, permission, lifecycle, and two-phase streaming tests.
5. Existing hotkey, overlay state, model routing, Markdown, TTS, and Nexus Connect tests.
6. Available UI launch smoke tests.
