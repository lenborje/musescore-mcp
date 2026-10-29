# Handoff: musescore-mcp — röster, music21, run_qml

Dokumentet är sessionsöverskridande kontext. Läs detta + `ARBETSPLAN.md` + `VERIFIERINGSRESULTAT.md` innan du fortsätter arbetet.

## Senaste textändring 2026-10-29 — Cantai-vokaler i system 1–4

Efter NFC-rättningen bad användaren att enbart å/ä/ö i Sopran/Alt/Tenor/Bas
skulle transformeras enligt `~/Documents/MuseScore4/Plugins/CantaiSvengelska.qml`
("Cantai Swedish pronunciation"): å→aw, ä→eh, ö→uh (versaler Aw/Eh/Uh).
Utfört i ett runCode/undo-steg: 24 Lyrics-fält, 6 per system. Kontrollerade
samtliga 475 Lyrics före/efter: exakt dessa ersättningar, system 5–6
(Damer/Herrar) oförändrade. Not-/Harmony-JSON identiskt före/efter; 0 kvarvarande
åäö i system 1–4. Regler för i/lj/ju kördes inte. Inte explicit sparat till fil.
Körningslogg: `/tmp/musescore-cantai-vowels-applied.json`.

## Senaste körning 2026-10-29 — sångtext normaliserad till NFC

- Användaren har uttryckligen godkänt aktivering av `run_qml`; **`allowEval: true` är nu aktuell inställning**, både i repo och installerad plugin, och körs efter användarens omstart. Äldre uppgifter om `false` nedan är supersederade.
- Aktuellt partitur har 21 takter och 6 system: Sopran/Alt/Tenor/Bas/Damer/Herrar. Notantal 49/51/52/51/100/103; Damer och Herrar har två röster. 34 Harmony-symboler på Damer.
- På användarens begäran genomsöktes 513 textfält. 33 Lyrics-fält med dekomponerade Unicode-tecken normaliserades till NFC (å/ä/ö) i ett runCode-anrop/undo-steg. Efterkontroll: 0 kvarvarande skillnader mot NFC, partitur-JSON för noter/ackord identiskt före/efter. Ändringen ligger i öppet partitur, ingen explicit filsparning utförd.
- **Runtime-faktum:** Lyrics har skrivbar ärvd `text` (formaterad text); `plainText` är read-only men det hindrar INTE skrivning via `lyrics.text`. Tidigare cookbook-påstående om att Lyrics måste återskapas är felaktigt och har rättats.
- Körningskod/loggar i `/tmp/musescore-normalize-text.js`, `/tmp/musescore-normalize-preview.json`, `/tmp/musescore-normalize-applied.json`.

## Tillägg 2026-10-29 — Harmony-stöd implementerat och liveverifierat

- `getScore` har nu additivt `measures[].harmonies`, separat från noter och `numElements`. Läser segmentens Harmony-annotations en gång över hela partituret (även positioner där staff 0 saknar not).
- Actions via `processSequence`: `getHarmonies {staff?, startTick?, endTick?}` och `setHarmony {staff, startTick, text, voice?, harmonyType?, index?}`. `setHarmony` uppdaterar eller skapar vid exakt position, ett undo-steg, rollback vid undantag. Kräver index vid flera symboler på samma track/tick. Nya symboler kräver befintlig chord/rest-position. Ingen borttagning/fretboard-harmony i denna leverans.
- `processSequence` har additivt `results` (varje actions returvärde), så filtrerade läsresultat når MCP-klienten.
- `server.py` har TypedDict-scheman för båda actions. Fortfarande 7 verktyg, ren brygga och `allowEval: false`.
- Automatiskt verifierat: `node dev/harmony-test.js` **6/6 grönt**, GraalPy laddar alla 7 MCP-verktyg och båda nya actions i schemat, Python syntaxkontroll samt `git diff --check` grönt.
- Liveprov **GRÖNT** efter användarens omstart: `venv/bin/python dev/harmony-live-test.py --write`. Läste 20 ackordsymboler (takt 2–21), `getScore` och `processSequence.results` överensstämmer; ändring + undo, skapa slashackord + undo och avvisad ogiltig exakt position verifierade. Hela partitur-JSON återställt efter varje skrivprov. Kör utan flagga för endast läsning.
- Repo-pluginen är kopierad till `~/Documents/MuseScore4/Plugins/musescore-mcp-plugin.qml` och den uppdaterade koden körs efter omstart. Ändringar ej committade.
- Docs: `docs/ACTIONS.md`, README. Native API kontrollerat mot v4.7.5-källan: Harmony har skrivbar `text` och `harmonyType` genom EngravingItem. Sätt text först EFTER `cursor.add`, eftersom native Harmony-parsern behöver parent-segment.

## AKUELLT LÄGE 2026-10-29 — flerstämmighetsbugg fixad och verifierad — läs detta först

**En verklig plugin-bugg är åtgärdad och runtime-verifierad på ett fyrstämmigt partitur.** Diffen är ännu inte commit:ad (`musescore-mcp-plugin.qml`, +19/−11). Committa när användaren ber om det.

- **Symptom**: `get_score` rapporterade bara staff 0; stämmorna 1–3 kom med som tomma. Användaren hade rätt ("det finns noter i alla stämmor"). `getVoices` och `voiceRangeSnapshot` hade samma bugg.
- **Rotorsak**: i cursor-vandringen anropades `cursor.rewind(0)` *innan* `cursor.staffIdx`/`cursor.voice` sattes. I MuseScore 4.7.x positionerar `rewind(SCORE_START)` inom *nuvarande* spår (`setSegment(firstMeasure->first(filter))` + `nextInTrack()`; `nextInTrack()` går till första segmentet med element i aktuellt track — källa: `src/engraving/api/v1/cursor.cpp`, tag v4.7.5). `setStaffIdx`/`setVoice` ändrar bara track, aldrig segmentet — positionen var alltså redan låst till staff 0/röst 0 när staven sattes. Dessutom låg `numElements++` utanför `if (element)`: 15 fantom-iterationer per takt (en per övrig staff/röst-kombination, `element == null`) blåste upp takt 1:s `numElements` till 16.
- **Fix** (tre ställen: `getScoreSummary` ~rad 1924, `getVoices` ~rad 724, `voiceRangeSnapshot` ~rad 771): **en ny, oberoende cursor per staff/röst** (`inputStateMode = INPUT_STATE_INDEPENDENT`), där track sätts (`staffIdx`, `voice`) **före** `rewind(0)`. `numElements++` nu inuti `if (element)`.
- **Verifiering** (MuseScore 4.7.6, "Så mörk är natten.mscz": 21 takter, 4 stämmor Sopran/Alt/Tenor/Bas, 3/4, F-dur, en-slags uppslagstakt): `get_score` läser nu alla fyra stämmorna. Takt 1 = 4 element (uppslagston i varje stämma: Sopran A4, Alt A4, Tenor A3, Bas A3); takt 21 = 4 element (slutackord: Sopran F4, Alt A3, Tenor A3, Bas F2). Noter per stämma: Sopran 49, Alt 52, Tenor 51, Bas 50. Full JSON (119 771 tecken) finns sparad i sessionens tool-results.
- **Operativ gotcha (viktig!)**: MuseScore läser plugin-QML **en gång per process**. Att köra om pluginet i samma session laddar INTE ändrad kod. Verifiera via sessionsloggen `~/Library/Application Support/MuseScore/MuseScore4/logs/MuseScore_YYMMDD_HHMMSS.log` — leta efter `action://extensions/v1/musescore-mcp-plugin.qml?action=main` (en dispatch per verklig inläsning). Efter en plugin-ändring: Cmd+Q MuseScore, starta igen, öppna partituret, Plugins > MuseScore API Server, och anropa `connect_to_musescore` på nytt (den gamla WebSocket:en dör vid omstarten).
- **Känt, benignt, pre-existing**: `getScoreSummary`'s reset-block gör `curScore.selection.select(cursor.element)` med ett Chord → MuseScore loggar `Selection::select | Cannot select element of type Chord` (urvalet ändras inte; harmlöst). Åtgärda inte opåkallat.

### Installationsläge för denna användare (2026-10-29)

- venv: `<REPO>/venv`, byggd med **GraalPy 3.12.8** (`~/.local/bin/graalpy`) — systemets CPython är 3.9.6, för gammal för `mcp>=1.2.0,<2` (kräver ≥3.10). Server-sanity: 7 verktyg. GraalPy-shimmen i server.py behövs. (Äldre `cenv/` är supersederat.)
- Vibe-registrering: `vibe mcp add musescore --transport stdio --command <REPO>/venv/bin/python --arg <REPO>/server.py` — verktygen fungerar i pågående session.
- Plugin installerad i `~/Documents/MuseScore4/Plugins/musescore-mcp-plugin.qml`, **identisk med repo-kopian (fixen inkluderad)**. `allowEval: false` — `run_qml` är avstängd; aktivera bara på användarens uttryckliga begäran.
- MuseScore **4.7.6** (build 261022093).
- Öppet partitur: "Så mörk är natten.mscz" (`~/Documents/Noter/`). Efter varje plugin-omstart: anropa `connect_to_musescore` igen.

## AKUELLT LÄGE 2026-10-23 (sent)

**Alla planerade faser är genomförda och runtime-verifierade:**
- Ren brygga (F28), 7 verktyg: helhetstest GRÖNT 10/10 (`dev/bridge-smoke-test.py`: röst-census, verifierad röstväxling, verifierad undo, runCode-grind, processSequence).
- run_qml GRÖNT 8/8 (`dev/run-qml-test.py`: eval, ctx-fasad + consoleLog, ctx.processCommand, beständig state — överlever t.o.m. pluginomstarter —, rollback vid kast, committad mutation + undo, cookbook-traversering). Runtime-fakta i cookbooken: `addNote` på belagd position ERSÄTTER noten (verifiera pitch, inte antal).
- setInstrumentSound/mixern empiriskt verifierad på ett ryskt nedladdat partitur: alla fem spårnamn till svenska (Сопрано→Sopran, Альт→Alt, Тенор→Tenor, Бас→Bas, Орган→Orgel), instrument/noter/klang bevarade. Mixern uppdaterar först när partituret sparats, stängts och öppnats igen — inte realtid, inte mixer-omstart.
- GraalPy-stöd (användarens default-python): pydantic-NameError-shim + klassiskt alias i stället för PEP 695 i server.py; **mcp är spärrat `>=1.2.0,<2` i requirements.txt — ta inte bort spärren** (mcp 2.x byter namn på FastMCP till MCPServer). Verifierat: GraalPy 25.0 startar servern och registrerar alla verktyg; CPython-regression grön.
- Agent-självinstallation: `docs/INSTALL-PROMPT.md` (prompt till agenten) + flervärds-tabell i README. Möjligt i alla värdar (Vibe: `vibe mcp add --transport stdio`, Codex: `codex mcp add`, Claude Desktop: config-JSON + full omstart, Claude Code: `claude mcp add`, Copilot/VS Code: `.vscode/mcp.json`). **Användarens Vibe har redan en fungerande registrering** (post "MuseScore" i ~/.vibe/config.toml, cenv-python + server.py — aktuell, registrerar dagens 7 verktyg).

Projektets kvarvarande backlog (medvetet uppskjutet, se ARBETSPLAN "Efter fas 3"):
- Atomisk processSequence (ett undo-steg för hela batchen) — kräver refactor av alla actions till apply/commit-par + runtime-verifiering.
- Kuratering av återkommande run_qml-uppgifter till stabila actions (F20) — efter verklig användning (användarens egna plugin CopyLyrics.qml, FillRepeatedLyrics.qml, CantaiSvengelska/Tyska är naturliga första kandidater).
- Ev. röstnavigerings-förbättringar (F3:S "ingen state-full röstnavigering" kan omprövas om agenterna visar behov).

Kända runtime-fakta: se tabellen i VERIFIERINGSRESULTAT.md (V1–V21). Viktigast: swap = `cmd("voice-x12")`, undo = versionsmedveten (`action://notation/undo` ≥4.7 via `mscoreMajorVersion`), eval fungerar, `setVoiceVisible` returvärdet oanvändbart, **FileIO-skrivningar blockeras (apiv1::isPathAllowed + macOS /private-kanonisering) — använd aldrig FileIO i plugin**, delete via cmd assertar (deleteSelection verifierar ärligt), console.log från meny-körda plugins kastas bort (använd api.log.info + MuseScores loggfil). **Tillagt 2026-10-29:** (a) cursor-vandring över flera stämmor — sätt track (`staffIdx`/`voice`) **före** `rewind(0)`, helst med en ny oberoende cursor per staff/röst (`rewind` positionerar inom nuvarande track); (b) plugin-QML läses **en gång per MuseScore-process** — efter plugin-ändring krävs Cmd+Q + omstart + plugin-start, verifiera via sessionsloggen i `~/Library/Application Support/MuseScore/MuseScore4/logs/`; (c) `Selection::select` på ett Chord loggar ett fel men ändrar inte urvalet (benignt).

## Uppdrag och upphov

Behåll Python-servern (`server.py`, FastMCP/mcp 1.30.0). Utöka plugin och server med tre kapabiliteter:

1. **Röster**: läs/navigera/skriva i flera understämmor per system, inklusive röstväxling och synlighet.
2. **Server = ren brygga** (ursprungligen music21-analys; **supersederat av beslut F28 2026-10-23**: ingen music21, ingen partiturfils-export — MusicXML-tur och retur förkastas, music21:s beroendebörda togs bort).
3. **run_qml**: agenten skickar godtycklig QML/JS-kod som exekveras in-process i MuseScore — för komplexa uppgifter som är dyra att styra stegvis över MCP (upphovet: användaren har upprepade gånger bett agenter skriva QML-plugins för specifika uppgifter, t.ex. kopiera sångtext, transformera text, skapa pianoreduktion).

Långsiktigt mål: MCP ska, så långt rimligt, kunna utföra allt MuseScore-GUI erbjuder.

## Miljö och givna fakta

- Installerat: **MuseScore 4.7.6** (build 261022093; tidigare verifierat på 4.7.5 — mekanismerna är desamma) (`/Applications/MuseScore 4.app`).
- Källkollning `../MuseScore` är **dev-main (efter 4.7)** — bra för mekanismförståelse, men action-koder skiljer sig (se nedan). Ändra inget i utcheckningen.
- Plugin-API (verifierat i källan, `src/engraving/api/v1/`):
  - `Cursor.voice` (skriv/läs, track % 4, dvs. röster 0–3 per staff), `Cursor.staffIdx`. Pluginet accepterar redan `params.voice` i `createCursor` (rad 211 i musescore-mcp-plugin.qml) men inget annat använder det.
  - `Score.setVoiceVisible(staff, voiceIndex, visible)` — score.h:697.
  - `writeScore(score, name, ext)` — qmlpluginapi.h:537 / engravingapiv1.h:290. **Omtvistat: returnerar tyst false på 4.7.5** (enda lyckade utskrift i körning 1 av fas 0); lämnat ouppklarat och oaktuellt per F28.
  - `PluginAPI::cmd(s)` — qmlpluginapi.h:534. Action-koder är versionsberoende: swap = `voice-xNN`, undo = `action://notation/undo` på ≥4.7 (läs av `mscoreMajorVersion`/`mscoreMinorVersion`), delete assertar internt (Score::deleteRange).
  - FileIO i util.h — **blockeras av säkerhetsskiktet** (`apiv1::isPathAllowed`; tillåtna kataloger + macOS /private-kanoniseringsbugg) och förgiftar sessionen: använd aldrig FileIO i plugin.
  - Ingen `dirty`/`saved`-egenskap i score-API:t. runCode har ingen fil-backup; skyddet är ett undo-steg (rollback vid fel, ångra med undo-kommandot).
  - Röstväxling implementeras i C++ som `ExchangeVoices::exchangeVoicesInSelection` (`src/engraving/editing/exchangevoices.cpp`) — agerar på aktuellt urval, hanterar alla annex korrekt. INTE exponerat som API — nås via `cmd()`.
- **Kommandokoder för röstväxling** (F9, try-lista, logga vilken som tog):
  - 4.7.5 (binärsträngar verifierade med `strings`): `voice-x12`, `voice-x13`, `voice-x14`, `voice-x23`, `voice-x24`, `voice-x34`.
  - dev-main: `command://notation/swap-voice-xNN`.
  - Även i binären: `voice-1`…`voice-4` (inmatningsröst), `voice-assignment-all-in-staff/instrument` — framtidsmaterial.
- Ingen precedent i MuseScores egna QML för `eval`/`Qt.createQmlObject` — runtime-verifiering krävs (fas 0).
- Ingen watchdog in-process: eval körs på GUI-tråden; oändlig loop fryser MuseScore oåterkalleligt. Kan inte tekniskt skyddas — endast dokumenteras (agentdisciplin).
- Python-miljö: `<REPO>/venv` (GraalPy 3.12.8) med mcp 1.30.0 + websockets 17.3 — music21 är borttaget per F28. mcp har WebSocket-klient (`mcp.client.websocket`, deprecated men funktionell).
- MCP-semantik att bevara (server.py kör FastMCP): dict-resultat → `content:[{type:"text", text:<JSON>}]` + `structuredContent`, `isError:false`; kast/okänt verktyg → `isError:true` med meddelandetext; kuvert `{status:"success"|"error", ...}` från pluginet bevaras.

## Avgjorda beslut (F1–F27)

| # | Beslut |
|---|---|
| F1 | QML-migrering avskedad som huvudspår; designa protokollneutralt. Referensmaterial för eventuell återkomst: `.ai/serverless-mcp/` (brief + machbarhetsrapporter från Vibe och Codex). |
| F2 | Röster: läs + navigera + skriva, inkl. röstväxling mellan godtyckliga röster och synlighet. |
| F3 | `voice`-parameter genomtrådad i befintliga actions + nya läs/actions; ingen state-full röstnavigering. |
| F4 | Röstoperationer exponeras enbart via processSequence, inga nya MCP-röstverktyg i v1. |
| F5 | Hybrid är standard för analysverktyg; stateless teorifrågor är agent-/parametermatade. |
| F6 | Tre music21-verktyg: analyze_key, harmonic_analysis, music_theory_query. |
| F7 | Strikt additiv kompatibilitet: inga fält byter namn eller tas bort. |
| F8 | swapVoices: default intervall = current selection; endast växelpär i v1. |
| F9 | Try-lista för kommandokoder + loggning; ingen tyst fallback. |
| F10 | GUI-paritetsregel: cmd() endast för urvalsbaserade, dialogfria, deterministiska kommandon. Explode/Implode v2. |
| F11 | getVoices: census per staff default, per takt på begäran; voice+staffIdx i elementutdata; selectionState.voice; inga getScore-filter i v1. |
| F12 | Synlighet endast per staff/röst (staff-egenskap). |
| F13 | exportScore: server-genererad absolut tempfile-path, ingen cache, heltpartiturexport, servern skär per takt. |
| F14 | Källor åtskilda per verktyg i v1: analyze_key/harmonic_analysis = endast partitur; music_theory_query = endast parametrar. |
| F15 | Verifierings-plugin först (fas 0), innan all implementation. |
| F16 | Godtycklig kodkörning godkänd med skyddspaket: opt-in (av default), .mscz-backup, kodstorleksgräns, localhost-dokumentation. |
| F17 | eval()-JS i v1; Qt.createQmlObject v2. Båda verifieras i fas 0. |
| F18 | Kontrakt: kod = funktion(ctx, params, state) → JSON; startCmd/endCmd/rollback; svar {status, result, consoleLog}; persistent state mellan anrop. |
| F19 | Agentcookbook ingår: snabbreferens + tre mönsterexempel (sångtext, texttransformation, pianoreduktion). Kort. |
| F20 | Eval först; kuratering av återkommande uppgifter sker i efterhand baserat på användning. |
| F21 | run_qml som toppnivå-MCP-verktyg (inte processSequence); opt-in-styrt med instruktionsfel; körningar loggas i plugin-konsolen. |
| F22 | Fyra nya toppnivå-verktyg: run_qml, analyze_key, harmonic_analysis, music_theory_query. exportScore är intern action, ej MCP-verktyg. |
| F23 | ActionSequence-unionen utökas additivt (nya actions + voice i befintliga TypedDicts). |
| F24 | testClient.html: minimal utökning (röstväljare, knappar, param-textarea, eval-textarea). |
| F25 | Dokstruktur: README kort + docs/AGENT-COOKBOOK.md + docs/ACTIONS.md. |
| F26 | Opt-in via QML-egenskap `allowEval` i plugin-filen; kan ej påverkas av agenten. |
| F27 | Verifieringsplugin sparas i dev/ som regressionstest; en commit per fas på main. |
| F28 | **(2026-10-23, efter mcp-score-analysen)** Ingen music21 i servern — servern är en ren brygga till pluginet. Export/import av MusicXML förkastas medvetet (tur och retur förvränger partituret); `analyze_key`, `harmonic_analysis`, `music_theory_query` och `exportScore` är borttagna. Säkerheten för runCode = ett undo-steg (rollback vid fel; committad körning ångras med undo-kommandot) — ingen fil-backup. Ev. framtida musikteoretisk funktionalitet skall ligga i pluginet (run_qml eller actions), aldrig via partiturfils-export. |

## Kontraktsspecifikation (implementationens sanning)

Nya plugin-actions (alla följer befintligt kuvert `{status:"success"|"error", ...}`):

```
getVoices           {staff?, startTick?, endTick?}   → census: per staff, röster 0–3 {hasContent, visible, firstMeasure, lastMeasure}
swapVoices          {voice1, voice2, startStaff, endStaff?, startTick?, endTick? | measure?}
                    → selectRange + cmd(<try-lista>) + syncStateToSelection; default intervall = current selection
setVoiceVisibility  {staff, voice, visible}         → Score.setVoiceVisible
exportScore          {path, format:"musicxml"|"mscz"} → writeScore(curScore, path, format); path = absolut, server-genererad
runCode              {code, params}                  → endast om allowEval; se kontrakt nedan
```

Additivt i elementutdata: `voice` (0–3), `staffIdx`. `selectionState` får fält `voice`.

`runCode`-kontraktet:
- Plugin: `.mscz`-backup till temp → `startCmd` → exekvera `code` som funktion(`ctx`, `params`, `state`) → `endCmd` (rollback vid undantag; ett undo-steg).
- `ctx`: dokumenterad fasad — `curScore`, `newCursor`, `processCommand`, läshjälpmedel, FileIO (dokumenterat som risk).
- `state`: beständigt objekt mellan runCode-anrop (agentens anteckningsutrymme för fortlöpande styrning).
- Retur: JSON-serialiserbart objekt. Svar till server: `{status, result|error, consoleLog}`.
- Kodstorleksgräns ~100 kB. Logga per körning: kodradslängd, paramantal, status.

Nya MCP-verktyg (server.py, snake_case, separata toppnivåverktyg):

```
run_qml             {code, params?}                              — opt-in-styrd; beskrivning pekar på cookbook
analyze_key         {}                                          — exporterat partitur → tonart (global + per del)
harmonic_analysis   {measure_start?, measure_end?}              — chordify → ackord + romerska tal per takt
music_theory_query  {query: {type: "interval"|"chord"|"scale", ...}}  — stateless
```

## Öppna punkter som bara fas 0 kan besvara

1. fungerar `cmd("voice-x12")` i 4.7.5 (och bekräftar getScoreSummary faktisk växling)?
2. fungerar `writeScore` med ext `musicxml` och `mscz` från plugin, och var får det skriva?
3. finns `eval` och `Qt.createQmlObject` i plugin-QML-motorn?
4. läsbarhet/tillstånd för `cursor.voice` över flera röster.
5. `setVoiceVisible` returbeteende.

Resultat dokumenteras i `.ai/VERIFIERINGSRESULTAT.md` (skapas i fas 0).

## Medvetna risker (godkända av användaren)

- eval: evig loop fryser GUI oåterkalleligt; QML-fel stoppar pluginet (endpoint dör); elementmissbruk kan krascha MuseScore (kända fallgropar: ties/barlines via element-API:t); kod har full FS-åtkomst. Skydd: opt-in, backup, storleksgräns, dokumentation.
- cmd()-koder är versionsberoende (try-lista + dev/-regressionstest vid uppgradering).
- WS-endpoint har ingen auth; binds förmodligen alla interface (dokumenteras; samma exponering som befintlig brygga).

## Hur man fortsätter

1. Läs `ARBETSPLAN.md`. Fasordning: 0 → 1 → 2 → 3, en commit per fas på main.
2. Fas 0 körs mot installerat MuseScore 4.7.5 med ett testpartitur (två röster i en staff) via Plugins-menyn; utdata via console.log i MuseScores plugin-konsol (starta MuseScore från terminal för synlig logg).
3. `cenv/` har alla python-beroenden; `testClient.html` för manuell test av plugin-actions.
4. Ändra inget i `../MuseScore`. MuseScore-pluginet (`musescore-mcp-plugin.qml`) installeras i `~/Documents/MuseScore4/Plugins/` — håll repo och installerad kopia synkade vid varje fasbyte.
5. Bortglömda avgöranden ska inte tyst antas — fråga användaren; faktumfrågor undersöks i källan/binären först.
