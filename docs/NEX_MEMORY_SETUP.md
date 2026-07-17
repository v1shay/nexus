# Set up Nex Memory on another Mac

Setup is one-time. Nex selects the same vault on every launch and automatically creates or ingests its local retrieval index. Do not repeat pairing or setup after restarting Nex.

Give Codex on the other Mac these exact instructions:

```text
Work in my existing Nexus repository without discarding local changes.

1. Verify that Obsidian is installed and that this directory exists:
   ~/Library/Mobile Documents/iCloud~md~obsidian/Documents

2. If it does not exist, stop and ask me to open Obsidian once, enable its
   iCloud vault option, and sign into the same Apple ID used by my other Macs.
   Do not silently create a different local vault.

3. Make sure the Nexus checkout includes commit 8a31dd3 or a newer compatible
   origin/main. Preserve any existing work before updating.

4. Confirm iCloud has delivered this canonical vault:
   ~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Nex

   If it has not arrived yet, wait for iCloud. Do not copy the vault manually
   and do not use ~/Documents/Nex as a substitute.

5. Build and run Nexus from the repository:
   ./scripts/build-nexus.sh --run

6. Verify all of the following:
   - The Nex vault contains 00 Inbox, 10 Profile, 20 Projects, 30 Goals,
     40 People, 50 Organizations, 60 Decisions, 70 Knowledge, 80 Chats,
     90 System, and .nex.
   - The local retrieval database exists at:
     ~/Library/Application Support/Nexus/Memory/index.sqlite
   - No index.sqlite file exists anywhere inside the iCloud Nex vault.
   - Nex reports "Vault changes ingested" rather than claiming synchronization
     while iCloud placeholder files are still pending.

7. Run the Nexus unit/integration test target and report the result, the exact
   vault path selected, and whether existing saved conversations are visible
   from the clock button in the notch.

Never synchronize or copy the SQLite database. Obsidian Markdown, .nex events,
and tombstones are the only cross-device canonical data.
```

After that, nothing else is required. Unsaved chats remain only in the current session. Press **Save to Obsidian** when a conversation should become searchable and available on the other Macs.
