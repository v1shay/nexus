# Nexus V2

Nexus is a native macOS proof of concept for an agent that lives in the MacBook notch.

## Included

- A non-activating AppKit panel measured from the display's actual notch geometry—not a normal app window. It expands down from the notch on hover and collapses after the pointer leaves.
- The idle state is visually indistinguishable from the notch. Hold **Command-Shift-Space** from any app to dictate: the orb appears on the left wing, the waveform appears on the right wing, and the physical notch remains an empty protected center gap. Release to save the transcript, then hover the notch to open it.
- Native macOS Speech recognition streams the actual dictated text into the glass transcript surface.
- A deliberately unstyled local-model aggregator is retained as the beginning of Nexus's local-AI layer. It provides RAM-aware recommendations, a small starter catalog, and direct support for arbitrary Ollama tags or LM Studio/Hugging Face model identifiers.
- Background downloads through the installed CLI: `ollama pull <tag>` or `lms get <model>`, including progress and completion/failure state.

## Run

Open [`nexus/nexus.xcodeproj`](nexus/nexus.xcodeproj) in Xcode, select **My Mac**, and run the `nexus` scheme. macOS 14.2 or newer is required.

The app intentionally is not sandboxed: invoking user-installed Ollama and LM Studio command-line tools requires process execution outside the App Sandbox. On first dictation, macOS asks for Microphone and Speech Recognition access.

## Model identifiers

The catalog is a useful starting set, not a claim that the universe of community model files is finite. Paste any valid Ollama tag or Hugging Face/LM Studio model identifier into the search field, select the corresponding runtime, and press Return or **Download**. Nexus passes it straight to the runtime’s CLI.
