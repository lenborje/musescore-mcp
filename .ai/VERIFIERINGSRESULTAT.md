# Verifieringsresultat fas 0 — STÄNGD 2026-10-23

Status: **avslutad.** Samtliga runtime-frågor som projektet behöver svar på är besvarade (V1–V21 nedan); den enda olösta frågan (writeScore:s tysta false) är oaktuellt per beslut F28 och lämnad dokumenterad utan lösning. Regressionssviten `dev/verify-voices.qml` (v0.4) körs vid MuseScore-uppgraderingar för att omverifiera: röstväxling (`voice-x12`), undo (`action://notation/undo` på ≥4.7 via versionsavkänning), cursor.voice och baseline-state.

**Helhetstest 2026-10-23 11:10: 10/10 GRÖNT** (`dev/bridge-smoke-test.py` mot öppet testpartitur med den F28-baserade pluginen): ping, getScoreMetadata, getVoices-census, baslinje-pitchläsning (elementens voice+pitchMidi), **swapVoices(0,1) med verifierad röstväxling**, **undo med verifierad återställning**, runCode:s allowEval-grind, processSequence-batch. Probe `"Unknown command: exportScore"` bekräftar att F28-pluginfilen (ren brygga) är den körande.

Körs mot MuseScore 4.7.5 (`/Applications/MuseScore 4.app`). Metod: `dev/verify-voices.qml` mot `dev/test-voices.mscz` (movementTitle "MCP verify test"), utdata via api.log + MuseScores loggfil (console.log från meny-körda plugins kastas bort; FileIO är förbjudet i plugin — blockerat + förgiftar sessionen).

## Körning 1 — 2026-10-22 16:08 (plugin v0.1, partiell utdata)

Pluginet körde (dispatchad som `action://extensions/v1/verify-voices.qml?action=main`) men producerade ingen läsbar utdata via console.log. Följande kunde ändå fastställas:

| # | Faktum | Konsekvens |
|---|---|---|
| V1 | **`writeScore` musicxml fungerar från plugin**: `/tmp/mcp-verify-export.musicxml` skapades, 5961 byte. Filändelsen läggs till av `writeScore` själv (namn utan ändelse + ext-parameter). | `exportScore`-designen är korrekt; serverns music21-export fungerar. |
| V2 | **`writeScore` mscz är trasigt från plugin**: 0-byte fil + `WARN MscNotationWriter::writeList \| Not supported!!` i loggen. | `runCode`-backupen (.mscz) måste byta format — mscx/musicxml testas i körning 2. |
| V3 | **`console.log` kastas bort** när plugin körs från Plugins-menyn (inga [MCP-VERIFY]-rader i loggen). | Verifieringen skriver nu till `/tmp/mcp-verify-result.txt` via FileIO + `api.log.info` (`MuseApi.Log` finns i 4.7.5-binären). |
| V4 | **`Qt.quit()` stänger inte appen** (MuseScore lever, testpartituret kvar). En QML-varning i MuseScores egen ButtonBox.qml uppträdde strax efter — sannolikt en dialog för att partituret blivit "dirty" av testernas committed ändringar. | `Qt.quit()` borttaget ur verifieringen. |
| V5 | T1–T5 och T7 gav ingen utdata i körning 1 (kanalen saknades) — **okända, väntar på körning 2**. | — |

## Körning 2 — 2026-10-22 16:15 (plugin v0.2, komplett utdata via api.log)

| # | Faktum | Konsekvens |
|---|---|---|
| V6 | **T1 eval: fullständigt fungerande.** `typeof eval = "function"`, aritmetik, funktionsuttrycksmönstret (`eval("(function(a){...})")` + anrop) och scope-åtkomst (`eval("ctx.x")`) fungerar. | `run_qml`-designen (F17/F18) är bekräftad genomförbar. |
| V7 | **T2 `Qt.createQmlObject` misslyckas**: "QtObject is not a type" (inga imports tillåts i strängen; typen kan inte resolveras). | F17:s val av eval som primär mekanism var rätt; createQmlObject kräver speciallösning om det någonsin behövs. |
| V8 | **T3 `cmd` finns** (function). | – |
| V9 | **T4 `cursor.voice` fungerar**: voice0=60, voice1=64 med `INPUT_STATE_INDEPENDENT`. | Röstaffärd i fas 1 fungerar. |
| V10 | **T5 `setVoiceVisible` returnerar false** vid alla anrop (även när värde borde ändras) — returvärdet är oanvändbart på 4.7.5; inget undantag kastas. Tillämpning okänd. | `setVoiceVisibility` får inte lita på returvärdet. |
| V11 | **T6 `writeScore` till /tmp misslyckades** (false i alla tre format, <1 ms = tidig avvisning) — samtidigt som FileIO-skrivningar till /tmp **blockerades** av säkerhetsskiktet (`apiv1::isPathAllowed`): tillåtna kataloger är MuseScore4-datadirs + **per-user temp (/var/folders/.../T)**. Körning 1 (utan FileIO) kunde skriva musicxml till /tmp — hypotes: blockerad FileIO-skrivning förgiftar sessionen för efterföljande exports. | Alla plugin-filskrivningar ska ske i per-user temp (`FileIO.tempPath()`); serverns `tempfile.gettempdir()` = samma katalog på macOS. Backup i runCode bytt till musicxml + tempPath. |
| V12 | **T7 röstväxling fungerar via `cmd("voice-x12")`** — primära try-listkoden bekräftad; växlingen verkställd (voice0=64, voice1=60). | Fas 1:s swapVoices-design fungerar på 4.7.5. |
| V13 | **`cmd("undo")` är en no-op**: `ActionsDispatcher::dispatch | not a registered action: undo`. Main-pluginets `undo()` har alltså varit tyst trasigt på 4.7.5. Binären har `action://undo` och `action://delete` som action-URI:er. | `undo()` ändrad till `cmd("action://undo")` (bekräftas i körning 3); `deleteSelection` avvaktar T8. |

## Körning 3 — 2026-10-22 16:25 (plugin v0.3, komplett utdata via api.log)

| # | Faktum | Konsekvens |
|---|---|---|
| V14 | **T7: `action://undo` fungerar** — växlingen ångrades korrekt (60/64 återställda). Ärvda `undo` förblev no-op. | Main-pluginets `undo()`-fix (`cmd("action://undo")`) bekräftad korrekt. |
| V15 | **T7: swap via `voice-x12` bekräftad igen** (andra körningen). | swapVoices stabil på 4.7.5. |
| V16 | **T6: writeScore misslyckades även i tillåten temp-katalog** — rotorsaken synlig i loggen: macOS kanoniserar `/var/folders/...` till `/private/var/folders/...`, som inte matchar tillåtelselisten. Dessutom lyckades den **första** FileIO-skrivningen och blockerades sedan — och körning 1 (inget FileIO) kunde skriva till `/tmp` som inte ens är i listan. Slutsats: FileIO-skrivningar förgiftar sessionen; writeScore själv kontrollerar sökvägen bara i förgiftat tillstånd. | **FileIO avlägsnats ur alla plugin.** Export/backup sker nu till `~/Documents/MuseScore4` (riktig sökväg utan symlänkar, i tillåtelselisten), angiven av servern (`MUSESCORE_MCP_DATA_DIR`). |
| V17 | **T8: båda delete-koderna dispatchar men `Score::deleteRange` assertar** (edit.cpp:3970, "s1") — raderingen avbröts, inget togs bort, MuseScore kraschade inte. `action://delete` är registrerad; problemet är rå `selectRange` vs notationens selection-tillstånd. | `deleteSelection` omskriven till ärlig verifiering (jämför elementantal före/efter, rapporterar `deleted: true/false`). Känd begränsning dokumenterad i ACTIONS.md. |

## Körning 4 — 2026-10-22 16:30 (plugin v0.4, utan FileIO)

| # | Faktum | Konsekvens |
|---|---|---|
| V18 | **T7-regression grön**: swap via `voice-x12` + `action://undo` fungerar stabilt (tredje bekräftelsen; `action://undo` dispatchar internt vidare till `action://notation/undo`). | Roststödet och undo är klara. |
| V19 | **T6 misslyckades även utan FileIO och i tillåten katalog** — tyst false (<1 ms), inga varningar i loggen. | Förgiftnings- och sökvägshypoteserna räcker inte. |
| V20 | **Timingmönster**: writeScore lyckades enbart i körning 1 — den enda som kördes 67 s efter sessionens start; körning 2–4 kördes 11–35 s efter start och misslyckades. MuseScores async-uppstart (MuseSampler-uppdateringskoll ~5–8 s in i sessionen, projekt-/exportscenario-initiering) var sannolikt fortfarande igång. Hypotes: `exportScores()` avböjer tyst medan uppstartsuppgifter pågår. | Avgörande test: kör v0.4 oförändrad **minst 60 s efter** att MuseScore startat (och partituret öppnats). Om T6 då lyckas: rotorsak = startrace; åtgärd = serverside retry + dokumentation. |

## Körning 5 — 2026-10-22 16:35 (plugin v0.4, ≥60 s väntan efter start)

| # | Faktum | Konsekvens |
|---|---|---|
| V21 | Väntan hölls (session 16:34:31 → plugin 16:35:53 = 82 s). **T6 misslyckades fortfarande** (tyst false, alla format, ingen fil skapad). T7-regression grön. | Timing-hypotesen (V20) är död. Körning 1 är det enda framgående fallet någonsin. |

## Källanalys efter körning 5 (v4.7.5-taggen i ../MuseScore — OBS: 4.7.x var monorepo, io-lagret fanns i huvudrepot då)

- `EngravingPluginAPIHelper::writeScore` (v4.7.5, src/project/internal/engravingpluginapihelper.cpp): `currentNotation()` null → LOGW (frånvarande i loggarna ⇒ notation fanns); `determineWriterUnitType(ext)` null → LOGW "format is not supported" (frånvarande ⇒ writer finns); annars `exportProjectScenario()->exportScores(...)`.
- `ExportProjectScenario::exportScores` (src/project/internal/exportprojectscenario.cpp): tysta/tidiga utgångar: (1) `writers()->writer(suffix)` null → **tyst false**; (2) supportsUnitType-assert (skulle logga "ASSERT FAILED" — frånvarande); (3) `doExportLoop`-retur Cancel → tyst false.
- `doExportLoop`: filöppning misslyckas → `askForRetry` (dialog — i pluginkontext kan dialogen inte visas/dotto; körning 1:s ButtonBox-fel var sannolikt en sådan dialog) → Cancel. Writer-fel EFTER lyckad öppning ger en **tom fil** (körning 1:s mscz: 0 byte + MscNotationWriter-varning — den vägen är bevisad). I körning 2–5 finns **inga filer alls** varken tomma (kontrollerat /tmp, /var/folders/…/T och ~/Documents/MuseScore4) ⇒ antingen misslyckades öppningen (QFile::open) eller nåddes aldrig doExportLoop.
- 4.7.5:s io-lager (src/framework/global/io/internal/filesystem.cpp): `openStream` är ett naket `QFile::open` — **ingen sökvägsrestriktion i io-lagret** i 4.7.5 (restriktionen "fs api restriction" tillkom i muse_framework först sep 2026, efter 4.7.5; 4.7.5 har bara apiv1::isPathAllowed som vaktar FileIO-API:t).
- Slutsats: den tysta false kommer från `exportScores` — mest sannolikt `writers()->writer(suffix)`-utgången eller en Cancel från doExportLoop — men källan till det kan inte avgöras statiskt; skillnaden mot körning 1 är okänd. Kvarvarande observation: körning 1 (67 s efter start, v0.1, /tmp) är det ENDA fallet där writeScore exekverat en writer.

## Nästa steg (påbörjat, avbröts vid dagens slut)

1. ** Hämta tskovlund/mcp-scores plugin-källkod** (src/mcp_score/musescore + bridge, GitHub): deras live-plugin-CI är grön på 4.7.5 — deras sätt att få ut partiturdata (writeScore? readScore? helt annat?) är den snabbaste vägen till ett fungerande mönster. Web-hämtningen av deras katalogstruktur påbörjades men avbröts.
2. Om writeScore förblir trasigt — plan B (redan identifierad i F5/F11): music21-ström byggs server-side ur getScoreSummary-JSON (förlustig men genomförbar), och runCode-backup ersätts med server-side JSON-snapshot före/efter (faktiskt bättre för diff).

## Slutsats 2026-10-23 (beslut F28)

**writeScore-mysteriet avslutas oaktuellt utan lösning.** Efter beslutet att servern skall vara en ren brygga (F28: ingen music21, ingen partiturfils-export) kräver ingen funktion fil-export från pluginet. Faktumet kvarstår dokumenterat: `writeScore` från plugin returnerar tyst false på 4.7.5 i alla testkörningar utom körning 1, oavsett sökväg (tillåten eller ej), FileIO-inblandning och väntetid efter start. Återupptas endast om en framtida funktion verkligen behöver export — och då först med en reproducerbar setup.

## Slutsatser för implementationen (efter körning 1-3)

- Röster: fullt fungerande (cursor.voice, element.voice, swap via `voice-x12`, `action://undo`).
- run_qml: eval bevisat fungerande; kontraktet håller.
- Filskrivningar: enbart via `writeScore` till `~/Documents/MuseScore4`; ingen FileIO i plugin; mscz-writer trasig från plugin (0-byte + "MscNotationWriter::writeList Not supported"), musicxml fungerar.
- `setVoiceVisible`: returvärde falskt men anropet kastar inte — rapportera `success: true` utan att lita på returen.
- `deleteSelection`: ärlig verifiering; radering via cmd opålitlig på 4.7.x.
- Opt-in (`allowEval`), try-lista för swap-koder och `action://`-koder: implementerade enligt ovan.
