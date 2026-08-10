# Nexus repeatable-launch reliability framework

Status: audit and implementation plan
Audit date: 2026-07-29
Repository baseline: `f655e39b4aab4bb063ad89824520426bf3c83b86`

## One-time local prerequisites

Install the exact Piper runtime once on each development Mac:

```sh
./scripts/install-piper-runtime.sh
```

No local signing certificate or Keychain trust operation is required. The
project embeds the explicit development requirement `identifier "na.nexus"`
in every macOS build. The Piper script installs an exact official version from
its binary Python distribution under
`~/Library/Application Support/Nexus/Voice`; voice models remain wherever the
user selected them.

## Implemented verification snapshot

The 2026-07-29 implementation was verified on the M1 Ultra with:

- an unsigned Debug compile and test build succeeding;
- 293 hosted unit tests executed, with 9 intentional live-test skips and 8
  pre-existing resource lookups failing only when `xctest` is invoked manually
  outside Xcode's resource-host environment;
- the focused permission, tool-search, planner, runtime, voice-state, and
  transport-firewall tests passing;
- a live `gpt-oss:latest` two-capability route selecting both saved memory and
  current web research in 1.998 seconds;
- a real frontmost-window JPEG capture of 177,547 bytes;
- the selected `jarvis-medium.onnx` producing 61,952 bytes of Piper PCM; and
- two materially different Xcode 27 Beta builds whose CDHashes changed while
  their designated requirement and permission identity fingerprints remained
  identical.

GPT-OSS requires Ollama's string reasoning levels rather than a Boolean
`think: false`. Nexus now maps its thinking-off state to `low`, raises the
status-line completion budget from 24 to 96 tokens, keeps the model resident,
and uses a compact native routing prompt. This reduced the live multi-tool
case from a failing 14.5-second loop to a passing 2.0-second route. Xcode 27
Beta builds no longer depend on Keychain certificate trust and validate the
explicit requirement after every scripted build.

## Objective

Every supported Mac must treat every approved Nexus development rebuild as the
same application identity, while keeping each physical Mac's data and TCC
grants device-local. Repeated Xcode Run/Stop, normal quit/relaunch, crashes,
reboots, and helper upgrades must produce:

- one visible Nexus UI process;
- one compatible instance of each background service;
- stable macOS and Keychain authorization after the one-time onboarding on
  each Mac;
- deterministic voice-session state with no stale transcript reuse;
- bounded, observable model planning and tool execution;
- semantic capability discovery before refusal;
- no raw tool-call transport in a user-visible answer; and
- measurable cold and warm latency budgets.

This is a reliability contract, not a promise that macOS permissions sync
between Macs. TCC grants are local security decisions. Each Mac must complete
onboarding once for the stable Nexus signing identity used on that Mac.

## Executive findings

### P0: the current Xcode app is not a stable identity

The project declares the bundle identifier `na.nexus`. The original audited
configuration named a missing `system local code signing` certificate:

- `security find-identity -v -p codesigning` reports zero valid identities.
- The existing Xcode product is ad-hoc signed.
- Its designated requirement is a `cdhash`, so the requirement changes when
  the executable changes.
- The current product happens to pass Input Monitoring, Accessibility, and
  Screen Recording preflight. Those grants apply to that exact old ad-hoc
  build, not to future rebuilds.

That certificate setup was removed after macOS 27 Beta's trust service hung
indefinitely. The corrected project uses an explicit designated requirement,
and the shell build verifies both the signature and the requirement.

Apple's code-signing model expects an app's designated requirement to be
satisfied by future versions of the same app. An ad-hoc requirement tied to a
content hash cannot satisfy that invariant.

### P0: the live tool path bypasses the protected runtime

`NexComputerRuntime` implements manifest timeouts, retry policy, cancellation,
output-schema validation, structured envelopes, and execution logging.
`NexComputerCLI` uses it. The live model path does not.

Computer actions are registered in `NexComputerRegistry` with handlers that
call `registry.invoke(...)` directly. `NexToolOrchestrator` then executes those
handlers through `NexToolRegistry`. Consequently, the live app bypasses the
runtime behavior exercised by the timeout and validation tests.

This is a harness defect: a manifest may declare a timeout while the actual
model-invoked action is not governed by it.

### P0: always-on voice can loop on stale text and speaker echo

The audited settings have hands-free voice enabled. The live diagnostics show
this sequence:

1. a valid turn is transcribed and submitted;
2. Nexus immediately starts another Apple Speech recording while it is
   thinking or speaking;
3. the new recognition session returns `No speech detected`;
4. `finishGlobalDictation()` still proceeds to submission;
5. because an empty endpoint does not replace the UI transcript, the previous
   prompt can be submitted again; and
6. listening starts again.

The implementation also lacks an explicit echo-cancellation contract while the
microphone is active during Nexus TTS. Its own speech can satisfy the VAD gate.
An empty or echo-only recording must never create a user turn.

### P1: ordinary chat pays for planning before answering

Every normal request:

1. builds the tool registry;
2. performs semantic tool discovery;
3. runs the selected primary model for a tool-planning pass;
4. waits an intentional 280 ms;
5. only then starts the answer inference; and
6. may perform as many as three more planner passes around tools.

On the audited M1 Ultra, memory is not constrained: system memory pressure
reported 96% free and `gpt-oss:latest` was fully GPU-resident when loaded.
Measured directly through the local Ollama API:

| Measurement | Result |
| --- | ---: |
| First short request model load | 2.38 s |
| First short request total | 3.11 s |
| Second short request total | 0.87 s |
| Warm request with a roughly Nexus-sized 2,248-token system prompt | 3.68 s |
| Warm prompt evaluation | 1.89 s |
| Warm output generation | 1.48 s |
| Warm output rate | about 82 tokens/s |

The measured model is healthy. The user-visible delay is dominated by cold
loading, prompt evaluation, hidden reasoning, and duplicate planner/answer
passes. RAM capacity does not eliminate those costs.

The current settings also run `smollm2:latest` as a secondary status model
concurrently with `gpt-oss`. Ollama can keep both resident on this Mac, but the
extra request adds scheduling, prompt, and UI work. The app does not set a
longer `keep_alive` for the primary conversational model.

### P1: final-answer tool transport is not contained

Planning can parse JSON, native Ollama tool calls, and legacy
`<tool_call>...` markup. The final response stream has no equivalent transport
guard. The final model still receives extensive instructions about tool names
but receives no tool definitions in that pass.

If planning falls back, misses a capability, or reaches its 12-second
deadline, a tool-trained model may emit tool markup as ordinary content.
`receiveResponseDelta` streams that content directly to the UI and speech
pipeline. Prompt instructions alone are not a containment boundary.

### P1: semantic search exists, but its contract is incomplete

`NexToolSearchEngine` is not keyword-only. It combines weighted lexical
metadata with Apple's on-device English word embeddings. This is a useful
start, and tests cover examples such as conceptually related wording.

However:

- the embedding fallback uses the single strongest word-to-word match rather
  than sentence-level intent;
- misspellings and ASR errors are not semantically normalized;
- embeddings are recomputed through nested comparisons on each search;
- the default search omits unavailable tools, even though the model prompt
  promises it can report a missing permission or connection;
- the model may need a second planning pass just to obtain the definition of a
  tool the first shortlist missed; and
- there is no production telemetry for recall, ranking confidence, refusal
  after search, or false dispatch.

The repository's FunctionGemma document describes a dedicated router that is
not present on the current main branch. Git history shows it was replaced by
primary-model planning. Documentation must not claim a runtime that no longer
exists.

### P1: helpers are path- and generation-ambiguous

Two installed LaunchAgents currently point at different historical builds:

- ConnectHost points into Xcode DerivedData.
- NexCLIHost points into another checkout's `.build-no-sign` product.

The second referenced product is an invalid ad-hoc bundle with a different
identifier. Both LaunchAgents were found in an exited state.

ConnectHost also returns early when it sees any fresh live status record,
before comparing the desired executable path, build generation, protocol, or
designated requirement. A healthy old host can therefore survive a UI rebuild
indefinitely. Preserving a long-running job is valid; preserving an unidentified
generation is not.

### P2: panel work is amplified during transitions

Compact dictating/thinking presentation always performs synchronous frame,
layout, display, alpha, and order-front work, even when the frame is already
correct. Streaming and tool events call `resize` frequently. While an
expansion animation is in flight, repeated events still observe a changing
presentation frame and repeatedly order the panel front.

Diagnostics show bursts of identical tool-size requests and repeated compact
commits. The 30 fps orb itself is modest; synchronous window work and event
storms on the main actor are the higher-value profiling targets.

## Target architecture

### 1. Build identity contract

Define two explicit channels:

| Channel | Bundle ID | Signing policy | Data domain |
| --- | --- | --- | --- |
| Development | `na.nexus.dev` | fixed Team ID Apple Development identity, or one explicitly shared persistent development certificate | development defaults, Keychain services, Application Support |
| Release | `na.nexus` | Developer ID Application or distribution identity | release defaults, Keychain services, Application Support |

Do not change a channel's bundle ID to encode a branch, device name, checkout,
or build number. Put those values in build metadata.

For local Xcode development, the repository pins an explicit requirement to
the fixed `na.nexus` signing identifier. Distribution builds should instead
use an enrolled Apple Development or Developer ID team with a fixed App ID and
Team ID.

Add a shared Xcode scheme and build gate that fails before launch unless all of
these are true:

- the expected bundle identifier is embedded;
- `codesign --verify --deep --strict` succeeds;
- the designated requirement is not `cdhash`-only; and
- the built requirement fingerprint matches the channel's recorded expected
  fingerprint.

Run the same post-build verifier from Xcode, the shell build script, and CI.
There must be no permissive Xcode-only path.

### 2. Canonical runtime location and role identity

Xcode build products are staging artifacts. Install the verified development
app atomically to a stable path, for example:

```text
~/Applications/Nexus Dev.app
```

The Run scheme should launch and debug that verified copy. LaunchAgents must
reference a stable installed helper path, not DerivedData or a repository
checkout.

Give the UI, Connect host, and NexCLI host explicit roles. Prefer embedded,
separately identified helper executables or XPC services:

```text
na.nexus.dev
na.nexus.dev.connect-host
na.nexus.dev.nex-cli-host
```

Each role gets a per-user singleton lock and a versioned handshake. Do not use
the shared display name or bundle-ID process enumeration as the sole
coordination mechanism.

Every helper status record must contain:

- role;
- PID and parent/launchd identity;
- executable canonical path;
- app build ID and Git commit;
- designated-requirement fingerprint;
- protocol range;
- boot-session identifier;
- monotonic lease timestamp; and
- active-job state.

On launch, compare desired and running generations. Reuse only a compatible
generation. If an old helper owns a long job, mark it draining, finish or
checkpoint the job, then replace it. A stale status file is never authority.

### 3. Deterministic boot state machine

Replace incidental startup tasks with an observable, idempotent state machine:

```text
created
  -> identityVerified
  -> singletonAcquired
  -> helpersReconciled
  -> permissionsObserved
  -> UIInstalled
  -> toolCatalogReady
  -> audioReady
  -> modelWarm
  -> ready
```

Each stage records start time, end time, outcome, and build/role identifiers.
Stages may retry safely, but may not create duplicate monitors, audio taps,
tool registrations, panels, or LaunchAgents.

The UI may appear before all optional stages finish, but capabilities must
advertise `starting`, `ready`, or a structured unavailable reason. A user
request must await the specific required readiness barrier, not rerun the
entire registration sequence.

### 4. Permission coordinator

Create one main-app permission coordinator with a declared ownership table:

| Permission | Owning role | Runtime check |
| --- | --- | --- |
| Microphone | UI/audio role | `AVCaptureDevice.authorizationStatus` plus real engine start |
| Speech Recognition | UI/audio role | `SFSpeechRecognizer.authorizationStatus` plus a recognition smoke |
| Input Monitoring | UI role | `CGPreflightListenEventAccess` plus event-tap creation |
| Accessibility | UI role | `AXIsProcessTrusted` plus focused-element smoke |
| Screen Recording | UI role | preflight plus real bounded capture |
| Automation | executing role | `AEDeterminePermissionToAutomateTarget` for the exact target |
| Contacts/Calendar/Photos | executing role | framework authorization plus harmless read |
| Full Disk Access | executing role | exact protected-resource read; never a global guessed status |

Rules:

- Never mutate TCC during launch.
- Remove `tccutil reset` from normal in-app recovery. Keep an explicitly
  confirmed developer repair command for one exact bundle ID and service.
- Observe authorization again when the app becomes active and while the
  permission settings page is open.
- Reconcile dependent resources after a grant. For Input Monitoring, create
  the event tap after authorization instead of requiring a quit.
- If macOS genuinely requires relaunch for a capability, relaunch the same
  canonical app and verify the designated requirement before exit.
- Store onboarding history only as explanation. Live APIs and functional
  probes remain authoritative.
- Display code identity, executable path, and live capability state in a
  diagnostics page so same-name/different-identity cases are visible.

After the signing identity is stabilized, each Mac may require one deliberate
cleanup of stale ad-hoc TCC rows followed by one-time grants. Do not perform
that cleanup before the final identity is verified.

### 5. Voice session state machine

Represent every microphone turn with a unique session object:

```text
idle
  -> preparing(sessionID)
  -> recording(sessionID, newTranscript)
  -> finalizing(sessionID)
  -> submitted(turnID)
  -> speaking(turnID)
  -> idle
```

Required invariants:

- A new session starts with an empty session-scoped transcript.
- UI text from an earlier turn is never the source of a new model request.
- An empty final transcript returns to idle/listening and cannot submit.
- Every callback validates its session ID.
- `stop`, finalization, and continuation completion are exactly-once.
- An audio-engine start error is visible and retried with bounded backoff.
- Audio-device and sample-rate changes rebuild the engine safely.

Ship reliable half-duplex hands-free mode first: stop listening while Nexus is
speaking, and let an explicit Command hold interrupt speech and open a new
recording. Enable full duplex only after macOS voice-processing/AEC is active
and tests prove Nexus TTS cannot trigger its own VAD.

The hotkey monitor must select one authoritative source:

1. passive CGEvent tap when authorized;
2. HID fallback only when the event tap is unavailable; and
3. session-state polling only as the final fallback.

Do not let AppKit, CGEvent, HID, and polling overwrite one shared flag state.
Add edge coalescing/debounce and assert one callback per physical gesture.

### 6. Low-latency model pipeline

Separate direct response, planning, and status concerns:

```text
request
  -> local semantic capability gate
      -> direct-answer stream
      -> compact native tool plan -> execute -> answer from evidence
```

For a high-confidence no-tool request, skip model planning and start the answer
stream immediately. For an external action or uncertain capability, run a
compact planner with only the discovered tool definitions.

Performance changes:

- Remove tool-routing instructions from the final answer system prompt.
- Use the model's low reasoning effort for routing and simple answers where
  supported.
- Set explicit context budgets rather than loading the model's full 131k
  context for short voice turns.
- Preload the selected primary model after boot or selection and send
  `keep_alive` (for example 30 minutes) on chat requests.
- Keep deterministic status as the default. If a secondary status model is
  enabled, place it on an independent scheduler/server or suppress it while
  primary TTFT is pending.
- Remove the unconditional 280 ms delay.
- Cache the immutable tool catalog and precomputed search vectors.
- Compact or summarize old conversation before it inflates every planner and
  answer prompt.

Instrument Ollama's returned `load_duration`, `prompt_eval_duration`,
`eval_duration`, prompt token count, output token count, and done reason.

Initial budgets on the audited M1 Ultra:

| Metric | Warm target | Cold target |
| --- | ---: | ---: |
| Gesture to visible listening UI | p95 under 100 ms | p95 under 150 ms |
| Final transcript to direct-answer first token | p95 under 1.5 s | p95 under 4 s |
| Semantic search | p95 under 50 ms | p95 under 100 ms |
| Tool-plan decision after search | p95 under 1.5 s | p95 under 4 s |
| Main-thread frame work | p95 under 8 ms | p99 under 16 ms |

Tune targets from recorded distributions, not anecdotal averages.

### 7. Semantic capability discovery

Keep lexical retrieval for exactness, then add:

- normalized edit-distance and ASR-confusion matching;
- sentence-level embeddings over action purpose, examples, workflows, app,
  provider, and schema descriptions;
- precomputed manifest vectors;
- clause-aware retrieval for compound requests;
- availability as a ranking feature rather than an early destructive filter;
  and
- calibrated confidence with a required `search_tools` fallback below the
  direct-dispatch threshold.

Return two lists:

```text
available candidates: definitions the planner may invoke
blocked candidates: capability plus exact permission/installation/connection recovery
```

The planner may execute only available candidates. It may explain a missing
permission from a blocked candidate. It may claim Nexus lacks a capability
only after both lists are empty for a sufficiently broad semantic query.

Build an evaluation corpus containing:

- exact tool names;
- paraphrases and synonyms;
- realistic dictation errors and misspellings;
- pronouns resolved from active conversation;
- compound multi-tool requests;
- installed-but-unapproved actions;
- disconnected connectors;
- adversarial unrelated requests; and
- requests that should use no tool.

Track Recall@5, MRR, blocked-capability recall, no-tool precision, false
dispatch rate, and refusal-without-search rate.

### 8. One execution gateway

All UI, voice, CLI, connector, and model actions must pass through the same
execution gateway. The gateway owns:

- schema validation;
- availability and permission checks;
- confirmation policy;
- idempotency key;
- timeout;
- cancellation;
- retry policy;
- structured progress;
- output validation;
- redacted logging; and
- a final result envelope.

Refactor the runtime so it executes the stored low-level action handler
directly after policy checks. Registered model-tool handlers should call that
runtime rather than recursively entering `NexToolRegistry`.

`NexToolOrchestrator` should receive only structured envelopes. A timed-out or
permission-blocked action must become evidence for the final answer, not an
unbounded task or a generic failure string.

### 9. Tool-transport containment

Native function calls and structured output are the only accepted planning
transports. Legacy XML may remain as a bounded compatibility parser in the
planning pass, but it is never displayable content.

Add a streaming transport firewall:

- hold a small prefix buffer before displaying or speaking;
- detect Harmony channel headers, native-call serialization, XML tool tags,
  JSON action envelopes, and known function-call wrappers;
- cancel the final stream if transport is detected;
- validate the call against the current allowlist;
- execute it through the gateway and regenerate once from evidence; and
- fail closed with a concise user-visible error after the one bounded retry.

Do not rely on “never emit tool markup” in the prompt. Add tests that split
every marker across arbitrary streaming chunk boundaries.

### 10. Main-thread and panel discipline

- Commit atomic compact geometry only on a real presentation transition or
  frame change.
- Do not call `orderFrontRegardless`, `displayIfNeeded`, or synchronous layout
  for identical state.
- Coalesce token, tool-progress, audio-meter, and pointer updates to a display
  cadence.
- Keep model parsing, semantic scoring, JSON encoding, file indexing, and tool
  availability probes off the main actor.
- Replace repeated tool-registration work per request with one readiness
  snapshot.
- Signpost panel transition, layout, Canvas render, model callbacks, and tool
  event handling; profile with Instruments Animation Hitches and Time
  Profiler.

## Verification matrix

### Signed identity and permissions

Run on every supported Mac and OS lane:

1. Build A, record bundle ID, designated requirement,
   requirement fingerprint, CDHash, and canonical path.
2. Grant each required permission once.
3. Quit and relaunch 20 times.
4. Make a source edit, build B, and repeat.
5. Clean DerivedData, build C, and repeat.
6. Stop from Xcode, crash, reboot, and log out/in.
7. Move or freshly clone the source repository and build D.

Acceptance:

- the designated-requirement fingerprint is identical for A through D;
- CDHashes may change;
- every live permission probe remains authorized;
- no new System Settings row is needed after A;
- Keychain reads do not prompt again after initial approval;
- one UI and one compatible helper per role are running; and
- every LaunchAgent references the canonical verified path.

### Voice

Automate at least 100 cycles for:

- hold-to-talk with speech;
- hold-to-talk with silence;
- rapid cancel/restart;
- always-on silence;
- Nexus TTS playing;
- external speaker audio;
- microphone and output-device changes;
- sleep/wake;
- Bluetooth reconnect; and
- permission revoke/regrant while running.

Acceptance:

- zero old-transcript resubmissions;
- zero self-triggered TTS turns;
- zero duplicate physical-gesture callbacks;
- exactly one active input tap;
- no continuation double-resume; and
- successful recovery without an identity-changing rebuild.

### Models and tools

Test cold and warm primary models with deterministic and secondary status
modes. Exercise direct questions, exact actions, semantic paraphrases,
misspellings, compound requests, unavailable actions, permissions, timeouts,
cancellation, malformed outputs, and tool markup split across stream chunks.

Acceptance:

- direct no-tool requests do not pay for a planning inference;
- every live computer action is visible in the execution gateway log;
- manifest timeouts govern UI-triggered actions;
- blocked capabilities return exact recovery;
- no raw tool transport reaches UI, TTS, chat storage, or memory;
- a tool is never reported complete without a successful result envelope; and
- latency distributions satisfy the recorded budgets.

### OS coverage

Keep separate lanes for the current stable macOS release and any developer
beta. The audited Mac reports macOS 27.0 build `26A5368g`, so beta-only TCC or
window-server behavior must not be generalized to stable machines without a
comparison run.

## Implementation sequence

### Milestone 0: stop identity churn

1. Choose and provision the development signing policy on every Mac.
2. Add the shared Xcode signing verifier and fail all ad-hoc launches.
3. Introduce the development bundle ID/data domain if it is not already in
   use.
4. Install and launch from the canonical development path.
5. Reconcile stale LaunchAgents only after the canonical product verifies.
6. Perform the one-time per-Mac stale-TCC cleanup and onboarding.

Exit criterion: two changed rebuilds have the same requirement fingerprint and
retain all live grants.

### Milestone 1: make boot and voice deterministic

1. Add role-aware singletons and helper generation handshakes.
2. Add the boot state machine and diagnostics page.
3. Add permission activation/reconciliation.
4. Replace shared UI transcript submission with session-owned voice text.
5. Ship half-duplex always-on behavior and authoritative hotkey-source
   selection.

Exit criterion: the relaunch and 100-cycle voice matrices pass on two Macs.

### Milestone 2: unify execution and contain tool transport

1. Route every computer action through `NexComputerRuntime`.
2. Return structured envelopes to the orchestrator.
3. Add the final-stream transport firewall.
4. Add end-to-end timeout, cancellation, unavailable, and leakage tests.

Exit criterion: no live action bypasses the gateway and the leakage corpus has
zero user-visible escapes.

### Milestone 3: reduce response latency

1. Add direct-answer bypass.
2. Compact the final prompt and planner prompt.
3. Add primary prewarm/keep-alive and explicit context budgets.
4. Default status to deterministic and isolate optional status inference.
5. Remove redundant panel commits and profile the main thread.

Exit criterion: warm and cold latency budgets pass under the configured model
matrix.

### Milestone 4: harden semantic discovery

1. Precompute hybrid lexical, fuzzy, and sentence embeddings.
2. Include blocked candidates with recovery.
3. Add confidence calibration and evaluation telemetry.
4. Remove or rewrite stale FunctionGemma documentation.

Exit criterion: the semantic evaluation corpus meets agreed recall and false
dispatch thresholds.

## Immediate safe operating guidance

For repeatable local development:

- do not reset TCC repeatedly across ad-hoc builds;
- keep the bundle ID and `NexusDevelopment.requirements` unchanged;
- use the project settings or guarded build script rather than overriding
  `OTHER_CODE_SIGN_FLAGS`;
- set Status to Instant to avoid the secondary `smollm2` request;
- disable hands-free voice and use hold-to-talk to avoid the stale/echo loop;
  and
- verify the executable path and signature before granting a permission.

These are temporary safeguards, not substitutes for the architecture above.

## Required observability payload

One redacted launch/request trace should correlate:

```text
launchID, requestID, role, PID, canonicalPath
bundleID, buildID, commit, requirementFingerprint
permission snapshots and functional probes
boot-stage durations
voice session IDs and state transitions
hotkey source and edge count
model ID, context budget, reasoning effort
load/prompt/eval durations and token counts
discovery candidates, scores, availability, planner decision
execution ID, timeout, retry, progress, outcome
panel transition and main-thread duration
```

Never log microphone audio, full prompts, secrets, OAuth tokens, clipboard
contents, or raw protected-file data.

## Primary references

- Apple, “macOS Code Signing In Depth”:
  <https://developer.apple.com/library/archive/technotes/tn2206/>
- Apple, “Certificates overview”:
  <https://developer.apple.com/help/account/create-certificates/certificates-overview>
- Apple, “Developer ID certificates”:
  <https://developer.apple.com/help/account/certificates/create-developer-id-certificates/>
- Ollama, “FAQ” (preload, keep-alive, concurrent model behavior):
  <https://docs.ollama.com/faq>
- Ollama, “Generate a chat message” (latency fields):
  <https://docs.ollama.com/api/chat>
- OpenAI, “gpt-oss-20b”:
  <https://developers.openai.com/api/docs/models/gpt-oss-20b>
