# Nexus interaction contract

## Hover

- The top-center physical-notch zone is part of Nexus even where no Nexus pixels are drawn.
- Moving the pointer into that zone reveals the full transcript and model surface.
- Nexus remains present while the pointer is in its expanded window, then dismisses shortly after the pointer leaves both the window and notch zone.
- Clicking is never required to reveal the overlay.

## Dictation hotkey

- `Command` + `Shift` + `Space` is registered as a global hotkey.
- Holding it reveals the dictation wings only: the orb is left of the physical notch and the waveform is right of it.
- The physical notch width is a protected center gap; interactive visuals must never be placed inside it.
- Releasing the hotkey closes the wings and retains the recognized transcript without opening the full surface.
- Hovering the physical notch after dictation opens the full glass surface with the retained transcript.

## Visual language

- The compact dictation surface uses only the separated agent orb and waveform.
- The transcript surface is intentionally sparse: an orb, transcript, and a quiet Models control. Status labels such as “Listening” are avoided.
