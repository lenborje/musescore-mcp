# Analys: tskovlund/mcp-score (kompletterande MCP-implementation)

Analysdatum: 2026-10-23. Källa: github.com/tskovlund/mcp-score (main, sep 2026), filer lästa: README.md, docs/reference.md, src/mcp_score/musescore/plugin/* (qml + 6 js-moduler), musescore/headless.py, tools/{analysis,manipulation,generate,render}.py.

## Arkitektur (tre helt separata förmågor)

1. **Generering (ingen MuseScore inblandad):** `generate_score` — agenten skriver en music21-Python-script; servern kör det som sub-process (120 s-timeout, temporärt script, utdatakatalog på skrivbordet); resultatet är MusicXML-filer. Därtill `score_generation_guide` (prompt/skill med instruktioner). Detta är deras svar på "hela uppgiften i ett anrop" — men på SERVERSIDAN, inte i MuseScore.
2. **Rendering (headless CLI, ingen plugin):** `render_score` — `mscore -f -o ut.format in.musicxml` som sub-process (QT_QPA_PLATFORM=offscreen på Linux). PDF/PNG/MIDI/MP3/WAV/MusicXML. Framgång bedöms på skrivna filer (MuseScore 4.7 på macOS 26 skriver ut PDFen och kräsen sedan i avstängning — exit-kod är opålitlig). MuseScore skall inte vara igång.
3. **Live-brygga (QML-plugin, ws://localhost:8765):** `pluginType: "dialog"` med synligt statusfönster som måste hållas öppet ("Closing it stops the plugin"). Protokoll `{command, params}` → `{result|error}`. Kommandon: ping, getScore (metadata: delar, taktantal, takt-/tonartssignatur), getCursorInfo, goToMeasure, goToStaff, addNote, addRehearsalMark, setBarline, setKeySignature, setTimeSignature, setTempo, addChordSymbol, addDynamic, appendMeasures, selectCurrentMeasure, selectCustomRange, transpose, undo, processSequence.

## Avgörande implementationsfynd

- **Ingen writeScore/readScore någonstans.** De exporterar ALDRIG från plugin; live-läsning är cursorbaserad elementbeskrivning. Deras grönCI på 4.7.5 bevisar därmed INTE att writeScore fungerar — de har designat bort det helt. Stark indikation: plugin-filskrivningar är opålitliga även i ett moget projekt.
- **Voice: hårdkodat 0** ("always 0 for now"). Inget röststöd: ingen census, ingen swap, ingen synlighet.
- **Läsning ytlig:** `get_measure_content` = elementet vid TAKTENS START (endast voice 0); `read_passage` = en post per takt. De kan inte återskapa partiturinnehåll — deras "read the melody" bygger på tunna mätardata + agentens musikaliska omdöme.
- **Undo versionsmedvetet (viktigt för oss):** `"undo"` på 4.4–4.6, **`"action://notation/undo"`** på ≥4.7, via `plugin.mscoreMajorVersion`/`mscoreMinorVersion`. Bekräftar vår fas 0-experimentation (vår `action://undo` dispatchar internt till notation/undo — fungerar, men deras mönster är det renare).
- **`withUndoStep(plugin, name, fn)`:** `startCmd(namn)` → `endCmd(response.error !== undefined)` — rollback även vid returnerat felobjekt, inte bara kast. Dessutom: processSequence batchar flera apply* i ETT undo-steg.
- **Barline-crash bekräftad:** "MuseScore 4 rejects bar lines inserted through Cursor.add (it crashes)" — de modifierar takens existerande slutstreck-subtyp i stället; repet är measure-flags. Matchar vår cookbook-varning.
- **newElement+cursor.add-mönster** för rehearsal marks, ackordsymboler (HARMONY), dynamics — fungerande uppsättning av säkra elementtyper.
- **Transpose:** direkt elementmutation på valt intervall (tpc-respelling-matematik i constants.js) — mönster för vår runCode.
- **Python 3.14+, MIT, PyPI-paket, CLI-install, CI-matris** (oldest/middle/newste MuseScore-linje), typade result modeller, ToolError-semantik. Ingenjursmässigt betydligt moget.

## Jämförelse mot våra mål

| Mål | mcp-score | musescore-mcp (vi) |
|---|---|---|
| Flera röster per staff (läsa/navigera/skriva/växla/synlighet) | **Nej** (voice hårdkodad 0) | **Ja, implementerat + runtime-verifierat** (getVoices, swapVoices via voice-x12, setVoiceVisibility, voice-parametrar) |
| Komplex ångrad/sekvensering | processSequence i ETT undo-steg (fin mönsterdetalj: `endCmd(response.error)` | processSequence, men per-sub-kommando; deras batch-i-ett-steg är bättre |
| music21-analys (tonart, harmonisk analys av LIVE partitur) | **Nej** — music21 endast för generering; ingen teorifråga-verktyg | Implementerat, men blockerat av writeScore-mysteriet; **plan B: server-side rekonstruktion ur getScoreSummary-JSON** |
| Stateless musikteori-frågor | Nej | **Ja** (music_theory_query) |
| Generera hela partitur från agentkod | **Ja** — music21-script på serversidan (snyggt: ingen risk för live-appen) | Nej (uppe på vår önskelista; deras modell är den rätta) |
| Godtycklig kod I MuseScore-processen (run_qml) | **Nej** | **Ja, unikt** — complements deras modell: deras sker på filer/serversidan, vår på det LIVE öppna partituret |
| Rendering/konvertering (PDF/PNG/MIDI/MusicXML) | **Ja** — CLI-headless, filer | Saknas; samma teknik är bevisad hos oss (CLI-konverteringen 15:49 i fas 0) |
| Djup partitur-läsning live | Grund (element vid taktstart, voice 0) | **Djupare** (alla stämmor, alla 4 röster, per element, voice+staffIdx) |
| Plugin-livscykel | Statusfönster som måste hållas öppet | Vår server lever utan fönster (fungerar i praktiken) |
| Mognad (paket, CI, felhantering) | PyPI + CI-matris + typade modeller | Experimentell |
| Dorico-stöd | Experimentellt | Nej |

## Slutsatser och rekommendationer

1. **writeScore-mysteriet: deras arkitektur är svaret, inte deras kod.** Ett moget projekt med grön 4.7.5-CI undviker plugin-filskrivningar totalt. Sluta jaga writeScore; genomför plan B direkt: (a) music21-analys byggs server-side ur getScoreSummary-JSON (våra källdata är bättre än deras), (b) runCode-backup blir server-side JSON-snapshot, (c) fil-konvertering/render sker via mscore-CLI (för sparade filer).
2. **Anta deras undo-mönster:** versionsmedveten kod via `plugin.mscoreMajorVersion` (`action://notation/undo` ≥4.7, annars `undo`) + `endCmd(response.error)`-rollback vid felobjekt + processSequence som ETT undo-steg. Små ändringar, tydligt bättre semantik. Versionsläsningen kan även driva vår swap-try-lista.
3. **Lägg till generate_score-modellen** (agentens music21-script körs serversidigt → MusicXML): uppfyller upprinnelsens "hela komplexa uppgiften i ett anrop" utan eval-risk i live-appen. Kompletterar run_qml (som behålls för kirurgi på det ÖPPNA partituret).
4. **Lägg till render/convert-verktyg** (mscore-CLI): PDF/PNG/MIDI/MusicXML från filer — bevisat fungerande väg, ersätter plugin-exporten helt.
5. **Cookbook-tillägg:** deras barline-workaround (mutera existerande slutstreck, aldrig cursor.add), deras newElement-uppsättning (rehearsal/dynamics/HARMONY), transpose-via-elementmutation.
6. **Konkreta skillnader att bevara:** vårt röststöd, vår djupläsning, vår run_qml och vårt opt-in-tänk är kapabiliteter de saknar — deras projekt validerar samtidigt att generering hör hemma på serversidan.
