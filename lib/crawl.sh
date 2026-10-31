# Recursive crawler. One JSON file per id in $CACHE_DIR; mkdir-based locks
# keep concurrent crawls of the same id from racing. A `.done_<id>` marker
# prevents redundant traversal of shared subtrees within a single run.

: "${ROOT_DIR:?must be set}"
JQ_DIR="$ROOT_DIR/lib/jq"

cache_file_for() {
  local kind="$1" id="$2"
  if [ "$kind" = "database" ]; then
    printf '%s/db_%s.json' "$CACHE_DIR" "$id"
  else
    printf '%s/page_%s.json' "$CACHE_DIR" "$id"
  fi
}

# Try to acquire a per-id lock; returns 0 if acquired, 1 if another worker
# already has it. If another worker has it, this waits up to ~5min for the
# done marker to appear before giving up.
acquire_lock() {
  local id="$1" lock_dir="$CACHE_DIR/.lock_$id" done_marker="$CACHE_DIR/.done_$id"
  if mkdir "$lock_dir" 2>/dev/null; then
    return 0
  fi
  local waited=0
  while [ ! -f "$done_marker" ] && [ -d "$lock_dir" ] && [ "$waited" -lt 600 ]; do
    sleep 0.5
    waited=$((waited + 1))
  done
  return 1
}

release_lock() {
  rmdir "$CACHE_DIR/.lock_$1" 2>/dev/null || true
}

mark_done() {
  touch "$CACHE_DIR/.done_$1"
}

is_done() {
  [ -f "$CACHE_DIR/.done_$1" ]
}

# _reuse_cached_page FILE PARENT_ID: echo the refs of a cached page that is
# current. Its refs are recomputed from its cached blocks, and when they or
# the parent it is reached from now differ from the cache, both are rewritten
# atomically. That repairs caches whose refs once included mentions (which
# placed a merely mentioned page under the page that mentioned it) without
# fetching anything.
_reuse_cached_page() {
  local f="$1" parent="$2" old title
  IFS=$'\x1f' read -r old title < <(jq -r '[.parentId // "", .title] | join("\u001f")' "$f")
  jq -L "$JQ_DIR" --arg p "$parent" '
    include "extract_refs";
    (.blocks | child_refs) as $refs
    | (if $p == "" then null else $p end) as $np
    | select(.parentId != $np or .childRefs != $refs)
    | .parentId = $np | .childRefs = $refs' "$f" > "$f.tmp"
  if [ -s "$f.tmp" ]; then
    mv "$f.tmp" "$f"
    [ "$old" = "$parent" ] || log_info "Moved: $title (now under ${parent:-the root})"
  else
    rm -f "$f.tmp"
  fi
  jq -c '.childRefs // []' "$f"
}

# Recursively walk childRefs: the pages and databases a node contains, never
# the ones it mentions or links to. A ref may carry `edited` (database rows),
# which lets crawl_page skip the GET when the cache is current. In incremental
# mode (SYNC_MODE=incremental) refs without `edited` that are already cached
# are not descended into: the search pass decides what changed.
recurse_refs() {
  local refs="$1" parent_id="$2"
  local cid ckind cedited
  while IFS=$'\t' read -r -u 3 cid ckind cedited; do
    [ -z "$cid" ] && continue
    if [ "${SYNC_MODE:-full}" = "incremental" ] && [ -z "$cedited" ] \
       && [ -f "$(cache_file_for "$ckind" "$cid")" ]; then
      continue
    fi
    if [ "$ckind" = "database" ]; then
      crawl_database "$cid" "$parent_id"
    else
      crawl_page "$cid" "$parent_id" "$cedited"
    fi
  done 3< <(jq -r '.[]? | [.id, .kind, (.edited // "")] | @tsv' <<<"$refs")
}

# crawl_page ID [PARENT_ID] [EDITED] [FORCE]
#   EDITED  last_edited_time already known (from a query or search result):
#           when it matches the cache, the page is not fetched at all.
#   FORCE   "force" refetches blocks even if last_edited_time is unchanged.
crawl_page() {
  local id="$1" parent_id="${2:-}" known_edited="${3:-}" force="${4:-}"
  is_done "$id" && return 0
  if ! acquire_lock "$id"; then
    is_done "$id" && return 0
    return 0
  fi

  local cache_file="$(cache_file_for page "$id")"
  if [ -n "$known_edited" ] && [ "$force" != "force" ] && [ -f "$cache_file" ] \
     && [ "$(jq -r '.last_edited_time // ""' "$cache_file")" = "$known_edited" ]; then
    bump_cached "page: $(jq -r '.title' "$cache_file")"
    set_status "$cache_file" active
    local cached_refs
    cached_refs="$(_reuse_cached_page "$cache_file" "$parent_id")"
    mark_done "$id"
    release_lock "$id"
    recurse_refs "$cached_refs" "$id"
    return 0
  fi

  local page rc=0
  page="$(notion_get_page "$id")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 3 ] && set_status "$cache_file" unreachable
    bump_error "page $id"
    record_failure page "$id" "$parent_id"
    release_lock "$id"
    mark_done "$id"
    return 1
  fi

  local last_edited title status
  last_edited="$(jq -r '.last_edited_time' <<<"$page")"
  title="$(jq -r -f "$JQ_DIR/page_title.jq" <<<"$page")"
  status="$(status_of <<<"$page")"

  local refs
  if [ "$force" != "force" ] && [ -f "$cache_file" ] \
     && [ "$(jq -r '.last_edited_time // ""' "$cache_file")" = "$last_edited" ] \
     && [ "$(jq -r '.kind' "$cache_file")" = "page" ]; then
    bump_cached "page: $title"
    set_status "$cache_file" "$status"
    refs="$(_reuse_cached_page "$cache_file" "$parent_id")"
  else
    bump_fetched "page: $title"
    local blocks
    blocks="$(notion_list_blocks_recursive "$id")" || blocks="[]"
    refs="$(jq -c -L "$JQ_DIR" 'include "extract_refs"; child_refs' <<<"$blocks")"

    local tmp="$cache_file.tmp"
    jq -n \
      --arg id "$id" \
      --arg title "$title" \
      --arg parent "$parent_id" \
      --arg edited "$last_edited" \
      --arg status "$status" \
      --arg since "$(status_since "$cache_file" "$status")" \
      --argjson props "$(jq '.properties // {}' <<<"$page")" \
      --argjson blocks "$blocks" \
      --argjson refs "$refs" \
      '{
        id: $id, kind: "page", title: $title,
        parentId: (if $parent == "" then null else $parent end),
        last_edited_time: $edited,
        status: $status, status_since: $since,
        properties: $props, blocks: $blocks, childRefs: $refs
      }' > "$tmp" && mv "$tmp" "$cache_file"
  fi

  mark_done "$id"
  release_lock "$id"

  recurse_refs "$refs" "$id"
}

crawl_database() {
  local id="$1" parent_id="${2:-}"
  is_done "$id" && return 0
  if ! acquire_lock "$id"; then
    is_done "$id" && return 0
    return 0
  fi

  local cache_file="$(cache_file_for database "$id")"
  local db rc=0
  db="$(notion_get_database "$id")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 3 ] && set_status "$cache_file" unreachable
    bump_error "db $id"
    record_failure database "$id" "$parent_id"
    release_lock "$id"
    mark_done "$id"
    return 1
  fi

  local last_edited title ds_count status
  status="$(status_of <<<"$db")"
  last_edited="$(jq -r '.last_edited_time // empty' <<<"$db")"
  [ -z "$last_edited" ] && last_edited="1970-01-01T00:00:00.000Z"
  title="$(jq -r '(.title // [] | map(.plain_text // "") | join("")) | if . == "" then "Untitled DB" else . end' <<<"$db")"
  ds_count="$(jq '.data_sources // [] | length' <<<"$db")"
  bump_fetched "db: $title (${ds_count} data source$([ "$ds_count" = "1" ] || echo s))"

  # Always re-query rows + schema for databases (rows can be added without
  # bumping db.last_edited_time; safer to refresh). Accumulators live in tmp
  # files (--slurpfile) to avoid the 128 KB per-argv kernel limit on large DBs.
  local refs_file schema_file
  refs_file="$(mktemp)"; schema_file="$(mktemp)"
  printf '[]' > "$refs_file"
  printf '{}' > "$schema_file"

  # A linked view is a database block whose data sources belong to another
  # database. Its rows are the source's rows, so it is cached as a pointer
  # (view: true, viewOf: source id) and never listed or rendered on its own.
  local ds_ids ds_id view_of=""
  mapfile -t ds_ids < <(jq -r '.data_sources[]?.id' <<<"$db")
  for ds_id in "${ds_ids[@]}"; do
    local ds_detail
    if ds_detail="$(notion_get_data_source "$ds_id")"; then
      local ds_db
      ds_db="$(jq -r '.parent.database_id // "" | gsub("-";"") | ascii_downcase' <<<"$ds_detail")"
      if [ -n "$ds_db" ] && [ "$ds_db" != "$id" ]; then
        view_of="$ds_db"
        title="$(jq -r '.title // [] | map(.plain_text // "") | join("") | if . == "" then "Untitled DB" else . end' <<<"$ds_detail")"
        break
      fi
      local ds_props_file
      ds_props_file="$(mktemp)"
      jq '.properties // {}' <<<"$ds_detail" > "$ds_props_file"
      jq -c --slurpfile props "$ds_props_file" '. + $props[0]' "$schema_file" > "$schema_file.new" \
        && mv "$schema_file.new" "$schema_file"
      rm -f "$ds_props_file"
    else
      log_warn "Failed to retrieve data source $ds_id"
    fi

    local ds_refs_file
    ds_refs_file="$(mktemp)"
    if notion_query_data_source "$ds_id" > "$ds_refs_file"; then
      log_debug "  $(jq 'length' "$ds_refs_file") rows from data source $ds_id"
      jq -c --slurpfile new "$ds_refs_file" '. + $new[0]' "$refs_file" > "$refs_file.new" \
        && mv "$refs_file.new" "$refs_file"
    else
      log_warn "Failed to query data source $ds_id"
    fi
    rm -f "$ds_refs_file"
  done
  [ -n "$view_of" ] && log_debug "  db $id is a linked view of $view_of ($title)"

  local tmp="$cache_file.tmp"
  if jq -n \
      --arg id "$id" \
      --arg title "$title" \
      --arg parent "$parent_id" \
      --arg edited "$last_edited" \
      --arg view_of "$view_of" \
      --arg status "$status" \
      --arg since "$(status_since "$cache_file" "$status")" \
      --slurpfile schema "$schema_file" \
      --slurpfile refs "$refs_file" \
      '{
        id: $id, kind: "database", title: $title,
        parentId: (if $parent == "" then null else $parent end),
        last_edited_time: $edited,
        status: $status, status_since: $since,
        schema: $schema[0], childRefs: ($refs[0] | map({id, kind}))
      } + (if $view_of == "" then {} else {view: true, viewOf: $view_of, schema: {}, childRefs: []} end)' > "$tmp"; then
    mv "$tmp" "$cache_file"
    mark_done "$id"
  else
    log_error "Failed to write cache for db $id ($title)"
    bump_error "db $id"
    record_failure database "$id" "$parent_id"
    rm -f "$tmp"
  fi

  local refs="[]"
  [ -z "$view_of" ] && refs="$(cat "$refs_file")"
  rm -f "$refs_file" "$schema_file"

  release_lock "$id"

  recurse_refs "$refs" "$id"
}
