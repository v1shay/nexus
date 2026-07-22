# Nex Computer application support

Generated from the applications installed on Vishay's Mac on 2026-07-22. `applications.open` uses LaunchServices for every installed bundle ID. Additional actions are enabled only where Nexus has a deterministic native API, CLI, connector, URL scheme, or AppleScript dictionary.

| App | Bundle ID / discovery | Supported actions | Method | Permission | Status and limitations |
| --- | --- | --- | --- | --- | --- |
| Terminal | `com.apple.Terminal` | open, tab, session, write, run, output, respond, cancel | AppleScript + argv Process | Automation / confirmation | Supported; no arbitrary shell strings |
| Finder | `com.apple.finder` | open, reveal, selection, search, create/copy/move/rename/trash | Filesystem + AppleScript | Files / Automation | Supported with root and symlink containment |
| Spotify | `com.spotify.client` | open, search, exact URI play, control, volume, track | AppleScript / URL | Automation | Name search cannot claim exact playback without a resolved URI |
| Messages | `com.apple.MobileSMS` | open, contacts, read history, draft, confirmed send | Contacts / read-only SQLite / AppleScript | Contacts / Full Disk / Automation | Supported; send requires confirmation |
| Photos | `com.apple.Photos` | open, metadata search, export, albums | PhotoKit | Photos | Person/semantic query and exact UI focus unavailable via public API |
| VS Code | `com.microsoft.VSCode` if installed | project/file/search/edit/commands | `code` CLI | Files | Currently unavailable in standard install paths on this Mac |
| Codex | installed CLI | open/start/continue/status/cancel/session | `codex exec --json` | Files / code execution | Supported; specialized compact UI preserved |
| Obsidian | `md.obsidian` | open/search/read/create/update/append | Canonical Markdown + URL scheme | Files | Supported; no UI editing |
| GitHub Desktop | discovered app | open only | LaunchServices | None | Git/GitHub operations use `git`/`gh`, not Desktop UI |
| Xcode | `com.apple.dt.Xcode` | open/project/file/build/test/run/status | `xed` / `xcodebuild` | Files / code execution | Supported |
| Preview | `com.apple.Preview` | open/page hint/export/combine PDFs | AppKit / PDFKit | Files | Supported; exact page selection depends on Preview URL handling |
| Google Chrome | `com.google.Chrome` | open/tab actions and managed browser agent | AppleScript + managed browser | Automation / network | Phase 18 |
| Slack, Notion, Gmail, Calendar, Contacts, GitHub, Discord | provider-specific | connector capabilities only after OAuth/scopes | Official APIs | OAuth | Phases 19–23; Discord self-bots prohibited |
| Arc, Blender, BlueStacks, Claude, Cursor, Discord, Docker, Excel, Gemini, Keynote, LM Studio, Notion Calendar, Notion Mail, Numbers, Pages, Perplexity, ProtonVPN, PyCharm, Safari, Screen Studio, Tailscale, Things, Warp, Webex, Zoom and other installed apps | dynamically read from bundle | open/activate only | LaunchServices | None | Reliable app-specific semantic mutation API not yet established; no fake executor registered |

The installed-app list is dynamic at runtime. Nexus returns exact bundle identifiers and paths, and refuses unknown bundle IDs.
