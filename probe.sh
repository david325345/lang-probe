#!/usr/bin/env bash
# =====================================================================
# NimeToDex lang-probe — FÁZE 2
# Vezme dávky torrentů bez jazyků z indexeru, pro cached MKV vytáhne
# jazyky stop (curl 256 KB range -> mkvmerge -J) a zapíše výsledky do
# JSONL souboru. NEPOSÍLÁ nic zpět do indexeru (to je fáze 3).
#
# Cached-only: necached se přeskočí. Ne-MKV (.avi/.mp4) se přeskočí.
# Zip (TorBox drží torrent jako .zip) se přeskočí. Po probu se torrent
# smaže z TorBox accountu, ať se nehromadí sloty.
#
# Ruční spuštění:   bash /app/probe.sh --limit 10
# Noční cron:       bash /app/probe.sh --limit 100   (viz crontab)
# =====================================================================

set -uo pipefail

# ---- Konfigurace (env s rozumnými defaulty) ----
INDEXER_URL="${INDEXER_URL:-http://indexer:3003}"
TORBOX_API="${TORBOX_API:-https://api.torbox.app/v1/api}"
LIMIT="${PROBE_LIMIT:-100}"          # max torrentů za běh (strop /noc)
BATCH_SIZE="${PROBE_BATCH_SIZE:-50}" # kolik si vzít z indexeru na dávku
SLEEP_BETWEEN="${PROBE_SLEEP:-20}"   # rozestup mezi torrenty (s)
RANGE_BYTES="${PROBE_RANGE:-262143}" # 256 KB - 1
OUT="${PROBE_OUT:-/tmp/results.jsonl}"
TMP="/tmp/probe_work.bin"

# ---- Argumenty ----
while [ $# -gt 0 ]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --out)   OUT="$2"; shift 2 ;;
    *) echo "Neznámý argument: $1" >&2; exit 1 ;;
  esac
done

# ---- Kontrola prostředí ----
for bin in curl jq mkvmerge od; do
  command -v "$bin" >/dev/null 2>&1 || { echo "CHYBÍ nástroj: $bin" >&2; exit 1; }
done
[ -n "${TORBOX_API_KEY:-}" ] || { echo "CHYBÍ env TORBOX_API_KEY" >&2; exit 1; }
[ -n "${INDEXER_USER:-}" ] && [ -n "${INDEXER_PASS:-}" ] || { echo "CHYBÍ env INDEXER_USER / INDEXER_PASS" >&2; exit 1; }

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# JSONL řádek přes jq (bezpečné escapování názvů s [] a diakritikou)
emit() {
  # emit <id> <infohash> <status> <subs_csv> <audio_csv> <name>
  jq -cn \
    --argjson id "$1" \
    --arg hash "$2" \
    --arg status "$3" \
    --arg subs "$4" \
    --arg audio "$5" \
    --arg name "$6" \
    '{id:$id, infohash:$hash, status:$status,
      subtitle_langs: ($subs | if .=="" then [] else split(",") end),
      audio_langs:    ($audio | if .=="" then [] else split(",") end),
      name:$name, ts: (now|todate)}' >> "$OUT"
}

# ---- Login -> token ----
login() {
  local resp
  resp=$(curl -s -m 15 -X POST "$INDEXER_URL/api/login" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$INDEXER_USER" --arg p "$INDEXER_PASS" '{username:$u,password:$p}')")
  TOKEN=$(echo "$resp" | jq -r '.token // empty')
  [ -n "$TOKEN" ] || { echo "Login selhal: $resp" >&2; exit 1; }
  log "Login OK (token ${#TOKEN} znaků)"
}

# ---- TorBox helpery ----
tb_checkcached() {  # arg: comma-separated hashes -> JSON data objekt
  curl -s -m 15 "$TORBOX_API/torrents/checkcached?hash=$1&format=object" \
    -H "Authorization: Bearer $TORBOX_API_KEY" | jq -c '.data // {}'
}
tb_add() {          # arg: hash -> torrent_id | prázdno
  curl -s -m 20 -X POST "$TORBOX_API/torrents/createtorrent" \
    -H "Authorization: Bearer $TORBOX_API_KEY" \
    -F "magnet=magnet:?xt=urn:btih:$1" | jq -r '.data.torrent_id // empty'
}
tb_files() {        # arg: torrent_id -> JSON files[]
  curl -s -m 15 "$TORBOX_API/torrents/mylist?id=$1&bypass_cache=true" \
    -H "Authorization: Bearer $TORBOX_API_KEY" | jq -c '.data.files // []'
}
tb_dl() {           # args: torrent_id file_id -> URL
  curl -s -m 15 "$TORBOX_API/torrents/requestdl?token=$TORBOX_API_KEY&torrent_id=$1&file_id=$2" \
    -H "Authorization: Bearer $TORBOX_API_KEY" | jq -r '.data // empty'
}
tb_delete() {       # arg: torrent_id
  curl -s -m 15 -X POST "$TORBOX_API/torrents/controltorrent" \
    -H "Authorization: Bearer $TORBOX_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"torrent_id\":$1,\"operation\":\"delete\"}" >/dev/null 2>&1
}

# ---- Výběr souboru z TorBox files[] podle indexer hintu ----
# Priorita: 1) basename(short_name)==basename(hint) 2) přesná size
#           3) size ±0.1% 4) první video soubor
# Vrací: "<file_id>\t<mimetype>\t<short_name>"  nebo prázdno když žádný video soubor
pick_file() {
  local files="$1" hint_name="$2" hint_size="$3"
  local base_hint; base_hint=$(basename "$hint_name")

  # jen video soubory (mkv/mp4/avi/webm)
  local vids
  vids=$(echo "$files" | jq -c '[.[] | select((.short_name // .name // "")
          | ascii_downcase | test("\\.(mkv|webm|mp4|mov|m4v|avi)$"))]')
  [ "$(echo "$vids" | jq 'length')" -gt 0 ] || { echo ""; return; }

  # 1) basename match
  local hit
  hit=$(echo "$vids" | jq -c --arg b "$base_hint" \
    'map(select(((.short_name // .name) | split("/") | last) == $b)) | .[0] // empty')
  # 2) přesná size
  [ -z "$hit" ] && [ "$hint_size" -gt 0 ] 2>/dev/null && \
    hit=$(echo "$vids" | jq -c --argjson s "$hint_size" 'map(select(.size == $s)) | .[0] // empty')
  # 3) size ±0.1 %
  if [ -z "$hit" ] && [ "$hint_size" -gt 0 ] 2>/dev/null; then
    local tol=$(( hint_size / 1000 ))
    hit=$(echo "$vids" | jq -c --argjson s "$hint_size" --argjson t "$tol" \
      'map(select((.size - $s | fabs) <= $t)) | sort_by(.size - $s | fabs) | .[0] // empty')
  fi
  # 4) první video
  [ -z "$hit" ] && hit=$(echo "$vids" | jq -c '.[0]')

  local fid mt sn
  fid=$(echo "$hit" | jq -r '.id')
  mt=$(echo "$hit"  | jq -r '.mimetype // ""')
  # reálné jméno souboru v TorBoxu (má vždy správnou příponu, na rozdíl od hintu)
  sn=$(echo "$hit"  | jq -r '(.short_name // .name // "") | split("/") | last')
  printf '%s\t%s\t%s' "$fid" "$mt" "$sn"
}

# ---- Probe MKV/WebM: range download + mkvmerge -> jazyky ----
# Vrací status na stdout: "ok|SUBS_CSV|AUDIO_CSV"  nebo  "empty|..." nebo "error||"
probe_mkv() {
  local url="$1"
  curl -s -m 30 -r "0-$RANGE_BYTES" -o "$TMP" "$url" || { echo "error||"; return; }

  # ověř MKV magic (1a 45 df a3); jinak neprobovatelné
  local magic; magic=$(od -A n -t x1 -N 4 "$TMP" | tr -d ' \n')
  [ "$magic" = "1a45dfa3" ] || { echo "error||"; return; }

  local j; j=$(mkvmerge -J "$TMP" 2>/dev/null)
  [ -n "$j" ] || { echo "error||"; return; }

  # subtitle + audio jazyky (IETF, fallback na language); video ignorujeme
  local subs audio
  subs=$(echo "$j" | jq -r '[.tracks[] | select(.type=="subtitles")
          | (.properties.language_ietf // .properties.language // "und")] | unique | join(",")')
  audio=$(echo "$j" | jq -r '[.tracks[] | select(.type=="audio")
          | (.properties.language_ietf // .properties.language // "und")] | unique | join(",")')

  local clean; clean=$(echo "$subs$audio" | tr -d ',und')
  if [ -z "$clean" ]; then echo "empty|$subs|$audio"; else echo "ok|$subs|$audio"; fi
}

# ---- Probe MP4/MOV: ffprobe čte přímo přes HTTP (bez lokálního stažení) ----
# ffprobe si sám vezme přes range jen hlavičku; u MP4 s moov na konci udělá
# 2 range requesty (začátek + konec), pořád levné. Jazyky z streams[].tags.language
# (ISO 639-2, normalizace až ve fázi 3). Vrací stejný formát jako probe_mkv.
probe_mp4() {
  local url="$1"
  local j
  j=$(ffprobe -v quiet -print_format json -show_streams \
        -analyzeduration 0 -probesize 2M "$url" 2>/dev/null)
  [ -n "$j" ] || { echo "error||"; return; }

  local subs audio
  subs=$(echo "$j" | jq -r '[.streams[] | select(.codec_type=="subtitle")
          | (.tags.language // "und")] | unique | join(",")')
  audio=$(echo "$j" | jq -r '[.streams[] | select(.codec_type=="audio")
          | (.tags.language // "und")] | unique | join(",")')

  # ffprobe nevrátil žádný stream -> error (ne empty)
  local nstreams; nstreams=$(echo "$j" | jq '.streams | length')
  [ "$nstreams" -gt 0 ] 2>/dev/null || { echo "error||"; return; }

  local clean; clean=$(echo "$subs$audio" | tr -d ',und')
  if [ -z "$clean" ]; then echo "empty|$subs|$audio"; else echo "ok|$subs|$audio"; fi
}

# ---- Rozcestník: podle přípony REÁLNÉHO jména (short_name z TorBoxu) ----
# short_name má spolehlivou příponu (na rozdíl od hint jména z indexeru, které
# někdy končí tagem/}). Když přípona chybí i tady, rozhodne mimetype; a když ani
# ten ne, default = mkvmerge (anime je z ~95 % MKV, magic-check to stejně ověří).
probe_langs() {
  local url="$1" name="$2" mime="$3"
  if echo "$name" | grep -qiE '\.(mkv|webm)$'; then
    probe_mkv "$url"
  elif echo "$name" | grep -qiE '\.(mp4|mov|m4v)$'; then
    probe_mp4 "$url"
  elif echo "$mime" | grep -qi 'matroska\|webm'; then
    probe_mkv "$url"
  elif echo "$mime" | grep -qi 'mp4\|quicktime'; then
    probe_mp4 "$url"
  else
    # neznámá přípona i mimetype -> zkus mkvmerge (magic-check uvnitř ověří MKV)
    probe_mkv "$url"
  fi
}

# =====================================================================
# HLAVNÍ SMYČKA
# =====================================================================
login
: > "$OUT"   # vyprázdnit výstup pro tento běh
log "Start — limit=$LIMIT, batch=$BATCH_SIZE, sleep=${SLEEP_BETWEEN}s, out=$OUT"

processed=0
after_id=0

while [ "$processed" -lt "$LIMIT" ]; do
  # --- dávka z indexeru ---
  batch=$(curl -s -m 20 "$INDEXER_URL/api/admin/lang-probe/batch?limit=$BATCH_SIZE&afterId=$after_id" \
    -H "Authorization: Bearer $TOKEN")
  n=$(echo "$batch" | jq '.items | length' 2>/dev/null || echo 0)
  [ "$n" -gt 0 ] || { log "Žádné další položky — konec."; break; }

  # --- hromadný checkcached na celou dávku ---
  hashes=$(echo "$batch" | jq -r '[.items[].infohash] | join(",")')
  cached=$(tb_checkcached "$hashes")   # objekt {hash:{...}}

  # --- iterace přes položky ---
  count=$(echo "$batch" | jq '.items | length')
  i=0
  while [ "$i" -lt "$count" ] && [ "$processed" -lt "$LIMIT" ]; do
    item=$(echo "$batch" | jq -c ".items[$i]")
    i=$((i+1))

    id=$(echo "$item"     | jq -r '.id')
    hash=$(echo "$item"   | jq -r '.infohash')
    hname=$(echo "$item"  | jq -r '.file_hint.name // ""')
    hsize=$(echo "$item"  | jq -r '.file_hint.size // 0')

    # cached?
    is_cached=$(echo "$cached" | jq --arg h "$hash" 'has($h)')
    if [ "$is_cached" != "true" ]; then
      log "  #$id uncached — skip"
      emit "$id" "$hash" "uncached" "" "" "$hname"
      processed=$((processed+1)); continue
    fi

    # Neprobovatelné formáty — .avi/.wmv nenesou per-stream jazyk,
    # indexer je řeší z názvu. .mp4/.mov/.mkv/.webm jdou dál.
    if echo "$hname" | grep -qiE '\.(avi|wmv|flv|mpg|mpeg|ts)$'; then
      log "  #$id nonmkv ($hname) — indexer řeší z názvu, skip"
      emit "$id" "$hash" "nonmkv" "" "" "$hname"
      processed=$((processed+1)); continue
    fi

    # přidat torrent -> id
    tid=$(tb_add "$hash")
    if [ -z "$tid" ]; then
      log "  #$id createtorrent selhal — skip"
      emit "$id" "$hash" "error" "" "" "$hname"
      processed=$((processed+1)); continue
    fi

    # struktura -> vyber soubor
    files=$(tb_files "$tid")
    picked=$(pick_file "$files" "$hname" "$hsize")
    if [ -z "$picked" ]; then
      log "  #$id žádný video soubor (nejspíš zip) — skip"
      emit "$id" "$hash" "zip" "" "" "$hname"
      tb_delete "$tid"
      processed=$((processed+1)); continue
    fi
    fid=$(printf '%s' "$picked" | cut -f1)
    mt=$(printf '%s'  "$picked" | cut -f2)
    sname=$(printf '%s' "$picked" | cut -f3)   # reálné jméno z TorBoxu (spolehlivá přípona)

    # pojistka na zip mimetype
    if echo "$mt" | grep -qi 'zip'; then
      log "  #$id zip mimetype — skip"
      emit "$id" "$hash" "zip" "" "" "$hname"
      tb_delete "$tid"
      processed=$((processed+1)); continue
    fi

    # requestdl -> URL
    url=$(tb_dl "$tid" "$fid")
    if [ -z "$url" ]; then
      log "  #$id requestdl selhal — skip"
      emit "$id" "$hash" "error" "" "" "$hname"
      tb_delete "$tid"
      processed=$((processed+1)); continue
    fi

    # probe (rozcestník podle REÁLNÉHO jména z TorBoxu + mimetype)
    res=$(probe_langs "$url" "$sname" "$mt")
    st=$(printf '%s'    "$res" | cut -d'|' -f1)
    subs=$(printf '%s'  "$res" | cut -d'|' -f2)
    audio=$(printf '%s' "$res" | cut -d'|' -f3)
    log "  #$id $st  subs=[$subs] audio=[$audio]"
    emit "$id" "$hash" "$st" "$subs" "$audio" "$hname"

    # úklid + rozestup
    tb_delete "$tid"
    processed=$((processed+1))
    [ "$processed" -lt "$LIMIT" ] && sleep "$SLEEP_BETWEEN"
  done

  # posun cursoru
  after_id=$(echo "$batch" | jq -r '.nextAfterId')
  done_flag=$(echo "$batch" | jq -r '.done')
  [ "$done_flag" = "true" ] && { log "Indexer done=true — konec."; break; }
done

log "Hotovo — zpracováno $processed, výstup: $OUT"
