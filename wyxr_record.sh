#!/usr/bin/env bash
set -euo pipefail

SHOW_NAME="How Gravity Works"
DJ_NAME="Davy Ray Bennett"
STATION_NAME="WYXR 91.7 FM Memphis"
STREAMGUYS_ID="313411"
SPINTRON_ID="29"
FEED_URL="https://files.wyxr.org/master-list/rss.php?spintronId=${SPINTRON_ID}&streamguysId=${STREAMGUYS_ID}"
LIVE_STREAM_URL="https://crosstown.streamguys1.com/live-website-aac"

BASE_DIR="$HOME/Music/Radio_recordings"
DEST_DIR="${BASE_DIR}/${SHOW_NAME}"
TEMP_DIR="/tmp/wyxr_staging"
AIR_DATE="${AIR_DATE:-$(date +%Y-%m-%d)}"
YEAR="${YEAR:-$(date +%Y)}"
COVER_ART="${DEST_DIR}/cover.jpg"
OUTPUT_FILE="${DEST_DIR}/${SHOW_NAME} - ${AIR_DATE}.mp3"
RAW_FILE="${TEMP_DIR}/raw_${AIR_DATE}.mp3"
PLEX_SERVER_IP="${PLEX_SERVER_IP:-plex.local}"
PLEX_SECTION_ID="${PLEX_SECTION_ID:-12}"

mkdir -p "${TEMP_DIR}"
mkdir -p "${DEST_DIR}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Initializing WYXR processor for ${SHOW_NAME} (${AIR_DATE})..."

# Check if on-demand archive URL is available in feed for the given date
ARCHIVE_URL=$(python3 -c "
import urllib.request, json, sys
feed_url = '${FEED_URL}'
target_date = '${AIR_DATE}'
try:
    req = urllib.request.Request(feed_url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode())
        for b in data.get('recent_broadcasts', []):
            if b.get('sortableDate') == target_date:
                print(b.get('url', ''))
                sys.exit(0)
except Exception as e:
    pass
sys.exit(1)
" 2>/dev/null || true)

if [ -n "${ARCHIVE_URL}" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Found published on-demand broadcast: ${ARCHIVE_URL}"
  curl -sSL "${ARCHIVE_URL}" -o "${RAW_FILE}"
else
  MODE="${1:-archive_check}"
  if [ "$MODE" = "--live" ]; then
    RECORD_SECONDS="${RECORD_SECONDS:-7200}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Capturing live stream from ${LIVE_STREAM_URL} for ${RECORD_SECONDS}s..."
    ffmpeg -y \
      -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
      -i "${LIVE_STREAM_URL}" \
      -t "${RECORD_SECONDS}" \
      -c:a libmp3lame -b:a 160k \
      "${RAW_FILE}"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] No on-demand archive file published yet for ${AIR_DATE}."
    echo "Note: The show airs Saturdays 10:00 AM – 12:00 PM CDT. WYXR StreamGuys publishes the completed 2-hour broadcast right after 12:00 PM CDT (17:00 UTC)."
    echo "To record the active live stream directly right now, run: $0 --live"
    rm -rf "${TEMP_DIR}"
    exit 0
  fi
fi

# Embed ID3v2 tags and cover artwork
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Embedding metadata and cover art..."
if [ -f "${COVER_ART}" ]; then
  ffmpeg -y \
    -i "${RAW_FILE}" \
    -i "${COVER_ART}" \
    -map 0:a -map 1:v \
    -c:a copy -c:v copy \
    -id3v2_version 3 \
    -metadata:s:v title="Album cover" \
    -metadata:s:v comment="Cover (front)" \
    -metadata artist="${SHOW_NAME}" \
    -metadata album_artist="${SHOW_NAME}" \
    -metadata album="${SHOW_NAME} (${YEAR})" \
    -metadata title="${SHOW_NAME} - ${AIR_DATE}" \
    -metadata date="${AIR_DATE}" \
    -metadata year="${YEAR}" \
    -metadata publisher="${STATION_NAME}" \
    -metadata genre="Radio" \
    -metadata comment="Broadcast live on ${STATION_NAME} - ${SHOW_NAME} with ${DJ_NAME}." \
    "${OUTPUT_FILE}"
else
  ffmpeg -y \
    -i "${RAW_FILE}" \
    -c copy \
    -id3v2_version 3 \
    -metadata artist="${SHOW_NAME}" \
    -metadata album_artist="${SHOW_NAME}" \
    -metadata album="${SHOW_NAME} (${YEAR})" \
    -metadata title="${SHOW_NAME} - ${AIR_DATE}" \
    -metadata date="${AIR_DATE}" \
    -metadata year="${YEAR}" \
    -metadata publisher="${STATION_NAME}" \
    -metadata genre="Radio" \
    -metadata comment="Broadcast live on ${STATION_NAME} - ${SHOW_NAME} with ${DJ_NAME}." \
    "${OUTPUT_FILE}"
fi

rm -rf "${TEMP_DIR}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Published to: ${OUTPUT_FILE}"

# Sync to remote Plex server if accessible
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing to Plex server (plexuser@${PLEX_SERVER_IP}:/mnt/plex/radio/)..."
scp -r "${DEST_DIR}" "plexuser@${PLEX_SERVER_IP}:/mnt/plex/radio/" 2>/dev/null || true

# Refresh Plex library
curl -s -X GET "http://${PLEX_SERVER_IP}:32400/library/sections/${PLEX_SECTION_ID}/refresh" >/dev/null 2>&1 || true
curl -s -X GET "http://127.0.0.1:32400/library/sections/${PLEX_SECTION_ID}/refresh" >/dev/null 2>&1 || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Plex scan triggered."
