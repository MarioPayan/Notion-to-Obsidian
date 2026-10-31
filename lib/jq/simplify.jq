# Notion property → clean value. Drives output by .type so unknown additions
# fall through to a safe default and the script keeps working.

def plain_rt: . // [] | map(.plain_text // "") | join("");

def simplify_prop:
  if . == null or type != "object" then null
  elif .type == "title"           then (.title           | plain_rt | if . == "" then null else . end)
  elif .type == "rich_text"       then (.rich_text       | plain_rt | if . == "" then null else . end)
  elif .type == "number"          then (.number // null)
  elif .type == "select"          then (.select.name // null)
  elif .type == "status"          then (.status.name // null)
  elif .type == "multi_select"    then (.multi_select // [] | map(.name))
  elif .type == "date"            then
    (if .date == null or .date.start == null then null
     elif .date.end then {start: .date.start, end: .date.end}
     else {start: .date.start} end)
  elif .type == "people"          then (.people // [] | map(.name // .id) | map(select(. != null)))
  # Notion-hosted files have signed URLs that expire within an hour: keep the name only.
  elif .type == "files"           then (.files  // [] | map(if .type == "external" then {name: .name, url: .external.url} else {name: .name, inNotion: true} end))
  elif .type == "checkbox"        then (.checkbox // false)
  elif .type == "url"             then (.url             // null)
  elif .type == "email"           then (.email           // null)
  elif .type == "phone_number"    then (.phone_number    // null)
  elif .type == "formula"         then
    (if .formula == null then null
     else (.formula[.formula.type]) end)
  elif .type == "relation"        then
    (if (.relation // [] | length) == 0 then null
     else (.relation | map(.id | gsub("-";"") | ascii_downcase)) end)
  elif .type == "rollup"          then
    (if .rollup == null then null
     elif .rollup.type == "array" then (.rollup.array | map(simplify_prop) | map(select(. != null)))
     else (.rollup[.rollup.type] // null) end)
  elif .type == "created_time"    then (.created_time    // null)
  elif .type == "last_edited_time" then (.last_edited_time // null)
  elif .type == "created_by"      then (.created_by.name // .created_by.id // null)
  elif .type == "last_edited_by"  then (.last_edited_by.name // .last_edited_by.id // null)
  elif .type == "unique_id"       then
    (if .unique_id == null then null
     elif (.unique_id.prefix // "") != "" then "\(.unique_id.prefix)-\(.unique_id.number)"
     else .unique_id.number end)
  elif .type == "verification"    then (.verification.state // null)
  elif .type == "button"          then null
  else
    # Unknown type: try to grab a sensible payload key.
    [to_entries[] | select(.key != "id" and .key != "type") | .value | select(. != null)] | first // null
  end;

def simplify_props:
  to_entries
  | map(.value = (.value | simplify_prop))
  | map(select(.value != null))
  | map(select((.value | type) != "array" or (.value | length) > 0))
  | from_entries;

def simplify_schema:
  to_entries
  | map({
      key: .key,
      value: (
        .value as $f
        | {type: $f.type}
        + (if $f.type == "select" or $f.type == "status"
             then {options: ($f[$f.type].options // [] | map(.name))}
           elif $f.type == "multi_select"
             then {options: ($f.multi_select.options // [] | map(.name))}
           elif $f.type == "number"
             then {format: $f.number.format}
           elif $f.type == "relation"
             then {relationTarget: ($f.relation.database_id // $f.relation.data_source_id)}
           else {} end)
      )
    })
  | from_entries;
