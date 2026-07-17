# Nex Unified Memory architecture

Unified Memory is additive to the existing notch, streaming model adapters, TTS pipeline, and Nexus Connect routing. Generation still runs through `ModelDownloadViewModel`; memory is injected as ordered chat context and does not depend on the chosen Ollama/LM Studio model or execution node.

## Runtime boundaries

| Layer | Canonical lifetime | Implementation |
| --- | --- | --- |
| Active conversation | Current app session | `NexConversationSession` actor, recent verbatim turns, rolling summary, entities, current task, decisions, and open threads |
| Saved chats | Explicit **Save to Obsidian** only | Stable conversation UUID and deterministic `80 Chats/YYYY/MM/chat-<uuid>.md` file |
| Durable memory | Explicit supported memory proposals | Typed Obsidian notes in profile/project/goal/person/organization/decision/knowledge folders |
| Local retrieval index | Rebuildable per Mac | SQLite schema v1, FTS5 lexical search, replaceable local embeddings stored as chunk blobs |
| Tool execution | Process lifetime | `NexToolRegistry`, strict schemas, permission checks, structured errors, and lifecycle event bus |

The active context is never replaced by RAG. Every generation receives recent ordered turns. Long sessions additionally receive a rolling earlier-turn summary, active entities, unresolved threads, and the current task. One-word follow-ups and pronouns therefore resolve from the live conversation even when no memory search runs.

## Canonical vault

`NexObsidianVault` owns paths, filenames, YAML, message IDs, chunking, atomic writes, events, and tombstones. Models never supply a path. The generated structure is:

```text
Nex/
├── 00 Inbox/
├── 10 Profile/
├── 20 Projects/
├── 30 Goals/
├── 40 People/
├── 50 Organizations/
├── 60 Decisions/
├── 70 Knowledge/
├── 80 Chats/YYYY/MM/
├── 90 System/
└── .nex/
    ├── events/
    └── tombstones/
```

Markdown is the source of truth. `.nex` contains only portable JSON upsert/delete facts used for idempotency and conflict detection. The SQLite database lives at `~/Library/Application Support/Nexus/Memory/index.sqlite` and can be deleted and rebuilt without losing memory.

Every chat note contains schema version, stable ID, type, title, summary, timestamps, revision, status, active flag, importance/confidence, topics, projects, entities, decisions, open threads, evidence message IDs, retrieval guidance, and the transcript. Transcript messages retain stable IDs and finalized/interrupted state.

## Synchronization

The UI starts a bounded four-second vault scan. On each pass Nex:

1. Requests download of pending iCloud placeholders.
2. Parses available Markdown and tombstones.
3. Hash-compares documents against the local index.
4. Reindexes changes and removes deleted documents.
5. Rebuilds every embedding when the provider identifier changes.
6. Refreshes the saved-chat roster.
7. Reports synchronized only when no available file failed ingestion and no iCloud file is still pending.

Atomic file replacement prevents partial Markdown reads. Stable IDs make ingestion idempotent. Same-document/same-revision events with different hashes are reported as conflicts rather than silently selecting a winner.

## Retrieval

`NexMemoryIndex` combines FTS5 rank, cosine similarity, topic/project/entity relationships, recency, importance, confidence, and source priority. Durable memory ranks ahead of chat summaries, which rank ahead of small transcript excerpts. Results are thresholded, limited to two chunks per source, and always include a `source_id`; deleted and tombstoned sources are excluded.

Short follow-ups stay in active context. Prompts with personal-history signals use the real `memory_search` tool. Mixed questions such as “What is a neural network and have I used one?” stream the independent explanation first, then show **Checking memory…**, then stream the stored-history answer as a second ordered segment. Piper receives each new word once and never reads the visual paragraph separator.

## UI and voice preservation

The existing panel remains the only notch window. Tool activity reuses its state machine and panel resizing, so it cannot clone the overlay. A generic `ToolActivityIndicator` consumes registry lifecycle events and maps tool names to labels/icons. Memory uses an embedded SVG with coordinated shimmer; Reduce Motion switches to a static state. No activity appears unless a registry execution actually starts.

Saving and vault synchronization run outside the generation stream. Memory failure degrades to the existing local-only conversation path; it does not break model switching, token streaming, interruption, barge-in, Markdown rendering, or TTS.
