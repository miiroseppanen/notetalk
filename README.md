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

`notetalk.lua` (main), `lib/` — `analyzer`, `audio_service`, `grid_visualizer`, `mapping`, `midi_out`, `onset_service`, `pitch_service`.

## If something breaks

- **No sound**: Check matron logs (`sudo journalctl -u norns-matron -f`). Script tries engines PolyPerc → TestSine → SimplePassThru.
- **Restart stuck**: `ssh we@norns.local`, then stop matron/sclang/crone, restart norns-jack, sleep 2, start crone/sclang/matron.
