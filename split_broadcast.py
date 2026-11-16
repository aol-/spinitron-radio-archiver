#!/usr/bin/env python3
"""
Spinitron Broadcast Splitter & ID3v2 Tagger
Splits long continuous radio archive MP3s into individual tracks using Spinitron
timestamp logs. Keeps DJ commentary at the *end* of the preceding track so every
track begins cleanly on the music start.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import urllib.request
from datetime import datetime
from pathlib import Path

from mutagen.id3 import APIC, COMM, ID3, TALB, TCON, TDRC, TIT2, TPE1, TPE2, TPUB, TRCK


def sanitize(name: str) -> str:
    name = re.sub(r'[/\\?%*:|"<>]', "-", name)
    return re.sub(r"\s+", " ", name).strip()


def get_file_duration(file_path: Path) -> float:
    res = subprocess.run(
        [
            "ffprobe", "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            str(file_path),
        ],
        capture_output=True, text=True, check=True,
    )
    return float(res.stdout.strip())


def fetch_spins(url: str) -> list:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        html_content = resp.read().decode("utf-8", errors="ignore")
    blocks = re.findall(r"<code>\s*(\{.*?\})\s*</code>", html_content, re.DOTALL)
    if blocks:
        raw_json = blocks[1] if len(blocks) >= 2 else blocks[0]
        data = json.loads(raw_json)
        return data.get("items", [])[::-1]
    data = json.loads(html_content)
    if isinstance(data, dict):
        return data.get("items", [])[::-1]
    return []


def tag_file(
    file_path: Path,
    title: str,
    artist: str,
    album_artist: str,
    album: str,
    track_str: str,
    year: str,
    date: str,
    station: str,
    dj: str,
    cover_art: Path = None,
):
    try:
        audio = ID3(str(file_path))
    except Exception:
        audio = ID3()

    audio.add(TIT2(encoding=3, text=title))
    audio.add(TPE1(encoding=3, text=artist))
    audio.add(TPE2(encoding=3, text=album_artist))
    audio.add(TALB(encoding=3, text=album))
    audio.add(TRCK(encoding=3, text=track_str))
    audio.add(TDRC(encoding=3, text=year))
    audio.add(TCON(encoding=3, text="Radio"))
    audio.add(TPUB(encoding=3, text=station))
    audio.add(COMM(encoding=3, lang="eng", desc="", text=f"Recorded from {station} - {album_artist} ({dj}, {date})."))

    if cover_art and cover_art.exists():
        img_data = cover_art.read_bytes()
        audio.add(APIC(encoding=3, mime="image/jpeg", type=3, desc="Album cover", data=img_data))
    audio.save(str(file_path), v2_version=3)


def split_broadcast(args):
    full_file = Path(args.input).resolve()
    if not full_file.exists():
        raise FileNotFoundError(f"Input audio not found: {full_file}")

    album_dir = Path(args.output_dir).resolve()
    album_dir.mkdir(parents=True, exist_ok=True)
    cover_art = Path(args.cover).resolve() if args.cover else (full_file.parent.parent / "cover.jpg")
    if cover_art.exists():
        shutil.copy2(cover_art, album_dir / "cover.jpg")
        shutil.copy2(cover_art, album_dir / "folder.jpg")

    if args.spinitron_url:
        feed_url = args.spinitron_url
    else:
        feed_url = args.spinitron_url_template.format(date=args.date, show_id=args.show_id)

    spins = fetch_spins(feed_url)
    if not spins:
        print(f"[!] No Spinitron spins found at: {feed_url}")
        return 1

    b_start = datetime.strptime(f"{args.date}T{args.start_time}{args.tz_offset}", "%Y-%m-%dT%H:%M:%S%z")
    file_dur = get_file_duration(full_file)

    track_entries = []
    for s in spins:
        s_start = datetime.strptime(s["start"], "%Y-%m-%dT%H:%M:%S%z")
        offset = (s_start - b_start).total_seconds()
        artist = (s.get("artist") or "").strip() or "Various Artists"
        song = (s.get("song") or "").strip() or "Untitled Track"
        if track_entries and abs(offset - track_entries[-1]["start"]) < 3:
            track_entries[-1]["artist"] += f" / {artist}"
            track_entries[-1]["song"] += f" / {song}"
            continue
        track_entries.append({"start": max(0.0, offset), "artist": artist, "song": song})

    final_tracks = []
    if track_entries and track_entries[0]["start"] > 15.0:
        final_tracks.append({
            "start": 0.0,
            "end": track_entries[0]["start"],
            "artist": args.artist,
            "song": "Show Opening & DJ Intro",
        })

    for i, entry in enumerate(track_entries):
        start = entry["start"]
        end = track_entries[i + 1]["start"] if (i + 1 < len(track_entries)) else file_dur
        if end <= start:
            end = min(file_dur, start + 30.0)
        final_tracks.append({"start": start, "end": end, "artist": entry["artist"], "song": entry["song"]})

    total = len(final_tracks)
    year = args.date[:4]
    album_name = f"{args.show_name} ({args.date})"

    for idx, t in enumerate(final_tracks, 1):
        fname = f"{idx:02d} - {sanitize(t['artist'])} - {sanitize(t['song'])}.mp3"
        out_path = album_dir / fname
        print(f"[{idx:02d}/{total:02d}] {t['start']:.1f}s -> {t['end']:.1f}s : {t['artist']} - {t['song']}")
        if not out_path.exists() or out_path.stat().st_size < 5000:
            subprocess.run(
                ["ffmpeg", "-y", "-ss", str(t["start"]), "-to", str(t["end"]), "-i", str(full_file), "-c", "copy", str(out_path)],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        tag_file(out_path, t["song"], t["artist"], args.show_name, album_name, f"{idx}/{total}", year, args.date, args.station, args.artist, cover_art)

    if args.plex_host and args.plex_section:
        try:
            urllib.request.urlopen(
                urllib.request.Request(f"http://{args.plex_host}:32400/library/sections/{args.plex_section}/refresh"),
                timeout=5,
            )
        except Exception as e:
            print(f"Plex refresh notice: {e}")

    print(f"Split {total} track(s) into {album_dir}")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Split radio archive MP3s into tagged tracks via Spinitron timestamps.")
    parser.add_argument("--input", "-i", required=True, help="Path to full broadcast MP3")
    parser.add_argument("--date", "-d", required=True, help="Broadcast date (YYYY-MM-DD)")
    parser.add_argument("--output-dir", "-o", required=True, help="Directory to write numbered track MP3s")
    parser.add_argument("--start-time", default="10:00:15", help="Broadcast air start time HH:MM:SS (default: 10:00:15)")
    parser.add_argument("--tz-offset", default="-0500", help="Timezone UTC offset of start-time (default: -0500)")
    parser.add_argument("--show-id", default="", help="Spinitron show ID")
    parser.add_argument("--spinitron-url", default="", help="Direct Spinitron playlist URL (overrides template)")
    parser.add_argument(
        "--spinitron-url-template",
        default="https://files.wyxr.org/static-html/api-spinitron/playlists.php?date={date}&show_id={show_id}",
        help="Spinitron endpoint template containing {date} and {show_id}",
    )
    parser.add_argument("--show-name", default="Radio Show")
    parser.add_argument("--artist", default="Show Host")
    parser.add_argument("--station", default="Community Radio")
    parser.add_argument("--cover", default="", help="Path to front cover JPEG")
    parser.add_argument("--plex-host", default="", help="Optional Plex server host/IP to refresh")
    parser.add_argument("--plex-section", default="", help="Optional Plex library section ID")
    args = parser.parse_args()
    sys.exit(split_broadcast(args))


if __name__ == "__main__":
    main()
