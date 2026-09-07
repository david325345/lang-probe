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

# ---- Normalizace jazykových kódů: ISO 639-2/B a /T -> 639-1 ----
# Kompletní mapa z pycountry (204 kódů, všech 21 dvojitých B/T + zbytek).
# Pořadí: 639-2/3 -> 639-1 přes mapu; regionální (es-419/pt-BR/zh-Hans) -> část
# před pomlčkou; und/mul/mis/zxx zahodit; neznámý (není v mapě, není 2-písm)
# nechat projít + zalogovat do UNKNOWN_LOG pro pozdější doladění.
ISO_MAP='{"aar":"aa","abk":"ab","afr":"af","aka":"ak","alb":"sq","amh":"am","ara":"ar","arg":"an","arm":"hy","asm":"as","ava":"av","ave":"ae","aym":"ay","aze":"az","bak":"ba","bam":"bm","baq":"eu","bel":"be","ben":"bn","bis":"bi","bod":"bo","bos":"bs","bre":"br","bul":"bg","bur":"my","cat":"ca","ces":"cs","cha":"ch","che":"ce","chi":"zh","chu":"cu","chv":"cv","cmn":"zh","cor":"kw","cos":"co","cre":"cr","cym":"cy","cze":"cs","dan":"da","deu":"de","div":"dv","dut":"nl","dzo":"dz","ell":"el","eng":"en","enm":"en","epo":"eo","est":"et","eus":"eu","ewe":"ee","fao":"fo","fas":"fa","fij":"fj","fil":"tl","fin":"fi","fra":"fr","fre":"fr","fry":"fy","ful":"ff","geo":"ka","ger":"de","gla":"gd","gle":"ga","glg":"gl","glv":"gv","gre":"el","grn":"gn","guj":"gu","hat":"ht","hau":"ha","hbs":"sh","heb":"he","her":"hz","hin":"hi","hmo":"ho","hrv":"hr","hun":"hu","hye":"hy","ibo":"ig","ice":"is","ido":"io","iii":"ii","iku":"iu","ile":"ie","ina":"ia","ind":"id","ipk":"ik","isl":"is","ita":"it","jav":"jv","jpn":"ja","kal":"kl","kan":"kn","kas":"ks","kat":"ka","kau":"kr","kaz":"kk","khm":"km","kik":"ki","kin":"rw","kir":"ky","kom":"kv","kon":"kg","kor":"ko","kua":"kj","kur":"ku","lao":"lo","lat":"la","lav":"lv","lim":"li","lin":"ln","lit":"lt","ltz":"lb","lub":"lu","lug":"lg","mac":"mk","mah":"mh","mal":"ml","mao":"mi","mar":"mr","may":"ms","mkd":"mk","mlg":"mg","mlt":"mt","mon":"mn","mri":"mi","msa":"ms","mya":"my","nau":"na","nav":"nv","nbl":"nr","nde":"nd","ndo":"ng","nep":"ne","nld":"nl","nno":"nn","nob":"nb","nor":"no","nya":"ny","oci":"oc","oji":"oj","ori":"or","orm":"om","oss":"os","pan":"pa","per":"fa","pli":"pi","pol":"pl","por":"pt","pus":"ps","que":"qu","roh":"rm","ron":"ro","rum":"ro","run":"rn","rus":"ru","sag":"sg","san":"sa","sin":"si","slk":"sk","slo":"sk","slv":"sl","sme":"se","smo":"sm","sna":"sn","snd":"sd","som":"so","sot":"st","spa":"es","sqi":"sq","srd":"sc","srp":"sr","ssw":"ss","sun":"su","swa":"sw","swe":"sv","tah":"ty","tam":"ta","tat":"tt","tel":"te","tgk":"tg","tgl":"tl","tha":"th","tib":"bo","tir":"ti","ton":"to","tsn":"tn","tso":"ts","tuk":"tk","tur":"tr","twi":"tw","uig":"ug","ukr":"uk","urd":"ur","uzb":"uz","ven":"ve","vie":"vi","vol":"vo","wel":"cy","wln":"wa","wol":"wo","xho":"xh","yid":"yi","yor":"yo","yue":"zh","zha":"za","zho":"zh","zul":"zu"}'
UNKNOWN_LOG="${UNKNOWN_LOG:-/tmp/unknown_langs.log}"

# normalize_langs <comma-separated-codes> -> normalizovaný comma-separated (unique)
normalize_langs() {
  local raw="$1"
  [ -z "$raw" ] && { echo ""; return; }
  echo "$raw" | jq -Rr --argjson map "$ISO_MAP" '
    split(",")
    | map(
        ascii_downcase
        | gsub("^\\s+|\\s+$";"")          # trim
        | . as $orig
        # regionální varianta -> část před pomlčkou (es-419->es, pt-br->pt, zh-hans->zh)
        | (if test("-") then split("-")[0] else . end) as $base
        # zahodit ne-jazyky
        | if ($base | IN("und","mul","mis","zxx","")) then empty
          # už 2-písmenný -> nech
          elif ($base | length == 2) then $base
          # 3-písmenný v mapě -> přelož
          elif ($map[$base] != null) then $map[$base]
          # neznámý -> nech projít (zaloguje se zvlášť v bashi)
          else $base end
      )
    | unique
    | join(",")
  '
}

# log_unknown <comma-separated-codes> — zapíše kódy, co nejsou 2-písm ani v mapě
log_unknown() {
  local raw="$1"
  [ -z "$raw" ] && return
  echo "$raw" | tr ',' '\n' | while read -r c; do
    c=$(echo "$c" | tr '[:upper:]' '[:lower:]' | sed 's/-.*//; s/^ *//; s/ *$//')
    [ -z "$c" ] && continue
    case "$c" in und|mul|mis|zxx) continue;; esac
    [ ${#c} -eq 2 ] && continue
    echo "$ISO_MAP" | jq -e --arg c "$c" 'has($c)' >/dev/null 2>&1 && continue
    echo "$(date '+%Y-%m-%d %H:%M:%S') $c" >> "$UNKNOWN_LOG"
  done
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

  # zaloguj neznámé kódy (ze surových, před normalizací), pak normalizuj na 639-1
  log_unknown "$subs"; log_unknown "$audio"
  subs=$(normalize_langs "$subs")
  audio=$(normalize_langs "$audio")

  # empty = po normalizaci nic nezbylo (jen und/mul/zahozené)
  if [ -z "$subs$audio" ]; then echo "empty|$subs|$audio"; else echo "ok|$subs|$audio"; fi
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

  # zaloguj neznámé, pak normalizuj na 639-1
  log_unknown "$subs"; log_unknown "$audio"
  subs=$(normalize_langs "$subs")
  audio=$(normalize_langs "$audio")

  if [ -z "$subs$audio" ]; then echo "empty|$subs|$audio"; else echo "ok|$subs|$audio"; fi
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
# ---- Zpracování jedné fáze (0 = neprobnuté, 1 = uncached retry) ----
# Bere torrenty z indexeru pro danou fázi a probíná je, dokud není fáze
# ---- Hlavní smyčka ----
# Endpoint řeší prioritu (neprobnuté první, uncached potom) i počítání pokusů
# sám — worker jen bere dávky a probíná, dokud není done nebo nedojde strop.
# Noční cron: jednorázový běh, doběhne a skončí (žádná pauza/smyčka navíc).
run_probe() {
  log "=== Start probe (strop: $LIMIT) ==="

  while [ "$processed" -lt "$LIMIT" ]; do
    # --- dávka z indexeru (endpoint sám řadí: neprobnuté první, uncached potom) ---
    local batch n
    batch=$(curl -s -m 20 "$INDEXER_URL/api/admin/lang-probe/batch?limit=$BATCH_SIZE" \
      -H "Authorization: Bearer $TOKEN")

    # 401 -> token expiroval -> re-login a zkus dávku znovu
    if echo "$batch" | jq -e '.needLogin // (.error=="Unauthorized")' >/dev/null 2>&1; then
      log "Token expiroval — re-login."
      login
      continue
    fi

    n=$(echo "$batch" | jq '.items | length' 2>/dev/null || echo 0)
    [ "$n" -gt 0 ] || { log "Fronta prázdná (done) — konec."; return 0; }

    # --- hromadný checkcached na celou dávku ---
    local hashes cached
    hashes=$(echo "$batch" | jq -r '[.items[].infohash] | join(",")')
    cached=$(tb_checkcached "$hashes")

    # --- iterace přes položky ---
    local count i
    count=$(echo "$batch" | jq '.items | length')
    i=0
    while [ "$i" -lt "$count" ] && [ "$processed" -lt "$LIMIT" ]; do
      local item id hash hname hsize is_cached tid files picked fid mt sname url res st subs audio
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

    # done:true -> fronta vyčerpaná, konec (endpoint řídí prioritu i retry sám)
    local done_flag; done_flag=$(echo "$batch" | jq -r '.done')
    [ "$done_flag" = "true" ] && { log "done=true — fronta hotová."; return 0; }
  done

  log "Dosažen strop $LIMIT."
  return 0
}

run_probe

log "Hotovo — zpracováno celkem $processed, výstup: $OUT"

# ---- Odeslání výsledků do indexeru (jeden POST na konci běhu) ----
# Mapování worker status -> endpoint status: ok->cached, empty/nonmkv/zip->no_data,
# uncached/error->uncached. Jazyky (už normalizované 639-1) se joinnou z JSONL
# array na comma-separated string. uncached se posílá bez jazyků (endpoint je jen
# nechá v kandidátech). Pole audio_codec/dual_audio/multi_subs zatím neposíláme.
post_results() {
  [ -s "$OUT" ] || { log "POST: žádné výsledky k odeslání"; return; }

  # sestav {results:[...]} z JSONL — mapuj status, joinni jazyky na string
  local payload
  payload=$(jq -s '{
    results: [ .[] | {
      id: .id,
      status: ( { "ok":"cached", "empty":"no_data", "nonmkv":"no_data",
                  "zip":"no_data", "uncached":"uncached", "error":"uncached" }[.status] // "uncached" ),
      subtitle_langs: (.subtitle_langs | join(",")),
      audio_langs:    (.audio_langs    | join(","))
    }
    # u uncached neposílej jazyky (stejně prázdné), u no_data nech audio kdyby bylo
    | if .status=="uncached" then {id,status} else . end ]
  }' "$OUT")

  local n; n=$(echo "$payload" | jq '.results | length')
  log "POST: odesílám $n výsledků na indexer..."

  local resp
  resp=$(curl -s -m 60 -X POST "$INDEXER_URL/api/admin/lang-probe/result" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload")

  # zaloguj odpověď endpointu
  if echo "$resp" | jq -e '.updated' >/dev/null 2>&1; then
    log "POST OK: $(echo "$resp" | jq -c '{updated,uncached,no_data,errors:(.errors|length)}')"
  else
    log "POST SELHAL — odpověď: $resp"
    log "Výsledky zůstávají v $OUT (lze poslat ručně)"
  fi
}

# token může být starý (běh trval ~33 min) — obnov před POSTem
login
post_results

