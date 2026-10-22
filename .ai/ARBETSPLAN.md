# Arbetsplan: Röster, music21 och run_qml för musescore-mcp

Status: planerad, ej påbörjad. Beslutsunderlag: grill-session 2026-10-22 (27 beslut, se `HANDOFF.md`).
Principer som gäller hela planen: strikt additiv kompatibilitet (F7), röstoperationer via processSequence (F4), inga ändringar i MuseScore självt.

## Beroendegraf

```
Fas 0: Verifierings-plugin (dev/)
   ├──> Fas 1: Röster            (behöver cmd()-svar, röstfakta)
   ├──> Fas 2: exportScore+music21 (behöver writeScore-svar)
   └──> Fas 3: run_qml            (behöver eval/createQmlObject-svar)
```
Fas 1 kan påbörjas parallellt med fas 2/3 efter fas 0, men sekvensen 0 → 1 → 2 → 3 är arbetsordningen. En commit per fas på main (F27).

## Fas 0: Verifierings-plugin (dev/verify-voices.qml)

Engångs-plugin som körs en gång mot MuseScore 4.7.5 med ett testpartitur (två stämmor, två röster). Allt loggas via console.log. Spara pluginet i `dev/` som regressionstest för framtida MuseScore-uppgraderingar (F27).

Tester:
1. **cmd()-mekanismen**: logga att `cmd` finns; mot testpartitur med markerad takt och innehåll i röst 1+2, pröva i tur och ordning: `voice-x12`, `command://notation/swap-voice-x12`, `swap-voice-x12` — logga vilken som tog (förväntat: `voice-x12` i 4.7.5). Verifiera efteråt med getScoreSummary att rösterna faktiskt växlade.
2. **writeScore**: exportera `musicxml` och `mscz` till `util.tempPath()`-katalogen; logga returvärde och filsökvägar; kontrollera att filerna är läsbara och rimliga.
3. **eval / createQmlObject**: logga `typeof eval`; kör trivial eval (aritmetik); logga om `Qt.createQmlObject` är anropbart (skapa en QtObject). Obs: eval kör på GUI-tråden — trivial kod endast.
4. **cursor.voice-läsning**: logga `cursor.voice` för varje röst 0–3 på en position med innehåll i flera röster; bekräfta läsbarhet och tillstånd efter rewind.
5. **setVoiceVisible**: slå av/på synlighet för röst 2 på staff 0; logga returvärde.

Acceptanskriterier: svar på alla fem punkter loggade och dokumenterade i `.ai/VERIFIERINGSRESULTAT.md`. Blockerare escalateas till användaren innan implementation fortsätter.

## Fas 1: Röster (plugin + server)

Plugin (`musescore-mcp-plugin.qml`):
- `selectionState` får fältet `voice` (aktuell inmatningsröst, 0–3). Alla cursor-skapande actions accepterar `voice` (grunden finns i `createCursor` rad 211).
- `processElement`-utdata får `voice` och `staffIdx` på varje element (additivt).
- `getCursorInfo` rapporterar `voice` via `currentSelection`.
- Ny action `getVoices {staff?, measure/startTick?, endTick?}`: census per staff (röster 0–3: `hasContent`, `visible`, `firstMeasure`, `lastMeasure`); per-takt-endast på begäran.
- Ny action `swapVoices {voice1, voice2, startStaff, endStaff?, startTick?, endTick? | measure?}`: default intervall = current selection. Implementation: `curScore.selection.selectRange(...)` → `cmd(<kod ur try-lista>)` → `syncStateToSelection()` → returnera summary. Röster 0–3 internt (MuseScore-röster 1–4 i GUI = 0–3).
- Ny action `setVoiceVisibility {staff, voice, visible}` → `Score.setVoiceVisible`.
- Ingen "flytta till tom röst utan växling" i v1 (F8).
- cmd()-användning följer GUI-paritetsregeln (F10): endast urvalsbaserade, dialogfria, deterministiska kommandon.

Server (`server.py`):
- `ActionSequence`-unionen utökas additivt: `getVoicesAction`, `swapVoicesAction`, `setVoiceVisibilityAction` (+ `exportScoreAction` läggs i fas 2).
- `voice` läggs i befintliga TypedDicts: `addNoteParams`, `addRestParams`, `addTupletParams`, `goToMeasureParams` m.fl.
- Inga nya MCP-verktyg för röster (F4).
- Try-lista för swap-koder (F9): `["voice-x12", "command://notation/swap-voice-x12", "swap-voice-x12"]` (mönstret x13/x14/x23/x24/x34) — logga vilken som träffade.

testClient.html: röstväljare (0–3) på befintliga operationer, `getVoices`-knapp, `swapVoices`-form med defaultvärden, synlighets-toggles (F24, minimalt).

Acceptanskriterier: med ett partitur med två röster — `getVoices` rapporterar korrekt census; `swapVoices` byter innehåll och är ångradbart som ett steg; `addNote` med `voice: 1` hamnar i röst 2; `getCursorInfo` visar voice; gamla anrop utan voice fungerar oförändrat (bakåtkompatibilitet).

## Fas 2: exportScore + music21

Plugin:
- Ny action `exportScore {path, format}` → `writeScore(curScore, path, format)`. Servern genererar absolut tempfile-sökväg och skickar som parameter. Alltid heltpartitur (F13); ingen cache i v1.

Server:
- Intern hjälpfunktion: tempfile → `exportScore` via WS → `music21.converter.parse(path)` → radera fil.
- `analyze_key()` → tonartsanalys (global + per del om de skiljer).
- `harmonic_analysis(measure_start?, measure_end?)` → chordifyad progression per takt med ackord och romerska tal relativt analys-tonarten. Endast partiturkälla i v1 (F14).
- `music_theory_query(query: {type: "interval"|"chord"|"scale", ...})` → stateless musikteoretiska frågor. Endast parameterkälla i v1 (F14).
- music21 10.5.0 finns redan i `cenv/`.

Acceptanskriterier: `analyze_key` returnerar korrekt tonart för ett känt partitur; `harmonic_analysis` ger progression för angivet taktintervall; fel vid stängt partitur hanteras graceful; tempfiler städas alltid (även vid fel).

## Fas 3: run_qml + dokumentation

Plugin:
- `property bool allowEval: false` — opt-in i QML-filen (F16, F26).
- Ny action `runCode {code, params}` (endast aktiv när allowEval är true; annars felmeddelande med instruktion).
- Kontrakt (F18): kod exekveras som funktion med (`ctx`, `params`, `state`); `ctx` = dokumenterad fasad (curScore, newCursor, processCommand, läshjälpmedel); `state` = beständigt objekt mellan anrop; returvärde måste vara JSON-serialiserbart.
- Inklädnad: `.mscz`-backup till temp före körning → `startCmd` → kör → `endCmd` (rollback vid fel; ett undo-steg per körning).
- Skydd (F16): kodstorleksgräns (förslag: 100 kB), loggning per körning (kodradslängd, paramantal, status — ej koden själv).
- Svar: `{status, result | error, consoleLog}`.

Server:
- Nytt toppnivå-verktyg `run_qml {code, params?}` (F21, F22). Verktygsbeskrivning pekar på cookbook och säkerhetskontraktet.

Dokumentation (F25):
- `docs/AGENT-COOKBOOK.md`: kort QML-referens för `ctx`-faskaden, element-typer, cursor-mönster, kända fallgropar/krascher (ties, barlines), tre fullständiga mönsterexempel (kopiera sångtext, transformera text, pianoreduktion).
- `docs/ACTIONS.md`: action-referens för processSequence (både gamla och nya actions, parametrar, felvillkor).
- `README.md`: nya funktioner, röst-guide kort, opt-in-instruktion för run_qml, länkar till docs/.

Acceptanskriterier: med allowEval=true körs ett cookbook-exempel (t.ex. sångtext-extraktion) som ett anrop och returnerar korrekt resultat; med allowEval=false svarar verktyget med instruktionsfel; en krasch-simulering (kod som kastar) ger rollback och felmeddelande, inte död endpoint; backup-fil finns i temp under körningen.

## Efter fas 3 (ej i scope, medvetet uppskjutet)

- Explode/Implode som actions (F10, v2).
- Kuratering av återkommande eval-uppgifter till stabila actions (F20).
- Cachad export vid latensproblem (F13).
- Källbyte `source: "musescore"|"inline"` på harmonic_analysis (F14).
- `Qt.createQmlObject`-baserad kod om eval visar sig otillräcklig (F17).
- QML-migreringsspåret (F1) — se `MCP-QML-FEASIBILITY-REPORT.md`.
