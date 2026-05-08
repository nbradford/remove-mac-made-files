#!/usr/bin/env bash
set -euo pipefail

# update_genre_playlist_no_deps.sh
# No extra deps; best-effort ID3v2 TCON and ID3v1 genre extraction with standard macOS tools.
# Prompts for: root directory to search, genre, and playlist path.
# Usage: ./update_genre_playlist_no_deps.sh

prompt() {
  local varname="$1"; local prompt_text="$2"; local default="${3:-}"; local value=""
  if [[ -n "$default" ]]; then
    read -r -p "$prompt_text [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$prompt_text: " value
  fi
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf -v "$varname" '%s' "$value"
}

# --- ID3 reading (best-effort) ---

read_id3v2_genre() {
  local file="$1"
  if ! dd if="$file" bs=1 count=3 2>/dev/null | grep -q "^ID3"; then
    echo ""
    return
  fi

  local b1 b2 b3 b4
  read -r b1 b2 b3 b4 < <(dd if="$file" bs=1 skip=6 count=4 2>/dev/null | od -An -t u1)
  local tag_size=$(( (b1<<21) + (b2<<14) + (b3<<7) + b4 ))
  if (( tag_size <= 0 )); then
    echo ""
    return
  fi

  local hex
  hex=$(dd if="$file" bs=1 skip=10 count="$tag_size" 2>/dev/null | xxd -p -c 100000 2>/dev/null || true)
  if [[ -z "$hex" ]]; then
    echo ""
    return
  fi

  local idx_hex
  idx_hex=$(echo "$hex" | grep -b -o '54434f4e' | awk -F: '{print $1; exit}' || true)
  if [[ -z "$idx_hex" ]]; then
    echo ""
    return
  fi

  local byte_offset=$(( idx_hex / 2 ))
  local size_hex
  size_hex=$(echo "$hex" | awk -v s="$idx_hex" '{print substr($0, s+9, 8)}')
  if [[ -z "$size_hex" ]]; then
    echo ""
    return
  fi

  local fsize=0
  if [[ "$size_hex" =~ ^[0-9a-fA-F]{8}$ ]]; then
    fsize=$((16#${size_hex}))
  fi
  if (( fsize <= 0 )); then
    echo ""
    return
  fi

  local frame_start_char=$(( byte_offset*2 + 1 ))
  local payload_start_char=$(( frame_start_char + 20 ))
  local payload_hex
  payload_hex=$(echo "$hex" | cut -c${payload_start_char}-$(( payload_start_char + fsize*2 -1 )))
  if [[ -z "$payload_hex" ]]; then
    echo ""
    return
  fi

  local tmpbin
  tmpbin="$(mktemp)"
  echo "$payload_hex" | sed 's/../& /g' > "${tmpbin}.hex"
  if command -v xxd >/dev/null 2>&1; then
    xxd -r -p "${tmpbin}.hex" > "$tmpbin" 2>/dev/null || true
  else
    awk '{for(i=1;i<=NF;i++) printf("%c", "0x"$i)}' "${tmpbin}.hex" > "$tmpbin" 2>/dev/null || true
  fi
  rm -f "${tmpbin}.hex"

  if [[ ! -s "$tmpbin" ]]; then
    rm -f "$tmpbin"
    echo ""
    return
  fi

  local first_byte
  first_byte=$(dd if="$tmpbin" bs=1 count=1 2>/dev/null | od -An -t u1 | awk '{$1=$1;print}')
  local textbin
  textbin=$(dd if="$tmpbin" bs=1 skip=1 2>/dev/null)
  rm -f "$tmpbin"

  if [[ "$first_byte" -eq 1 ]]; then
    if command -v iconv >/dev/null 2>&1; then
      printf '%s' "$textbin" | iconv -f utf-16 -t utf-8 2>/dev/null || printf '%s' "$textbin"
    else
      printf '%s' "$textbin" | tr -d '\000' 2>/dev/null || printf '%s' "$textbin"
    fi
  else
    printf '%s' "$textbin"
  fi
}

read_id3v1_genre() {
  local file="$1"
  local fsize
  if ! fsize=$(stat -f%z "$file" 2>/dev/null); then
    fsize=0
  fi
  if (( fsize < 128 )); then
    echo ""
    return
  fi
  if ! dd if="$file" bs=1 skip=$((fsize - 128)) count=3 2>/dev/null | grep -q "^TAG"; then
    echo ""
    return
  fi
  local gid
  gid=$(dd if="$file" bs=1 skip=$((fsize - 1)) count=1 2>/dev/null | od -An -t u1 | awk '{$1=$1;print}')
  local -a gmap=( "Blues" "Classic Rock" "Country" "Dance" "Disco" "Funk" "Grunge" "Hip-Hop" "Jazz" "Metal" "New Age" "Oldies" "Other" "Pop" "R&B" "Rap" "Reggae" "Rock" "Techno" "Industrial" "Alternative" "Ska" "Death Metal" "Pranks" "Soundtrack" "Euro-Techno" "Ambient" "Trip-Hop" "Vocal" "Jazz+Funk" "Fusion" "Trance" "Classical" "Instrumental" "Acid" "House" "Game" "Sound Clip" "Gospel" "Noise" "AlternRock" "Bass" "Soul" "Punk" "Space" "Meditative" "Instrumental Pop" "Instrumental Rock" "Ethnic" "Gothic" "Darkwave" "Techno-Industrial" "Electronic" "Pop-Folk" "Eurodance" "Dream" "Southern Rock" "Comedy" "Cult" "Gangsta" "Top 40" "Christian Rap" "Pop/Funk" "Jungle" "Native US" "Cabaret" "New Wave" "Psychadelic" "Rave" "Showtunes" "Trailer" "Lo-Fi" "Tribal" "Acid Punk" "Acid Jazz" "Polka" "Retro" "Musical" "Rock & Roll" "Hard Rock" )
  if [[ -n "$gid" && "$gid" -ge 0 && "$gid" -lt "${#gmap[@]}" ]]; then
    echo "${gmap[$gid]}"
  else
    echo ""
  fi
}

read_genre() {
  local f="$1"
  local g
  g=$(read_id3v2_genre "$f" 2>/dev/null || true)
  g="${g:-}"
  g="$(printf '%s' "$g" | awk '{$1=$1; print}')"
  if [[ -n "$g" ]]; then
    echo "$g"
    return
  fi
  g=$(read_id3v1_genre "$f" 2>/dev/null || true)
  g="${g:-}"
  g="$(printf '%s' "$g" | awk '{$1=$1; print}')"
  echo "$g"
}

# --- Main ---

prompt ROOT_DIR "Enter root directory to search for mp3s" "$PWD"
prompt GENRE "Enter target genre (matches case-insensitively)"
prompt PLAYLIST "Enter path to .m3u playlist to update (will be created if missing)" "$PWD/playlist.m3u"

TARGET_RAW="$GENRE"
TARGET="$(printf '%s' "$TARGET_RAW" | tr '[:upper:]' '[:lower:]')"

PLAYLIST="${PLAYLIST/#\~/$HOME}"
ROOT_DIR="${ROOT_DIR/#\~/$HOME}"

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "Root directory '$ROOT_DIR' does not exist."
  exit 1
fi

if [[ "$PLAYLIST" == */* ]]; then
  PLAYLIST_DIR="$(dirname "$PLAYLIST")"
  if ! mkdir -p "$PLAYLIST_DIR" 2>/dev/null; then
    PLAYLIST_DIR="$HOME/Playlists"
    mkdir -p "$PLAYLIST_DIR"
    PLAYLIST="$PLAYLIST_DIR/$(basename "$PLAYLIST")"
  fi
else
  PLAYLIST_DIR="$PWD"
  PLAYLIST="$PLAYLIST_DIR/$PLAYLIST"
fi

touch "$PLAYLIST"
PLAYLIST="$(perl -MFile::Spec -le 'print File::Spec->rel2abs($ARGV[0])' -- "$PLAYLIST" 2>/dev/null || realpath "$PLAYLIST" 2>/dev/null || printf '%s' "$PLAYLIST")"

echo "Updating playlist: $PLAYLIST"
echo "Searching under: $ROOT_DIR for MP3s whose genre matches: $TARGET_RAW (case-insensitive)"

# Build temporary existing-entry list (safe for non-UTF8 bytes)
TMP_EXIST="$(mktemp)"
(
  LC_ALL=C
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -z "$line" || "${line:0:1}" == "#" ]]; then
      continue
    fi
    printf '%s\n' "$line"
  done < "$PLAYLIST"
) > "$TMP_EXIST" || :

# Walk files
find "$ROOT_DIR" -type f \( -iname '*.mp3' \) -print0 |
while IFS= read -r -d '' mp3; do
  genre_raw=$(read_genre "$mp3" || true)
  genre_norm="$(printf '%s' "$genre_raw" | LC_ALL=C awk '{$1=$1; print tolower($0)}')"
  if [[ -z "$genre_norm" ]]; then
    continue
  fi
  if [[ "$genre_norm" == *"$TARGET"* ]]; then
    entry="$mp3"
    if command -v realpath >/dev/null 2>&1; then
      if realpath --help >/dev/null 2>&1 2>/dev/null; then
        entry_rel=$(realpath --relative-to="$(dirname "$PLAYLIST")" "$mp3" 2>/dev/null || true)
        if [[ -n "$entry_rel" ]]; then
          entry="$entry_rel"
        fi
      else
        if command -v python3 >/dev/null 2>&1; then
          entry_rel=$(python3 - <<PY
import os,sys
print(os.path.relpath(sys.argv[1], sys.argv[2]))
PY
 "$mp3" "$(dirname "$PLAYLIST")" 2>/dev/null || true)
          if [[ -n "$entry_rel" ]]; then
            entry="$entry_rel"
          fi
        fi
      fi
    fi

    if ! LC_ALL=C grep -Fqx -- "$entry" "$TMP_EXIST" 2>/dev/null; then
      echo "$entry" >> "$PLAYLIST"
      echo "$entry" >> "$TMP_EXIST"
      echo "Added: $entry"
    fi
  fi
done

rm -f "$TMP_EXIST"
echo "Done."
#!/usr/bin/env bash
set -euo pipefail

# update_genre_playlist_no_deps.sh
# No extra deps; best-effort ID3v2 TCON and ID3v1 genre extraction with standard macOS tools.
# Prompts for: root directory to search, genre, and playlist path.
# Usage: ./update_genre_playlist_no_deps.sh

prompt() {
  local varname="$1"; local prompt_text="$2"; local default="${3:-}"; local value=""
  if [[ -n "$default" ]]; then
    read -r -p "$prompt_text [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$prompt_text: " value
  fi
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf -v "$varname" '%s' "$value"
}

# --- ID3 reading (best-effort) ---

read_id3v2_genre() {
  local file="$1"
  if ! dd if="$file" bs=1 count=3 2>/dev/null | grep -q "^ID3"; then
    echo ""
    return
  fi

  local b1 b2 b3 b4
  read -r b1 b2 b3 b4 < <(dd if="$file" bs=1 skip=6 count=4 2>/dev/null | od -An -t u1)
  local tag_size=$(( (b1<<21) + (b2<<14) + (b3<<7) + b4 ))
  if (( tag_size <= 0 )); then
    echo ""
    return
  fi

  local hex
  hex=$(dd if="$file" bs=1 skip=10 count="$tag_size" 2>/dev/null | xxd -p -c 100000 2>/dev/null || true)
  if [[ -z "$hex" ]]; then
    echo ""
    return
  fi

  local idx_hex
  idx_hex=$(echo "$hex" | grep -b -o '54434f4e' | awk -F: '{print $1; exit}' || true)
  if [[ -z "$idx_hex" ]]; then
    echo ""
    return
  fi

  local byte_offset=$(( idx_hex / 2 ))
  local size_hex
  size_hex=$(echo "$hex" | awk -v s="$idx_hex" '{print substr($0, s+9, 8)}')
  if [[ -z "$size_hex" ]]; then
    echo ""
    return
  fi

  local fsize=0
  if [[ "$size_hex" =~ ^[0-9a-fA-F]{8}$ ]]; then
    fsize=$((16#${size_hex}))
  fi
  if (( fsize <= 0 )); then
    echo ""
    return
  fi

  local frame_start_char=$(( byte_offset*2 + 1 ))
  local payload_start_char=$(( frame_start_char + 20 ))
  local payload_hex
  payload_hex=$(echo "$hex" | cut -c${payload_start_char}-$(( payload_start_char + fsize*2 -1 )))
  if [[ -z "$payload_hex" ]]; then
    echo ""
    return
  fi

  local tmpbin
  tmpbin="$(mktemp)"
  echo "$payload_hex" | sed 's/../& /g' > "${tmpbin}.hex"
  if command -v xxd >/dev/null 2>&1; then
    xxd -r -p "${tmpbin}.hex" > "$tmpbin" 2>/dev/null || true
  else
    awk '{for(i=1;i<=NF;i++) printf("%c", "0x"$i)}' "${tmpbin}.hex" > "$tmpbin" 2>/dev/null || true
  fi
  rm -f "${tmpbin}.hex"

  if [[ ! -s "$tmpbin" ]]; then
    rm -f "$tmpbin"
    echo ""
    return
  fi

  local first_byte
  first_byte=$(dd if="$tmpbin" bs=1 count=1 2>/dev/null | od -An -t u1 | awk '{$1=$1;print}')
  local textbin
  textbin=$(dd if="$tmpbin" bs=1 skip=1 2>/dev/null)
  rm -f "$tmpbin"

  if [[ "$first_byte" -eq 1 ]]; then
    if command -v iconv >/dev/null 2>&1; then
      printf '%s' "$textbin" | iconv -f utf-16 -t utf-8 2>/dev/null || printf '%s' "$textbin"
    else
      printf '%s' "$textbin" | tr -d '\000' 2>/dev/null || printf '%s' "$textbin"
    fi
  else
    printf '%s' "$textbin"
  fi
}

read_id3v1_genre() {
  local file="$1"
  local fsize
  if ! fsize=$(stat -f%z "$file" 2>/dev/null); then
    fsize=0
  fi
  if (( fsize < 128 )); then
    echo ""
    return
  fi
  if ! dd if="$file" bs=1 skip=$((fsize - 128)) count=3 2>/dev/null | grep -q "^TAG"; then
    echo ""
    return
  fi
  local gid
  gid=$(dd if="$file" bs=1 skip=$((fsize - 1)) count=1 2>/dev/null | od -An -t u1 | awk '{$1=$1;print}')
  local -a gmap=( "Blues" "Classic Rock" "Country" "Dance" "Disco" "Funk" "Grunge" "Hip-Hop" "Jazz" "Metal" "New Age" "Oldies" "Other" "Pop" "R&B" "Rap" "Reggae" "Rock" "Techno" "Industrial" "Alternative" "Ska" "Death Metal" "Pranks" "Soundtrack" "Euro-Techno" "Ambient" "Trip-Hop" "Vocal" "Jazz+Funk" "Fusion" "Trance" "Classical" "Instrumental" "Acid" "House" "Game" "Sound Clip" "Gospel" "Noise" "AlternRock" "Bass" "Soul" "Punk" "Space" "Meditative" "Instrumental Pop" "Instrumental Rock" "Ethnic" "Gothic" "Darkwave" "Techno-Industrial" "Electronic" "Pop-Folk" "Eurodance" "Dream" "Southern Rock" "Comedy" "Cult" "Gangsta" "Top 40" "Christian Rap" "Pop/Funk" "Jungle" "Native US" "Cabaret" "New Wave" "Psychadelic" "Rave" "Showtunes" "Trailer" "Lo-Fi" "Tribal" "Acid Punk" "Acid Jazz" "Polka" "Retro" "Musical" "Rock & Roll" "Hard Rock" )
  if [[ -n "$gid" && "$gid" -ge 0 && "$gid" -lt "${#gmap[@]}" ]]; then
    echo "${gmap[$gid]}"
  else
    echo ""
  fi
}

read_genre() {
  local f="$1"
  local g
  g=$(read_id3v2_genre "$f" 2>/dev/null || true)
  g="${g:-}"
  g="$(printf '%s' "$g" | awk '{$1=$1; print}')"
  if [[ -n "$g" ]]; then
    echo "$g"
    return
  fi
  g=$(read_id3v1_genre "$f" 2>/dev/null || true)
  g="${g:-}"
  g="$(printf '%s' "$g" | awk '{$1=$1; print}')"
  echo "$g"
}

# --- Main ---

prompt ROOT_DIR "Enter root directory to search for mp3s" "$PWD"
prompt GENRE "Enter target genre (matches case-insensitively)"
prompt PLAYLIST "Enter path to .m3u playlist to update (will be created if missing)" "$PWD/playlist.m3u"

TARGET_RAW="$GENRE"
TARGET="$(printf '%s' "$TARGET_RAW" | tr '[:upper:]' '[:lower:]')"

PLAYLIST="${PLAYLIST/#\~/$HOME}"
ROOT_DIR="${ROOT_DIR/#\~/$HOME}"

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "Root directory '$ROOT_DIR' does not exist."
  exit 1
fi

if [[ "$PLAYLIST" == */* ]]; then
  PLAYLIST_DIR="$(dirname "$PLAYLIST")"
  if ! mkdir -p "$PLAYLIST_DIR" 2>/dev/null; then
    PLAYLIST_DIR="$HOME/Playlists"
    mkdir -p "$PLAYLIST_DIR"
    PLAYLIST="$PLAYLIST_DIR/$(basename "$PLAYLIST")"
  fi
else
  PLAYLIST_DIR="$PWD"
  PLAYLIST="$PLAYLIST_DIR/$PLAYLIST"
fi

touch "$PLAYLIST"
PLAYLIST="$(perl -MFile::Spec -le 'print File::Spec->rel2abs($ARGV[0])' -- "$PLAYLIST" 2>/dev/null || realpath "$PLAYLIST" 2>/dev/null || printf '%s' "$PLAYLIST")"

echo "Updating playlist: $PLAYLIST"
echo "Searching under: $ROOT_DIR for MP3s whose genre matches: $TARGET_RAW (case-insensitive)"

# Build temporary existing-entry list (safe for non-UTF8 bytes)
TMP_EXIST="$(mktemp)"
(
  LC_ALL=C
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -z "$line" || "${line:0:1}" == "#" ]]; then
      continue
    fi
    printf '%s\n' "$line"
  done < "$PLAYLIST"
) > "$TMP_EXIST" || :

# Walk files
find "$ROOT_DIR" -type f \( -iname '*.mp3' \) -print0 |
while IFS= read -r -d '' mp3; do
  genre_raw=$(read_genre "$mp3" || true)
  genre_norm="$(printf '%s' "$genre_raw" | LC_ALL=C awk '{$1=$1; print tolower($0)}')"
  if [[ -z "$genre_norm" ]]; then
    continue
  fi
  if [[ "$genre_norm" == *"$TARGET"* ]]; then
    entry="$mp3"
    if command -v realpath >/dev/null 2>&1; then
      if realpath --help >/dev/null 2>&1 2>/dev/null; then
        entry_rel=$(realpath --relative-to="$(dirname "$PLAYLIST")" "$mp3" 2>/dev/null || true)
        if [[ -n "$entry_rel" ]]; then
          entry="$entry_rel"
        fi
      else
        if command -v python3 >/dev/null 2>&1; then
          entry_rel=$(python3 - <<PY
import os,sys
print(os.path.relpath(sys.argv[1], sys.argv[2]))
PY
 "$mp3" "$(dirname "$PLAYLIST")" 2>/dev/null || true)
          if [[ -n "$entry_rel" ]]; then
            entry="$entry_rel"
          fi
        fi
      fi
    fi

    if ! LC_ALL=C grep -Fqx -- "$entry" "$TMP_EXIST" 2>/dev/null; then
      echo "$entry" >> "$PLAYLIST"
      echo "$entry" >> "$TMP_EXIST"
      echo "Added: $entry"
    fi
  fi
done

rm -f "$TMP_EXIST"
echo "Done."
