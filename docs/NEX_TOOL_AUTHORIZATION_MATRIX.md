# Nexus Tool Authorization Matrix

Snapshot: 2026-08-10. The headless registry exposes 202 definitions: 201
operational tools plus the non-executing `search_tools` discovery meta-tool.
This matrix lists every operational action that cannot currently receive a meaningful real-functionality
test without one of: a durable macOS grant, an account connection, an
explicitly authorized target, or a platform host. The source snapshot is
`./scripts/nex-computer doctor` plus the full machine-readable
`./scripts/nex-computer tools` output. The GPT-OSS planning and discovery
audits exclude `search_tools`, so their 201-tool total is expected.

Nexus now excludes disconnected connector actions from the model's runnable
allowlist. Directly invoking one returns a bounded `connection_required`
recovery object; it does not make an OAuth request or expose a token.

## macOS privacy or Automation grant needed

| Prerequisite | Actions that need it for real functionality | What is needed |
|---|---|---|
| Messages Full Disk Access | `messages.search`, `messages.triage` | Grant Full Disk Access to a durably signed Nexus build. |
| Contacts | `messages.search_contacts` | Grant Contacts access; this is needed to resolve Vishay to an exact handle without guessing. |
| Messages Automation | `messages.send_draft` | Approve Automation for Messages, then use only Vishay's resolved handle and an immutable confirmation. |
| Photos library | `photos.open`, `photos.open_result`, `photos.search`, `photos.export`, `photos.copy_results`, `photos.create_album`, `photos.add_to_album` | Grant Photos access and select only generated/export-safe assets. |
| Google Chrome Automation | `chrome.open`, `chrome.list_tabs`, `chrome.get_active_tab`, `chrome.open_url`, `chrome.activate_tab`, `chrome.close_tab` | Approve Chrome Automation. `chrome.close_tab` also needs an explicit disposable tab target. |
| Spotify Automation | `spotify.open`, `spotify.search`, `spotify.play`, `spotify.control`, `spotify.get_current_track`, `spotify.set_volume` | Approve Spotify Automation and have a signed-in Spotify desktop session. |
| Finder Automation | `finder.get_selection` | Approve Finder Automation; other Finder actions can use generated paths without it. |
| Terminal Automation | `terminal.get_active_session`, `terminal.open_tab`, `terminal.write_to_session` | Approve Terminal Automation. Nexus-owned `terminal.run_command` sessions are separately testable. |

The present Debug build is ad-hoc signed. Its live designated requirement is a
`cdhash`, so its TCC grants are not durable across rebuilds; `security
find-identity -v -p codesigning` reports no valid Apple Development identity.
Nexus now detects that exact condition at runtime and blocks permission
requests, Settings navigation, and repairs rather than creating a disposable
grant. The durable build flow preserves macOS's normal Apple-backed designated
requirement (rather than forcing an identifier-only requirement), automatically
selects exactly one installed Apple Development identity, and refuses durable
installation unless that identity is verified. A stable Apple Development
certificate is still required before granting the rows above.

## Account connection needed

These actions require the named OAuth account to be connected with the
declared scopes. A connection alone does not authorize a write to a real
person or account-owned item; consequential actions remain confirmation-bound.

| Account | Actions | Safe real-test target after connection |
|---|---|---|
| Google Gmail | `gmail.search`, `gmail.read`, `gmail.read_thread`, `gmail.list_labels`, `gmail.download_attachment`, `gmail.triage`, `gmail.draft`, `gmail.update_draft`, `gmail.send_draft`, `gmail.reply_draft`, `gmail.forward`, `gmail.archive`, `gmail.unarchive`, `gmail.mark_read`, `gmail.mark_unread`, `gmail.star`, `gmail.unstar`, `gmail.apply_label`, `gmail.remove_label`, `gmail.trash` | A dedicated test mailbox/thread; sending, forwarding, and trashing require a separately approved target. |
| Google Calendar | `calendar.list_calendars`, `calendar.list_events`, `calendar.view_upcoming`, `calendar.search_events`, `calendar.get_event`, `calendar.find_availability`, `calendar.draft_event`, `calendar.open_event`, `calendar.create_event`, `calendar.update_event`, `calendar.cancel_event`, `calendar.delete_event`, `calendar.respond_to_invitation`, `calendar.create_focus_block`, `calendar.create_recurring_event` | A dedicated test calendar and generated events only. |
| Google Contacts | `contacts.search`, `contacts.get`, `contacts.list`, `contacts.resolve_person`, `contacts.get_email`, `contacts.get_phone` | A disposable or deliberately approved contact record. |
| Google account metadata | `google.connection_status`, `google.account_info`, `google.list_capabilities`, `google.disconnect` | Signing in enables the first three; `google.disconnect` should be tested only after an explicit request to disconnect that account. |
| Notion | `notion.search`, `notion.read_page`, `notion.open_page`, `notion.search_databases`, `notion.read_database`, `notion.query_database`, `notion.create_page`, `notion.update_page`, `notion.append_content`, `notion.create_database_item`, `notion.update_database_item`, `notion.archive_page` | A dedicated integration-shared test page/database. Archive only generated test content. |
| Slack | `slack.get_channel`, `slack.get_user`, `slack.list_channels`, `slack.list_recent_messages`, `slack.read_channel`, `slack.read_thread`, `slack.search`, `slack.open_channel`, `slack.draft_message`, `slack.send_draft`, `slack.reply_to_thread`, `slack.add_reaction`, `slack.remove_reaction`, `slack.upload_file` | A dedicated private test channel. Sends, replies, reactions, and uploads require that channel as the explicit target. |
| GitHub OAuth connector | `github.search_repositories`, `github.get_repository`, `github.list_issues`, `github.get_issue`, `github.list_pull_requests`, `github.get_pull_request`, `github.list_notifications`, `github.list_workflows`, `github.get_workflow_run`, `github.update_issue`, `github.comment_issue`, `github.comment_pull_request`, `github.merge_pull_request`, `github.mark_notification_read`, `github.rerun_workflow`, `github.cancel_workflow` | The private `v1shay/nexus-tool-validation-20260810` fixture repository, never the production repository. Local `gh` alternatives already validated safe search, checks, issue creation, and PR creation. |

## Explicit target needed even after grants

- `messages.draft` and `messages.open_conversation`: an exact verified Vishay
  phone number or email address. `messages.send_draft` is the only real-message
  send action in scope, and it must target Vishay only.
- `browser.import_chrome_profile`: explicit consent to read selected state from
  the user's Chrome profile. Nexus should otherwise use its separate managed
  profile.
- `browser.reset_profile`: explicit consent to erase the existing managed
  profile. It is not a generated fixture owned by this validation.
- `chrome.close_tab`, `finder.move`, `finder.rename`, `finder.trash`,
  `git.pull`, `git.push`, `preview.export`, and `preview.combine_pdfs`: use
  only generated fixture tabs, paths, repositories, and documents. These are
  testable once a target is named; no blanket access should imply a target.

## Platform or host limitation, not a permission request

- `youtube_play`, `youtube_play_current`, `youtube_fullscreen`: a standalone
  headless run has no Nexus media-overlay host. Test them from the live app
  after the macOS desktop is unlockable for visual/output verification.
- `system.toggle_focus_mode`: macOS has no stable public API for that mutation;
  Nexus correctly exposes the Settings-navigation recovery instead of claiming
  that Focus was toggled.
- Visual verification of launch actions is currently blocked because the Mac
  desktop is locked to Computer Use. Headless launch/process evidence remains
  available, but it is not a substitute for an unlocked visual check.

All remaining local action families have a safe generated-fixture strategy
and are tracked with prompts, model, result, and latency in
`docs/NEX_COMPUTER_VALIDATION.md`.
