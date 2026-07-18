# FunctionGemma intent router

Nex runs `functiongemma:latest` as a small intent sidecar. It does not write the answer. The primary model still receives the original request and the complete active conversation, then streams the final response.

## Runtime flow

1. A finalized voice or text request starts primary generation and FunctionGemma concurrently.
2. FunctionGemma runs on a dedicated local Ollama endpoint (`127.0.0.1:11435`) so a large primary model cannot queue ahead of the status/router request.
3. FunctionGemma emits native function calls. Nexus validates them semantically, converts them to the minimal `FunctionGemmaOutput`, and immediately displays its contextual status.
4. No-tool requests activate the already-running primary stream. Tool requests discard the private speculative stream, execute independent registry tools concurrently, and restart primary generation with normalized evidence and failures.
5. The fallback order is dedicated local FunctionGemma, compatible online Mac Studio FunctionGemma, deterministic semantic routing, then the existing primary response path. Failure never prevents an answer.

The app-managed output schema is intentionally limited to:

```json
{
  "status": "Checking your project…",
  "actions": [
    { "tool": "memory_search", "query": "saved robotics project capabilities and awards" }
  ],
  "memory_write": null
}
```

The old randomized acknowledgement pool no longer exists. `Looking into it…` is the only neutral failure status.

## Tools and memory

FunctionGemma receives compact descriptions of compatible tools from `NexToolRegistry`. It never receives raw SQL or filesystem paths. Memory and web lookups use the existing registry lifecycle, permission checks, status SVGs, and structured errors. Independent actions execute concurrently.

Active-chat references stay on the primary conversation path. Saved-memory retrieval is reserved for information outside visible conversation context. Memory append/update proposals remain advisory and pass through the existing finalized-evidence classifier and policy validator. Forget proposals are resolved to a stable canonical source ID by the app and are rejected when the match is weak or ambiguous.

## Installation and lifecycle

No manual router setup is required. At app launch Nexus verifies `functiongemma:latest`, downloads it through Ollama when absent, warms it, and keeps it loaded for 30 minutes between requests. Nexus stops only the dedicated server process it started during clean shutdown.

## Validation commands

Run the complete suite:

```bash
xcodebuild -project nexus/nexus.xcodeproj -scheme nexus -destination platform=macOS test
```

Run the focused deterministic router suite:

```bash
xcodebuild -project nexus/nexus.xcodeproj -scheme nexus -destination platform=macOS test -only-testing:nexusTests/NexFunctionGemmaTests
```

Run real local FunctionGemma routing and latency diagnostics:

```bash
xcodebuild -project nexus/nexus.xcodeproj -scheme nexus -destination platform=macOS SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) NEXUS_LIVE_ROUTER_TESTS' test -only-testing:nexusTests/NexFunctionGemmaTests
```

Mac Studio latency is reported only when Tailscale and a compatible paired Studio host are genuinely online; it is never fabricated from a local measurement.
