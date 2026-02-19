# notetalk

Norns script: audio → onset + pitch detection → scale quantization → MIDI + optional synth.

- **Input**: line-in or softcut (loaded sample). Sample triggering needs output routed to input if you want level-based triggers.
- **Params**: Threshold, Min Confidence, Scale, Sample/Synth levels, MIDI device/channel, note length.
- **UI**: E1/E2/E3 = threshold, confidence, scale; K2 = freeze, K3 = manual trigger.
- **Grid**: VU bars (8×8 / 16×8 / 16×16). Bar height = level; sample mode = full-width + pitch peak. Params: VU Floor, Pitch Min/Max, VU Mode, VU Test Animation. **VU Debug (screen)** = on shows level/poll values on screen.

## Deploy

```bash
./loitsu.sh
# or: ./loitsu.sh 192.168.1.123
```

Syncs to `/home/we/dust/code/notetalk/`. If auto-load fails, run script from Norns UI.

## Files

- **notetalk.lua** — main script (orchestration, state, params, screen).
- **lib/** — one module per concern:
  - **audio_input** — amp + pitch polls, health check and restart.
  - **audio_output** — DAC/cut/engine levels.
  - **audio_service** — softcut, sample load, routing.
  - **vu_analyzer** — VU level, normalization (sample mode), amp_norm/amp_for_vu.
  - **pitch_service** — continuous pitch (100 ms grid).
  - **onset_service** — stab/onset detection.
  - **synth_service** — Norns engine trigger, deferred init, boot tone.
  - **grid_controller** — grid connect; wraps **grid_visualizer** (VU/pitch on grid).
  - **analyzer** — observation processing; **mapping** — scales, hz→midi; **midi_out** — MIDI note output.

## Debug / log

Script `print()` output appears in:

1. **Maiden** (easiest): open `http://norns.local` (or your hostname), run the script; the REPL/console shows notetalk lines (e.g. `notetalk: SYNTH ...`, `notetalk: TRIGGER ...`).
2. **Terminal (SSH)**:
   ```bash
   ssh we@norns-shield.local   # or we@norns.local
   journalctl -f
   ```
   Filter for notetalk: `journalctl -f | grep notetalk`

Look for: `SYNTH engine loaded`, `SYNTH note played`, `SYNTH skip (engine not loaded)`, `SYNTH engine.hz failed`, etc.

## If something breaks

- **No sound**: Check logs (see above). Script tries engines PolyPerc → TestSine → SimplePassThru; `eng_cut` (engine→mix level) must be > 0 when Use Synth is on.
- **Restart stuck**: `ssh we@norns.local`, then stop matron/sclang/crone, restart norns-jack, sleep 2, start crone/sclang/matron.
