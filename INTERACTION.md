# Nexus interaction contract

## Hover

- The top-center physical-notch zone is part of Nexus even where no Nexus pixels are drawn.
- Moving the pointer into that zone reveals the full transcript and model surface.
- Nexus remains present while the pointer is in its expanded window, then dismisses shortly after the pointer leaves both the window and notch zone.
- Clicking is never required to reveal the overlay.

## Dictation hotkey

- Holding `Command` by itself for 180 ms starts dictation globally; releasing it finishes dictation.
- A quick Command tap and normal Command shortcuts are ignored. Pressing another key, clicking, or scrolling cancels a pending hold so Nexus does not interfere with ordinary shortcuts.
- Holding it reveals the dictation wings only: the selected pet is left of the physical notch and the waveform is right of it.
- The physical notch width is a protected center gap; interactive visuals must never be placed inside it.
- Releasing the hotkey closes the wings and automatically opens the full surface with the retained transcript.
- That automatic reveal stays open until the pointer visits the notch and then leaves; later notch hovers reopen the retained transcript normally.
- If an installed model is selected, Nexus briefly reveals the prompt, contracts to the working pet and a thinking indicator, then reopens automatically with the latest prompt and answer.
- Nexus reads the answer aloud using the system voice or the configured local Piper voice.

## Visual language

- The compact dictation surface uses only the selected animated pet and waveform, separated by the physical notch.
- Supplied atlas rows map attentive/waiting to dictation, active work to thinking and tool use, and review to the expanded response.
- In the expanded overlay, click the pet to mute, Command-click it to cycle through the six bundled pets, or double-click it to close. The selected pet persists across launches.
- The transcript surface is intentionally sparse: a pet, transcript, and a quiet Models control. Status labels such as “Listening” are avoided.
