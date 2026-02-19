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
- **Sample Source and triggering**: Norns does not expose a level poll for softcut output. For amplitude-based note triggering when using a sample, route the main output to the input (e.g. patch cable or internal routing), or use line-in with the sample playing; otherwise triggers will not fire from the sample alone.

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

## Grid Visualizer

`notetalk` includes a size-agnostic Monome Grid visualizer that works with 8x8, 16x8, and 16x16 layouts without hardcoded dimensions.

- `Y axis`: VU from bottom to top
- `X axis`: pitch position
- On onset trigger, a horizontal line is drawn across the full grid width and fades out linearly over `500 ms`
- Visualizer uses existing analysis outputs (`amp_norm`, `pitch_midi`, `pitch_conf`, threshold/confidence) and does not change onset or pitch calculations

### Grid Parameters

- `VU Floor`
- `Pitch Min MIDI`
- `Pitch Max MIDI`
- `VU Mode`: `column` or `wide`
- `Line Mode`: `threshold` or `onset`

Default behavior at connect time:

- 8x8: defaults to `column` and narrower pitch range
- 16x8 / 16x16: defaults to `wide` and wider pitch range

In `wide` mode:

- a dim background VU fills all columns
- the current pitch column is highlighted brighter

In `column` mode:

- only the current pitch column is shown

## One-Command Deploy + Run

Use:

```bash
./loitsu.sh
```

Optional host:

```bash
./loitsu.sh 192.168.1.123
```

This command rsyncs the project to `/home/we/dust/code/notetalk/` and then tries to auto-load the script.
If REPL CLI tools are unavailable, it falls back gracefully and asks you to run from Norns UI.

## Files

- `notetalk.lua`: main script, params, UI, loop logic
- `lib/analyzer.lua`: analysis chain and event detection
- `lib/mapping.lua`: pitch-to-note mapping and quantization
- `lib/midi_out.lua`: MIDI sending and note timing

## Restart / Recovery

If **SYSTEM > RESTART** gets stuck on “restarting” (Norns services sometimes start in an order where crone runs before JACK is ready), recover from another machine:

```bash
ssh we@norns.local
sudo systemctl stop norns-matron norns-sclang norns-crone
sudo systemctl restart norns-jack
sleep 2
sudo systemctl start norns-crone norns-sclang norns-matron
```

Then refresh the Norns UI; the script can be reloaded as usual.

## Monitoring Matron Logs via SSH

To monitor matron logs in real-time from command line (instead of browser):

```bash
# Connect to norns
ssh we@norns.local

# Follow matron logs live (systemd journal)
sudo journalctl -u norns-matron -f

# Or view recent logs (last 100 lines)
sudo journalctl -u norns-matron -n 100

# View logs since boot
sudo journalctl -u norns-matron -b

# View logs with timestamps
sudo journalctl -u norns-matron --since "10 minutes ago"

# Related services (if troubleshooting audio issues)
sudo journalctl -u norns-crone -f
sudo journalctl -u norns-sclang -f
sudo journalctl -u norns-jack -f
```

**Note**: Matron logs are stored in systemd journal (not traditional log files). Use `journalctl` to access them.

## Debugging Audio Issues

If no sound from script (but norns boot sound works):

### Check Matron Logs
```bash
ssh we@norns-shield.local
sudo journalctl -u norns-matron -f
```

Look for messages like:
- `notetalk: engine.name set to PolyPerc` (engine loaded OK)
- `notetalk: WARNING - failed to set engine.name` (engine load failed)
- `notetalk: audio levels set - DAC:1.0, CUT:1.0, ENG_CUT:0.6` (levels OK)

### Check Engine Status via REPL

**Option 1: maiden-remote-repl (if installed locally)**
```bash
maiden-remote-repl --host norns-shield.local
# Then in REPL:
tab.print(engine.names)
print(engine.name)
```

**Option 2: maiden on norns**
```bash
ssh we@norns-shield.local
maiden repl
# Then in REPL:
tab.print(engine.names)
print(engine.name)
```

**Option 3: Browser REPL**
- Open `http://norns-shield.local:5555` in browser
- Use REPL tab
- Run: `tab.print(engine.names)` and `print(engine.name)`

### Manual Audio Level Check
In REPL, check current levels:
```lua
print("DAC:", audio.level_dac())
print("CUT:", audio.level_cut())
print("ENG_CUT:", audio.level_eng_cut())
print("Engine:", engine.name)
```

## Notes

- Pitch/confidence polls (`pitch_in`, `pitch_conf`) are used when available.
- If your engine does not expose these polls, manual trigger (`K3`) and MIDI/synth routing still work, but automatic pitch-trigger behavior depends on available pitch data.
- Grid drawing runs in its own refresh loop (about 30 FPS) and overlays the trigger line above VU LEDs.
