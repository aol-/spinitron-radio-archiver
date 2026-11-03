#!/usr/bin/env bash
set -euo pipefail

SHOW_NAME="Freak Flag"
DJ_NAME="PetaL"
STATION_NAME="WKDU 91.7 FM Philadelphia"
STREAM_URL="https://streams.wkdu.org/listen.mp3"

AIR_DATE="$(date +%Y-%m-%d)"
YEAR="$(date +%Y)"

# Calculate remaining time until 12:05 AM (end of 10pm-12am show + 5m buffer)
NOW_SEC=$(date +%s)
MIDNIGHT_BUFFER_SEC=$(date -d "tomorrow 00:05:00" +%s 2>/dev/null || date -d "00:05:00" +%s)
REMAINING_CALC=$(( MIDNIGHT_BUFFER_SEC - NOW_SEC ))
if [ "${REMAINING_CALC}" -le 0 ]; then
  # If executed during standard 2-hour show window
  REMAINING_CALC=7200
fi

RECORD_SECONDS="${RECORD_SECONDS:-$REMAINING_CALC}"

BASE_DIR="$HOME/Music/Radio_recordings"
DEST_DIR="${BASE_DIR}/${SHOW_NAME}"
TEMP_DIR="/tmp/wkdu_staging_${AIR_DATE}"
OUTPUT_FILE="${DEST_DIR}/${SHOW_NAME} - ${AIR_DATE}.mp3"
RAW_FILE="${TEMP_DIR}/raw_${AIR_DATE}.mp3"
COVER_ART="${DEST_DIR}/cover.jpg"
PLEX_SERVER_IP="${PLEX_SERVER_IP:-plex.local}"
PLEX_SECTION_ID="${PLEX_SECTION_ID:-12}"

echo "[$(date "+%Y-%m-%d %H:%M:%S")] Initializing live recorder for ${SHOW_NAME} (${STATION_NAME})..."
echo "[$(date "+%Y-%m-%d %H:%M:%S")] Recording for ${RECORD_SECONDS} seconds (target: ${OUTPUT_FILE})..."

mkdir -p "${TEMP_DIR}"
mkdir -p "${DEST_DIR}"

# Stream capture directly from WKDU live Icecast feed
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
    -metadata artist="${SHOW_NAME} (${DJ_NAME})" \
    -metadata album_artist="${SHOW_NAME}" \
    -metadata album="${SHOW_NAME} (${YEAR})" \
    -metadata title="${SHOW_NAME} - ${AIR_DATE}" \
    -metadata date="${AIR_DATE}" \
    -metadata year="${YEAR}" \
    -metadata publisher="${STATION_NAME}" \
    -metadata genre="Electronic / Radio" \
    -metadata comment="Broadcast live on ${STATION_NAME} (Drexel University Student Radio) - Freak Flag with ${DJ_NAME}." \
    "${OUTPUT_FILE}"
else
  ffmpeg -y \
    -i "${RAW_FILE}" \
    -c copy \
    -id3v2_version 3 \
    -metadata artist="${SHOW_NAME} (${DJ_NAME})" \
    -metadata album_artist="${SHOW_NAME}" \
    -metadata album="${SHOW_NAME} (${YEAR})" \
    -metadata title="${SHOW_NAME} - ${AIR_DATE}" \
    -metadata date="${AIR_DATE}" \
    -metadata year="${YEAR}" \
    -metadata publisher="${STATION_NAME}" \
    -metadata genre="Electronic / Radio" \
    -metadata comment="Broadcast live on ${STATION_NAME} (Drexel University Student Radio) - Freak Flag with ${DJ_NAME}." \
    "${OUTPUT_FILE}"
fi

# Clean up temp staging
rm -rf "${TEMP_DIR}"
echo "[$(date "+%Y-%m-%d %H:%M:%S")] Published archive to: ${OUTPUT_FILE}"

# Trigger Plex refresh if local or remote server is up
curl -s -X GET "http://${PLEX_SERVER_IP}:32400/library/sections/${PLEX_SECTION_ID}/refresh" >/dev/null 2>&1 || true
curl -s -X GET "http://127.0.0.1:32400/library/sections/${PLEX_SECTION_ID}/refresh" >/dev/null 2>&1 || true
echo "[$(date "+%Y-%m-%d %H:%M:%S")] Plex refresh requested."
