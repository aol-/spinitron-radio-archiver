#!/usr/bin/env bash
set -euo pipefail

SHOW_NAME="R & B with DJ Swamp Boogie"
DJ_NAME="DJ Swamp Boogie"
STATION_NAME="WWOZ 90.7 FM New Orleans"
STREAM_URL="https://wwoz.streamguys1.com/wwoz-hi.mp3"
ARCHIVE_LIST_URL="https://www.wwoz.org/listen/archive/"

BASE_DIR="$HOME/Music/Radio_recordings"
DEST_DIR="${BASE_DIR}/${SHOW_NAME}"
AIR_DATE="${AIR_DATE:-$(date +%Y-%m-%d)}"
YEAR="${YEAR:-$(date +%Y)}"
TEMP_DIR="/tmp/wwoz_staging_${AIR_DATE}"
OUTPUT_FILE="${DEST_DIR}/${SHOW_NAME} - ${AIR_DATE}.mp3"
RAW_FILE="${TEMP_DIR}/raw_${AIR_DATE}.mp3"
COVER_ART="${DEST_DIR}/cover.jpg"
PLEX_SERVER_IP="${PLEX_SERVER_IP:-plex.local}"
PLEX_SECTION_ID="${PLEX_SECTION_ID:-12}"

mkdir -p "${TEMP_DIR}"
mkdir -p "${DEST_DIR}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Python helper to look up published on-demand broadcast URL
find_archive_url() {
  python3 -c "
import urllib.request, re, sys

target_date = '${AIR_DATE}'.replace('-', '')
url = '${ARCHIVE_LIST_URL}'
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        html = resp.read().decode('utf-8', errors='ignore')
        streams = re.findall(r'data-stream=\"([^\"]+)\"', html)
        keywords = ['swamp', 'boogie', 'randb', 'r-b']
        for s in streams:
            if target_date in s and any(k in s.lower() for k in keywords):
                print(s)
                sys.exit(0)
except Exception as e:
    pass
sys.exit(1)
" 2>/dev/null || true
}

process_and_publish() {
  local input_file="$1"
  log "Embedding ID3v2 metadata and album artwork..."
  if [ -f "${COVER_ART}" ]; then
    ffmpeg -y \
      -i "${input_file}" \
      -i "${COVER_ART}" \
      -map 0:a -map 1:v \
      -c:a copy -c:v copy \
      -id3v2_version 3 \
      -metadata:s:v title="Album cover" \
      -metadata:s:v comment="Cover (front)" \
      -metadata artist="${DJ_NAME}" \
      -metadata album_artist="${SHOW_NAME}" \
      -metadata album="${SHOW_NAME} (${YEAR})" \
      -metadata title="${SHOW_NAME} - ${AIR_DATE}" \
      -metadata date="${AIR_DATE}" \
      -metadata year="${YEAR}" \
      -metadata publisher="${STATION_NAME}" \
      -metadata genre="Rhythm & Blues / Soul" \
      -metadata comment="Broadcast live on ${STATION_NAME} (New Orleans Jazz & Heritage Foundation) - ${SHOW_NAME}." \
      "${OUTPUT_FILE}"
  else
    ffmpeg -y \
      -i "${input_file}" \
      -c copy \
      -id3v2_version 3 \
      -metadata artist="${DJ_NAME}" \
      -metadata album_artist="${SHOW_NAME}" \
      -metadata album="${SHOW_NAME} (${YEAR})" \
      -metadata title="${SHOW_NAME} - ${AIR_DATE}" \
      -metadata date="${AIR_DATE}" \
      -metadata year="${YEAR}" \
      -metadata publisher="${STATION_NAME}" \
      -metadata genre="Rhythm & Blues / Soul" \
      -metadata comment="Broadcast live on ${STATION_NAME} (New Orleans Jazz & Heritage Foundation) - ${SHOW_NAME}." \
      "${OUTPUT_FILE}"
  fi

  log "Published recording to: ${OUTPUT_FILE}"

  # Sync to Plex remote library share if reachable
  if ping -c 1 -W 2 "${PLEX_SERVER_IP}" >/dev/null 2>&1; then
    log "Syncing show directory to Plex server (plexuser@${PLEX_SERVER_IP}:/mnt/plex/radio/${SHOW_NAME}/)..."
    rsync -avz --quiet "${DEST_DIR}/" "plexuser@${PLEX_SERVER_IP}:/mnt/plex/radio/${SHOW_NAME}/" 2>/dev/null || log "Warning: Rsync to Plex server had non-zero exit, continuing..."
  fi

  # Notify Plex to rescan section
  curl -s -X GET "http://${PLEX_SERVER_IP}:32400/library/sections/${PLEX_SECTION_ID}/refresh" >/dev/null 2>&1 || true
  curl -s -X GET "http://127.0.0.1:32400/library/sections/${PLEX_SECTION_ID}/refresh" >/dev/null 2>&1 || true
  log "Plex radio library refresh signal sent."

  rm -rf "${TEMP_DIR}"
}

MODE="${1:-auto}"

log "Initializing WWOZ recorder/harvester for '${SHOW_NAME}' (${AIR_DATE}), mode: ${MODE}"

case "${MODE}" in
  --live|live)
    RECORD_SECONDS="${RECORD_SECONDS:-10800}"
    log "Capturing live stream from ${STREAM_URL} for ${RECORD_SECONDS}s..."
    ffmpeg -y \
      -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
      -i "${STREAM_URL}" \
      -t "${RECORD_SECONDS}" \
      -c:a libmp3lame -b:a 192k \
      "${RAW_FILE}"
    process_and_publish "${RAW_FILE}"
    ;;

  --archive-now|archive-now)
    ARCHIVE_URL="$(find_archive_url)"
    if [ -n "${ARCHIVE_URL}" ]; then
      log "Found on-demand archive: ${ARCHIVE_URL}"
      log "Downloading full broadcast archive..."
      curl -fSL "${ARCHIVE_URL}" -o "${RAW_FILE}"
      process_and_publish "${RAW_FILE}"
    else
      log "Archive for ${AIR_DATE} not available yet."
      exit 1
    fi
    ;;

  --wait-archive|auto)
    # Check if archive already published
    ARCHIVE_URL="$(find_archive_url)"
    if [ -n "${ARCHIVE_URL}" ]; then
      log "Archive is already available: ${ARCHIVE_URL}"
      log "Downloading complete 3-hour broadcast from WWOZ archive..."
      curl -fSL "${ARCHIVE_URL}" -o "${RAW_FILE}"
      process_and_publish "${RAW_FILE}"
      exit 0
    fi

    # Show airs Monday 7:00 PM - 10:00 PM CST (8:00 PM - 11:00 PM EST).
    # Calculate seconds until 23:00:30 EST
    NOW_SEC=$(date +%s)
    END_SEC=$(date -d "${AIR_DATE} 23:00:30" +%s 2>/dev/null || date -d "23:00:30" +%s)
    WAIT_SEC=$(( END_SEC - NOW_SEC ))

    if [ "${WAIT_SEC}" -gt 0 ]; then
      log "Program is currently airing (7:00 PM - 10:00 PM CST / 8:00 PM - 11:00 PM EST)."
      log "Waiting ${WAIT_SEC} seconds until program ends at 11:00 PM EST before retrieving from archive..."
      sleep "${WAIT_SEC}"
    fi

    log "Program window ended. Polling WWOZ archive for published file..."
    MAX_RETRIES=40
    RETRY_COUNT=0
    ARCHIVE_URL=""

    while [ "${RETRY_COUNT}" -lt "${MAX_RETRIES}" ]; do
      ARCHIVE_URL="$(find_archive_url)"
      if [ -n "${ARCHIVE_URL}" ]; then
        break
      fi
      RETRY_COUNT=$(( RETRY_COUNT + 1 ))
      log "Archive not published yet. Retry ${RETRY_COUNT}/${MAX_RETRIES} in 30 seconds..."
      sleep 30
    done

    if [ -n "${ARCHIVE_URL}" ]; then
      log "Discovered published archive: ${ARCHIVE_URL}"
      log "Downloading complete broadcast..."
      curl -fSL "${ARCHIVE_URL}" -o "${RAW_FILE}"
      process_and_publish "${RAW_FILE}"
    else
      log "Error: Timed out waiting for archive publication after ${MAX_RETRIES} retries."
      exit 1
    fi
    ;;

  *)
    echo "Usage: $0 [--wait-archive | --archive-now | --live]"
    exit 1
    ;;
esac
