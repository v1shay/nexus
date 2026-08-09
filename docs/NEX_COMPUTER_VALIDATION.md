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
