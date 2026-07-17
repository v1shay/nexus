<div align="center">

### nexus

<img width="588" alt="nexus flagship" src="https://github.com/user-attachments/assets/3601921f-3a31-4daf-9d40-2ad1cefd4c9a" />

### meet nex; powered by local models

<img width="534" alt="meet nex" src="https://github.com/user-attachments/assets/bcdc5dc9-6af9-4f0e-b502-608072a01dfb" />

### aggregates 400+ models from day one

<table>
<tr>
<td align="center"><img height="340" alt="lm studio" src="https://github.com/user-attachments/assets/27bf12d1-4c6c-49a1-a27e-06958b560cfd" /></td>
<td align="center"><img height="340" alt="ollama" src="https://github.com/user-attachments/assets/0c1284a5-811b-409c-9e1a-1243a80c9fcb" /></td>
</tr>
</table>

### a one click setup

<img width="672" alt="one click download" src="https://github.com/user-attachments/assets/3492cf07-5b53-4bc0-ab7f-63d43fb6ee78" />

### Nexus Connect

Nexus Connect lets the Mac app securely route model inference, OCR, indexing, approved structured processes, files, and downloads across any saved Studio/iMac on the same Tailscale tailnet. Every device is paired once, retains an independently pinned identity, reconnects after restart, and runs through a persistent background host even when its visible Nexus UI is closed. Existing local Ollama/LM Studio behavior remains available.

Build and run:

```bash
./scripts/build-nexus.sh --run
```

Then open the model window from the notch and expand **Nexus Connect**. Follow the MacBook + Studio + iMac steps in [Nexus Connect setup](docs/NEXUS_CONNECT_SETUP.md). The model window separately controls where inference runs and which one or more Macs receive a model download.

- [Architecture and security](docs/NEXUS_CONNECT_ARCHITECTURE.md)
- [Unified workload API](docs/NEXUS_CONNECT_API.md)
- [Migration and rollback](docs/NEXUS_CONNECT_MIGRATION.md)
- [Voice setup](VOICE_SETUP.md)

### Unified Memory

Nex now keeps unsaved active-chat continuity in memory, saves chats only when you press **Save to Obsidian**, and uses a human-readable Obsidian vault as the canonical long-term store. Each Mac builds its own replaceable SQLite/FTS/vector index outside iCloud; the live database is never synchronized. A clock button in the notch opens saved chats and resumes the original conversation ID on another Mac after iCloud has delivered and Nex has ingested the Markdown.

- [Memory architecture](docs/NEX_MEMORY_ARCHITECTURE.md)
- [Obsidian and iCloud setup](docs/NEX_MEMORY_SETUP.md)
- [Memory tool contracts](docs/NEX_MEMORY_TOOLS.md)
- [Migration, rollback, and limitations](docs/NEX_MEMORY_MIGRATION.md)
