# Memory tool contracts

All tools register through `NexToolRegistry`. Schemas reject unknown keys, wrong types, invalid enums, and out-of-range values before execution. Results are JSON-compatible `NexJSONValue` objects; errors have stable codes. Models never receive SQL or filesystem paths.

## Lifecycle

Every successful validation emits one execution ID with:

```text
started → progress* → completed
                    ↘ failed
```

The notch consumes these generic events. Future tools can provide their own status label and icon without changing memory or conversation code.

## `memory_search`

Permission: `read_memory`

```json
{
  "query": "Have I used OCR in Project Atlas?",
  "limit": 6,
  "document_types": ["memory", "chat"],
  "include_transcript_excerpts": true
}
```

Returns concise ranked items with `source_id`, `chunk_id`, optional `message_id`, type/kind, title, excerpt, score, and `stored_evidence: true`.

## `memory_get`

Permission: `read_memory`

```json
{ "source_id": "stable-uuid" }
```

Returns one canonical item. Arbitrary filenames are not accepted.

## `memory_propose`

Permission: `write_memory`. A model invocation is rejected unless the user authorized a durable write.

Required fields are `idempotency_key`, `kind`, `title`, `statement`, and `evidence_message_ids`. Optional typed metadata includes summary, topics, projects, entities, importance, and confidence. Evidence IDs must refer to finalized messages in the active conversation. The service normalizes content identity, prevents exact duplicate facts, chooses the folder/filename, writes YAML, and updates the index.

Supported kinds are:

```text
preference, personal_context, project, goal, person,
organization, decision, knowledge
```

Saying “remember that …” is treated as an explicit authorized proposal and runs asynchronously so it cannot delay response streaming.

## `memory_forget`

Permission: `forget_memory`. A user-authorized model call must provide an existing stable `source_id`. The service removes the note, writes a portable tombstone, and excludes it from retrieval. Vague deletion by generated text or guessed path is not permitted.

## `conversation_recall`

Permission: `read_memory`

```json
{
  "scope": "current",
  "query": "launch decision",
  "limit": 6
}
```

Scope is `current`, `saved`, or `all`. Current recall returns live summary/task/open threads/recent turns without vector retrieval. Saved recall searches only explicitly saved chat documents.

## Adding a Versatility tool

Register another `NexRegisteredTool` with a name, description, status/spoken label, icon, permission, strict schema, and async handler. Use `NexToolExecutionContext.reportProgress` for progress. No notch, voice, model-provider, or memory-storage changes are required.
