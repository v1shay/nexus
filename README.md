# Nexus V2

Nexus is a native macOS proof of concept for an agent that lives around the MacBook notch.

## Included

- A floating, titlebar-free notch overlay with an animated dictation waveform, animated agent orb, and spring transition into a glassy command surface.
- A deliberately unstyled local-model aggregator available from **Models** in the overlay. It provides RAM-aware recommendations, a small starter catalog, and direct support for arbitrary Ollama tags or LM Studio/Hugging Face model identifiers.
- Background downloads through the installed CLI: `ollama pull <tag>` or `lms get <model>`, including progress and completion/failure state.

## Run

Open [`nexus/nexus.xcodeproj`](nexus/nexus.xcodeproj) in Xcode, select **My Mac**, and run the `nexus` scheme. macOS 14.2 or newer is required.

The app intentionally is not sandboxed: invoking user-installed Ollama and LM Studio command-line tools requires process execution outside the App Sandbox.

## Model identifiers

The catalog is a useful starting set, not a claim that the universe of community model files is finite. Paste any valid Ollama tag or Hugging Face/LM Studio model identifier into the search field, select the corresponding runtime, and press Return or **Download**. Nexus passes it straight to the runtime’s CLI.
