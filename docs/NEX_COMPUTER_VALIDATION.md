# Nex Computer Phase 27 Validation

Validated on macOS on 2026-07-22 against the signed Debug build produced by `./scripts/build-nexus.sh`. The live CLI commands below use the same registry, runtime, permission manager, confirmation gateway, connector roster, and executors as Nexus. No real message or email was sent, no call was placed, no purchase or publication occurred, no remote Git push ran, and no personal file was deleted.

## Environment

- Registry: 201 actions; 193 available in the current environment.
- Managed browser: provisioned and isolated under Nexus Application Support.
- Connectors: Google, Notion, Slack, GitHub, and Discord are not configured on this Mac, and are reported as disconnected.
- Current permission gaps: Messages Full Disk Access and Photos access are not granted to this signed build.
- Current executable gaps: the VS Code CLI/application path is not installed; the installed Codex CLI is `0.142.5` and rejects its configured `gpt-5.6-luna` model as requiring a newer Codex build.

## Safe workflow matrix

| # | Workflow | Result | Evidence / limitation |
|---|---|---|---|
| 1 | Open a safe Finder test file | PASS | `finder.open` opened `/tmp/nex-phase27-workspace/NEX_PHASE27_SAFE_TEST.txt` and returned its canonical path. |
| 2 | Run and stream a harmless Terminal command | PASS | `terminal.run_command` required confirmation, then `/bin/echo phase27-stream-ok` completed with exit status 0 and the exact stdout. The separately launched CLI process resumed the persisted pending action. |
| 3 | Spotify search/play | BLOCKED — permission/environment | Both current-track and search validation remained inside the Spotify Automation request instead of returning. The processes were terminated without changing playback. Unit tests cover search, exact URI playback, and malformed resolution; live playback is not claimed. |
| 4 | Messages read-only safe filter | BLOCKED — permission | `messages.search` returned `PERMISSION_REQUIRED` for `full_disk_access.messages` with the exact System Settings recovery path. No history was returned or changed. |
| 5 | Photos read-only query | BLOCKED — permission | `photos.search` returned `PERMISSION_REQUIRED` for `photos.library`. No asset metadata was returned or changed. |
| 6 | VS Code temporary workspace | BLOCKED — executable unavailable | `vscode.open_project` returned `UNAVAILABLE`; none of the declared VS Code CLI paths exists on this Mac. Fixture-backed VS Code search/edit tests pass. |
| 7 | Harmless Codex task | BLOCKED — external version mismatch | The confirmed read-only prompt reached the installed Codex CLI. Codex rejected configured model `gpt-5.6-luna` because CLI `0.142.5` needs an upgrade. Nexus reported the real error and changed no files. |
| 8 | Temporary Obsidian note read/update | PASS | `obsidian.create_note`, `obsidian.read_note`, and confirmed `obsidian.update_note` used one vault-relative stable path and returned the exact diff. The validation note was removed afterward. |
| 9 | Git status in an isolated repository | PASS | `git.status` on `/tmp/nex-phase27-git` returned structured initial branch state and made no mutation. |
| 10 | Battery and network reads | PASS | `system.get_battery` returned the live power source; `system.get_network_state` returned reachable interface state. The report intentionally omits addresses. |
| 11 | Xcode build and test | PASS WITH HARNESS LIMITATION | Confirmed `xcode.build` completed with `** BUILD SUCCEEDED **` and three artifacts. The unfiltered `xcode.test` action entered the existing full-suite geometry/app-process stall and was terminated. The bounded Phase 27 suites completed successfully (37 tests after the final connector-resume test). The complete focused Nex Computer matrix completed 65 tests. |
| 12 | Combine fixture PDFs | PASS | Two one-page fixture PDFs were combined by confirmed `preview.combine_pdfs`; the output is a valid two-page PDF at `/tmp/nex-phase27-pdf/combined.pdf`. |
| 13 | Managed Nexus browser profile | PASS | Confirmed `browser.run_task` launched the isolated persistent profile, navigated to `https://example.com`, extracted `Example Domain`, and saved a screenshot under the Nexus-owned task directory. |
| 14 | Disconnected connector Connect card | PASS | `slack.list_channels` returned a schema-valid `connection_required` result with a persisted `connectionId`, original action, empty results, and `Connect Slack to list channels.` The runtime no longer rejects the Connect-card payload. |
| 15 | Connect a test provider when credentials are available | NOT CONFIGURED | No provider credential is present. Nexus reports every provider as disconnected and does not fabricate a connection. Official account-bound request construction, OAuth refresh, token redaction, and least-privilege scope mapping pass fixture-backed tests. |
| 16 | Resume pending work after connection | PASS (isolated integration) | The integration test creates a disconnected Slack request, applies an exact connected capability document, resumes by stable `connectionId`, and verifies the original action and arguments. No external Slack account is required or contacted. |
| 17 | High-risk dry-run and confirmation binding | PASS | `terminal.run_command` dry-run produced no side effect; execution produced a stable pending ID; `nex-computer confirm <id>` resumed the exact immutable action. The CLI namespace bug discovered during live validation was fixed. Confirmation digest, expiry, replay, and changed-argument rejection remain covered by focused tests. |
| 18 | Compact previews and provider icons | PASS (focused UI-model tests) | Tests verify raw provider image bytes without Nexus-added tiles, structured confirmable email and connector previews, and the preserved specialized compact Codex/NexCLI layouts. The registry advertises all expected preview renderers. |

## Defects found and fixed during live validation

1. `nex-computer confirm` and `cancel` referenced nonexistent namespaced control tools. They now call the registered `confirm_action` and `cancel_action` tools, so confirmations survive CLI process boundaries.
2. CLI JSON conversion bridged integer `1` to Boolean `true`. It now distinguishes Core Foundation Booleans from numeric `NSNumber` values; integer limits work through the live CLI.
3. Disconnected connector results contained Connect-card fields missing from their declared output schema. The connector contract now returns all required common fields plus optional `connectionId`, `requestedAction`, and `ok`, and the runtime accepts it.

## Commands and results

```text
./scripts/build-nexus.sh
  ** BUILD SUCCEEDED **
  Durable requirement: designated => identifier "na.nexus"

xcodebuild -project nexus/nexus.xcodeproj -scheme nexus \
  -destination 'platform=macOS' -derivedDataPath .build-phase27-test \
  CODE_SIGNING_ALLOWED=NO test \
  -only-testing:nexusTests/NexComputerFoundationTests \
  -only-testing:nexusTests/NexComputerExtendedActionTests
  ** TEST SUCCEEDED **

scripts/nex-computer doctor
  ok=true, tools=201, available_tools=193, browser_profile=ready
```

The final targeted run completed 37 tests and the complete focused Nex Computer matrix completed 65 tests. The repository-wide UI smoke runner and unfiltered test action still encounter the documented Xcode package-resolution/app-process harness stall; that is not represented as a product pass.

## Cleanup

- The temporary Obsidian validation note was removed after its update was verified.
- Test files, repositories, generated PDFs, and browser screenshots live only in `/tmp` or Nexus Application Support.
- No live connector authorization was initiated because no credential was available.

## 2026-08-09 headless hardening increment (GPT-OSS-20B)

This is a rolling ledger for the current headless pass. The model for every
planned prompt below was local `gpt-oss:latest` (GPT-OSS 20B). Browser writes
and the disposable Obsidian writes crossed Nexus's own confirmation boundary;
no message, email, remote Git mutation, or personal note was sent or changed.

| Prompt / operation | Expected action | Actual outcome | Latency | Status |
|---|---|---|---:|---|
| `Visit https://www.wikipedia.org/ and describe the page.` | `browser.visit_url` | Correct tool and URL selected; the isolated browser returned the real Wikipedia language portal text. | 1,427 ms execution | PASS |
| Fresh `browser.get_task` for that visit | `browser.get_task` | Restored the completed task and page text after the originating CLI process exited. | 0 ms execution | PASS after fix |
| `On https://www.wikipedia.org/, take a full-page screenshot and tell me which languages are prominently displayed.` | `browser.run_task` with navigate, screenshot, extract | Correct agentic browser action was selected, but GPT-OSS alternated between screenshot-only and extract-only three-step plans. The compound-plan completeness issue remains open. | about 2–3 s planning | PARTIAL / recorded failure |
| `Take a full-page screenshot of https://www.wikipedia.org/.` | `browser.run_task` | GPT-OSS selected structured `navigate`, `wait_for_element`, and `screenshot` steps. The action required confirmation, then completed and saved a 1280×1100 Wikipedia image. Computer Use opened and visually inspected that image in Preview. | 2 ms to request confirmation; 1.7 s confirmed run | PASS |
| Existing runtime running a new `wait_for_element` step | `browser.run_task` | Initially failed because an old generated `agent.mjs` remained on disk after the app changed. The runtime now refreshes its Nexus-owned script when its bundled content changes; the same structured task then passed. | 1.7 s confirmed run | FIXED + PASS |
| `Create a short note called Tool Validation in my validation vault explaining that this is a disposable test.` | `obsidian.create_note` | Discovery ranked the correct action, but GPT-OSS first selected invalid `open_note`, then returned no action after contract guidance. This is retained as a routing failure. | 1.9–2.8 s planning | FAIL / recorded |
| Disposable-vault `obsidian.create_note` | `obsidian.create_note` | Confirmation bound the exact note content and relative path; confirmed create completed. | 2 ms to request confirmation; about 0.3 s confirmed run | PASS |
| Disposable-vault `obsidian.read_note` | `obsidian.read_note` | Returned the exact created content. | 0 ms execution | PASS |
| Disposable-vault `obsidian.append_note` | `obsidian.append_note` | Returned an atomic diff after confirmation. | 2 ms to request confirmation; about 0.3 s confirmed run | PASS |
| Disposable-vault `obsidian.search` for `headless CLI` | `obsidian.search` | Found the one generated note with its matching excerpt. | 1 ms execution | PASS |
| Disposable-vault `obsidian.update_note` then read | `obsidian.update_note`, `obsidian.read_note` | Confirmed atomic replacement returned its diff; a final read returned the replacement content. | 2 ms to request confirmation; 0 ms final read | PASS |

### Defects fixed in this increment

1. `browser.get_task` kept results only in memory, so a later headless CLI invocation reported `BROWSER_TASK_MISSING`. Final non-secret task results now persist beside the task's own screenshots/downloads and are read only by validated UUID.
2. Agentic browser screenshot requests did not rank `browser.run_task` above a simple visit. The action's semantic metadata now describes full-page screenshots and a registered-catalog regression test covers that natural request.
3. Native function calls embedded browser steps as a JSON string, which caused GPT-OSS/Ollama tool-call decoding to truncate the outer call. New calls use a structured `steps` array; the accepted legacy `steps_json` field is hidden from model-facing schemas.
4. The managed browser script was not refreshed after an application update. Nexus now rewrites only its own generated script when its bundled implementation changes, preventing stale runtimes from advertising unsupported behavior.

## 2026-08-09 native function-schema and fixture increment (GPT-OSS-20B)

The local model was `gpt-oss:latest` (20.9B reported by Ollama). These are
natural, target-complete requests against disposable paths under
`.build/validation-fixtures`; Nexus still required its normal immutable
confirmation before every mutation. No personal file, message, account, or
remote repository was changed.

| Prompt / operation | Expected / selected action | Result | Latency | Status |
|---|---|---|---:|---|
| `In the disposable validation workspace at …, run the harmless command printf planner-proof and show me its output.` | `terminal.run_command` with structured argv | Confirmed execution returned exact stdout `planner-proof`, exit 0, and a Nexus-owned session ID. | about 2.8 s planning; 4 ms execution | PASS |
| `In the disposable validation workspace at …, make a folder called Model Finder Proof so I can organize a harmless test artifact.` | `finder.create_folder` | Confirmed creation returned the generated folder path. | about 2.8 s planning; 2 ms to confirmation | PASS |
| `Please keep the source untouched and put a copy of …/ValidationNote.md in …/Model Finder Proof.` | `finder.copy` | GPT-OSS selected the natural collision policy `overwrite`; confirmed copy preserved the source and returned the generated destination path. | about 3.1 s planning; 2 ms to confirmation | PASS after fix |
| `In the disposable Git repository at …, start a local branch called model-route-proof for this harmless validation.` | `git.create_branch` | Confirmed Git action completed; direct status verified the fixture on `model-route-proof`. | about 2.8 s planning; 2 ms to confirmation | PASS |
| `Make a disposable combined PDF at …/ModelCombinedProof.pdf by putting the pages from …/NexusPreviewFixture.pdf in twice, in that order.` | `preview.combine_pdfs` | Confirmed action produced 4 pages. Computer Use opened the generated PDF in Preview and visually verified page order 1, 2, 1, 2. | about 3.4 s planning; 2 ms to confirmation | PASS |

### Model-routing audit after the schema repair

`nex-computer audit-plan --model gpt-oss:latest` completed all 198 registered
examples without external execution. Direct selection increased from 117 to
121; 59 returned no action, 14 correctly requested discovery-first, and 4
selected another action. This is diagnostic evidence, not a claim that the
remaining examples work: many older catalog examples deliberately omit a
required path, ID, recipient, page, or prior-tool result, so a valid native
call would be impossible. The end-to-end rows above use target-complete
natural prompts instead.

### Defects fixed in this increment

1. Native Ollama function schemas emitted the internal `string_array` label,
   which is not JSON Schema. Nexus now sends JSON-schema `array` properties
   with typed `items`, field descriptions, and scalar bounds. This prevents
   GPT-OSS tool calls from being dropped before validation.
2. The native planner's broad reference to “writing” accidentally covered
   requests to change files or records. It now distinguishes conversational
   reply-writing from a requested external state change, which remains routed
   through the ordinary tool, permission, and confirmation layers.
3. GPT-OSS naturally uses `overwrite` for collision handling; Finder
   previously recognized only its internal `replace` spelling. `overwrite` is
   now an explicit, confirmation-gated synonym with the same nonempty-folder
   safeguard. A focused regression test verifies the alias replaces only the
   generated file collision and preserves the source.

## 2026-08-09 routing-boundary follow-up (GPT-OSS-20B)

This follow-up exercised the rebuilt headless app using the same local
`gpt-oss:latest` / GPT-OSS 20B model. All targets remained under
`.build/validation-fixtures`; the Finder operation below was read-only.

| Prompt / operation | Expected / selected action | Result | Latency | Status |
|---|---|---|---:|---|
| `In the validation Obsidian vault, create Tool Routing Proof.md with the heading Tool Routing Proof and one sentence saying this is a disposable model-routing test.` | `obsidian.create_note` | GPT-OSS selected the create action with a vault-relative path and supplied Markdown content. Immutable confirmation then created the generated note; direct read returned the exact content. | about 2–3 s planning; about 0.3 s confirmed run | PASS after fix |
| `In the disposable validation workspace at …, find files whose names contain Validation.` | `finder.search` | GPT-OSS selected Finder search and returned `root`, `nameContains: Validation`, and a bounded limit. Execution found the generated `ValidationNote.md`. | 2,773 ms planning; 1 ms execution | PASS after fix |

### Defects fixed in this follow-up

1. Obsidian's external-vault actions were incorrectly registered as internal
   memory permissions. The native planner intentionally filters internal
   memory writes, so real `create_note`, `append_note`, and `update_note`
   actions were absent from its model-facing allowlist. They are now correctly
   filesystem tools; their existing confirmation policy still governs writes.
2. Absolute filesystem targets contributed directory tokens such as `nexus`
   to capability ranking and could crowd out the requested Finder action.
   Search now removes only absolute path spans for semantic ranking while
   preserving the original prompt for argument generation, and native
   allowlists default to the three strongest candidates.
3. GPT-OSS can emit an optional placeholder for every JSON-Schema property
   despite native instructions—for example empty Finder filters and
   `maximumSize: 0`, which rejects ordinary files. Before execution, Nexus now
   schema-checks model-originated plans and removes only empty optional values,
   nulls, and an unrequested zero optional number. It never adds arguments,
   changes tool selection, or changes direct CLI/user-supplied calls. A user
   request that explicitly says `zero` preserves a zero value.

Focused regression suites passed after this change:

```text
xcodebuild -quiet -project nexus/nexus.xcodeproj -scheme nexus \
  -configuration Debug -destination 'platform=macOS,name=My Mac' \
  -derivedDataPath .build test \
  -only-testing:nexusTests/NexPrimaryToolPlannerTests \
  -only-testing:nexusTests/NexComputerToolSearchTests \
  -only-testing:nexusTests/NexComputerExtendedActionTests
  ** TEST SUCCEEDED **

./scripts/build-nexus.sh
  ** BUILD SUCCEEDED **
```

## 2026-08-09 terminal session continuity and live headless bridge (GPT-OSS-20B)

The local planner model was `gpt-oss:latest` (GPT-OSS 20B). The natural
requests below selected the tool; the new `nexusctl tool-*` commands then
executed the model-selected action through the already-running Nexus app,
which is necessary for stateful sessions to retain their in-memory process,
stdin pipe, and captured output. All commands were harmless. The one shell
file existed only at `/private/tmp/nexus-terminal-prompt-test.sh` and was
created exclusively for this validation.

| Prompt / operation | Expected / selected action | Result | Latency | Status |
|---|---|---|---:|---|
| `Run a harmless print command and show me its output.` | `terminal.run_command` | GPT-OSS selected `echo` with the separate argument `Hello, world!`; the generic grounding layer removed the model-invented optional working directory `/` because the user had not supplied a filesystem root. | 1,800 ms planning | PASS after fix |
| Confirmed live-app echo, then separate `terminal.get_output` | `terminal.run_command`, `terminal.get_output` | Immutable confirmation ran `echo persistent terminal proof`; a later headless call to the same app returned that exact stdout, exit 0, and the same session ID. | 2 ms preview; 8 ms confirmed run; 0 ms output read | PASS after fix |
| Generated prompt script: `Continue?`, respond `yes`, then read output | `terminal.run_command`, `terminal.respond_to_prompt`, `terminal.get_output` | The run returned a live `yes_no` prompt session; a second immutable confirmation sent `yes`; output read returned `Continue?reply=yes` and exit 0. | 2 ms run preview; 11 ms initial confirmed run; 4 ms response confirmation; 0 ms output read | PASS after fix |
| Start generated `/bin/sleep 15`, then cancel by returned session ID | `terminal.run_command`, `terminal.cancel`, `terminal.get_output` | After the 750 ms initial observation, Nexus returned a running session. `terminal.cancel` targeted only that session. The later read reported exit status 15, proving the generated process was terminated rather than naturally completed. | 2 ms preview; 777 ms initial run; 0 ms cancel; 0 ms output read | PASS after fix |
| `Open Terminal.` | `terminal.open` | GPT-OSS selected the low-risk open action. The live action returned `Opened Terminal.` and the macOS Terminal process was present afterward. Computer Use could not inspect Terminal because that app is safety-restricted by the Computer Use environment, so no visual claim is made. | 3,600 ms planning; 104 ms execution | PASS (process evidence) |
| `Which terminal session is active?` before macOS Automation is granted | `terminal.get_active_session` | GPT-OSS selected the correct action; execution returned the exact `automation.com.apple.Terminal` permission recovery. No existing Terminal tab was read or written. | prior live probe | EXPECTED PERMISSION LIMITATION |

### Defects fixed in this increment

1. A standalone `nex-computer execute` process created a terminal session in
   its own short-lived memory, so a later `get_output`, `respond_to_prompt`,
   or `cancel` invocation could never find it. `nexusctl tool-execute`,
   `tool-dry-run`, `tool-confirm`, and `tool-cancel-confirmation` now route
   generic action requests to the existing Nexus app and its ordinary
   registry, runtime, permission checks, and immutable confirmation gateway.
   They do not select tools or manufacture arguments.
2. `terminal.run_command` waited indefinitely for a noninteractive command to
   finish, making its advertised `terminal.cancel` action unreachable. It now
   returns the stable session ID after completion, a bounded supported prompt,
   or a 750 ms initial observation window. Short commands still return their
   complete output; long-running commands can be safely inspected or
   cancelled by their exact session ID.
3. GPT-OSS sometimes filled an optional filesystem field with `/`. Generic
   schema-aware grounding now removes only that unrequested global root from
   optional path/directory/folder/root fields. It preserves an explicitly
   supplied `/`, never changes the model's selected tool, and never adds an
   argument.

Focused verification:

```text
xcodebuild -quiet -project nexus/nexus.xcodeproj -scheme nexus \
  -configuration Debug -destination 'platform=macOS,name=My Mac' \
  -derivedDataPath .build test \
  -only-testing:nexusTests/NexTerminalActionTests \
  -only-testing:nexusTests/NexPrimaryToolPlannerTests
  ** TEST SUCCEEDED **

./scripts/build-nexus.sh
  ** BUILD SUCCEEDED **
```

## 2026-08-09 macOS permission-pane routing (GPT-OSS-20B + Computer Use)

This safe UI flow did not toggle, add, or remove any privacy control. It used local `gpt-oss:latest` / GPT-OSS 20B to select the tool, then Computer Use to verify the actual macOS System Settings destination.

| Prompt / operation | Expected / selected action | Result | Latency | Status |
|---|---|---|---:|---|
| `Open Privacy settings.` before schema repair | `system.open_setting` | Semantic discovery returned the correct action, but GPT-OSS emitted no native call because the function contract did not explain its supported setting domains. | about 1.8–2.2 s planning | FAIL / fixed |
| Same prompt after schema repair | `system.open_setting` with `pane: privacy` | GPT-OSS selected the action and exact allowed pane on repeat. The manifest describes its supported domains and semantic input; this is function-schema grounding, not a keyword route. | 1,519 ms planning | PASS after fix |
| `Open Network settings.` and `Open Focus settings.` after schema repair | `system.open_setting` with `pane: network` and `pane: focus` | GPT-OSS selected the same general action with the two different model-inferred enum values, confirming the repair generalizes across setting domains. | 3,334 ms combined planning | PASS |
| Headless execute with the model-selected arguments | `system.open_setting` | Returned `Opened privacy settings.` with no confirmation or setting mutation. | 29 ms execution | PASS |
| Computer Use visual check | macOS Privacy & Security / Full Disk Access | System Settings visibly showed the Privacy & Security selection and the Full Disk Access subpanel, proving the action opened the real operating-system destination rather than merely reporting success. No toggle was clicked. | visual inspection | PASS |
| Live `nexusctl permissions` | permission health probe | Microphone and Speech Recognition are authorized; Input Monitoring, Accessibility, Screen Recording, and Messages Full Disk Access remain ungranted for this ad-hoc build. | under 1 s | EXPECTED LIMITATION |

### Defect fixed in this increment

`system.open_setting` already had a strict enum, but its model-facing function description omitted what the enum represented and which setting domains Nexus can safely open. GPT-OSS therefore discovered the action but declined to emit a native call. The manifest now states the supported system-pane domains and the `pane` field explains its semantic purpose. The action remains restricted to the same validated enum and opens no control directly.

The durable permission-host requirement remains intentionally enforced: `security find-identity -p codesigning -v` reports no valid Apple Development identity, so the build script refuses to install an ad-hoc app as the TCC host. That prevents a misleading “granted” claim which would disappear on the next rebuilt copy. A stable Apple Development certificate is required before the remaining manual TCC grants can persist across rebuilds.

## 2026-08-09 LaunchServices and confirmation-bound macOS actions (GPT-OSS-20B + Computer Use)

These checks used only a built-in app and a reversible system value. The system volume began at 100%, was changed to 99% for the confirmation-path check, and was restored and verified at 100% before this row was recorded.

| Prompt / operation | Expected / selected action | Result | Latency | Status |
|---|---|---|---:|---|
| `What applications can I open on this Mac?` | `applications.list` | GPT-OSS selected application discovery. The headless result returned 33 installed applications as names, bundle identifiers, and paths. | about 1.7 s planning; 9 ms execution | PASS |
| `Open Calculator.` | `applications.open` with the model-inferred Calculator bundle identifier | The headless action returned `Opened Calculator.` Computer Use inspected the actual Calculator window and visible keypad. | about 2.0 s planning; 245 ms execution; visual inspection | PASS |
| `Set the output volume to 99 percent.` | `system.set_volume` with `volume: 99` | GPT-OSS selected the correct macOS action. Nexus returned an exact immutable confirmation preview; confirmation changed volume to 99%, and a direct read verified it. | 2,100 ms planning; 2 ms preview; 239 ms confirmed write; 106 ms read | PASS |
| Restoration to the original volume | `system.set_volume` with `volume: 100` | A second immutable confirmation was required. Confirmed execution restored 100%, and a final read returned 100%. | 2 ms preview; 125 ms confirmed write; 105 ms read | PASS / restored |
| `Turn on Focus mode.` | explicitly unavailable `system.toggle_focus_mode` | Discovery does not offer an unavailable mutation. Direct execution returned the documented stable-public-API limitation and made no change; `system.open_setting` remains the safe navigation recovery. | about 2.9 s planning; 0 ms unavailable response | EXPECTED PLATFORM LIMITATION |

## 2026-08-09 compound system-read discovery (GPT-OSS-20B)

This safe read-only check used local `gpt-oss:latest` (GPT-OSS 20B). The request was intentionally natural and asked for three independent facts; it did not direct the model to specific tools. No system setting, account, file, message, or network configuration changed. Network-address details returned by the tool are deliberately omitted here.

| Prompt / operation | Expected / selected action | Result | Latency | Status |
|---|---|---|---:|---|
| `Tell me whether this Mac is online, whether it is on battery power, and what the current output volume is.` — semantic discovery | `system.get_network_state`, `system.get_battery`, `system.get_volume` | Discovery returned exactly those three system-read capabilities as its strongest candidates; an unrelated media-current-state action was no longer selected. | 669 ms discovery | PASS after fix |
| Same natural prompt — first native planning pass | GPT-OSS selects one independently needed read | GPT-OSS selected `system.get_network_state` in 2.2 s. This is expected for the local native-call interface: the app's existing bounded re-planning loop removes completed tools and asks for the next missing action, rather than treating a single native call as a complete answer. | 2,225 ms planning | PASS / staged planning |
| Direct headless execution of discovered reads | `system.get_network_state`, `system.get_battery`, `system.get_volume` | Each returned structured, non-mutating current state: reachable network, AC power, and 100% output volume. | 8 ms; 14 ms; 124 ms execution | PASS |

### Defect fixed in this increment

Compound discovery split the natural request into independent clauses, but then globally truncated its ranked list. A lower-scoring clause leader could therefore disappear before the model saw it, while generic words such as `current` could promote an unrelated action. Search now preserves the best semantic candidate for each independent clause before filling remaining slots by global relevance, and treats `current` as conversational filler. This is a generic ranking repair: it does not name or force any particular tool. A regression test creates competing network, battery, volume, and media-current tools and asserts that all three requested semantic domains survive a three-candidate allowlist.

## 2026-08-09 complete visual browser workflow (GPT-OSS-20B + Computer Use)

This row replaces the earlier partial browser-plan result with a fresh,
target-complete natural request. The browser target was public Wikipedia in
Nexus's isolated profile; no private browser session, sign-in, download, or
form submission was involved.

| Prompt / operation | Expected / selected action | Result | Latency | Status |
|---|---|---|---:|---|
| `Visit https://www.wikipedia.org, take a full-page screenshot, and describe the different languages shown on the page.` | `browser.run_task` with navigate, screenshot, extract | GPT-OSS selected exactly the three structured steps: navigate to Wikipedia, full-page screenshot, and `extract` on `body`. Confirmation bound that exact immutable workflow. The completed task returned actual Wikipedia language evidence (English, Japanese, German, Russian, French, Spanish, Chinese, Italian, Polish, Portuguese, and the full language menu). | 3,516 ms planning; 2 ms confirmation request; 1.8 s confirmed run | PASS |
| Computer Use visual check of the generated browser image | generated `shot-1.png` | Preview showed the real Wikipedia language portal: title/logo, central globe, the ten prominent language links, search bar, and Wikimedia project grid. This verifies the screenshot is page evidence rather than a synthetic placeholder. | visual inspection | PASS |
| Fresh headless `browser.get_task` for the completed UUID | `browser.get_task` | A separate CLI process restored the complete text, screenshot path, and tab URL from Nexus-owned persisted task state. | 0 ms execution | PASS |

The browser task image lives only in Nexus Application Support under the
Nexus-owned task UUID directory. No user Chrome state was read or modified.

## 2026-08-09 complete headless-registry bridge (GPT-OSS-20B)

The planner and runtime must expose the same tool surface. The prior
`nex-computer tools` command showed only 192 computer-manifest actions even
though model discovery saw 199 registered actions (the 198 model-audited
actions plus the meta `search_tools` action). This increment makes the CLI
list, describe, and execute both registry surfaces while preserving the
computer runtime for manifest-backed actions.

| Prompt / operation | Expected / selected action | Result | Latency | Status |
|---|---|---|---:|---|
| `Find a short public YouTube video explaining how robotic arms work.` | `youtube_search` | GPT-OSS selected `youtube_search` with a complete natural query. | about 2.3 s planning | PASS |
| Headless execute `youtube_search` for `robotic arms explained` | `youtube_search` | Returned five public candidates with title, URL, and stable 11-character video ID; no media was downloaded or played. | 1,637 ms execution | PASS after fix |
| Headless execute `youtube_play` with the returned `C_UbBz59Te0` ID | `youtube_play` | Returned explicit `UNAVAILABLE`: a standalone CLI has no media-overlay host. The user-facing app remains the required presentation host. | 0 ms execution | EXPECTED LIMITATION |

### Defect fixed in this increment

`nex-computer plan` could select a real registry action such as
`youtube_search`, but `nex-computer execute` always called only the computer
manifest runtime and therefore returned `TOOL_NOT_FOUND`. The CLI now:

1. Lists all 199 registered actions, including confirmation controls,
   `search_tools`, and the four YouTube tools.
2. Describes the actual schema and tool-managed permission for non-manifest
   actions instead of pretending they do not exist.
3. Executes a registered non-manifest action through the same validated
   `NexToolRegistry` used by the planner, returning the standard headless
   result envelope.
4. Explicitly marks the three overlay-dependent YouTube controls unavailable
   from a standalone headless process, with a recovery to use the Nexus app;
   it never falsely claims that video playback happened.

Focused tests and the signed Debug build passed:

```text
xcodebuild -quiet -project nexus/nexus.xcodeproj -scheme nexus \
  -configuration Debug -destination 'platform=macOS,name=My Mac' \
  -derivedDataPath .build test \
  -only-testing:nexusTests/NexComputerFoundationTests \
  -only-testing:nexusTests/NexComputerExtendedActionTests \
  -only-testing:nexusTests/NexComputerToolSearchTests \
  -only-testing:nexusTests/NexPrimaryToolPlannerTests
  ** TEST SUCCEEDED **

./scripts/build-nexus.sh
  ** BUILD SUCCEEDED **
```
