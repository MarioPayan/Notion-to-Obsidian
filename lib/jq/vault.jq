# Input: every cache node (page_*.json / db_*.json) as a stream; run with -n.
# Output (--raw-output0): for each note, its id, its vault-relative path and
# then its markdown, as three NUL-terminated strings. Last comes _estado.md,
# the index of notes whose page is no longer active in Notion or is outside
# every root.
#
# Folders mirror the cached parent chain. Linked database views get no note;
# they render as "[[Source]] (vista)" wherever they appear.

include "simplify";
include "rich_text";
include "blocks_to_md";
include "status";

# Filenames safe for Obsidian / common filesystems.
def safe_name:
  gsub("[\\]\\\\/:*?\"<>|#^\\[]"; "")
  | gsub("\\s+"; " ") | sub("^ "; "") | .[:120] | sub(" $"; "");

def folder_parts($by; $id; $depth):
  ($by[$id].parentId // "") as $p
  | if $depth > 64 or $p == "" or (($by[$p].title // "") == "") then []
    else folder_parts($by; $p; $depth + 1) + [$by[$p].title | safe_name] end;

def frontmatter:
  ["---", "id: \(.id)", "kind: \(.kind)", "last_edited: \(.last_edited_time)"]
  + (if .parentId then ["parent: \(.parentId)"] else [] end)
  + ["notion_status: \(node_status)", "status_since: \(.status_since // "")", "---", ""]
  + (if node_status == "active" then []
     else ["> ⚠️ Esta " + (if .kind == "database" then "base de datos" else "página" end)
           + " " + (node_status | status_phrase) + " desde " + (.status_since // "" | dmy), ""] end)
  + ["# \(.title)", ""];

# Property value → markdown. Rich text keeps mentions as wikilinks, relations
# resolve to titles, Notion-hosted files show their name only.
def prop_md($t):
  def fmt:
    if   type == "string"  then (if test("^[0-9a-f-]{32,36}$") and $t[normalize_id] then "[[" + $t[normalize_id] + "]]" else . end)
    elif type == "number"  then tostring
    elif type == "boolean" then tostring
    elif type == "array"   then map(fmt) | join(", ")
    elif type == "object" and (.start // null) then (if .end then "\(.start) → \(.end)" else .start end)
    elif type == "object" and (.url   // null) then "[" + (.name // .url) + "](" + .url + ")"
    elif type == "object" and (.name  // null) then "📎 " + .name + " (en Notion)"
    else tojson end;
  if   .type == "rich_text" then (.rich_text | render_rt($t))
  elif .type == "relation"  then (.relation // [] | map(wikilink($t; .id; null)) | join(", "))
  elif .type == "files"     then (.files // [] | map(file_md(null; null)) | join(", "))
  else (simplify_prop | if . == null or (type == "array" and length == 0) then "" else fmt end) end;

def section($heading; $lines):
  if ($lines | length) > 0 then ["## " + $heading] + $lines + [""] else [] end;

# " (archivada)" etc. after a link to a node that is not active.
def status_tag($by; $id):
  ($by[$id] // {} | node_status) as $s
  | if $s == "active" then "" else " (" + ($s | status_label) + ")" end;

# childRefs plus cached children that Notion no longer lists under this node
# (an archived row drops out of its database's query, a trashed page out of
# its parent's blocks): their notes stay, so the listing keeps them.
def child_ids($kids):
  ((.childRefs // []) | map(.id)) as $refs
  | $refs + (($kids[.id] // []) - $refs);

def linked_md($t; $by; $kids):
  child_ids($kids) | map(
    if $t["_view:" + .] then "- [[" + $t["_view:" + .] + "]] (vista)"
    elif $t[.] then "- " + wikilink($t; .; null) + status_tag($by; .)
    else empty end);

def page_md($t; $by; $kids):
  ((.properties // {}) | to_entries
   | map(select(.value.type != "title")
         | (.value | prop_md($t)) as $v
         | select($v != "")
         | "- **\(.key)**: \($v)")) as $props
  | ((.blocks // []) | blocks_to_md($t)) as $body
  | frontmatter
    + section("Properties"; $props)
    + (if $body != "" then ["## Content", "", $body, ""] else [] end)
    + section("Linked"; linked_md($t; $by; $kids));

def db_md($t; $by; $kids):
  ((.schema // {}) | simplify_schema | to_entries | map(
     "- **\(.key)** (\(.value.type))"
     + (if .value.options then " — options: " + (.value.options | join(", ")) else "" end)
     + (if .value.format  then " — format: "  + .value.format else "" end)
     + (if .value.relationTarget then " — → " + .value.relationTarget else "" end))) as $schema
  | child_ids($kids) as $rows
  | frontmatter
    + section("Schema"; $schema)
    + section("Rows (\($rows | length))"; $rows | map("- " + wikilink($t; .; null) + status_tag($by; .)));

# Index of every note whose page is not active, or no longer under a root,
# by status then date.
def estado_md($out):
  ($out | map(select(.node | node_status != "active"))
   | sort_by([(.node | node_status), (.node.status_since // ""), .node.title])) as $off
  | ["# Estado de las páginas", ""]
    + (if ($off | length) == 0 then ["Todas las páginas del espejo están activas en Notion."]
       else ["Páginas que ya no están activas en Notion o que quedaron fuera de las raíces sincronizadas. Sus notas se conservan como estaban.", ""]
         + ($off | map("- [[" + (.rel | split("/") | last | sub("\\.md$"; "")) + "]] — "
                       + (.node | node_status | status_label) + " desde " + (.node.status_since // "" | dmy)))
       end);

[inputs]
| sort_by([(.kind != "page"), .id])
| (map({key: .id, value: .}) | from_entries) as $by
| (map(select(.parentId and (.view | not))) | group_by(.parentId)
   | map({key: .[0].parentId, value: map(.id)}) | from_entries) as $kids
| (map(if .view then {key: ("_view:" + .id), value: .title} else {key: .id, value: .title} end)
   | from_entries) as $t
| reduce (.[] | select(.view | not)) as $n ({used: {}, out: []};
    (folder_parts($by; $n.id; 0) | join("/")) as $folder
    | ($n.title | safe_name) as $base
    | (if $folder == "" then "" else $folder + "/" end) as $dir
    | ($dir + $base + ".md") as $rel
    | (if .used[$rel] then $dir + $base + " (" + $n.id[:6] + ").md" else $rel end) as $rel
    | .used[$rel] = true
    | .out += [{rel: $rel, node: $n}])
| .out as $out
| ($out[]
   | .node.id, .rel,
     ((if .node.kind == "database" then (.node | db_md($t; $by; $kids)) else (.node | page_md($t; $by; $kids)) end)
      | join("\n") | sub("\n+$"; "") + "\n")),
  "_estado", "_estado.md", (estado_md($out) | join("\n") + "\n")
