# notetalk

`notetalk` is a Norns script that listens to incoming audio, detects pitched onsets, quantizes notes to a selected scale, and sends MIDI notes (with optional synth trigger).

## Engine

- Script engine: `wordpitch_engine`

## Input and Source Behavior

- `Input Mode`: `audio_in` or `softcut`
- `Sample Source`: `off` or `on`
- `Load Sample`: opens file picker for audio files
- `Clear Sample`: unloads current sample
- If a sample is loaded, you can still set `Sample Source` to `off` so the script uses live line input instead.
- If `Input Mode` is `softcut` but no sample is loaded (or sample source is off), analysis falls back to line input.

## Analysis Chain

Implemented in `lib/analyzer.lua`:

1. High-pass filter at 80 Hz
2. Envelope follower
3. VAD gate (`amp > threshold`) with hold/retrigger timing
4. Onset trigger when gate opens
5. Pitch estimates collected for `window_ms`, then median pitch chosen
6. If median confidence is below `min_conf`, no trigger is produced

## Mapping

Implemented in `lib/mapping.lua`:

- `hz -> midi = 69 + 12 * log2(hz / 440)`
- Quantization to nearest note in selected scale (or chromatic)
- MIDI note clamped to configured min/max range
- Additional `Octave Shift` applied before quantization

## MIDI Output

Implemented in `lib/midi_out.lua`:

- MIDI device select
- MIDI channel select
- Note length in milliseconds
- Velocity mode:
  - `amp`: mapped from detected amplitude
  - `fixed`: uses `Fixed Velocity`

## Synth and FX

Params include:

- `Use Synth` on/off
- `Synth Level`
- `FX Reverb Send`
- `FX Delay Send`

These are applied through safe engine/audio calls where supported by the selected engine.

## UI Controls

Main screen controls:

- `E1`: Threshold
- `E2`: Min Confidence
- `E3`: Scale
- `K2`: Freeze analysis on/off
- `K3`: Manual trigger test

The script UI and parameter labels are fully in English and follow standard Norns control conventions.

## Files

- `notetalk.lua`: main script, params, UI, loop logic
- `lib/analyzer.lua`: analysis chain and event detection
- `lib/mapping.lua`: pitch-to-note mapping and quantization
- `lib/midi_out.lua`: MIDI sending and note timing

## Notes

- Pitch/confidence polls (`pitch_in`, `pitch_conf`) are used when available.
- If your engine does not expose these polls, manual trigger (`K3`) and MIDI/synth routing still work, but automatic pitch-trigger behavior depends on available pitch data.
