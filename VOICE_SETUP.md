# Voice setup

Nexus speaks answers with the matching macOS system voice by default. No extra setup is required.

## Replace it with an open-source Piper voice

Nexus automatically switches to Piper when these exact three files exist:

```text
~/Library/Application Support/Nexus/Voice/piper
~/Library/Application Support/Nexus/Voice/voice.onnx
~/Library/Application Support/Nexus/Voice/voice.onnx.json
```

- `piper` must be a macOS binary built for the Mac's architecture and marked executable.
- `voice.onnx` is the Piper voice model.
- `voice.onnx.json` is the matching configuration distributed with that exact model. Renaming both voice files is fine; their contents must remain a matched pair.
- Review the voice's `MODEL_CARD` license before distributing it.

One-time setup after obtaining the Piper binary and the two matching voice files:

```bash
mkdir -p "$HOME/Library/Application Support/Nexus/Voice"
cp /path/to/piper "$HOME/Library/Application Support/Nexus/Voice/piper"
cp /path/to/chosen-voice.onnx "$HOME/Library/Application Support/Nexus/Voice/voice.onnx"
cp /path/to/chosen-voice.onnx.json "$HOME/Library/Application Support/Nexus/Voice/voice.onnx.json"
chmod +x "$HOME/Library/Application Support/Nexus/Voice/piper"
```

Restart Nexus. It passes answer text to Piper over standard input and invokes the binary directly with `Foundation.Process`; it never builds a shell command. If any required file is missing or Piper fails, Nexus falls back to the macOS voice automatically.
