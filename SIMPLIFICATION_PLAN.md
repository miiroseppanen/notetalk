# Notetalk Simplification Plan

## Ongelmat
1. **Restart jumittaa** - cleanup:ssa on `clock.sleep()` joka aiheuttaa coroutine-virheen
2. **Grid ei näy** - vaikka koodi näyttää oikealta, grid ei piirry
3. **Volume-potit eivät toimi** - encoderit eivät päivitä ääntä

## Yksinkertaistamissuunnitelma

### 1. Grid-yksinkertaistus
- **Poista kaikki debug-printit** grid-koodista
- **Kopioi täsmälleen toimiva koodi** grid_test.lua:sta
- **Yksinkertainen draw_grid()** - vain heartbeat + VU (ei monimutkaisia debug-viestejä)
- **Varmista että metro käynnistyy** oikein

### 2. Restart-korjaus
- **Poista kaikki clock.sleep()** cleanup-funktiosta
- **Yksinkertaista engine cleanup** - ei monimutkaisia resettejä
- **Poista turhat busy-waitit** - vain välttämättömät
- **Varmista että kaikki metrot pysähtyvät** ennen kuin scripti sulkeutuu

### 3. Volume-korjaus
- **Yksinkertainen enc()** - suoraan softcut.level() ja engine.amp() kutsut
- **Poista monimutkaiset param-actionit** - käytä suoraa kontrollia
- **Varmista että volume päivittyy heti** encoderin kääntämisestä

### 4. Yleinen yksinkertaistus
- **Poista turhat debug-viestit** - vain kriittiset
- **Yksinkertaista audio_service** - poista monimutkaiset routing-logiikat
- **Varmista että init() on yksinkertainen** - ei monimutkaisia defer_clock-kutsuja

## Toteutusjärjestys

1. **Restart-korjaus** (kriittisin)
   - Poista clock.sleep() cleanup:sta
   - Yksinkertaista engine cleanup
   - Testaa että restart toimii

2. **Grid-korjaus**
   - Kopioi toimiva koodi grid_test.lua:sta
   - Poista debug-viestit
   - Testaa että grid näkyy

3. **Volume-korjaus**
   - Yksinkertaista enc()
   - Testaa että volume toimii

4. **Lopullinen siivous**
   - Poista turhat debug-viestit
   - Yksinkertaista koodia missä mahdollista
