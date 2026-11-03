#!/usr/bin/env bash
set -euo pipefail

SHOW_NAME="Notes from Underground"
STATION_NAME="WKCR 89.9 FM New York"
STREAM_URL="https://wkcr.streamguys1.com/live"
# 2.5 hours = 9000 seconds (12:30 AM - 2:30 AM + 30 min buffer)
RECORD_SECONDS="${RECORD_SECONDS:-9000}"

AIR_DATE="$(date +%Y-%m-%d)"
YEAR="$(date +%Y)"

# Save directly to local Radio_recordings library
BASE_DIR="$HOME/Music/Radio_recordings"
DEST_DIR="${BASE_DIR}/${SHOW_NAME}"
TEMP_DIR="/tmp/wkcr_staging"
OUTPUT_FILE="${DEST_DIR}/${SHOW_NAME} - ${AIR_DATE}.mp3"
RAW_FILE="${TEMP_DIR}/raw_${AIR_DATE}.mp3"
COVER_ART="${DEST_DIR}/cover.jpg"
PLEX_SERVER_IP="${PLEX_SERVER_IP:-plex.local}"
PLEX_SECTION_ID="${PLEX_SECTION_ID:-12}"

echo "[$(date "+%Y-%m-%d %H:%M:%S")] Initializing live recorder for ${SHOW_NAME}..."

mkdir -p "${TEMP_DIR}"
mkdir -p "${DEST_DIR}"

echo "[$(date "+%Y-%m-%d %H:%M:%S")] Capturing live WKCR stream for ${RECORD_SECONDS} seconds (${SHOW_NAME})..."

# Stream capture directly from WKCR live feed
ffmpeg -y \
  -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 10 \
  -i "${STREAM_URL}" \
  -t "${RECORD_SECONDS}" \
  -c:a libmp3lame -b:a 192k \
  "${RAW_FILE}"

# Embed ID3 tags and cover artwork
echo "[$(date "+%Y-%m-%d %H:%M:%S")] Embedding metadata and album artwork..."
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
    -metadata genre="Hip-Hop / Underground" \
    -metadata comment="Broadcast live on ${STATION_NAME} (Columbia University Radio) - Notes from Underground." \
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
    -metadata genre="Hip-Hop / Underground" \
    -metadata comment="Broadcast live on ${STATION_NAME} (Columbia University Radio) - Notes from Underground." \
    "${OUTPUT_FILE}"
fi

# Clean up temp
rm -rf "${TEMP_DIR}"
echo "[$(date "+%Y-%m-%d %H:%M:%S")] Published to: ${OUTPUT_FILE}"

# Notify Plex to rescan
curl -s -X GET "http://${PLEX_SERVER_IP}:32400/library/sections/${PLEX_SECTION_ID}/refresh" >/dev/null 2>&1 || true
curl -s -X GET "http://127.0.0.1:32400/library/sections/${PLEX_SECTION_ID}/refresh" >/dev/null 2>&1 || true
echo "[$(date "+%Y-%m-%d %H:%M:%S")] Plex radio library refresh triggered."
