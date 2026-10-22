# Handoff: musescore-mcp — röster, music21, run_qml

Dokumentet är sessionsöverskridande kontext. Läs detta + `ARBETSPLAN.md` + `VERIFIERINGSRESULTAT.md` innan du fortsätter arbetet.

## AKUELLT LÄGE 2026-10-22 (kväll) — läs detta först

Fas 0–3 är implementerade och committade (röster, music21-verktyg, run_qml + docs, se gitloggen). Fem verifieringskörningar har gjorts; **röster, undo, swap, eval och hela run_qml-mekaniken är bevisade fungerande på 4.7.5.** EN fråga är olöst och blockerar music21-kedjan:

**`writeScore` från plugin returnerar tyst `false`** för alla format och alla sökvägar (inkl. tillåtna kataloger) — utom i körning 1 där musicxml till /tmp faktiskt skrevs. Ingen förklaring kvar i källan (4.7.5:s io-lager är restriktionsfritt; se VERIFIERINGSRESULTAT.md, körning 5 + källanalys). Upphör INTE med att anta att writeScore fungerar — det är omtvistat.

Imorgon:
1. Hämta tskovlund/mcp-scores pluginkällkod från GitHub (src/mcp_score/musescore + src/mcp_score/bridge) — deras CI är grön på 4.7.5; efterlikna deras partiturdata-flöde.
2. Om deras mönster inte hjälper: implementera plan B — server-side music21-ström ur getScoreSummary-JSON, och server-side JSON-snapshot som runCode-backup (ersätter fil-backupen helt).
3. Stäng fas 0: dokumentera i VERIFIERINGSRESULTAT.md, uppdatera ARBETSPLAN-status.

Kända runtime-fakta (bevisade, styr implementationen): se tabellen i VERIFIERINGSRESULTAT.md (V1–V21). Viktigast: swap = `cmd("voice-x12")`, undo = `cmd("action://undo")`, eval fungerar, `setVoiceVisible` returvärdet är oanvändbart, FileIO-skrivningar blockeras (macOS /private-kanonisering vs allowlist) — **använd aldrig FileIO i plugin**, delete via cmd assertar (deleteSelection verifierar ärligt), console.log från meny-körda plugins kastas bort (använd api.log.info + MuseScores loggfil).

## Uppdrag och upphov

Behåll Python-servern (`server.py`, FastMCP/mcp 1.30.0). Utöka plugin och server med tre kapabiliteter:

1. **Röster**: läs/navigera/skriva i flera understämmor per system, inklusive röstväxling och synlighet.
2. **music21**: generella musikteoretiska verktyg i servern (koppling till plugin för partiturinhämtning).
3. **run_qml**: agenten skickar godtycklig QML/JS-kod som exekveras in-process i MuseScore — för komplexa uppgifter som är dyra att styra stegvis över MCP (upphovet: användaren har upprepade gånger bett agenter skriva QML-plugins för specifika uppgifter, t.ex. kopiera sångtext, transformera text, skapa pianoreduktion).

Långsiktigt mål: MCP ska, så långt rimligt, kunna utföra allt MuseScore-GUI erbjuder.

## Miljö och givna fakta

- Installerat: **MuseScore 4.7.5** (`/Applications/MuseScore 4.app`).
- Källkollning `../MuseScore` är **dev-main (efter 4.7)** — bra för mekanismförståelse, men action-koder skiljer sig (se nedan). Ändra inget i utcheckningen.
- Plugin-API (verifierat i källan, `src/engraving/api/v1/`):
  - `Cursor.voice` (skriv/läs, track % 4, dvs. röster 0–3 per staff), `Cursor.staffIdx`. Pluginet accepterar redan `params.voice` i `createCursor` (rad 211 i musescore-mcp-plugin.qml) men inget annat använder det.
  - `Score.setVoiceVisible(staff, voiceIndex, visible)` — score.h:697.
  - `writeScore(score, name, ext)` — qmlpluginapi.h:537 / engravingapiv1.h:290. Export av musicxml/mscz möjlig.
  - `PluginAPI::cmd(s)` — qmlpluginapi.h:534. Pluginet använder redan `cmd("delete")`. I dev-main dispatchas `muse::rcommand::Command(s)` rakt av (med kompattabell för äldre namn).
  - FileIO i util.h: `read()`, `write()`, `writeBinary()`, `remove()`, `tempPath()` osv. — plugins har full FS-åtkomst med användarens rättigheter.
  - Ingen `dirty`/`saved`-egenskap i score-API:t — "kräv sparat partitur"-grind går inte; `.mscz`-backup före riskfylld körning används istället.
  - Röstväxling implementeras i C++ som `ExchangeVoices::exchangeVoicesInSelection` (`src/engraving/editing/exchangevoices.cpp`) — agerar på aktuellt urval, hanterar alla annex korrekt. INTE exponerat som API — nås via `cmd()`.
- **Kommandokoder för röstväxling** (F9, try-lista, logga vilken som tog):
  - 4.7.5 (binärsträngar verifierade med `strings`): `voice-x12`, `voice-x13`, `voice-x14`, `voice-x23`, `voice-x24`, `voice-x34`.
  - dev-main: `command://notation/swap-voice-xNN`.
  - Även i binären: `voice-1`…`voice-4` (inmatningsröst), `voice-assignment-all-in-staff/instrument` — framtidsmaterial.
- Ingen precedent i MuseScores egna QML för `eval`/`Qt.createQmlObject` — runtime-verifiering krävs (fas 0).
- Ingen watchdog in-process: eval körs på GUI-tråden; oändlig loop fryser MuseScore oåterkalleligt. Kan inte tekniskt skyddas — endast dokumenteras (agentdisciplin).
- music21 10.5.0 + mcp 1.30.0 + websockets 17.3 installerade i `cenv/` (python 3.15). mcp har WebSocket-klient (`mcp.client.websocket`, deprecated men funktionell).
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
