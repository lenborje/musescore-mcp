#!/usr/bin/env python3
"""Assign mixer sound presets (e.g. Cantai 'Ottetto' choirs) to an .mscz.

MuseScore's plugin API cannot set mixer sound presets: they live in
audiosettings.json inside the .mscz, keyed by partId+instrumentId (see
docs/ACTIONS.md, "Mixer channel properties"). This tool edits that file
offline - run it with MuseScore closed.

Usage (CLI):
  musescore-mcp set-mixer-sound SCORE.mscz --list
  musescore-mcp set-mixer-sound SCORE.mscz --choir-ottetto [--sopranos-uid N]
  musescore-mcp set-mixer-sound SCORE.mscz --set PART=SOUND [--dry-run]

PART is a MuseScore <Part id="..."> value (or a part name like "Sopran").
SOUND is one of: sopranos|altos|tenors|basses (Ottetto choirs), or
"uid=NAME,UID" for any MuseSampler package, e.g.
  --set 4=uid=Ottetto: Choir Sopranos,50352

Choir parts are matched by track name or instrument id (soprano/sopran,
alto/alt, tenor, bass/bas - English or Swedish, case-insensitive prefix).
"""
import argparse
import json
import re
import shutil
import sys
import zipfile
import os
import tempfile

OTTETTO_CHOIRS = {
    "sopranos": ("Ottetto: Choir Sopranos", "50352"),
    "altos": ("Ottetto: Choir Altos", "50353"),
    "tenors": ("Ottetto: Choir Tenors", "50354"),
    "basses": ("Ottetto: Choir Basses", "50355"),
}

CHOIR_CLASSES = [
    # fullmatch only: "Tenortrombon" must NOT match the tenor class
    ("sopranos", re.compile(r"(soprano|sopran)", re.I)),
    ("altos", re.compile(r"(alto|alt)", re.I)),
    ("tenors", re.compile(r"tenor", re.I)),
    ("basses", re.compile(r"(bass|bas)", re.I)),
]


def resource_meta(name, uid):
    return {
        "resourceMeta": {
            "attributes": {
                "isOnline": "1",
                "museCategory": "Choir",
                "museName": name,
                "musePack": "Cantai",
                "museUID": uid,
                "museVendorName": "Cantai",
                "playbackSetupData": "",
            },
            "hasNativeEditorSupport": False,
            "id": uid,
            "type": "muse_sampler_sound_pack",
            "vendor": "MuseSounds",
        },
        "unitConfiguration": {},
    }


def read_mscz(path):
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        mscx_name = next(n for n in names if n.endswith(".mscx"))
        mscx = z.read(mscx_name).decode("utf-8")
        try:
            audio = json.loads(z.read("audiosettings.json").decode("utf-8"))
        except KeyError:
            audio = {"tracks": []}
        return mscx_name, mscx, audio


def parse_parts(mscx):
    """Return [(partId, trackName, instrumentId)] from the mscx header."""
    parts = []
    for m in re.finditer(r"<Part(?: id=\"(\d+)\")?\s*>(.*?)</Part>\s*(?=<Part|<Staff |<Score)", mscx, re.S):
        pid, body = m.group(1), m.group(2)
        if "<Instrument" not in body:
            continue
        ordinal = len(parts) + 1
        tn = re.search(r"<trackName>([^<]*)</trackName>", body)
        iid = re.search(r'<Instrument id="([^"]+)"', body)
        parts.append({
            "partId": pid or str(ordinal),
            "trackName": tn.group(1).strip() if tn else "",
            "instrumentId": iid.group(1) if iid else "",
        })
    return parts


def tracks_as_list(audio):
    tracks = audio.get("tracks", [])
    if isinstance(tracks, dict):
        return [{"partId": k, **v} for k, v in tracks.items()], "dict"
    return tracks, "list"


def choir_class(track_name, instrument_id):
    for label, rx in CHOIR_CLASSES:
        if rx.fullmatch(track_name or "") or rx.fullmatch(instrument_id or ""):
            return label
    return None


def find_track(tracks, part_id):
    for t in tracks:
        if str(t.get("partId")) == str(part_id):
            return t
    return None


def add_arguments(ap):
    ap.add_argument("mscz")
    ap.add_argument("--list", action="store_true", help="show parts and current sounds")
    ap.add_argument("--choir-ottetto", action="store_true",
                    help="assign the four Ottetto choir presets to the SATB parts")
    ap.add_argument("--sopranos-uid", default=OTTETTO_CHOIRS["sopranos"][1],
                    help="UID for Choir Sopranos (default: %(default)s, unverified)")
    ap.add_argument("--set", action="append", default=[],
                    help="PART=SOUND, e.g. 4=sopranos or 4=uid=Name,50352")
    ap.add_argument("--dry-run", action="store_true")


def run(args):
    mscx_name, mscx, audio = read_mscz(args.mscz)
    parts = parse_parts(mscx)
    tracks, shape = tracks_as_list(audio)
    by_id = {p["partId"]: p for p in parts}

    assignments = []  # (part, name, uid)
    for spec in args.set:
        part_ref, sound = spec.split("=", 1)
        part = by_id.get(part_ref) or next(
            (p for p in parts if p["trackName"].lower().startswith(part_ref.lower())), None)
        if not part:
            sys.exit(f"error: no part matches {part_ref!r}")
        if sound.startswith("uid="):
            name, uid = sound[4:].rsplit(",", 1)
            assignments.append((part, name, uid))
        elif sound in OTTETTO_CHOIRS:
            name, uid = OTTETTO_CHOIRS[sound]
            if sound == "sopranos":
                uid = args.sopranos_uid
            assignments.append((part, name, uid))
        else:
            sys.exit(f"error: unknown sound {sound!r}")

    if args.choir_ottetto:
        for part in parts:
            cls = choir_class(part["trackName"], part["instrumentId"])
            if cls:
                name, uid = OTTETTO_CHOIRS[cls]
                if cls == "sopranos":
                    uid = args.sopranos_uid
                assignments.append((part, name, uid))

    print(f"{args.mscz}")
    for p in parts:
        t = find_track(tracks, p["partId"])
        src = (t or {}).get("in", {}).get("resourceMeta", {})
        sound = src.get("id") or (src.get("attributes", {}) or {}).get("museName") or "-"
        print(f"  part {p['partId']:>3}  {p['trackName'] or '?':<16} [{p['instrumentId']}]  sound: {sound}")

    if args.list and not assignments:
        return
    if not assignments:
        sys.exit("error: nothing to do (use --list, --choir-ottetto or --set)")

    changed = 0
    for part, name, uid in assignments:
        t = find_track(tracks, p_id := part["partId"])
        if t is None:
            t = {"partId": p_id, "instrumentId": part["instrumentId"],
                 "out": {"balance": 0, "fxChain": {}, "volumeDb": 0},
                 "soloMuteState": {"mute": False, "solo": False}}
            tracks.append(t)
        t["instrumentId"] = part["instrumentId"]
        t["in"] = resource_meta(name, uid)
        changed += 1
        print(f"  -> part {p_id} ({part['trackName']}) = {name} ({uid})")

    if args.dry_run:
        print("dry run - file unchanged")
        return

    backup = args.mscz + ".bak"
    shutil.copy2(args.mscz, backup)
    if shape == "dict":
        audio["tracks"] = {t["partId"]: {k: v for k, v in t.items() if k != "partId"} for t in tracks}
    else:
        audio["tracks"] = tracks
    audio_bytes = json.dumps(audio, indent=2).encode("utf-8")
    fd, temporary = tempfile.mkstemp(suffix=".mscz", dir=os.path.dirname(os.path.abspath(args.mscz)))
    os.close(fd)
    try:
        with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as zout:
            with zipfile.ZipFile(backup) as zin:
                for item in zin.infolist():
                    if item.filename != "audiosettings.json":
                        zout.writestr(item, zin.read(item.filename))
                zout.writestr("audiosettings.json", audio_bytes)
        with zipfile.ZipFile(temporary) as check:
            if check.testzip() is not None or json.loads(check.read("audiosettings.json")) != audio:
                raise ValueError("Could not verify updated mixer settings")
        shutil.copymode(args.mscz, temporary)
        os.replace(temporary, args.mscz)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"updated {args.mscz} (backup: {backup})")


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        prog="musescore-mcp set-mixer-sound")
    add_arguments(ap)
    run(ap.parse_args(argv))


if __name__ == "__main__":
    main()
