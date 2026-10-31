# Page status. Every cache node carries
#   status:       active | archived | in_trash | unreachable | outside
#   status_since: the date (YYYY-MM-DD) it took that status
# outside is ours, not Notion's: the page is active in Notion but a full
# crawl no longer reaches it from any root (it was only mentioned, or it was
# moved out). Its content is never refreshed again.
# Nodes are never removed from the cache: a page that disappears from Notion
# keeps its note, marked with its status (see lib/jq/vault.jq).

: "${ROOT_DIR:?must be set}"
: "${CACHE_DIR:?}"

today() { date -u +%Y-%m-%d; }

# Read a Notion object on stdin, echo its status.
status_of() { jq -r -L "$ROOT_DIR/lib/jq" 'include "status"; notion_status'; }

# status_since FILE STATUS: the date to record for STATUS on FILE's node; the
# current one when the status is unchanged, else today.
status_since() {
  local f="$1" s="$2"
  if [ -f "$f" ]; then
    jq -r --arg s "$s" --arg today "$(today)" \
      'if (.status // "active") == $s and .status_since then .status_since else $today end' "$f"
  else
    today
  fi
}

# set_status FILE STATUS: record STATUS on a cached node, atomically, only
# when it changed (or was never recorded).
set_status() {
  local f="$1" s="$2" line
  [ -f "$f" ] || return 0
  line="$(jq -r --arg s "$s" 'select(.status != $s or (.status_since | not)) | [(.status // "-"), .title] | @tsv' "$f")"
  [ -n "$line" ] || return 0
  jq --arg s "$s" --arg since "$(status_since "$f" "$s")" \
    '.status = $s | .status_since = $since' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  case "${line%%$'\t'*}" in
    -|"$s") ;;
    *) log_info "Status: ${line#*$'\t'} → $s" ;;
  esac
}

# Give every node cached before status tracking existed an explicit status.
backfill_status() {
  local f
  while IFS= read -r f; do
    set_status "$f" active
  done < <(find "$CACHE_DIR" -maxdepth 1 \( -name 'page_*.json' -o -name 'db_*.json' \) \
             -exec jq -r 'select(.status_since | not) | input_filename' {} +)
}

# check_status KIND ID [OUTSIDE]: GET the node and record what Notion says
# about it. A gone or unshared object becomes unreachable; any other error
# leaves the status as it was and returns 1. With OUTSIDE set, a node Notion
# reports as active is recorded as outside instead.
check_status() {
  local kind="$1" id="$2" outside="${3:-}" f obj s rc=0
  f="$(cache_file_for "$kind" "$id")"
  if [ "$kind" = "database" ]; then
    obj="$(NOTION_QUIET_GONE=1 notion_get_database "$id")" || rc=$?
  else
    obj="$(NOTION_QUIET_GONE=1 notion_get_page "$id")" || rc=$?
  fi
  case "$rc" in
    0) s="$(status_of <<<"$obj")"
       [ "$s" = active ] && [ -n "$outside" ] && s=outside
       set_status "$f" "$s" ;;
    3) set_status "$f" unreachable ;;
    *) return 1 ;;
  esac
}

# Public, after a full crawl: re-check every cached node the crawl did not
# reach (no .done_<id> marker) or could not fetch. An unreached node that is
# still active in Notion is outside every root.
check_unreached_status() {
  local f id kind failed outside n=0 bad=0
  failed="$(list_failures | cut -f2)"
  for f in "$CACHE_DIR"/page_*.json "$CACHE_DIR"/db_*.json; do
    [ -e "$f" ] || continue
    id="${f##*/}"; kind=page
    case "$id" in db_*) kind=database ;; esac
    id="${id#page_}"; id="${id#db_}"; id="${id%.json}"
    outside=outside
    if [ -f "$CACHE_DIR/.done_$id" ]; then
      grep -qxF "$id" <<<"$failed" || continue
      outside=""
    fi
    n=$((n + 1))
    check_status "$kind" "$id" "$outside" || bad=$((bad + 1))
  done
  [ "$n" -gt 0 ] || return 0
  log_info "Checked the status of $n cached node$([ "$n" = "1" ] || echo s) the crawl did not reach"
  [ "$bad" -eq 0 ] || log_warn "$bad status check$([ "$bad" = "1" ] || echo s) failed; their status is unchanged"
}

# Public, after an incremental run: re-check every node that is not active.
# Restoring a page from the trash does not bump its last_edited_time, so
# search never reports it; this keeps restores visible at the cost of one GET
# per non-active node (usually none). An outside node stays outside while
# Notion reports it active; only a full crawl that reaches it again clears it.
check_inactive_status() {
  local f id kind s outside n=0
  for f in "$CACHE_DIR"/page_*.json "$CACHE_DIR"/db_*.json; do
    [ -e "$f" ] || continue
    s="$(jq -r '.status // "active"' "$f")"
    [ "$s" = "active" ] && continue
    outside=""; [ "$s" = "outside" ] && outside=outside
    id="${f##*/}"; kind=page
    case "$id" in db_*) kind=database ;; esac
    id="${id#page_}"; id="${id#db_}"; id="${id%.json}"
    n=$((n + 1))
    check_status "$kind" "$id" "$outside" || log_warn "Status check failed for $id; status unchanged"
  done
  [ "$n" -gt 0 ] && log_info "Re-checked $n non-active node$([ "$n" = "1" ] || echo s)"
  return 0
}
