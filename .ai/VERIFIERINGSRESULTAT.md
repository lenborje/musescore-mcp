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

## Öppna frågor inför körning 2 (plugin v0.2)

1. T1: `eval` + funktionsuttrycksmönstret (kritiskt för run_qml).
2. T2: `Qt.createQmlObject`.
3. T3: `cmd`.
4. T4: `cursor.voice` läsning per röst (0→60, 1→64 väntat).
5. T5: `setVoiceVisible` returvärde.
6. T6: `writeScore` mscx (mscz konstaterat trasigt, musicxml fungerar).
7. T7: vilken swap-kommandokod som fungerar (`voice-x12` väntas i 4.7.5).
