# Nexus Connect unified API

`NexusConnectController.workloads` is the application-facing typed API. `NexusMultiNodeWorkloadRouter` owns placement, so callers do not manage sockets or remote clients.

## Model routing

Set the persistent route once:

```swift
connect.setModelRoute(.automatic)
connect.setModelRoute(.thisMac)
connect.setModelRoute(.pairedNode(imacNodeID))
```

Inference streams through the route:

```swift
let answer = try await connect.response(model: model, prompt: prompt) { delta, accumulated in
    await render(delta: delta, accumulated: accumulated)
}
```

An explicit node route requires that exact node to be online. Automatic chooses an online owner of the requested model and retains safe pre-output local fallback.

## Multi-target model placement

The UI persists `NexusDownloadTarget.automatic` or a set of concrete targets. Automatic resolves to one concrete healthy destination before work starts; persisted placement is never vague. Remote pulls address a concrete node and never fall back:

```swift
try await connect.pullModel(model, on: studioNodeID) { progress in
    await updateStudio(progress)
}
```

`ModelDownloadViewModel` runs independent pulls concurrently when multiple targets are checked. Each host downloads directly to its own disk. Placement records and the node inventory stay separate, so a model installed on Studio is not falsely marked local or present on iMac.

Host runtime operations are also node-specific:

```swift
let inventory = try await connect.runtimeInventory(on: imacNodeID)

let provisioned = try await connect.provisionDefaultRuntime(
    on: imacNodeID,
    preferred: .ollama,
    userConfirmed: true
)

try await connect.deleteModel(model, on: imacNodeID)
```

Only call provisioning after a visible user confirmation. Unsupported runtime-management features produce a version-specific message while other negotiated features remain usable.

## Generic typed work

```swift
let request = try NexusWorkloadRequest(
    kind: .inference,
    priority: .interactive,
    retrySafety: .idempotent,
    payload: NexusInferencePayload(
        runtime: .ollama,
        model: "qwen3:30b",
        messages: [.init(role: "user", content: "Explain this patch")],
        temperature: nil,
        maximumTokens: nil
    )
)

let stream = try await connect.workloads.events(for: request)
for try await event in stream {
    // accepted, token, progress, result, completed, or a typed failure
}
```

Requests have stable UUIDs, priorities, retry classifications, and bounded Codable payloads. Events for concurrent requests may interleave; each request's event sequence remains ordered.

## Routing and replay rules

- Explicit node routes are never silently replaced with a different node.
- Automatic safe idempotent work can fall back only before substantive remote output.
- Resumable operations retain their request/transfer identity and are not redirected.
- `neverReplay` operations are never repeated after an uncertain result.
- Remote model pulls and runtime provisioning do not fall back to This Mac.
- Cancellation sends an explicit request-cancel frame.

## Existing high-level operations

The existing unified actor also exposes OCR, index/search, named-root files, resumable transfers, host-side HTTPS downloads, and intentionally approved structured processes. These are existing capabilities, not an agent harness or workflow engine. Their security contract remains: typed payloads, canonical named roots, bounded I/O, allowlisted executables, argument arrays, and no shell interpreter.
