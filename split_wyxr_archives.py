#!/usr/bin/env python3
"""
split_wyxr_archives.py
Splits WYXR long archive broadcasts into individual tracks based on Spinitron timestamps.
Leaves DJ commentary/speaking at the end of each track, starting each new track cleanly
with the beginning of each song.
"""

import os
import sys
import re
import json
import subprocess
import urllib.request
from pathlib import Path
from datetime import datetime
from mutagen.id3 import ID3, TIT2, TPE1, TPE2, TALB, TRCK, TDRC, TCON, TPUB, COMM, APIC

BASE_DIR = Path("$HOME/Music/Radio_recordings/How Gravity Works")
FULL_DIR = BASE_DIR / "Full Broadcasts"
FULL_DIR.mkdir(parents=True, exist_ok=True)
COVER_ART = BASE_DIR / "cover.jpg"
PLEX_SERVER_IP = "plex.local"
PLEX_SECTION_ID = "12"

EPISODES = [
    {
        "date": "2026-10-24",
        "start_time": "10:00:19",
        "full_file": FULL_DIR / "How Gravity Works - 2026-10-24.mp3"
    },
    {
        "date": "2026-10-17",
        "start_time": "10:00:18",
        "full_file": FULL_DIR / "How Gravity Works - 2026-10-17.mp3"
    },
    {
        "date": "2026-10-10",
        "start_time": "10:00:18",
        "full_file": FULL_DIR / "How Gravity Works - 2026-10-10.mp3"
    },
    {
        "date": "2026-10-03",
        "start_time": "10:00:21",
        "full_file": FULL_DIR / "How Gravity Works - 2026-10-03.mp3"
    },
    {
        "date": "2026-09-26",
        "start_time": "10:00:11",
        "full_file": FULL_DIR / "How Gravity Works - 2026-09-26.mp3"
    }
]

def sanitize(name: str) -> str:
    name = re.sub(r'[/\\?%*:|"<>]', '-', name)
    name = re.sub(r'\s+', ' ', name).strip()
    return name

def get_file_duration(file_path: Path) -> float:
    cmd = [
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        str(file_path)
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return float(res.stdout.strip())

def fetch_spins(date: str):
    url = f"https://files.wyxr.org/static-html/api-spinitron/playlists.php?date={date}&show_id=313411"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        html_content = resp.read().decode("utf-8", errors="ignore")
    blocks = re.findall(r'<code>\s*(\{.*?\})\s*</code>', html_content, re.DOTALL)
    if len(blocks) < 2:
        return []
    data = json.loads(blocks[1])
    # Reverse to chronological order
    spins = data.get("items", [])[::-1]
    return spins

def tag_file(file_path: Path, title: str, artist: str, album: str, track_str: str, year: str, date: str):
    try:
        try:
            audio = ID3(str(file_path))
        except Exception:
            audio = ID3()
        
        audio.add(TIT2(encoding=3, text=title))
        audio.add(TPE1(encoding=3, text=artist))
        audio.add(TPE2(encoding=3, text="How Gravity Works"))
        audio.add(TALB(encoding=3, text=album))
        audio.add(TRCK(encoding=3, text=track_str))
        audio.add(TDRC(encoding=3, text=year))
        audio.add(TCON(encoding=3, text="Radio"))
        audio.add(TPUB(encoding=3, text="WYXR 91.7 FM Memphis"))
        audio.add(COMM(encoding=3, lang="eng", desc="", text=f"Broadcast live on WYXR 91.7 FM Memphis - How Gravity Works with Davy Ray Bennett ({date})."))
        
        if COVER_ART.exists():
            with open(COVER_ART, "rb") as f:
                img_data = f.read()
            audio.add(APIC(
                encoding=3,
                mime="image/jpeg",
                type=3, # front cover
                desc="Album cover",
                data=img_data
            ))
        audio.save(str(file_path), v2_version=3)
    except Exception as e:
        print(f"    [Tag Error] Could not tag {file_path.name}: {e}")

def process_episode(ep: dict):
    date = ep["date"]
    start_time_str = ep["start_time"]
    full_file = ep["full_file"]

    # Check full file existence; might be in FULL_DIR if already moved
    if not full_file.exists():
        cand = FULL_DIR / full_file.name
        if cand.exists():
            full_file = cand
        else:
            print(f"[Error] Source file {full_file.name} not found.")
            return

    album_dir = BASE_DIR / date
    album_dir.mkdir(parents=True, exist_ok=True)
    
    # Copy artwork into album directory
    if COVER_ART.exists():
        import shutil
        shutil.copy2(COVER_ART, album_dir / "cover.jpg")
        shutil.copy2(COVER_ART, album_dir / "folder.jpg")

    spins = fetch_spins(date)
    if not spins:
        print(f"[Warning] No spins found for {date}.")
        return

    b_start = datetime.strptime(f"{date}T{start_time_str}-0500", "%Y-%m-%dT%H:%M:%S%z")
    file_dur = get_file_duration(full_file)
    print(f"\n==================================================")
    print(f"Processing Episode: {date} (Duration: {file_dur:.1f}s, {len(spins)} spins)")
    print(f"Album Dir: {album_dir}")
    print(f"==================================================")

    # Calculate start offsets and remove duplicates / zero-duration jumps
    track_entries = []
    for s in spins:
        s_start = datetime.strptime(s["start"], "%Y-%m-%dT%H:%M:%S%z")
        offset = (s_start - b_start).total_seconds()
        artist = s.get("artist", "").strip() or "Various Artists"
        song = s.get("song", "").strip() or "Untitled Track"
        
        # If this offset is equal to previous offset, skip or combine
        if track_entries and abs(offset - track_entries[-1]["start"]) < 3:
            track_entries[-1]["artist"] += f" / {artist}"
            track_entries[-1]["song"] += f" / {song}"
            continue

        track_entries.append({
            "start": max(0.0, offset),
            "artist": artist,
            "song": song,
            "raw_offset": offset
        })

    # Prepare final tracklist including Show Opening if first track starts > 15s in
    final_tracks = []
    if track_entries and track_entries[0]["start"] > 15.0:
        final_tracks.append({
            "start": 0.0,
            "end": track_entries[0]["start"],
            "artist": "Davy Ray Bennett",
            "song": "Show Opening & DJ Intro",
            "is_intro": True
        })

    for i in range(len(track_entries)):
        start = track_entries[i]["start"]
        if i + 1 < len(track_entries):
            end = track_entries[i + 1]["start"]
        else:
            end = file_dur
        
        # Ensure end > start
        if end <= start:
            end = min(file_dur, start + 30.0)

        final_tracks.append({
            "start": start,
            "end": end,
            "artist": track_entries[i]["artist"],
            "song": track_entries[i]["song"],
            "is_intro": False
        })

    total_tracks = len(final_tracks)
    album_name = f"How Gravity Works ({date})"

    for idx, t in enumerate(final_tracks, 1):
        clean_artist = sanitize(t["artist"])
        clean_song = sanitize(t["song"])
        filename = f"{idx:02d} - {clean_artist} - {clean_song}.mp3"
        out_path = album_dir / filename

        dur = t["end"] - t["start"]
        start_min = int(t["start"] // 60)
        start_sec = int(t["start"] % 60)
        end_min = int(t["end"] // 60)
        end_sec = int(t["end"] % 60)

        print(f"[{idx:02d}/{total_tracks:02d}] {start_min:02d}:{start_sec:02d} - {end_min:02d}:{end_sec:02d} ({dur:.0f}s): {clean_artist} - {clean_song}")

        if not out_path.exists() or out_path.stat().st_size < 5000:
            cmd = [
                "ffmpeg", "-y",
                "-ss", str(t["start"]),
                "-to", str(t["end"]),
                "-i", str(full_file),
                "-c", "copy",
                str(out_path)
            ]
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            tag_file(out_path, t["song"], t["artist"], album_name, f"{idx}/{total_tracks}", "2026", date)
        else:
            tag_file(out_path, t["song"], t["artist"], album_name, f"{idx}/{total_tracks}", "2026", date)

    # Move full continuous file into Full Broadcasts folder
    if full_file.parent != FULL_DIR:
        dest_full = FULL_DIR / full_file.name
        shutil.move(full_file, dest_full)
        # Update tags of full broadcast file
        tag_file(dest_full, f"How Gravity Works - {date} (Full Show)", "How Gravity Works", "How Gravity Works (Full Broadcasts)", f"1/4", "2026", date)
        print(f"==> Moved continuous broadcast to: {dest_full}")

def sync_to_plex():
    print("\n==> Syncing all files to Plex server (plexuser@plex.local:/mnt/plex/radio/)...")
    cmd = [
        "rsync", "-avz", "--progress",
        str(BASE_DIR) + "/",
        f"p@{PLEX_SERVER_IP}:/mnt/plex/radio/How Gravity Works/"
    ]
    subprocess.run(cmd, check=True)

    print("==> Refreshing Plex Section 12...")
    refresh_url = f"http://{PLEX_SERVER_IP}:32400/library/sections/{PLEX_SECTION_ID}/refresh"
    try:
        req = urllib.request.Request(refresh_url, method="GET")
        with urllib.request.urlopen(req, timeout=5) as resp:
            print(f"==> Plex refresh signal sent (status {resp.status}).")
    except Exception as e:
        print(f"==> Plex refresh trigger note: {e}")

def main():
    if len(sys.argv) > 1:
        target_date = sys.argv[1]
        ep = next((e for e in EPISODES if e["date"] == target_date), None)
        if not ep:
            cand = BASE_DIR / f"How Gravity Works - {target_date}.mp3"
            if not cand.exists():
                cand = FULL_DIR / f"How Gravity Works - {target_date}.mp3"
            ep = {
                "date": target_date,
                "start_time": "10:00:15",
                "full_file": cand
            }
        process_episode(ep)
    else:
        for ep in EPISODES:
            process_episode(ep)
    sync_to_plex()
    print("\nAll episodes successfully split, tagged, and synced to Plex!")

if __name__ == "__main__":
    main()
