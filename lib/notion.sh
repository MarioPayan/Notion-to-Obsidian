# Curl wrappers for the Notion API. Returns JSON to stdout, status info to log.
# Requires NOTION_TOKEN to be set in the environment.

NOTION_BASE="https://api.notion.com/v1"
NOTION_VERSION="2025-09-03"

# notion_request METHOD PATH [BODY]
# Retries on 429 (Retry-After) and 5xx with exponential backoff. Echoes the
# response body to stdout. Non-2xx after retries → returns 1, message to stderr;
# returns 3 instead when the object is gone or not shared with the integration
# (404, 403, object_not_found). NOTION_QUIET_GONE=1 logs that case at debug level.
notion_request() {
  local method="$1" path="$2" body="${3:-}"
  local attempt=0 max_attempts=4
  local headers_file body_file status retry_after

  while :; do
    headers_file="$(mktemp)"
    body_file="$(mktemp)"

    log_debug "HTTP $method $path"
    local curl_args=(
      -sS -X "$method"
      -D "$headers_file" -o "$body_file"
      -w '%{http_code}'
      -H "Authorization: Bearer $NOTION_TOKEN"
      -H "Notion-Version: $NOTION_VERSION"
      -H "Content-Type: application/json"
    )
    [ -n "$body" ] && curl_args+=(--data "$body")

    status="$(curl "${curl_args[@]}" "${NOTION_BASE}${path}")" || {
      log_warn "curl failed for $path; retrying"
      rm -f "$headers_file" "$body_file"
      attempt=$((attempt + 1))
      [ "$attempt" -ge "$max_attempts" ] && return 1
      sleep $((2 ** attempt))
      continue
    }

    if [ "$status" = "429" ]; then
      retry_after="$(grep -i '^retry-after:' "$headers_file" | sed 's/.*: *//; s/[[:space:]]*$//')"
      retry_after="${retry_after:-1}"
      log_warn "429 rate-limited on $path; retrying in ${retry_after}s"
      rm -f "$headers_file" "$body_file"
      sleep "$retry_after"
      continue
    fi

    if [ "$status" -ge 500 ] && [ "$attempt" -lt "$max_attempts" ]; then
      log_warn "HTTP $status on $path; retry $((attempt + 1)) in $((2 ** attempt))s"
      rm -f "$headers_file" "$body_file"
      attempt=$((attempt + 1))
      sleep $((2 ** attempt))
      continue
    fi

    if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
      local code
      code="$(jq -r '.code // "http_error"' "$body_file" 2>/dev/null)"
      local msg
      msg="$(jq -r '.message // ""' "$body_file" 2>/dev/null)"
      rm -f "$headers_file" "$body_file"
      if [ "$status" = "404" ] || [ "$status" = "403" ] || [ "$code" = "object_not_found" ]; then
        if [ "${NOTION_QUIET_GONE:-}" = "1" ]; then
          log_debug "HTTP $status $code on $path"
        else
          log_error "HTTP $status $code on $path: $(_truncate "$msg" 120)"
        fi
        return 3
      fi
      log_error "HTTP $status $code on $path: $(_truncate "$msg" 120)"
      return 1
    fi

    cat "$body_file"
    rm -f "$headers_file" "$body_file"
    return 0
  done
}

notion_get_page()         { notion_request GET "/pages/$1"; }
notion_get_database()     { notion_request GET "/databases/$1"; }
notion_get_data_source()  { notion_request GET "/data_sources/$1"; }
notion_get_block()        { notion_request GET "/blocks/$1"; }

# Echo every page and data source edited at or after SINCE (ISO 8601, same
# format Notion returns) as a JSON array, newest first:
#   [{object, id, edited, status, parent: {type, id, database_id}}, ...]
# Ids are normalized. Search is sorted by last_edited_time descending, so
# paging stops at the first result older than SINCE.
notion_search_since() {
  local since="$1" cursor="" body page
  local all_file batch_file
  all_file="$(mktemp)"; batch_file="$(mktemp)"
  printf '[]' > "$all_file"
  while :; do
    body="$(jq -nc --arg c "$cursor" '
      {page_size: 100, sort: {direction: "descending", timestamp: "last_edited_time"}}
      + (if $c == "" then {} else {start_cursor: $c} end)')"
    if ! page="$(notion_request POST "/search" "$body")"; then
      rm -f "$all_file" "$batch_file"
      return 1
    fi
    printf '%s' "$page" | jq -c -L "$ROOT_DIR/lib/jq" --arg since "$since" '
      include "status";
      def nid: if . == null then null else gsub("-";"") | ascii_downcase end;
      [ .results[]
        | select(.last_edited_time >= $since)
        | { object, id: (.id | nid), edited: .last_edited_time,
            status: notion_status,
            parent: { type: .parent.type,
                      id: (.parent[.parent.type] | if type == "string" then nid else null end),
                      database_id: (.parent.database_id | nid) } } ]
    ' > "$batch_file" || { rm -f "$all_file" "$batch_file"; return 1; }
    jq -c --slurpfile batch "$batch_file" '. + $batch[0]' "$all_file" > "$all_file.new" \
      && mv "$all_file.new" "$all_file" \
      || { rm -f "$all_file" "$all_file.new" "$batch_file"; return 1; }
    # Stop once this page held anything older than SINCE, or nothing is left.
    if [ "$(jq -r --arg since "$since" '[.results[] | select(.last_edited_time < $since)] | length' <<<"$page")" != "0" ] \
       || [ "$(jq -r '.has_more' <<<"$page")" != "true" ]; then
      break
    fi
    cursor="$(jq -r '.next_cursor // ""' <<<"$page")"
    [ -z "$cursor" ] && break
  done
  cat "$all_file"
  rm -f "$all_file" "$batch_file"
}

# Echo all rows of a data source as a JSON array of id refs:
#   [{"id": "<normalized>", "kind": "page", "edited": "<last_edited_time>"}, ...]
# `edited` lets the crawler skip rows whose cache is already current without
# a GET per row; it is stripped before childRefs are persisted.
# The accumulator is held in a tmp file (piped through --slurpfile) so we
# never hit the per-argv 128 KB kernel limit (MAX_ARG_STRLEN), which used to
# blow up jq silently once a batch + accumulator exceeded that.
notion_query_data_source() {
  local ds_id="$1" cursor="" body page
  local all_file batch_file
  all_file="$(mktemp)"; batch_file="$(mktemp)"
  printf '[]' > "$all_file"
  while :; do
    if [ -n "$cursor" ]; then
      body="$(jq -nc --arg c "$cursor" '{page_size: 100, start_cursor: $c}')"
    else
      body='{"page_size":100}'
    fi
    if ! page="$(notion_request POST "/data_sources/$ds_id/query" "$body")"; then
      rm -f "$all_file" "$batch_file"
      return 1
    fi
    printf '%s' "$page" | jq -c '
      [ .results[]
        | select(.object == "page")
        | {id: (.id | gsub("-";"") | ascii_downcase), kind: "page", edited: .last_edited_time} ]
    ' > "$batch_file" || { rm -f "$all_file" "$batch_file"; return 1; }
    jq -c --slurpfile batch "$batch_file" '. + $batch[0]' "$all_file" > "$all_file.new" \
      && mv "$all_file.new" "$all_file" \
      || { rm -f "$all_file" "$all_file.new" "$batch_file"; return 1; }
    if [ "$(jq -r '.has_more' <<<"$page")" = "true" ]; then
      cursor="$(jq -r '.next_cursor // ""' <<<"$page")"
      [ -z "$cursor" ] && break
    else
      break
    fi
  done
  cat "$all_file"
  rm -f "$all_file" "$batch_file"
}

# Echo direct children of a block as a JSON array. Accumulator lives in a tmp
# file (--slurpfile) to avoid the 128 KB per-argv kernel limit (MAX_ARG_STRLEN),
# which blows up jq silently once a batch + accumulator exceeds that.
notion_list_children() {
  local block_id="$1" cursor="" page
  local all_file batch_file
  all_file="$(mktemp)"; batch_file="$(mktemp)"
  printf '[]' > "$all_file"
  while :; do
    local qs="page_size=100"
    [ -n "$cursor" ] && qs="$qs&start_cursor=$cursor"
    if ! page="$(notion_request GET "/blocks/$block_id/children?$qs")"; then
      rm -f "$all_file" "$batch_file"
      return 1
    fi
    printf '%s' "$page" | jq -c '.results // []' > "$batch_file" \
      || { rm -f "$all_file" "$batch_file"; return 1; }
    jq -c --slurpfile batch "$batch_file" '. + $batch[0]' "$all_file" > "$all_file.new" \
      && mv "$all_file.new" "$all_file" \
      || { rm -f "$all_file" "$all_file.new" "$batch_file"; return 1; }
    if [ "$(jq -r '.has_more' <<<"$page")" = "true" ]; then
      cursor="$(jq -r '.next_cursor // ""' <<<"$page")"
      [ -z "$cursor" ] && break
    else
      break
    fi
  done
  cat "$all_file"
  rm -f "$all_file" "$batch_file"
}

# Recursively walks a block tree, attaching `_children` to any block with
# `has_children: true` (excluding child_page / child_database, which are
# crawled separately as their own pages). This is what makes content nested
# inside column_list/column/toggle/synced_block discoverable.
notion_list_blocks_recursive() {
  local block_id="$1"
  local blocks
  blocks="$(notion_list_children "$block_id")" || return 1

  local count i
  count="$(jq 'length' <<<"$blocks" 2>/dev/null)"
  count="${count:-0}"
  i=0
  while [ "$i" -lt "$count" ]; do
    local has_children btype bid
    has_children="$(jq -r ".[$i].has_children" <<<"$blocks")"
    btype="$(jq -r ".[$i].type" <<<"$blocks")"
    bid="$(jq -r ".[$i].id" <<<"$blocks")"
    if [ "$has_children" = "true" ] && [ "$btype" != "child_page" ] && [ "$btype" != "child_database" ]; then
      local sub sub_file
      sub="$(notion_list_blocks_recursive "$bid")" || sub="[]"
      sub_file="$(mktemp)"
      printf '%s' "$sub" > "$sub_file"
      blocks="$(jq -c --slurpfile c "$sub_file" ".[$i]._children = \$c[0]" <<<"$blocks")"
      rm -f "$sub_file"
    fi
    i=$((i + 1))
  done
  printf '%s' "$blocks"
}

# Strip dashes and lowercase a Notion id for stable cache keys.
normalize_id() {
  printf '%s' "$1" | tr -d '-' | tr 'A-Z' 'a-z'
}

# Probe an id against /pages and /databases to determine which it is.
# Echoes "page" or "database" on success, returns 1 on failure.
notion_probe_kind() {
  local id="$1" status
  status="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $NOTION_TOKEN" \
    -H "Notion-Version: $NOTION_VERSION" \
    "$NOTION_BASE/pages/$id" 2>/dev/null)"
  if [ "$status" = "200" ]; then
    printf 'page'
    return 0
  fi
  status="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $NOTION_TOKEN" \
    -H "Notion-Version: $NOTION_VERSION" \
    "$NOTION_BASE/databases/$id" 2>/dev/null)"
  if [ "$status" = "200" ]; then
    printf 'database'
    return 0
  fi
  return 1
}

# Parse a Notion URL into "ID KIND" (page or database). Returns 1 if no id or
# if the id can't be resolved against the API.
ref_from_url() {
  local url="$1"
  case "$url" in
    *notion.so/*) ;;
    *) return 1 ;;
  esac
  local id_raw
  id_raw="$(printf '%s' "$url" | grep -oE '[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  [ -z "$id_raw" ] && return 1
  local id kind
  id="$(normalize_id "$id_raw")"
  if printf '%s' "$url" | grep -qE '[?&]v='; then
    kind="database"
  elif ! kind="$(notion_probe_kind "$id")"; then
    log_warn "Could not resolve $url: id $id is not accessible as page or database"
    return 1
  fi
  printf '%s %s' "$id" "$kind"
}
