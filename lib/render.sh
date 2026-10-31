# Reads cache files and produces:
#   1. $OUTPUT_DIR/<id>.json — simplified JSON dump (one per page/db)
#   2. $VAULT_DIR/<folder>/<title>.md — Obsidian-friendly markdown
# Both are rebuilt from the whole cache on every run in a single jq pass each
# (rendering is local and cheap). Nothing is deleted because a page vanished:
# the cache keeps every node it ever saw, each with its status.

: "${ROOT_DIR:?must be set}"
: "${CACHE_DIR:?}"
: "${OUTPUT_DIR:?}"
: "${VAULT_DIR:?}"
JQ_DIR="$ROOT_DIR/lib/jq"

# Concatenate every cached page/db node to stdout.
_cat_cache() {
  find "$CACHE_DIR" -maxdepth 1 \( -name 'page_*.json' -o -name 'db_*.json' \) -print0 \
    | xargs -0 -r cat
}

# _write_tree DIR: read NUL-separated (id, relative path, content) triples on
# stdin and write each file atomically under DIR. DIR/.notion-paths records
# the path each id was written to; when an id's path changes (rename or move),
# its old file is deleted, unless another id was just written there, and any
# folder left empty is removed. Echoes "written moved".
_write_tree() {
  local dir="$1" manifest="$1/.notion-paths" id rel content sub old n=0 moved=0
  local -A written=() made=() prev=() now=()
  if [ -f "$manifest" ]; then
    while IFS= read -r -d '' id && IFS= read -r -d '' rel; do
      prev[$id]="$rel"
    done < "$manifest"
  fi
  while IFS= read -r -d '' id && IFS= read -r -d '' rel && IFS= read -r -d '' content; do
    sub="$dir"; [[ "$rel" == */* ]] && sub="$dir/${rel%/*}"
    [ -n "${made[$sub]:-}" ] || { mkdir -p "$sub"; made[$sub]=1; }
    printf '%s' "$content" > "$dir/$rel.tmp" && mv "$dir/$rel.tmp" "$dir/$rel"
    written[$rel]=1
    now[$id]="$rel"
    n=$((n + 1))
  done
  for id in "${!prev[@]}"; do
    old="${prev[$id]}"
    [ -n "${now[$id]:-}" ] || now[$id]="$old"
    if [ "${now[$id]}" != "$old" ] && [ -z "${written[$old]:-}" ] && [ -f "$dir/$old" ]; then
      rm -f "$dir/$old"
      moved=$((moved + 1))
    fi
  done
  for id in "${!now[@]}"; do printf '%s\0%s\0' "$id" "${now[$id]}"; done > "$manifest.tmp" \
    && mv "$manifest.tmp" "$manifest"
  [ "$moved" -gt 0 ] && find "$dir" -mindepth 1 -type d -empty -not -path '*/.*' -delete 2>/dev/null
  printf '%d %d' "$n" "$moved"
}

_moved_note() { [ "$1" -gt 0 ] && printf ' · removed %d old path%s of renamed or moved notes' "$1" "$([ "$1" = "1" ] || echo s)"; }

# Public: write per-id JSON dumps (simplified properties, simplified schema).
write_json_dump() {
  mkdir -p "$OUTPUT_DIR"
  log_info "Writing JSON dump → $OUTPUT_DIR/"
  local n moved
  read -r n moved < <(_cat_cache | jq -n -L "$JQ_DIR" --raw-output0 '
    include "simplify";
    include "status";
    inputs | select(.view | not)
    | .id, (.id + ".json"),
      ({ id, kind, title, last_edited: .last_edited_time, parentId,
         status: node_status, status_since }
       + (if .kind == "database"
          then {schema: ((.schema // {}) | simplify_schema)}
          else {properties: ((.properties // {}) | simplify_props)} end)
       + {childRefs} | tojson + "\n")
  ' | _write_tree "$OUTPUT_DIR")
  log_ok "Wrote ${n:-0} JSON files$(_moved_note "${moved:-0}")"
}

# BFS a subtree from (id, kind) using cache files as the graph. Echoes
# "pages|dbs|direct_rows" — pages and dbs are inclusive of the starting node;
# direct_rows is the childRefs count of the starting node if it's a database
# (0 otherwise), useful for a "this DB has N rows" callout.
_subtree_stats() {
  local start_id="$1"
  _cat_cache | jq -rn --arg start "$start_id" '
    [inputs] | (map({key: .id, value: .}) | from_entries) as $by
    | {queue: [$start], seen: {}}
    | until(.queue | length == 0;
        .queue[0] as $h | .queue |= .[1:]
        | if .seen[$h] or ($by[$h] | not) then .
          else .seen[$h] = true | .queue += [$by[$h].childRefs[]?.id] end)
    | (.seen | keys | map($by[.])) as $nodes
    | "\($nodes | map(select(.kind == "page")) | length)|\($nodes | map(select(.kind == "database")) | length)|\(if $by[$start].kind == "database" then ($by[$start].childRefs | length) else 0 end)"
  '
}

# Public: write a per-root summary of what was fetched. Reads REFS from the
# surrounding shell (set by fetch.sh).
write_summary() {
  local total_fetched total_cached total_errors
  total_fetched="$(progress_fetched)"
  total_cached="$(progress_cached)"
  total_errors="$(progress_errors)"

  local total_pages=0 total_dbs=0
  local f
  for f in "$CACHE_DIR"/page_*.json; do
    [ -e "$f" ] || continue
    total_pages=$((total_pages + 1))
  done
  for f in "$CACHE_DIR"/db_*.json; do
    [ -e "$f" ] || continue
    total_dbs=$((total_dbs + 1))
  done

  log_rule "Summary"
  log_info "totals    ${C_BOLD}${total_pages}${C_RESET} pages · ${C_BOLD}${total_dbs}${C_RESET} databases in cache"
  log_info "activity  ${C_GREEN}✓${C_RESET} fetched ${total_fetched} · ${C_BLUE}●${C_RESET} cached ${total_cached} · ${C_RED}✗${C_RESET} errors ${total_errors}"
  log_info "roots:"

  local ref
  for ref in "${REFS[@]}"; do
    local id kind cf
    read -r id kind <<<"$ref"
    cf="$(cache_file_for "$kind" "$id")"
    if [ ! -f "$cf" ]; then
      log_warn "  [$kind] ${id:0:8}… — no cache written (fetch failed)"
      continue
    fi
    local title stats pages dbs rows
    title="$(jq -r '.title' "$cf")"
    stats="$(_subtree_stats "$id" "$kind")"
    IFS='|' read -r pages dbs rows <<<"$stats"
    if [ "$kind" = "database" ]; then
      log_ok "  [database] \"$title\" (${id:0:8}…) — ${pages} page(s), ${dbs} db(s), ${rows} direct row(s)"
    else
      log_ok "  [page]     \"$title\" (${id:0:8}…) — ${pages} page(s), ${dbs} db(s)"
    fi
  done
}

# Public: build the Obsidian vault (see lib/jq/vault.jq).
write_vault() {
  mkdir -p "$VAULT_DIR"
  log_info "Building vault → $VAULT_DIR/"
  local n moved
  read -r n moved < <(_cat_cache | jq -n -L "$JQ_DIR" --raw-output0 -f "$JQ_DIR/vault.jq" \
    | _write_tree "$VAULT_DIR")
  log_ok "Wrote ${n:-0} markdown files$(_moved_note "${moved:-0}")"
}
