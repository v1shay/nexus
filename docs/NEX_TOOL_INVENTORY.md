# Nexus Live Tool Inventory

Snapshot: 2026-08-10. `./scripts/nex-computer tools` reports 204 definitions:
203 executable actions and the non-executing `search_tools` discovery action.
The running app's `nexusctl tools` union adds `conversation_recall`,
`memory_forget`, `memory_get`, `memory_propose`, `memory_search`, and
`web_search`, for **210 live names**. The authorization and environment
prerequisites for actions that cannot yet receive a meaningful real test are
in [NEX_TOOL_AUTHORIZATION_MATRIX.md](NEX_TOOL_AUTHORIZATION_MATRIX.md).

## Applications (2)

`applications.list`, `applications.open`

## Chrome (7)

`browser.cancel_task`, `browser.get_task`, `browser.import_chrome_profile`, `browser.open_profile`, `browser.reset_profile`, `browser.run_task`, `browser.visit_url`

## Codex (6)

`codex.cancel_task`, `codex.continue_task`, `codex.get_status`, `codex.open`, `codex.open_session`, `codex.start_task`

## Finder (10)

`finder.activate`, `finder.copy`, `finder.create_folder`, `finder.get_selection`, `finder.move`, `finder.open`, `finder.rename`, `finder.reveal`, `finder.search`, `finder.trash`

## Git (10)

`git.checkout`, `git.commit`, `git.configure_remote`, `git.create_branch`, `git.diff`, `git.init`, `git.pull`, `git.push`, `git.stage`, `git.status`

## GitHub (23)

`github.cancel_workflow`, `github.comment_issue`, `github.comment_pull_request`, `github.create_issue`, `github.create_pull_request`, `github.get_checks`, `github.get_issue`, `github.get_pull_request`, `github.get_repository`, `github.get_workflow_run`, `github.list_issues`, `github.list_notifications`, `github.list_pull_requests`, `github.list_workflows`, `github.mark_notification_read`, `github.merge_pull_request`, `github.open`, `github.open_pull_request`, `github.open_repository`, `github.rerun_workflow`, `github.search`, `github.search_repositories`, `github.update_issue`

## Gmail (20)

`gmail.apply_label`, `gmail.archive`, `gmail.download_attachment`, `gmail.draft`, `gmail.forward`, `gmail.list_labels`, `gmail.mark_read`, `gmail.mark_unread`, `gmail.read`, `gmail.read_thread`, `gmail.remove_label`, `gmail.reply_draft`, `gmail.search`, `gmail.send_draft`, `gmail.star`, `gmail.trash`, `gmail.triage`, `gmail.unarchive`, `gmail.unstar`, `gmail.update_draft`

## Google Account (4)

`google.account_info`, `google.connection_status`, `google.disconnect`, `google.list_capabilities`

## Google Calendar (15)

`calendar.cancel_event`, `calendar.create_event`, `calendar.create_focus_block`, `calendar.create_recurring_event`, `calendar.delete_event`, `calendar.draft_event`, `calendar.find_availability`, `calendar.get_event`, `calendar.list_calendars`, `calendar.list_events`, `calendar.open_event`, `calendar.respond_to_invitation`, `calendar.search_events`, `calendar.update_event`, `calendar.view_upcoming`

## Google Chrome (6)

`chrome.activate_tab`, `chrome.close_tab`, `chrome.get_active_tab`, `chrome.list_tabs`, `chrome.open`, `chrome.open_url`

## Google Contacts (6)

`contacts.get`, `contacts.get_email`, `contacts.get_phone`, `contacts.list`, `contacts.resolve_person`, `contacts.search`

## Messages (7)

`messages.draft`, `messages.open`, `messages.open_conversation`, `messages.search`, `messages.search_contacts`, `messages.send_draft`, `messages.triage`

## Nex (3)

`cancel_action`, `confirm_action`, `search_tools`

## NexCLI (2)

`nex_cli_set_workspace`, `nex_cli_task`

## Notion (12)

`notion.append_content`, `notion.archive_page`, `notion.create_database_item`, `notion.create_page`, `notion.open_page`, `notion.query_database`, `notion.read_database`, `notion.read_page`, `notion.search`, `notion.search_databases`, `notion.update_database_item`, `notion.update_page`

## Obsidian (7)

`obsidian.append_note`, `obsidian.create_note`, `obsidian.open`, `obsidian.open_note`, `obsidian.read_note`, `obsidian.search`, `obsidian.update_note`

## Photos (7)

`photos.add_to_album`, `photos.copy_results`, `photos.create_album`, `photos.export`, `photos.open`, `photos.open_result`, `photos.search`

## Preview (4)

`preview.combine_pdfs`, `preview.export`, `preview.open`, `preview.open_at_page`

## Slack (14)

`slack.add_reaction`, `slack.draft_message`, `slack.get_channel`, `slack.get_user`, `slack.list_channels`, `slack.list_recent_messages`, `slack.open_channel`, `slack.read_channel`, `slack.read_thread`, `slack.remove_reaction`, `slack.reply_to_thread`, `slack.search`, `slack.send_draft`, `slack.upload_file`

## Spotify (6)

`spotify.control`, `spotify.get_current_track`, `spotify.open`, `spotify.play`, `spotify.search`, `spotify.set_volume`

## Terminal (8)

`terminal.cancel`, `terminal.get_active_session`, `terminal.get_output`, `terminal.open`, `terminal.open_tab`, `terminal.respond_to_prompt`, `terminal.run_command`, `terminal.write_to_session`

## Visual Studio Code (7)

`vscode.edit_file`, `vscode.get_active_workspace`, `vscode.open`, `vscode.open_file`, `vscode.open_project`, `vscode.run_command`, `vscode.search_workspace`

## Xcode (7)

`xcode.build`, `xcode.get_build_status`, `xcode.open`, `xcode.open_file`, `xcode.open_project`, `xcode.run`, `xcode.test`

## YouTube (4)

`youtube_fullscreen`, `youtube_play`, `youtube_play_current`, `youtube_search`

## macOS (7)

`system.get_battery`, `system.get_display_state`, `system.get_network_state`, `system.get_volume`, `system.open_setting`, `system.set_volume`, `system.toggle_focus_mode`

## Live app-only actions (6)

`conversation_recall`, `memory_forget`, `memory_get`, `memory_propose`, `memory_search`, `web_search`
