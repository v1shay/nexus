# Nexus V2

Nexus is a native macOS proof of concept for an agent that lives in the MacBook notch.

## Included

- A non-activating AppKit panel measured from the display's actual notch geometry—not a normal app window. It expands down from the notch on hover and collapses after the pointer leaves.
- The idle state is visually empty. Press **Option-Space** to toggle a listening session, which shows the animated orb and waveform inside the physical notch without any static demo transcript.
- A deliberately unstyled local-model aggregator is retained as the beginning of Nexus's local-AI layer. It provides RAM-aware recommendations, a small starter catalog, and direct support for arbitrary Ollama tags or LM Studio/Hugging Face model identifiers.
- Background downloads through the installed CLI: `ollama pull <tag>` or `lms get <model>`, including progress and completion/failure state.

## Run

Open [`nexus/nexus.xcodeproj`](nexus/nexus.xcodeproj) in Xcode, select **My Mac**, and run the `nexus` scheme. macOS 14.2 or newer is required.

The app intentionally is not sandboxed: invoking user-installed Ollama and LM Studio command-line tools requires process execution outside the App Sandbox. The global Option-Space listener can require Accessibility permission in macOS; the shortcut also works when Nexus is the active app.

## Model identifiers

The catalog is a useful starting set, not a claim that the universe of community model files is finite. Paste any valid Ollama tag or Hugging Face/LM Studio model identifier into the search field, select the corresponding runtime, and press Return or **Download**. Nexus passes it straight to the runtime’s CLI.
