# Handoff: Duruflé Requiem — satserna 5 (Pie Jesu) och 6 (Agnus Dei)

Extra handoff för pågående partiturarbete. Läs denna + `.ai/HANDOFF.md` innan du fortsätter. Skrivet 2026-10-23 när användaren lämnade sessionen mid-ström.

## Uppdrag

Användarens samlingsmapp `~/Documents/Noter/Cappella Catharinae/Duruflé — Requiem/` innehåller satserna 1–4 och 7–9 (redan svenska-playbook-behandlade: SATB + Orgel 3 system, orgelstavar 66% skalning). Saknade satser: **V. Pie Jesu** och **VI. Agnus Dei**. Målet: kompletta, rytmiskt korrekta, svenskt namngivna satsfiler i samma layout.

## Bakgrund: källan

- Bästa källan på musescore.com är **"Maurice Duruflé — Requiem — choir+organ — complete — revised 2026"** av Alexander Evstyugov-Babaev (https://musescore.com/user/27897310/scores/6002468, CC BY-NC-SA, Duruflés egna orgelreduktion, 717 takter, 14 stämmor, incl. cello för Pie Jesu). **Nedladdning medvetet avstängd av upphovspersonen** (han skickar till sin Patreon). Alternativ: fråga honom via kommentar (han svarar aktivt), eller det pågående OCR-spåret nedan.
- Användaren har Pro-konto och tog ut PDF via utskrift, lät **Myriad PDFtoMusicPro** konvertera till MusicXML: `~/Downloads/request.xml` (10,5 MB, MusicXML 2.0, divisions 6720/kvarts = 14× MuseScores 480-ticks, 14 delar, 717 takter).
- **PDFtoMusic-patologier som verifierats**: stämmor klyvda i lager-fläckar (orgeln = 6 stavar i stället för 3!), samma passage skriven flera gånger via `<backup>` ("multi-pass"), överlappande durationer, dubbletter på samma position utan `<chord/>`, manglad latin-text ("%e" = "Re"), part names OCR-manglade.

## Satskarta i request.xml (verifierad mot användarens egna satser som facit)

I=1–63, II=64–137, III=138–306, IV=307–372, **V. Pie Jesu=373–431 (59 takter)**, **VI. Agnus Dei=432–499 (68 takter)**, VII=500–558, VIII=559–687, IX=688–717. All info om gränserna (markörer, cellostämmans exklusiva intervall, tonartsbyten) redan verifierad.

## MuseScore-importfysik (viktigt, lärd på hårda vägen)

- **Spar-/publiseringskontrollen** (`src/engraving/dom/check.cpp`): röst 0 måste vara EXAKT taktlängden ("Incomplete measure" åt båda håll); röster 1–3 får vara korta men inte långa ("Voice too long"). KÖRS VID SPARNING — det är den slutliga porten.
- **MusicXML-importen** (pass1, `importmusicxmlpass1.cpp`): taktlängd = **max innehållsposition över alla delar** (`determineMeasureLength`), med `<time>`-elementens försoning. STRIPPA INTE `<time>` i extrakt — det gjorde tre takter till 5/4.
- Importörens "försoning" av multi-pass-strömmar är opak och olika mellan kontexter; mekanisk XML-påfyllning av multi-pass-röster är opålitlig — **kanonisk ombyggnad** (hela takten, röst för röst med explicit `<backup>`-positionering) är den enda säkra metoden för struliga takter.
- Extrahera genom att kopiera intakta `<measure>`-element + renumrera + injicera divisions/key/clef i första takten — INTE `<time>`.
- MCP-tjänstens cursor-genomgång för rytmkontroll: **använd "hitta måttet som innehåller cursor.tick"-metoden** (measure-objektet `no`/`tick`/`ticks` via `cursor.measure`, kedjat med `nextMeasure`). En binary-search-bucketvariant MISSADE en verifierad överlappning en gång (takt 24/stav 9) — den enkla metoden fångade den.

## Filer i ~/Downloads

| Fil | Innehåll |
|---|---|
| `request.xml` | Original från PDFtoMusicPro, orört |
| `request-repaired.musicxml` | Reparerad helhet; facit och källa för extrakt |
| `5-pie-jesu.musicxml` | **Ren extrakt, 59 takter, dubbelverifierad rytmiskt ren** |
| `6-agnus-dei.musicxml` | Extrakt, 68 takter, **ännu inte importerad/verifierad** |

Reparationsskript (scratchpad, ev. borta vid ny session): `repair_extract.py` (v1, överträffad), `repair_extract2.py` (mekanisk reparation: 12 chordify, 9 shorten, 87 pad, 2 raderingar), därefter manuella kanoniska ombyggnader av P9 m384/396/401/419 + P10 m390 i `request-repaired.musicxml`. Extrakt-byggaren (sista versionen) finns i bash-historiken/sessionen; återskapa vid behov — den är ~40 rader.

## Status Pie Jesu (sats V)

- Rytmiken **ren enligt två oberoende MCP-kontroller** (per-voice-summor per takt, 4/4 genom hela satsen). Användaren skulle spara som `5-pie-jesu.mscz` — **kontrollera att sparkontrollen var tyst**; om den rapporterar något, fixa direkt i det öppna partituret (ett undo-steg per run_qml) med kanoniskt tänk.
- Innehåll: 14 stavar; stav 1–6 = körens sex stämmor **tomma** (kören tiger i Pie Jesu), stav 7 = **sopransolo** (92 ackord), stav 8 = **cello** (73), stav 9 = orgel I (3 röster, v1/v2 = lagerfragment att skådas mot PDF), stav 10 = orgel II (2 röster), stav 13 = **orgelpedal** (49 ackord C2–F4), stav 11/12/14 tomma.

### Återstående för Pie Jesu

1. **Layout-playbook** (väntar på användarens beslut **A eller B**):
   - A: tre separata orgelparter alla döpta "Orgel" (snabbt via MCP).
   - B: konsolidera orgeln till EN part med 3 stavar som övriga satser — apiv1 kan INTE slå ihop partier (moveStaves fungerar bara inom en part), så B kräver manuell notflytt i GUI.
   - Oavsett: radera 9 tomma stavar (1–6, 11, 12, 14; via `sc.removeStaves([...])` — samla Staff-objekt FÖRE radering, index skiftar), byt namn ("Sopran solo" via replaceInstrument soprano + setInstrumentName; "Cello"; "Orgel"; orgelstavar mag=0.66; gärna setInstrumentAbbreviature för ev. delningar).
2. **Kontrolläsa mot PDF:et**: orgelröst-fragmenten i stav 9 (v1/v2), G4:an i orgelackorden takt 12 (min rekonstruktion — importören hade tappat den), linjen G3–G4–C5 i takt 24 (min rekonstruktion från OCR-materialet), de två raderade fragmenten (m482 stray, m486 4-tonarsfragment).
3. **Texten** är OCR-manglad latin — behöver omskrivning (användarens CopyLyrics.qml/FillRepeatedLyrics.qml kan hjälpa; källa = PDF eller annan utgåva).

## Status Agnus Dei (sats VI) — EJ PÅBÖRJAD

1. Importera `6-agnus-dei.musicxml` (en partitur-omstart i taget; OBS multiprocess-reglerna i huvudhandoffen), kör rytmkontrollen (metoden ovan), notera att takt 468-orig = **takt 37 i extraktet är 5/4 (2400 ticks)** — det är korrekt, inte ett fel.
2. Originalfel i intervallet var ~30 ställen (Pedal-staven värst, inkl. multi-pass-röror vid m432–446, m468, m489–497). De mekaniska reparationerna är applicerade i XML; förvänta ströstayster av samma typ som Pie Jesu — åtgärda med kanoniska ombyggnader i `request-repaired.musicxml` + ombyggt extrakt (beprövat flöde), eller kirurgi i live-partituret.
3. Sedan samma layout-playbook (beslut A/B gäller här också).

## Övrigt att minnas

- Multi-process-regler, plugin-uppdateringsregler, allowEval: se huvudhandoffen. allowEval är nu `true` (användarens val för detta arbete).
- All MusicXML-kirurgi görs på `request-repaired.musicxml` och extrakten byggs OM därifrån — original `request.xml` rör aldrig.
- Tidsåtgång Pie Jesu-riktning: varje import = en full MuseScore-omstart + pluginstart pga processmodellen. Planera rundor.
