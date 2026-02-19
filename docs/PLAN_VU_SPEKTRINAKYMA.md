# VU-korjaus ja spektrinäkymä

## Ongelma

1. **VU ei näy mitään** – todennäköisiä syitä: liian aggressiivinen decay (0.96 / 0.70) + matala gain → `vu_level` ja `grid_col_amp` ehtivät pudota nollaan heikon signaalin aikana; tai `vu_floor` / `vu_curve` leikkaa pois pienten arvot.
2. **Toive: spektrinäkymä** – X = taajuus (Hz), Y = amplitudi. Norns tarjoaa vain broadband-amp pollit (`amp_in_l/r`, `amp_out_l/r`) ja pitchin (Hz), ei taajuuskaistakohtaisia tasoja.

---

## Vaihe 1: Korjaus – VU näkyy aina kun signaalia on

### 1.1 VU-analyzer

- **lib/vu_analyzer.lua**
  - **vu_decay**: 0.96 → **0.98** (hieman hitaampi lasku).
  - **amp_for_vu_alpha**: 0.28 on ok; jos näkymä on vielä tyhjä, kokeilla **0.35**.
  - **vu_gain**: varmista 15; heikolle line-inille kokeilla **20** tai **25**.

### 1.2 Grid-visualizer

- **lib/grid_visualizer.lua**
  - Kun `vu_raw > 0.005` mutta `vu_amp` pieni: pakota vähintään yksi sarake (esim. keskisarake) näkyväksi (1–2 riviä).
  - **Line-in decay**: 0.70 → **0.82** (kompromissi).
  - **rise_speed** 0.55 voidaan pitää tai nostaa 0.65.

### 1.3 Dataflow

- Varmista että `state.amp_in_l/r`, `state.amp_out_l/r` tulevat audio_input-pollista ja että `vu_analyzer:update()` kutsutaan analyzer_loopissa.

---

## Vaihe 2: Spektrinäkymä (X = taajuus, Y = amplitudi)

Norns ei tarjoa taajuuskaistatasoja. Kaksi reittiä:

### 2.1 Pseudo-spektri (ilman FFT)

- **X-akseli = taajuus (Hz)** – vasen = matala, oikea = korkea (pitch_min_midi … pitch_max_midi → Hz).
- **Y-akseli = amplitudi** – palkin korkeus = broadband-taso.
- **Pitch löytyy:** yksi piikki kohdassa pitch_x, korkeus = taso.
- **Pitch puuttuu:** kaikki sarakkeet saman korkeudella (broadband), “tasainen spektri”.

Toteutus: grid_visualizer – kun ei pitch_x, käytä target = vu_amp kaikille x (jo nyt); varmista että vu_amp ei jää nollaksi (Vaihe 1).

### 2.2 Oikea spektri (FFT) – myöhempi laajennus

- Vaatii joko SuperCollider-moottorin (FFT + addPoll N kaistalle) tai Lua-FFT + äänipuskurin (Norns API ei suoraan anna sample-streamiä Lualle).
- Dokumentoi README:hen.

---

## Toimenpidejärjestys

1. **vu_analyzer.lua**: vu_decay 0.98, vu_gain 20 (tai 25), amp_for_vu_alpha 0.28 tai 0.35.
2. **grid_visualizer.lua**: line-in decay 0.82; pakota vähintään yksi palkki kun vu_raw > 0.005; pienempi vu_floor tarvittaessa.
3. Spektrinäkymä: kommentit/parametrit selkeäksi (X = taajuus, Y = amplitudi).
4. (Valinnainen) README: maininta FFT-toteutuksesta.
