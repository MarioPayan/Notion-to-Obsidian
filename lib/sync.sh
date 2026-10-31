# Sync state and the incremental pass.
#
# $CACHE_DIR/_sync_state.json records, per root id, the start time of the
# last run that finished without failures:
#   {"version": 1, "roots": {"<id>": "2026-10-31T20:33:00.000Z", ...}}
# An incremental run asks /search for everything edited since the oldest of
# those times (minus a safety margin) and refreshes only what falls under a
# configured root, judged by the parentId chain already in the cache.

: "${CACHE_DIR:?}"
SYNC_STATE_FILE="$CACHE_DIR/_sync_state.json"

now_iso() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }

# Echo the oldest recorded start time when the state covers exactly the given
# root ids; return 1 (full crawl needed) otherwise.
sync_state_since() {
  [ -f "$SYNC_STATE_FILE" ] || return 1
  local want
  want="$(printf '%s\n' "$@" | jq -R . | jq -sc 'sort')"
  jq -er --argjson want "$want" '
    select((.roots // {} | keys) == $want) | [.roots[]] | min
  ' "$SYNC_STATE_FILE" 2>/dev/null
}

# sync_state_write START_ISO ROOT_ID...
sync_state_write() {
  local start="$1"; shift
  local tmp="$SYNC_STATE_FILE.tmp"
  printf '%s\n' "$@" | jq -R . | jq -s --arg t "$start" \
    '{version: 1, roots: (map({key: ., value: $t}) | from_entries)}' > "$tmp" \
    && mv "$tmp" "$SYNC_STATE_FILE"
}

# iso_minus_minutes ISO MINUTES → ISO in the same format.
iso_minus_minutes() {
  date -u -d "@$(( $(date -u -d "$1" +%s) - $2 * 60 ))" +%Y-%m-%dT%H:%M:%S.000Z
}

# Load "id kind status parentId" for every cached node into the global
# associative arrays CACHED_KIND, CACHED_STATUS and CACHED_PARENT (one jq call
# for the whole cache).
_load_cache_index() {
  declare -gA CACHED_KIND=() CACHED_STATUS=() CACHED_PARENT=()
  local id kind status parent
  while IFS=$'\x1f' read -r id kind status parent; do
    [ -z "$id" ] && continue
    CACHED_KIND[$id]="$kind"
    CACHED_STATUS[$id]="$status"
    CACHED_PARENT[$id]="$parent"
  done < <(find "$CACHE_DIR" -maxdepth 1 \( -name 'page_*.json' -o -name 'db_*.json' \) \
             -exec jq -r '[.id, .kind, (.status // "active"), (.parentId // "")] | join("\u001f")' {} +)
}

# True when ID is cached and its cached parent chain reaches a root without
# crossing an outside node (whose cached parent is stale by definition).
_under_roots() {
  local cur="$1" hops=0 r
  while [ -n "$cur" ] && [ "$hops" -lt 64 ]; do
    [ -n "${CACHED_KIND[$cur]:-}" ] || return 1
    [ "${CACHED_STATUS[$cur]}" = "outside" ] && return 1
    for r in "${ROOT_IDS[@]}"; do
      [ "$cur" = "$r" ] && return 0
    done
    cur="${CACHED_PARENT[$cur]:-}"
    hops=$((hops + 1))
  done
  return 1
}

# Walk up from a block id to the page or database that contains it.
# Echoes "page <id>" or "database <id>"; returns 1 if it cannot tell.
_container_of_block() {
  local id="$1" hops=0 block ptype pid
  while [ "$hops" -lt 8 ]; do
    block="$(notion_get_block "$id")" || return 1
    ptype="$(jq -r '.parent.type // ""' <<<"$block")"
    pid="$(jq -r '.parent[.parent.type] // "" | strings | gsub("-";"") | ascii_downcase' <<<"$block")"
    case "$ptype" in
      page_id)        printf 'page %s' "$pid"; return 0 ;;
      database_id)    printf 'database %s' "$pid"; return 0 ;;
      data_source_id) printf 'database %s' "$(jq -r '.parent.database_id // "" | gsub("-";"") | ascii_downcase' <<<"$block")"; return 0 ;;
      block_id)       id="$pid" ;;
      *)              return 1 ;;
    esac
    hops=$((hops + 1))
  done
  return 1
}

# Public: refresh everything edited since SINCE. ROOT_IDS must be set.
# Changed cached pages are refetched; new pages are fetched after a forced
# refresh of their parent page; new or changed rows and data sources re-list
# their database (unchanged rows are not fetched again). A cached node that
# search reports as archived or in the trash only has its status updated.
incremental_sync() {
  local since="$1"
  local changes
  log_info "Incremental sync: changes since $since"
  if ! changes="$(notion_search_since "$since")"; then
    log_error "Search failed; run ./fetch.sh --full if this persists"
    return 1
  fi
  _load_cache_index

  local -A refresh_pages=() refresh_parent=() relist_dbs=() new_pages=()
  local object id edited status ptype pid pdb
  local seen=0 used=0
  while IFS=$'\x1f' read -r -u 3 object id edited status ptype pid pdb; do
    [ -z "$id" ] && continue
    seen=$((seen + 1))
    if [ "$status" != "active" ]; then
      # A data source stands for its database, which is what the cache keys on.
      [ "$object" = "data_source" ] && id="$pid"
      if [ -n "$id" ] && [ -n "${CACHED_KIND[$id]:-}" ] && _under_roots "$id"; then
        set_status "$(cache_file_for "${CACHED_KIND[$id]}" "$id")" "$status"
        used=$((used + 1))
      fi
      continue
    fi
    if [ "$object" = "data_source" ]; then
      # The database (not the data source) is what the cache keys on.
      if [ -n "$pid" ] && _under_roots "$pid"; then
        relist_dbs[$pid]=1; used=$((used + 1))
      fi
      continue
    fi
    if [ -n "${CACHED_KIND[$id]:-}" ]; then
      if _under_roots "$id"; then
        refresh_pages[$id]="$edited"; used=$((used + 1))
      fi
      continue
    fi
    # Not cached: a new page. Find the cached node it hangs from.
    if [ "$ptype" = "block_id" ]; then
      local container
      container="$(_container_of_block "$pid")" || continue
      ptype="${container%% *}_id"; pid="${container#* }"; pdb="$pid"
      [ "$ptype" = "database_id" ] || pdb=""
    fi
    case "$ptype" in
      page_id)
        if _under_roots "$pid"; then
          refresh_parent[$pid]=1; new_pages[$id]="$pid"; used=$((used + 1))
        fi ;;
      database_id|data_source_id)
        if [ -n "$pdb" ] && _under_roots "$pdb"; then
          relist_dbs[$pdb]=1; used=$((used + 1))
        fi ;;
    esac
  done 3< <(jq -r '.[] | [.object, .id, .edited, .status, (.parent.type // ""),
                         (.parent.id // ""), (.parent.database_id // "")] | join("\u001f")' <<<"$changes")

  log_info "Search returned $seen item$([ "$seen" = "1" ] || echo s) since $since; $used under the configured roots"

  local cf
  for id in "${!refresh_pages[@]}"; do
    crawl_page "$id" "${CACHED_PARENT[$id]:-}" "${refresh_pages[$id]}"
  done
  for id in "${!refresh_parent[@]}"; do
    # The parent's last_edited_time may lag the new child; force its blocks.
    rm -f "$CACHE_DIR/.done_$id"
    if [ "${CACHED_KIND[$id]}" = "database" ]; then
      crawl_database "$id" "${CACHED_PARENT[$id]:-}"
    else
      crawl_page "$id" "${CACHED_PARENT[$id]:-}" "" force
    fi
  done
  for id in "${!new_pages[@]}"; do
    # Covers a child the parent's refs did not list (e.g. nested in a block).
    crawl_page "$id" "${new_pages[$id]}"
  done
  for id in "${!relist_dbs[@]}"; do
    cf="$(cache_file_for database "$id")"
    [ -f "$cf" ] || continue
    crawl_database "$id" "${CACHED_PARENT[$id]:-}"
  done
}
