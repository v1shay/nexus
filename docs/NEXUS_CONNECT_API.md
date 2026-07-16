# Nexus Connect unified API

`NexusUnifiedWorkloadAPI` is the application-facing boundary. Feature code submits typed work and never selects a machine. `NexusWorkloadRouter` chooses the local executor or the authenticated Studio session according to the current mode and retry safety.

The live instance is available from `NexusConnectController.workloads`. Nexus Connect starts in `localOnly`, changes to automatic routing only for a paired Air, and returns to local-only routing when disabled or when this app is the Studio host.

## Stream any typed workload

```swift
let request = try NexusWorkloadRequest(
    kind: .agent,
    priority: .interactive,
    retrySafety: .idempotent,
    payload: NexusAgentPayload(
        runtime: .ollama,
        model: "qwen3:30b",
        instructions: "Review this change",
        context: [.init(role: "user", content: patch)],
        maximumSteps: 8
    )
)

let stream = try await connect.workloads.events(for: request)
for try await event in stream {
    // token, progress, stdout/stderr, result, and terminal events
}
```

Every request has a UUID, priority, retry classification, and typed Codable payload. Concurrent request events may interleave on one encrypted connection, while events within a request remain sequenced.

## High-level operations

The actor provides direct methods for:

- `recognizeText(imageData:languages:)`
- `index(rootID:relativePaths:replaceExisting:)`
- `searchIndex(query:limit:)`
- `listFiles(in:recursive:maximumEntries:)`
- `uploadFile(from:to:transferID:onProgress:)`
- `downloadFile(from:to:transferID:onProgress:)`
- `downloadOnStudio(sourceURL:destination:expectedSHA256:transferID:onProgress:)`
- `requestProcessApproval(executableID:validFor:)`
- `runApprovedProcess(_:)`

Reuse a transfer UUID after a reconnect to resume safely:

```swift
let transferID = persistedTransferID
try await connect.workloads.uploadFile(
    from: localURL,
    to: .init(rootID: "nexus", relativePath: "workspace/archive.bin"),
    transferID: transferID
) { progress in
    await updateProgress(progress.fraction)
}
```

`NexusConnectController.runApprovedProcess(...)` is the preferred UI entry point for command work because it presents the intentional **Run Once** confirmation before obtaining the Studio token.

## Routing and replay rules

- Safe idempotent operations can fall back only before any substantive remote event is delivered.
- Resumable operations retain their partial state and transfer ID; they are not redirected to the wrong machine.
- `neverReplay` process work is never silently retried after an uncertain remote result.
- Remote model pulls bypass local fallback so a very large model cannot accidentally fill the Air.
- Terminal remote failures surface as typed errors; cancellation sends an explicit request cancel frame.

## Adding a workload

1. Add a capability and workload kind in `NexusConnectModels.swift`.
2. Define a bounded Codable request/result payload with no arbitrary command or absolute-path fields.
3. Add a policy-checked host handler in `NexusConnectHostServices.swift`.
4. Decide its retry classification and fallback eligibility in `NexusWorkloadRouter.swift`.
5. Add deterministic success, cancellation, malformed-input, authentication, and policy-negative tests.
6. Preserve unknown-field tolerance for additive protocol changes; bump the protocol major version for breaking changes.
