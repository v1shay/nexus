# Nex Computer implementation plan

Status: Phase 0 repository discovery complete on 2026-07-22. No executor or UI phase may skip the checkpoints below.

## Implemented checkpoints

- Phase 0 (`6af5442`): repository discovery, architecture map, security/permission inventory, test baseline, and rollback plan committed and pushed.
- Phase 1 (`305c70e`): centralized provider artwork resolution, exact embedded 48×48 ChatGPT PNG for GPT/OpenAI models, API-provider icon coverage, focused tests, signed build, and push completed. No Codex, NexCLI, or task-preview layout was changed.
- Phase 2: `NexComputerActionManifest`, `NexComputerRegistry`, and `NexComputerRuntime` now extend the existing `NexToolRegistry`. The implementation includes versioned strict manifests, implementation priority metadata, required permissions, risk and confirmation metadata, availability probes, bounded retry, cancellation, timeout, no-side-effect dry runs, strict output validation, structured result/error envelopes, and redacted bounded logging. Eight focused foundation tests and the signed build are green; the full unit suite has only the two documented pre-existing prompt-contract failures.
- Phase 3: the app now performs local semantic discovery before every planning pass instead of injecting the complete registry. `search_tools` is an internal action in the shared registry, indexes names, descriptions, examples, aliases, tags, app/provider metadata, field descriptions, and supported workflows, handles compound clauses, applies deterministic reranking, caps strong results, suppresses irrelevant and duplicate actions, and omits unavailable actions by default. The planner and parser share a per-request allowlist; newly discovered actions become invokable only on the following bounded pass. Twenty-six focused discovery, planner, and runtime tests are green. Codex/NexCLI presentation remains untouched.
- Phase 4: a central confirmation gateway now wraps every Nex Computer action independently of model prompting. High-risk actions always return `confirmation_required`; approvals bind the exact action, canonical arguments, provider, and risk class, expire after a bounded interval, persist atomically across restarts, and cannot replay. `confirm_action` and `cancel_action` consume opaque `actionId` values through the shared registry. The permission manager lazily checks Automation, Accessibility, Contacts, Photos, Calendar, Screen Recording, and honest Full Disk Access limitations only when an action executes. Five focused security/recovery tests and the signed build are green; Codex/NexCLI presentation remains untouched.
- Phase 5: Terminal contributes eight semantic actions through the shared registry: open/activate, open a dedicated tab, inspect the selected stable TTY, write only to an explicitly identified visible TTY, run an isolated Nexus-owned process, inspect output, answer a detected prompt, and cancel. Nexus-owned execution uses `Process` with an executable plus separate argv—never `zsh -c`—and enforces executable roots, working-directory containment, an environment allowlist, metacharacter rejection, bounded stdout/stderr buffers, prompt detection, cancellation, exit status, and streamed progress. All command execution and visible-terminal writes are confirmation-bound. Five harmless executor/security tests pass; the affected confirmation and discovery tests also passed before Xcode reproduced its documented extra-runner launch defect. The signed app build is green, and Codex/NexCLI presentation remains untouched.
- Phase 6: Finder contributes activate, search, open, reveal, create-folder, copy, move, rename, trash, and get-selection actions through the same registry. Native filesystem operations enforce canonical allowed roots, resolve symlinks, reject traversal, validate names and existing parents, cap recursive results, support filename/extension/content/date/size filters, preserve copy metadata, and require explicit `error`, `replace`, or `keep_both` collision behavior. Any mutation that may overwrite or remove data is confirmation-bound; nonempty directories are never silently replaced. Finder selection uses Apple Events lazily and revalidates every returned path. Four focused tests use temporary fixtures and a fake Trash only; all pass.
- Phase 7: Spotify contributes open, search, play, playback-control, exact-volume, and current-track actions through desktop Apple Events and the registered Spotify URL scheme. Exact Spotify URLs/URIs play and are verified against returned track metadata; pause, resume, toggle, next, previous, volume steps, and exact volume are deterministic. Name/artist searches open the precise Spotify search but explicitly return `resolution_required` because the desktop scripting dictionary cannot safely identify and play a specific search result without authenticated Web API resolution. Four protocol-backed tests prove correct routing, metadata, controls, and the no-fabricated-resolution behavior without touching real playback.
- Phase 8: Messages contributes open, contact search, history search/triage, persistent draft creation, confirmed draft sending, and conversation opening. Contacts returns stable IDs and all candidate handles so ambiguity is never silently resolved. History access opens the local Messages database read-only, binds every query parameter, returns bounded stable IDs/participants/timestamps/conversation/attachment/read-state/text metadata, and is exposed only after an exact Messages database readability check with Full Disk Access recovery guidance. Immutable drafts persist under Application Support with stable `messageDraftId` values; sending consumes only that ID through a separate high-risk confirmation. Three protocol-backed tests pass and never execute a send operation.
- Phase 9: Photos now contributes open, metadata search, result opening, export/copy, album creation, and add-to-album actions through PhotoKit. Searches support ISO-8601 date ranges, exact album identifiers or titles, media type, favorites, coordinate radius, and bounded result counts with stable Photos IDs and structured metadata. Person and semantic-text search fail explicitly because PhotoKit provides no deterministic public API; exact-asset focusing similarly opens Photos while reporting the limitation rather than coordinate-clicking. Exports preserve original resources with collision-safe names. Album changes and exports are confirmation-bound, and the focused tests use a protocol mock without touching the real Photos library.
- Phase 10: VS Code now contributes open, project/file opening, bounded workspace search, allowlisted workbench commands, last-Nexus-opened workspace state, and deterministic exact file edits. The CLI is discovered in standard Homebrew and application locations; unavailable installations remain honestly unavailable. File edits preserve the detected UTF encoding and existing newline bytes, use atomic replacement, reject ambiguous multi-match edits unless explicitly broadened, return a unified diff, and are confirmation-bound. Focused tests edit temporary fixtures only.
- Phase 11: Codex now contributes open, start, continue, status, cancel, and open-session actions through the installed `/opt/homebrew/bin/codex` CLI. Tasks run in an explicit workspace with `codex exec --json`, stream parsed JSONL progress through the existing lifecycle channel, retain stable CLI session IDs, return final text, changed files, and observed test lines, and support cancellation. Start/continue/cancel remain confirmation-bound and never bypass Codex approvals or sandboxing. The pre-existing Codex monitor and its specialized compact layout were not altered.
- Phase 12: Obsidian now contributes open, multi-filter search, exact note read/open, create, atomic update, and atomic append actions against the configured canonical Markdown vault. Paths are vault-relative, traversal and symlink escape are rejected, `.md` placement is application-managed, updates return diffs, and note opening uses Obsidian's URL scheme. Search supports title/content, folder, tags, frontmatter, dates, and bounded results. Tests use an isolated temporary vault and prove update/search/traversal behavior; no UI automation edits notes.
- Phase 13: Git and GitHub now contribute structured status/diff, branch creation/switching, commit, fast-forward pull, push, GitHub search/open, issue creation, pull-request open/create, and checks. Every process uses a fixed executable plus separate argv; no shell interpolation or token logging exists. Commit/pull/push and all remote writes are confirmation-bound, while tests operate only on a temporary local repository and never push.
- Phase 14: macOS now contributes safe System Settings deep links, validated volume read/write, structured display state, and read-only battery/network state. Volume mutation is confirmation-bound and ranges are schema-validated. Focus-mode mutation is deliberately registered as unavailable with a clear recovery path because macOS provides no stable public API; Nexus can open Focus settings but never fabricates a toggle or changes privacy/network settings.
- Phase 15: Xcode now contributes open/project/file actions through `xed`, and build/test/run/status through explicit `xcodebuild` argv. Scheme, configuration, project/workspace, and destination are validated inputs; output streams diagnostics and test lines into lifecycle progress and returns status, bounded logs, diagnostics, test summaries, and discovered artifacts. Build/test/run are confirmation-bound and never type into Xcode UI.
- Phase 16: Preview now contributes validated document open/page-hint, native image export, PDF copy, and deterministic PDF combination. PDFKit preserves supplied page order and returns page count; output collision policy is explicit and all writes are confirmation-bound. Focused tests create and combine only temporary one-page PDFs.
- Phase 17: LaunchServices now contributes dynamic installed-application listing and exact bundle-ID open/activate. The installed application audit and per-app limitations are recorded in `docs/NEX_COMPUTER_APPLICATION_SUPPORT.md`. Apps without a stable native/CLI/connector interface receive open-only support and no fabricated semantic executor.
- Phase 18: Nexus now has a managed Playwright browser task service using installed Chrome with a separate persistent profile, stable task IDs, JSONL progress, bounded DOM/form/tab/upload/download/screenshot steps, cancellation, task results, reset, and one-time safe profile import. Runtime provisioning installs pinned `playwright-core` only on first confirmed browser execution. Import requires Chrome to be closed and copies only bookmarks/history/preferences; plaintext passwords, cookies, tokens, live-profile mutation, and Keychain scraping are prohibited. Live Chrome also contributes open/list/active/activate/open-URL/close-tab actions through its scripting dictionary and stable tab IDs.
- Phase 19: The complete mandatory connector contracts are encoded for Notion, Slack, Gmail, Google Calendar, Google Contacts, GitHub, Discord official bot/app capabilities, and generic Google. A connected account supplies a capability document; only actions both available and covered by granted scopes register into the shared semantic registry. Every registered action has strict semantic fields, required scope, risk/confirmation policy, structured output, and an injected official-API executor. Unavailable capabilities retain exact missing scopes/provider limitations but are never executable. Tokens and raw provider request bodies are absent from model schemas.

## Baseline

- Repository: native macOS Swift/SwiftUI application in `nexus/nexus.xcodeproj`.
- Deployment target: macOS 14.2. The app is an `LSUIElement` menu-bar/notch application with a separate full Nexus window.
- Dependency manager: Swift Package Manager through Xcode. The current external package is FluidAudio 0.5.2.
- Build command: `./scripts/build-nexus.sh`.
- Baseline build: passed on 2026-07-22 using the persistent `system local code signing` identity.
- Unit-test command: `xcodebuild -project nexus/nexus.xcodeproj -scheme nexus -configuration Debug -destination 'platform=macOS' -derivedDataPath .build CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' CODE_SIGN_IDENTITY='system local code signing' PROVISIONING_PROFILE_SPECIFIER='' test -only-testing:nexusTests`.
- Baseline unit tests: the suite ran to completion. All tests passed except `testDefaultModelInstructionsDescribeDirectAndToolRoutedResponses` and `testSystemPromptUsesRegisteredRoutingToolNames`. Those failures predate Nex Computer and are caused by the existing uncommitted `OllamaManager.swift` prompt edit no longer matching its prompt-contract assertions. That file is user-owned and is not modified by Phase 0.
- Baseline UI test: `nexusUITests.testExample()` passed in 15.105 seconds. The combined `test` action then hung while Xcode waited for a terminated runner to report completion, so it was interrupted after 91 seconds. This is recorded as an existing Xcode harness cleanup defect, not a passing full-suite result.
- Working tree at discovery: `nexus/nexus/OllamaManager.swift` was already modified. It must not be overwritten, staged, or included in Nex Computer checkpoints unless the user explicitly asks.

## Existing architecture to preserve

### Application and UI

- `nexusApp.swift` owns application startup, the notch `NSPanel`, global interaction flow, speech/model execution, tool orchestration, and lifecycle-event presentation.
- `ContentView.swift` owns compact/expanded notch rendering, the reusable tool activity views, the current Codex/NexCLI-specific compact layouts, model handoff animation, rich response content, and controls.
- `NotchInteractionState.swift` is the presentation state machine and maps generic lifecycle events to `ToolActivity`.
- `NotchGeometry.swift` centralizes physical-notch-aware sizing.
- `ModelAggregatorView.swift` provides the full app pages for models, Connect, memory, settings, and NexCLI.
- `RichMarkdownView.swift` and bundled KaTeX assets own response rendering. They must remain independent of tool executors.

Phase 25 will consume structured runtime events here. It will keep the pet on the left and the active application icon on the right for ordinary tools. Codex and NexCLI are explicit compatibility exceptions: their established app-on-one-side/tool-on-the-other compact layouts remain unchanged. Completed actions may expand into app-specific previews and bound confirmation controls.

### Agent, models, and tool exposure

- `ModelDownloadViewModel.swift`, `OllamaManager.swift`, and `NexusAPIProvider.swift` own local, remote, and OpenAI-compatible model execution.
- `NexPrimaryToolPlanner.swift` sends the complete active conversation plus registered tool definitions to the selected primary model, validates its plan, executes independent actions concurrently, and hands normalized evidence back to the primary response.
- The current planner injects every read-capable registry definition. Phase 3 must replace this with semantic discovery while keeping the active conversation and original request unchanged.
- `NexToolSystem.swift` already supplies strict schemas, unknown-field rejection, permissions, generic lifecycle events, progress reporting, and registry execution. Nex Computer extends this abstraction instead of introducing a second public registry.
- `NexMemoryService.swift` currently registers memory and NexCLI tools. Web and YouTube tools are registered during app preparation.
- Current registered families include `memory_search`, `memory_get`, `memory_propose`, `memory_forget`, `conversation_recall`, `web_search`, `nex_cli_task`, `nex_cli_set_workspace`, `youtube_play_current`, `youtube_search`, `youtube_play`, and `youtube_fullscreen`.

### Existing executors and services

- Memory: `NexObsidianVault.swift`, `NexMemoryIndex.swift`, `NexMemoryService.swift`, and `NexMemoryController.swift`; canonical Markdown plus a rebuildable local SQLite/FTS index.
- Web: `NexWebSearch.swift`; safe URL validation, provider aggregation, extraction, ranking, caching, and lifecycle progress.
- Browser/media: `NexusAudioReactiveMusic.swift` contains Chrome/Spotify AppleScript integration and browser-tab abstractions; `NexYouTubeTools.swift` owns YouTube search and playback routing.
- Coding: `NexCLITaskService.swift`, `NexCLIHostManager.swift`, `NexApiClient.swift`, and `NexCLIWorkspaceManager.swift`; authenticated managed local daemon and SSE task stream.
- Codex monitoring: `CodexProgressMonitor.swift`; structured Codex task progress and usage.
- Cross-device work: `NexusConnect*`, `NexusWorkloadRouter.swift`, and `NexusUnifiedWorkloadAPI.swift`; authenticated paired-node transport, bounded process policy, streaming, and file operations.
- Speech: `SpeechTranscriber.swift` with FluidAudio/Parakeet support and `ResponseSpeaker.swift` with streamed Piper/Apple speech.

### Persistence and security already present

- `NexusKeychainSecretStore` is used by Connect, NexCLI, and external model-provider credentials.
- UserDefaults stores nonsecret presentation choices, selected models, and app settings.
- Application Support stores managed daemon state, local indexes, and rebuildable operational data.
- The Obsidian/iCloud vault is canonical only for memory; live SQLite is local and never synchronized.
- The app is not sandboxed today. Its entitlements file is empty. New capabilities still require explicit TCC, OAuth, confirmation, and path-policy boundaries.

## Assets and installed applications

The following user-supplied assets were located in `~/Downloads` on 2026-07-22:

- `icons8-chatgpt-48.png`
- `Terminal--Streamline-Ultimate.png`
- `finder-svgrepo-com.svg`
- `google-calendar-svgrepo-com.svg`
- `imessage.svg`
- `notion-svgrepo-com (1).svg`
- `photos-svgrepo-com.svg`
- `preview-svgrepo-com.svg`
- `slack-svgrepo-com.svg`
- `vs-code-svgrepo-com.svg`
- `xcode-svgrepo-com.svg`

Previously supplied Chrome, Obsidian, YouTube, social-media, Codex, provider, and pet artwork is also present. Runtime must use bundled resources for shipped behavior; `~/Downloads` is only an import source. Icons must never receive an app-created background tile.

Observed installed applications include Terminal, Finder, Spotify, Messages, Photos, Xcode, Preview, Obsidian, Google Chrome, Slack, Discord, and Notion. Visual Studio Code was not found under the standard application roots during the Phase 0 scan, so its executor must report an honest unavailable state until discovered elsewhere or installed.

## Proposed module structure

The Xcode project uses explicit file references, so every new source and test must be deliberately added to the target. The implementation will live under the existing app target with this structure:

```text
nexus/nexus/NexComputer/
  Registry/       manifests, catalog, semantic discovery
  Runtime/        execution envelope, cancellation, timeout, logging, dry-run
  Permissions/    TCC/capability state and permission requests
  Confirmation/   pending actions, risk policy, argument binding
  State/          versioned nonsecret operational persistence
  Automation/     AppleScript, Accessibility, URL-scheme adapters
  Apps/           per-application semantic action executors
  Connectors/     provider capability manifests and OAuth clients
  Browser/        persistent Playwright service/profile bridge
  Previews/       structured preview models consumed by SwiftUI
  CLI/            local command surface and formatting
nexus/nexusTests/NexComputer/
docs/
```

This is a physical organization boundary, not a parallel runtime. It reuses `NexToolRegistry`, `NexToolLifecycleEvent`, `NexPrimaryToolPlanner`, `NexusKeychainSecretStore`, the existing notch controller, and current model adapters.

## Dependency-aware implementation order and checkpoints

Each phase gets its own focused tests, signed build, harmless integration or dry run, documentation update, and git checkpoint. A phase does not begin until the previous phase is green except for explicitly documented pre-existing baseline failures.

| Phase | Deliverable and principal dependency |
| --- | --- |
| 0 | This repository map, baseline, permissions/risk inventory, migration and rollback plan. |
| 1 | Central provider/family icon resolver and bundled ChatGPT icon for all GPT/OpenAI models. This precedes Nex Computer so every later preview shares one resolver. |
| 2 | `NexComputer` foundation extending the existing registry: versioned manifests, standard result/error envelopes, cancellation, timeouts, dry-run, and redacted action logging. |
| 3 | Semantic tool search over manifests. Only relevant tools are exposed to the planner; the complete registry remains available to runtime validation. |
| 4 | Central confirmation gateway, immutable pending action, risk levels, argument hash/binding, expiry, permission discovery, denial, and retry. |
| 5 | Terminal open/run/read/stop actions using argv-based `Process`, streamed output, cwd policy, and shell-metacharacter denial. |
| 6 | Finder/file semantic actions with canonical-path and symlink containment, temp-directory fixtures, and confirmation for mutation. |
| 7 | Spotify open/search/playback/queue/volume actions, preferring app/API capability and exposing honest fallbacks. |
| 8 | Messages and Contacts read/search/draft/send actions; send and personal-data changes require confirmation. |
| 9 | Photos search/open/export/create-album actions with read-only queries first and mutation confirmation. |
| 10 | VS Code discovery/open workspace/file/search actions; unsupported if the app/CLI is absent. |
| 11 | Codex start/inspect/cancel/open actions layered on the existing monitor without changing its compact notch layout. |
| 12 | Obsidian semantic open/search/read/create/update/append actions reusing canonical vault services. |
| 13 | Local Git inspection plus confirmed commit/push and GitHub semantic actions; no shell strings. |
| 14 | Battery, network, audio, display, and System Settings actions with native APIs and lazy permissions. |
| 15 | Xcode open/build/test/scheme actions using `xcodebuild`, structured logs, cancellation, and fixture projects. |
| 16 | Preview/document open, inspect, and combine-PDF actions with temp fixtures and confirmation for writes. |
| 17 | Dock/LaunchServices application discovery and a safe generic open/activate action; no coordinate automation. |
| 18 | Managed Playwright browser service with a dedicated Nexus profile, bounded page actions, safe profile import, and no plaintext credential exposure. |
| 19 | Full Notion, Slack, Gmail, Google Calendar, Google Contacts, GitHub, Discord, and generic Google connector contracts from the mandatory addendum; dynamic capability registration and scope reporting. |
| 20 | One-time Connect UX, provider-specific scope selection, PKCE launch/callback, account state, and revocation. |
| 21 | Contextual Connect cards emitted from unavailable actions and exact pending-action resume after connection. |
| 22 | Connector-management UI/CLI: status, capabilities, reconnect, disconnect/revoke, and account identity. |
| 23 | Auth hardening: Keychain-only tokens, PKCE/state/nonce, refresh rotation, redaction, least privilege, and migration. |
| 24 | Complete `nex-computer` CLI for registry search, inspect, dry-run, execute, confirm, cancel, connector, and pending-action operations. |
| 25 | Structured task previews. Ordinary tools show pet left and app icon right; completed tasks expand into app-native previews and bound confirmation. Codex/NexCLI retain their existing specialized two-sided layouts. |
| 26 | Full schema, discovery, ranking, validation, confirmation, executor, permission, cancellation, connector, Keychain, browser, CLI, and preview test suite. |
| 27 | The 18 specified harmless end-to-end workflows, recorded in `docs/NEX_COMPUTER_VALIDATION.md`. |

## Connector action contract

Phase 19 must implement the full separate addendum, not a generic “connector works” placeholder:

- Notion: search/read/open/create/update/append, database query/create/update, archive.
- Slack: workspace/channel/user discovery, search/history/thread reads, draft/send/reply/edit/delete, reactions, files, presence where supported.
- Gmail: account/label/thread/message search and reads, attachment download, draft lifecycle, send/reply/forward, labels, archive/trash, mark read/unread, spam where supported.
- Google Calendar: calendar/event reads and search, create/update/delete, RSVP, free/busy, availability, attendee and conference handling.
- Google Contacts: search/read/create/update/delete and groups where supported.
- GitHub: identity/repository/search/issues/pull requests/branches/commits/checks plus confirmed mutations.
- Discord: official API/bot capabilities only; no self-bot or user-token automation.
- Generic Google: status, account, capabilities/scopes, reconnect, and disconnect/revoke.

Each connector registers capabilities dynamically, declares required scopes per action, requests only missing scopes, preserves pending action arguments, resumes idempotently, and surfaces unsupported features explicitly.

## Permissions and confirmations

Permissions must be requested lazily at the action that needs them, never at startup in bulk.

- Automation/Apple Events: Chrome, Spotify, Finder, Messages, Photos, Xcode, Preview, Obsidian, and other scriptable apps as used.
- Accessibility: only for actions that cannot use a native API, connector, CLI, AppleScript, ScriptingBridge, or URL scheme. Coordinate clicking remains unsupported unless explicitly labeled experimental.
- Files and folders: user-selected or app-managed roots, canonical path checks, no arbitrary model paths.
- Microphone, speech recognition, and screen/system-audio capture: existing voice/media features only.
- Contacts, Calendars, Photos: native privacy grants when native frameworks are used.
- Network: provider APIs, OAuth, browser automation, and web tools.
- OAuth: system browser, authorization-code flow with PKCE, exact redirect validation, state/nonce, Keychain token storage, incremental scopes, and revocation.

Risk policy:

- Low: read-only, reversible inspection can execute when permission is present.
- Medium: local mutation, draft creation, app state changes, or bounded process execution requires visible intent and may require confirmation by policy.
- High: sending communications, deleting or publishing, pushing code, modifying personal data, destructive commands, calls, purchases, and other external side effects always require an action-bound confirmation.

Confirmation approval is bound to action ID, canonical arguments, target account/device, risk, expiration, and idempotency key. Changing any argument invalidates approval.

## Standard runtime behavior

- Model output supplies semantic action plus validated arguments only.
- Registry discovery returns compact manifests; model prompts never receive secrets, raw AppleScript, shell commands, OAuth tokens, arbitrary paths, or the entire action catalog.
- Runtime selects the safest executor, reports `queued`, `started`, `progress`, `waiting`, `confirmation_required`, `completed`, `failed`, or `cancelled`, and returns a versioned result envelope.
- Independent actions may run concurrently. Per-provider and per-app limits prevent overload.
- Cancellation and timeout propagate to `Process`, browser, network, connector, and UI operations.
- Dry-run returns the resolved action, risk, permissions, target, and planned executor without side effects.
- Logs contain stable IDs and redacted metadata only. Message bodies, email bodies, file contents, tokens, and model secrets are excluded by default.

## Test strategy

- Unit: manifest/schema validation, icon resolution, semantic ranking, unknown-field rejection, action binding, risk and permission policies, redaction, result/error decoding.
- Executor: protocol-backed mocks for every app/connector; temporary directories and repositories for Finder, Terminal, Git, Obsidian, Xcode, Preview, and CLI.
- Integration: harmless read-only or dry-run workflows, local fixture services, mocked OAuth/token stores, cancellation/timeout, disconnected connector resume.
- UI: preview state reducers and component behavior; compact sizing and icon alignment; Codex/NexCLI compatibility; confirmation buttons execute only their bound pending action.
- Security: path traversal/symlink escape, shell injection, unknown tool, approval replay/mutation, OAuth state mismatch, secret redaction, profile-import plaintext checks.
- Regression: signed build, existing unit suites, UI smoke, voice streaming, barge-in, Markdown/LaTeX, memory, web, YouTube, models, Connect, Codex, and NexCLI.
- End to end: only the harmless workflows specified in Phase 27. No test sends a real message/email, deletes user data, places calls, publishes, purchases, pushes remote code, or alters real personal data.

## Risks and honest limitations

- AppleScript dictionaries and Accessibility hierarchies vary by app version. Executors must capability-check and fail clearly rather than click guessed coordinates.
- Messages and Photos do not expose every requested operation through stable public APIs. Unsupported actions remain disabled or experimental until a safe deterministic executor exists.
- Spotify playback/search capabilities depend on installed app scripting support or an authenticated Web API account; neither is fabricated.
- Discord user-account automation is prohibited. Only official application/bot/OAuth capabilities are eligible.
- Browser authentication import is security-sensitive. The dedicated Nexus profile is canonical; import must never expose cookies or passwords to the model or logs.
- OAuth credentials and provider app registrations cannot be manufactured by the local app. The UX can configure and explain missing provider setup honestly.
- Full UI snapshot automation is limited by the current Xcode runner cleanup hang. Reducer/component tests and a UI smoke test remain mandatory while that harness defect is repaired.
- The existing prompt assertion failures must remain distinguished from Nex Computer regressions until the user-owned prompt edit and its tests are reconciled.

## Migration and rollback

- Additive, versioned manifests and state are introduced alongside existing tools. Existing registered names and handlers remain functional throughout migration.
- A feature flag gates semantic discovery and Nex Computer executors until their phase is green. If disabled, the current registry/planner path remains available.
- Keychain items use a new service namespace and versioned accounts; existing Connect, NexCLI, and model-provider secrets are not moved.
- Nonsecret persisted state uses versioned Codable records with forward-compatible unknown-field handling and explicit migrations.
- Connector capability caches and search indexes are rebuildable. Credentials are not.
- Every phase is a standalone git checkpoint. Rollback removes that phase without reverting unrelated user changes or later canonical data.
- Phase 25 is presentation-only over structured events. Rolling it back cannot cancel or corrupt executor work.

## Completion evidence

The subsystem is complete only when `docs/NEX_COMPUTER_VALIDATION.md` records actual results for all Phase 27 workflows and the final requirements in the source specification are verified. Unsupported or unconfigured capabilities must be listed explicitly; no mock, scaffold, or preview is reported as a working action.

## Phase checkpoints

- Phase 20: native Connections settings, system-browser OAuth authorization, PKCE/state, registered callback URL, least-privilege scopes, harmless identity verification, and Keychain-only credential persistence are implemented. Release OAuth client registrations remain an honest build-time requirement.
- Phase 21: disconnected connector calls return native `connection_required` envelopes, persist exact action/argument digests, deduplicate requests, expire safely, reject changed arguments, and hand resumed calls back through the standard registry/confirmation gateway.
- Phase 22: Connections management exposes account, health, last use, granted and optional scopes, incremental permissions, reconnect, disconnect, and revoke controls. A transport-independent management service supplies the same status/doctor/disconnect behavior to the CLI.
- Phase 23: connector credentials and sensitive account metadata remain in Keychain; callbacks require an exact scheme/host/path and state; PKCE is mandatory; expiring credentials refresh and rotate automatically; refresh failure/revocation removes local credentials; redaction strips OAuth secrets from diagnostics.
- Phase 24: the signed Nexus executable accepts `--nex-computer` with discover/apps/tools/search/describe/execute/dry-run/permissions/doctor/confirmation/connector commands; `scripts/nex-computer` is the direct shell entrypoint. Doctor performs only read-only capability checks and reports lazy browser provisioning honestly.
- Phase 25: ordinary compact tasks preserve pet-left/app-right geometry with exact user-supplied marks embedded as raw image bytes and no added icon tile. Structured completion/failure/connection/confirmation events expand into reusable app-aware previews with inspect/open/connect/cancel/confirm controls. Codex and NexCLI retain their established specialized compact layouts.
- Phase 26: the safety and reliability matrix now covers schema/registry/search, strict arguments, bound confirmation, permissions, timeout/cancellation, duplicate registration, dry-run, persistent pending state, CLI parsing, OAuth/Keychain refresh and redaction, safe browser-profile import, structured previews, and raw provider icons. Stored connector credentials are translated into exact logical capabilities and the live app registry now uses an account-bound official-API executor; unsupported operations remain explicitly unavailable. Sixty-four focused Nex Computer tests pass. The macOS UI smoke runner still enters Xcode's known package-resolution cleanup loop after launching, so it is recorded as a harness limitation rather than a false pass.
- Phase 27: the complete safe workflow matrix is recorded in `NEX_COMPUTER_VALIDATION.md`. Live Finder, Terminal, Git, system-state, Obsidian, PDF, Xcode-build, managed-browser, confirmation, and disconnected-connector paths pass. Live validation fixed cross-process CLI confirmation, JSON integer/Boolean bridging, and connector Connect-card schema compatibility. Messages, Photos, Spotify, VS Code, Codex, and external connector gaps are reported honestly as permission, executable/version, or unconfigured-environment blockers rather than mocked successes. The temporary Obsidian fixture was removed and no consequential external action was performed.
