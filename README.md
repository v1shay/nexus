# Nexus V2

Nexus is a native macOS proof of concept for an agent that lives in the MacBook notch.

The project builds on macOS 14 with Xcode 15. On macOS 26, build it with Xcode 26 or newer to compile and render SwiftUI's native Liquid Glass `glassEffect`; older SDKs compile the ultra-thin-material fallback instead.

## Included

- A non-activating AppKit panel measured from the display's actual notch geometry—not a normal app window. It expands down from the notch on hover and collapses after the pointer leaves.
- The idle state is visually indistinguishable from the notch. Hold **Command-Shift-Space** from any app to dictate: the orb appears on the left wing, the waveform appears on the right wing, and the physical notch remains an empty protected center gap. Release to save the transcript, then hover the notch to open it.
- Native macOS Speech recognition streams the actual dictated text into the glass transcript surface.
- A deliberately unstyled local-model aggregator with RAM-aware recommendations, the full Ollama registry (more than 200 official library entries), Hugging Face GGUF search for LM Studio, and support for any exact model identifier.
- Ollama downloads use the streamed local `POST /api/pull` API, byte-accurate progress, `GET /api/tags` verification, cancellation, retry, duplicate prevention, and persisted completion state. Nexus detects Homebrew, `/usr/local`, and app-bundled executables, starts `ollama serve` without Terminal, and can install the official app into `~/Applications` after one confirmation.
- LM Studio downloads use its bundled `lms get -y --gguf` command directly through `Foundation.Process`, including progress parsing, cancellation, verification through `lms ls`, and no shell or Terminal window.

## Run

Open [`nexus/nexus.xcodeproj`](nexus/nexus.xcodeproj) in Xcode, select **My Mac**, and run the `nexus` scheme. macOS 14.2 or newer is required.

The app intentionally is not sandboxed: invoking user-installed Ollama and LM Studio command-line tools requires process execution outside the App Sandbox. On first dictation, macOS asks for Microphone and Speech Recognition access.

## Model identifiers

Search the live registry or paste any valid Ollama tag or Hugging Face/LM Studio model identifier, select the runtime, and press **Download**. LM Studio must be installed and opened once so its `~/.lmstudio/bin/lms` helper exists. Ollama can be installed by Nexus when first needed.
