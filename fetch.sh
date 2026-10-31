#!/usr/bin/env bash
# Notion → Obsidian markdown fetcher.
#
#   ./fetch.sh --name NAME --root URL [--root URL ...] [--full]
#       Profile mode: mirror the given roots into mirrors/NAME/{cache,output,vault}.
#   ./fetch.sh [--full]
#       Default mode: roots from urls.json, folders from config.json.
#
#   --full   full crawl; also re-checks the status of pages it did not reach
#   --help   this text
#
# Other knobs (concurrency, debug, sync_margin_minutes) come from config.json
# when it exists, else from defaults. NOTION_TOKEN comes from the environment or
# .env (gitignored). DEBUG=true forces verbose logging. Ctrl-C is safe: every
# page is its own atomic cache file, so a killed run resumes on the next one.

set -uo pipefail

FULL=false
NAME=""
ROOT_URLS=()
usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --full) FULL=true ;;
    --name) [ "$#" -ge 2 ] || { echo "--name needs a value" >&2; exit 2; }; NAME="$2"; shift ;;
    --name=*) NAME="${1#--name=}" ;;
    --root) [ "$#" -ge 2 ] || { echo "--root needs a URL" >&2; exit 2; }; ROOT_URLS+=("$2"); shift ;;
    --root=*) ROOT_URLS+=("${1#--root=}") ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done
if [ -n "$NAME" ] || [ "${#ROOT_URLS[@]}" -gt 0 ]; then
  [ -n "$NAME" ] || { echo "--root needs --name (the mirror folder under mirrors/)" >&2; exit 2; }
  [ "${#ROOT_URLS[@]}" -gt 0 ] || { echo "--name needs at least one --root URL" >&2; exit 2; }
  if ! [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Invalid --name '$NAME': use letters, digits, '.', '_' or '-'" >&2
    exit 2
  fi
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROOT_DIR
cd "$ROOT_DIR"

# ---- Prerequisites ---------------------------------------------------------
for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required tool: $cmd" >&2
    exit 1
  fi
done

CONFIG_FILE="${CONFIG_FILE:-config.json}"
URLS_FILE="${URLS_FILE:-urls.json}"

# Load NOTION_TOKEN from .env for local runs if it's not already in the env.
if [ -z "${NOTION_TOKEN:-}" ] && [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# ---- Config validation -----------------------------------------------------
: "${NOTION_TOKEN:?NOTION_TOKEN is not set (export it or put it in .env)}"

# cfg KEY DEFAULT: a config.json value, or DEFAULT when the file or key is missing.
cfg() {
  if [ -f "$CONFIG_FILE" ]; then
    jq -r --arg k "$1" --arg d "$2" '.[$k] // $d | tostring' "$CONFIG_FILE"
  else
    printf '%s' "$2"
  fi
}

CONCURRENCY="$(cfg concurrency 3)"
: "${DEBUG:=$(cfg debug false)}"
# Notion timestamps are minute-granular and search indexing lags a little, so
# an incremental run looks back this far before the previous run's start.
SYNC_MARGIN_MINUTES="$(cfg sync_margin_minutes 5)"

if [ -n "$NAME" ]; then
  CACHE_DIR="mirrors/$NAME/cache"
  OUTPUT_DIR="mirrors/$NAME/output"
  VAULT_DIR="mirrors/$NAME/vault"
  URLS=("${ROOT_URLS[@]}")
else
  CACHE_DIR="$(cfg cache_dir .cache)"
  OUTPUT_DIR="$(cfg output_dir output)"
  VAULT_DIR="$(cfg vault_dir vault)"
  if [ ! -f "$URLS_FILE" ]; then
    echo "No $URLS_FILE: pass --name NAME --root URL, or copy urls.example.json to $URLS_FILE" >&2
    exit 1
  fi
  if ! jq -e 'type == "array"' "$URLS_FILE" >/dev/null 2>&1; then
    echo "$URLS_FILE must be a JSON array of strings" >&2
    exit 1
  fi
  mapfile -t URLS < <(jq -r '.[]' "$URLS_FILE")
  if [ "${#URLS[@]}" -eq 0 ]; then
    echo "No URLs found in $URLS_FILE" >&2
    exit 1
  fi
fi

export NOTION_TOKEN CACHE_DIR OUTPUT_DIR VAULT_DIR

mkdir -p "$CACHE_DIR" "$OUTPUT_DIR" "$VAULT_DIR"

# Clear stale per-run dedup markers from prior interrupted/completed runs.
rm -f "$CACHE_DIR"/.done_* 2>/dev/null || true
rm -rf "$CACHE_DIR"/.lock_* 2>/dev/null || true

# ---- Library load ----------------------------------------------------------
# shellcheck source=lib/log.sh
source "$ROOT_DIR/lib/log.sh"
# shellcheck source=lib/notion.sh
source "$ROOT_DIR/lib/notion.sh"
# shellcheck source=lib/crawl.sh
source "$ROOT_DIR/lib/crawl.sh"
# shellcheck source=lib/render.sh
source "$ROOT_DIR/lib/render.sh"
# shellcheck source=lib/sync.sh
source "$ROOT_DIR/lib/sync.sh"
# shellcheck source=lib/status.sh
source "$ROOT_DIR/lib/status.sh"

set_debug "$DEBUG"

cleanup() {
  finish_progress_line
  cleanup_log_state
}
trap cleanup EXIT
trap 'log_warn "Interrupted; partial cache preserved"; exit 130' INT TERM

# ---- Resolve URLs → refs ---------------------------------------------------
log_info "Notion API $NOTION_VERSION · concurrency $CONCURRENCY · debug=$DEBUG"

REFS=()
for u in "${URLS[@]}"; do
  if r="$(ref_from_url "$u")"; then
    REFS+=("$r")
  else
    log_warn "Skipping unparseable URL: $u"
  fi
done
[ "${#REFS[@]}" -eq 0 ] && { log_error "No valid URLs to crawl"; exit 1; }
ROOT_IDS=()
for ref in "${REFS[@]}"; do ROOT_IDS+=("${ref%% *}"); done

# ---- Pick full or incremental ----------------------------------------------
RUN_START="$(now_iso)"
backfill_status
SYNC_MODE=full
if [ "$FULL" != "true" ]; then
  if last_start="$(sync_state_since "${ROOT_IDS[@]}")"; then
    SYNC_MODE=incremental
  else
    log_info "No sync state for these roots; running a full crawl"
  fi
fi
export SYNC_MODE

start_heartbeat
if [ "$SYNC_MODE" = "incremental" ]; then
  incremental_sync "$(iso_minus_minutes "$last_start" "$SYNC_MARGIN_MINUTES")" \
    || record_failure search "-" ""
fi

# Wrapper run as a background job per root URL. Inner traversal is sequential
# but lock-safe — different roots can race on the same shared subtree without
# duplicating work.
crawl_root() {
  local ref="$1"
  local id kind
  read -r id kind <<<"$ref"
  if [ "$kind" = "database" ]; then
    crawl_database "$id" ""
  else
    crawl_page "$id" ""
  fi
}

# ---- Full crawl with bounded parallelism on roots ---------------------------
if [ "$SYNC_MODE" = "full" ]; then
  log_info "Crawling ${#REFS[@]} root$([ "${#REFS[@]}" = "1" ] || echo s)"
  active=0
  for ref in "${REFS[@]}"; do
    if [ "$active" -ge "$CONCURRENCY" ]; then
      wait -n
      active=$((active - 1))
    fi
    crawl_root "$ref" &
    active=$((active + 1))
  done
  wait
fi

stop_heartbeat
finish_progress_line

# ---- Retry pass for failed items ------------------------------------------
# Each retry clears the id's .done / .lock markers so the crawl actually runs
# again, then re-invokes the original kind. The failure list is rebuilt from
# scratch on each pass, so an id that fails again carries into the next pass.
retry_failed() {
  local max_passes=2 pass snapshot kind id parent
  for pass in $(seq 1 "$max_passes"); do
    [ "$(count_failures)" -gt 0 ] || return 0
    snapshot="$(list_failures)"
    local n
    n="$(printf '%s\n' "$snapshot" | grep -c .)"
    log_info "Retry pass $pass/${max_passes}: $n failed item$([ "$n" = "1" ] || echo s)"
    reset_failures
    [ "$pass" -gt 1 ] && sleep $((2 * (pass - 1)))

    start_heartbeat
    while IFS=$'\t' read -r kind id parent; do
      [ -z "$id" ] && continue
      if [ "$kind" = "search" ]; then
        incremental_sync "$(iso_minus_minutes "$last_start" "$SYNC_MARGIN_MINUTES")" \
          || record_failure search "-" ""
        continue
      fi
      rm -f "$CACHE_DIR/.done_$id" "$CACHE_DIR/.lock_$id" 2>/dev/null
      if [ "$kind" = "database" ]; then
        crawl_database "$id" "$parent"
      else
        crawl_page "$id" "$parent"
      fi
    done <<<"$snapshot"
    stop_heartbeat
    finish_progress_line
  done

  local remaining
  remaining="$(count_failures)"
  if [ "$remaining" -gt 0 ]; then
    log_warn "$remaining item$([ "$remaining" = "1" ] || echo s) still failing after retries"
  else
    log_ok "All retries succeeded"
  fi
}
retry_failed

# ---- Page status ------------------------------------------------------------
# Only a full crawl knows which cached nodes it no longer reaches; ask Notion
# about each of them. Their notes stay either way.
[ "$SYNC_MODE" = "full" ] && check_unreached_status
# Search never reports trash/restore changes; re-check what is not active.
[ "$SYNC_MODE" = "full" ] || check_inactive_status

# ---- Sync state --------------------------------------------------------------
# Only a run with no remaining failures moves the incremental window forward.
if [ "$(count_failures)" -eq 0 ]; then
  sync_state_write "$RUN_START" "${ROOT_IDS[@]}"
else
  log_warn "Sync state not updated; the next run retries from the previous point"
fi

# ---- Render outputs --------------------------------------------------------
write_json_dump
write_vault

# ---- Summary ---------------------------------------------------------------
write_summary
log_ok "Done"
