#!/usr/bin/env bash
set -euo pipefail

# Config-driven live stream / archive radio show recorder & ID3 tagger.
# Usage: record_show.sh /path/to/show.conf [--live] [YYYY-MM-DD]

CONF_FILE="${1:-}"
if [[ -n "$CONF_FILE" && -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    shift || true
fi

MODE="${1:-auto}"
if [[ "${MODE:-}" == "--live" ]]; then
    shift || true
else
    MODE="auto"
fi
AIR_DATE="${1:-${AIR_DATE:-$(date +%Y-%m-%d)}}"
YEAR="${YEAR:-$(date -d "$AIR_DATE" +%Y 2>/dev/null || date +%Y)}"

SHOW_NAME="${SHOW_NAME:-Radio Show}"
DJ_NAME="${DJ_NAME:-Host}"
STATION_NAME="${STATION_NAME:-Community Radio}"
GENRE="${GENRE:-Radio}"
STREAM_URL="${STREAM_URL:-}"
FEED_URL="${FEED_URL:-}"
ARCHIVE_PAGE_URL="${ARCHIVE_PAGE_URL:-}"
ARCHIVE_KEYWORDS="${ARCHIVE_KEYWORDS:-}"
RECORD_SECONDS="${RECORD_SECONDS:-7200}"
BITRATE="${BITRATE:-192k}"

BASE_DIR="${LIBRARY_DIR:-$HOME/Music/Radio_Recordings}"
DEST_DIR="${BASE_DIR}/${SHOW_NAME}"
FULL_DIR="${DEST_DIR}/Full Broadcasts"
TEMP_DIR="$(mktemp -d /tmp/radio_rec_XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT

COVER_ART="${COVER_ART:-${DEST_DIR}/cover.jpg}"
RAW_FILE="${TEMP_DIR}/raw_${AIR_DATE}.mp3"
OUTPUT_FILE="${FULL_DIR}/${SHOW_NAME} - ${AIR_DATE}.mp3"

PLEX_HOST="${PLEX_HOST:-}"
PLEX_SECTION_ID="${PLEX_SECTION_ID:-}"

mkdir -p "${FULL_DIR}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fetch_streamguys_json_archive() {
    python3 - "${FEED_URL}" "${AIR_DATE}" <<'PY'
import json, sys, urllib.request
feed_url, target_date = sys.argv[1], sys.argv[2]
req = urllib.request.Request(feed_url, headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(req, timeout=15) as resp:
    data = json.loads(resp.read().decode("utf-8", errors="ignore"))
for b in data.get("recent_broadcasts", []):
    if b.get("sortableDate") == target_date and b.get("url"):
        print(b["url"])
        sys.exit(0)
sys.exit(1)
PY
}

fetch_html_data_stream_archive() {
    python3 - "${ARCHIVE_PAGE_URL}" "${AIR_DATE}" "${ARCHIVE_KEYWORDS}" <<'PY'
import re, sys, urllib.request
page_url, air_date, kw_csv = sys.argv[1], sys.argv[2].replace("-", ""), sys.argv[3]
keywords = [k.strip().lower() for k in kw_csv.split(",") if k.strip()]
req = urllib.request.Request(page_url, headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(req, timeout=15) as resp:
    html = resp.read().decode("utf-8", errors="ignore")
for s in re.findall(r'data-stream="([^"]+)"', html):
    if air_date in s and (not keywords or any(k in s.lower() for k in keywords)):
        print(s)
        sys.exit(0)
sys.exit(1)
PY
}

ARCHIVE_URL=""
if [[ "$MODE" != "--live" ]]; then
    if [[ -n "$FEED_URL" ]]; then
        ARCHIVE_URL="$(fetch_streamguys_json_archive 2>/dev/null || true)"
    elif [[ -n "$ARCHIVE_PAGE_URL" ]]; then
        ARCHIVE_URL="$(fetch_html_data_stream_archive 2>/dev/null || true)"
    fi
fi

if [[ -n "$ARCHIVE_URL" ]]; then
    log "Downloading on-demand archive: ${ARCHIVE_URL}"
    curl -fsSL "${ARCHIVE_URL}" -o "${RAW_FILE}"
elif [[ "$MODE" == "--live" || ( -z "$FEED_URL" && -z "$ARCHIVE_PAGE_URL" ) ]]; then
    [[ -n "$STREAM_URL" ]] || { echo "STREAM_URL is required for live recording." >&2; exit 1; }
    log "Capturing live stream (${STATION_NAME} - ${SHOW_NAME}) for ${RECORD_SECONDS}s..."
    ffmpeg -y \
        -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 10 \
        -i "${STREAM_URL}" \
        -t "${RECORD_SECONDS}" \
        -c:a libmp3lame -b:a "${BITRATE}" \
        "${RAW_FILE}"
else
    log "No on-demand archive published yet for ${AIR_DATE}; rerun with --live during airtime."
    exit 0
fi

log "Tagging ID3v2.3 metadata -> ${OUTPUT_FILE}"
COMMON_META=(
    -id3v2_version 3
    -metadata "artist=${SHOW_NAME}"
    -metadata "album_artist=${SHOW_NAME}"
    -metadata "album=${SHOW_NAME} (${YEAR})"
    -metadata "title=${SHOW_NAME} - ${AIR_DATE}"
    -metadata "date=${AIR_DATE}"
    -metadata "year=${YEAR}"
    -metadata "publisher=${STATION_NAME}"
    -metadata "genre=${GENRE}"
    -metadata "comment=Recorded from ${STATION_NAME} - ${SHOW_NAME} (${DJ_NAME})."
)

if [[ -f "${COVER_ART}" ]]; then
    ffmpeg -y -i "${RAW_FILE}" -i "${COVER_ART}" \
        -map 0:a -map 1:v -c:a copy -c:v copy \
        -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" \
        "${COMMON_META[@]}" "${OUTPUT_FILE}"
else
    ffmpeg -y -i "${RAW_FILE}" -c copy "${COMMON_META[@]}" "${OUTPUT_FILE}"
fi

if [[ "${SPLIT_PLAYLIST:-0}" == "1" && -n "${SPINITRON_SHOW_ID:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SPLITTER_PY="${SCRIPT_DIR}/split_broadcast.py"
    if [[ -f "$SPLITTER_PY" ]]; then
        EXTRA_ARGS=()
        [[ -n "${SPINITRON_URL_TEMPLATE:-}" ]] && EXTRA_ARGS+=(--spinitron-url-template "${SPINITRON_URL_TEMPLATE}")
        [[ -n "${START_TIME:-}" ]] && EXTRA_ARGS+=(--start-time "${START_TIME}")
        [[ -n "${TZ_OFFSET:-}" ]] && EXTRA_ARGS+=(--tz-offset "${TZ_OFFSET}")
        python3 "$SPLITTER_PY" \
            --input "${OUTPUT_FILE}" \
            --date "${AIR_DATE}" \
            --show-name "${SHOW_NAME}" \
            --station "${STATION_NAME}" \
            --artist "${DJ_NAME}" \
            --show-id "${SPINITRON_SHOW_ID}" \
            --output-dir "${DEST_DIR}/${AIR_DATE}" \
            "${EXTRA_ARGS[@]}"
    fi
fi

if [[ -n "$PLEX_HOST" && -n "$PLEX_SECTION_ID" ]]; then
    curl -fsS -X GET "http://${PLEX_HOST}:32400/library/sections/${PLEX_SECTION_ID}/refresh" >/dev/null 2>&1 || true
    log "Triggered Plex section ${PLEX_SECTION_ID} refresh on ${PLEX_HOST}."
fi
