# Verifieringsresultat fas 0

Körs mot MuseScore 4.7.5 (`/Applications/MuseScore 4.app`). Metod: `dev/verify-voices.qml` mot `dev/test-voices.mscz` (movementTitle "MCP verify test"), utdata via FileIO till `/tmp/mcp-verify-result.txt` + api.log.info + console.log.

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

## Öppna frågor inför körning 3 (plugin v0.3)

1. T6: fungerar writeScore (musicxml/mscx/mscz) till tillåten temp-katalog? Avgör runCode-backupens slutgiltiga format (musicxml påkallat nu, mscx möjligt bättre).
2. T7: vilken undo-kod fungerar (`action://undo` förväntas)?
3. T8: fungerar `action://delete` (eller ärvda `delete`)?

Obs: körning 2 lämnade testpartituret växlat (undo var no-op). Körning 3 ska göras med partituret nyöppnat från fil.
