# Obsidian and iCloud setup

## Default location

Nex selects the first available root in this order:

1. `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Nex`
2. `~/Library/Mobile Documents/com~apple~CloudDocs/Nex`
3. `~/Documents/Nex`

On this Mac, if Obsidian has already created its iCloud container, option 1 is automatic. No SQLite file is placed in that folder.

## First-time setup

1. Enable iCloud Drive on every Mac using the same Apple ID.
2. In Obsidian, enable **Store in iCloud** or create/open a vault from iCloud Drive.
3. Build and run Nexus normally:

   ```bash
   ./scripts/build-nexus.sh --run
   ```

4. Complete a Nex conversation and hover the notch.
5. Press **Save to Obsidian**. The state changes through **Saving…** to **Saved**. A later turn changes it to **Save New Changes** and updates the same file when pressed.
6. In Obsidian, use **Open folder as vault** and choose the `Nex` folder above if it is not already visible as a vault.

The first save creates the complete folder structure and `90 System/README.md`. Nexus needs no Obsidian plugin.

## Another Mac

1. Install/run a compatible Nexus build and sign into the same iCloud Drive account.
2. Confirm the same `Nex` folder becomes available locally.
3. Start Nexus. It detects downloaded Markdown, builds that Mac’s local SQLite index, and changes its status to **Vault changes ingested** only after ingestion completes.
4. Hover the notch and press the clock-arrow button.
5. Choose **Resume**. Nex restores the stable conversation ID, summary, recent transcript, decisions, open threads, and current task, then continues the same chat.

An unsaved chat never appears on the other Mac. Sleeping/offline Macs naturally cannot receive iCloud changes until they reconnect. “Waiting for iCloud files” means placeholders exist but their contents are not available yet; it is not a synchronized state.

## Editing in Obsidian

You may edit generated Markdown directly. Keep the YAML block, stable `id`, `nex_schema`, and message comments intact. Nex detects the content hash change within the next scan and reindexes it. Removing a note directly removes it from local retrieval after the next complete scan. Application-driven forget operations additionally create a tombstone so deletion propagates safely.

If a note has invalid or unsupported frontmatter, Nexus leaves it untouched, excludes it from retrieval, and reports that the vault was not fully ingested. Fix the note rather than deleting the local index.

## Rebuilding

Canonical content is safe even if a local index is corrupt. Quit Nexus, remove only:

```text
~/Library/Application Support/Nexus/Memory/index.sqlite*
```

Restart Nexus to rebuild from Markdown. Never put this database inside iCloud or the Obsidian vault.
