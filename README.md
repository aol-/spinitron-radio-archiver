# Spinitron Radio Archiver (`spinitron-radio-archiver`)

Config-driven radio broadcast capture, on-demand archive fetcher, Spinitron playlist track splitter, and ID3v2.3 album-art tagger.

## Features

- **On-demand + live capture (`record_show.sh`)**: Pulls published StreamGuys / HTML `data-stream` archives or falls back (`--live`) to resilient FFmpeg live capture (`-reconnect 1 -reconnect_streamed 1`).
- **Clean Spinitron track splitting (`split_broadcast.py`)**: Aligns track boundaries against Spinitron timestamps, keeping DJ voiceovers at the *end* of the preceding track so each numbered MP3 starts cleanly on the song intro.
- **Zero re-encoding on split**: Cuts segments losslessly (`-c copy`), embeds full ID3v2 tags & cover art via `mutagen`, and optionally triggers a Plex library scan (`PLEX_HOST` + `PLEX_SECTION_ID`).

## Quick Start

```bash
pip install mutagen
install -Dm755 record_show.sh split_broadcast.py ~/.local/bin/
mkdir -p ~/.config/radio-archiver
cp examples/wyxr.conf.example ~/.config/radio-archiver/wyxr.conf
~/.local/bin/record_show.sh ~/.config/radio-archiver/wyxr.conf
```

## License

GPL-3.0-or-later — [labs.yuup.com](https://yuup.com/labs)
