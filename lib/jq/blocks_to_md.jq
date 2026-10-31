# Module: blocks_to_md($titles) turns a blocks array (with nested _children)
# into markdown; $titles maps normalized ids to titles.
#
# Container blocks (column_list/column/synced_block) flatten their children at
# the same depth; everything else nests children at depth+1. Mentions and
# link_to_page resolve to Obsidian wikilinks via the titles map. Files stored
# in Notion render as their name only (their signed URLs expire in an hour).

include "rich_text";

def resolve_title($titles; $id): title_for($titles; $id; null);

# One markdown table cell: no pipes or newlines may leak through.
def cell_md($titles): render_rt($titles) | gsub("\\|"; "\\|") | gsub("\n"; "<br>");

def indent_str($d): "  " * $d;

def render_one($depth; $num; $titles):
  . as $b
  | $b[$b.type] as $body
  | indent_str($depth) as $ind
  |
  if $b.type == "paragraph" then
    ($body.rich_text | render_rt($titles)) as $t
    | if $t == "" then [""] else [$ind + $t, ""] end
  elif $b.type == "heading_1" then [$ind + "# "  + ($body.rich_text | render_rt($titles)), ""]
  elif $b.type == "heading_2" then [$ind + "## " + ($body.rich_text | render_rt($titles)), ""]
  elif $b.type == "heading_3" then [$ind + "### "+ ($body.rich_text | render_rt($titles)), ""]
  elif $b.type == "bulleted_list_item" then [$ind + "- " + ($body.rich_text | render_rt($titles))]
  elif $b.type == "numbered_list_item" then [$ind + ($num | tostring) + ". " + ($body.rich_text | render_rt($titles))]
  elif $b.type == "to_do" then
    [$ind + "- [" + (if $body.checked then "x" else " " end) + "] " + ($body.rich_text | render_rt($titles))]
  elif $b.type == "toggle" then [$ind + "- " + ($body.rich_text | render_rt($titles))]
  elif $b.type == "quote"  then [$ind + "> " + ($body.rich_text | render_rt($titles)), ""]
  elif $b.type == "callout" then
    [$ind + "> " + ($body.icon.emoji // "💡") + " " + ($body.rich_text | render_rt($titles)), ""]
  elif $b.type == "code" then
    ($body.language // "") as $lang
    | (($body.rich_text // []) | map(.plain_text // "") | join("")) as $code
    | [$ind + "```" + $lang] + ($code | split("\n") | map($ind + .)) + [$ind + "```", ""]
  elif $b.type == "divider" then [$ind + "---", ""]
  elif $b.type == "image" and $body.type == "external" and ($body.external.url | is_signed_url | not) then
    ($body.caption | render_rt($titles)) as $cap
    | [$ind + "![" + (if $cap == "" then "image" else $cap end) + "](" + $body.external.url + ")", ""]
  elif ($b.type == "image" or $b.type == "file" or $b.type == "video" or $b.type == "audio" or $b.type == "pdf") then
    [$ind + ($body | file_md($b.type; ($body.caption | render_rt($titles)))), ""]
  elif ($b.type == "bookmark" or $b.type == "embed" or $b.type == "link_preview") then
    ($body.url // "") as $url
    | ($body.caption | render_rt($titles)) as $cap
    | if ($url | is_signed_url) then
        [$ind + ({type: "file", file: {url: $url}} | file_md($b.type; $cap)), ""]
      else
        [$ind + "[" + (if $cap == "" then $url else $cap end) + "](" + $url + ")", ""]
      end
  elif $b.type == "equation"        then [$ind + "$$" + ($body.expression // "") + "$$", ""]
  elif $b.type == "child_page"      then [$ind + "- → " + wikilink($titles; $b.id; $body.title)]
  elif $b.type == "child_database" then
    # Linked views have no title of their own; point at the source database.
    if ($body.title | meaningful) or ($titles[$b.id | normalize_id] | meaningful)
    then [$ind + "- ▦ " + wikilink($titles; $b.id; $body.title)]
    elif ($titles["_view:" + ($b.id | normalize_id)] | meaningful)
    then [$ind + "- ▦ [[" + $titles["_view:" + ($b.id | normalize_id)] + "]] (vista)"]
    else [$ind + "- ▦ (vista de base de datos)"] end
  elif $b.type == "link_to_page" then
    (if $body.type == "page_id" then $body.page_id
     elif $body.type == "database_id" then $body.database_id
     else null end) as $tid
    | [$ind + "- → [[" + (if $tid then resolve_title($titles; $tid) else "unknown" end) + "]]"]
  elif $b.type == "table" then
    (($b._children // []) | map(select(.type == "table_row") | .table_row.cells | map(cell_md($titles)))) as $rows
    | ([($body.table_width // 0)] + ($rows | map(length)) | max) as $w
    | ($rows | map(. + [range(length; $w) | ""])) as $rows
    | (if $body.has_column_header and ($rows | length) > 0
       then {head: $rows[0], body: $rows[1:]}
       else {head: [range(0; $w) | ""], body: $rows} end) as $t
    | def line: $ind + "| " + join(" | ") + " |";
      if $w == 0 then [] else
        [($t.head | line), ([range(0; $w) | "---"] | line)] + ($t.body | map(line)) + [""]
      end
  elif $b.type == "table_row" then []
  elif ($b.type == "column_list" or $b.type == "column" or $b.type == "synced_block") then []
  elif ($b.type == "table_of_contents" or $b.type == "breadcrumb" or $b.type == "unsupported") then []
  else
    (if $body.rich_text then ($body.rich_text | render_rt($titles)) else "" end) as $t
    | if $t != "" then [$ind + $t, ""] else [$ind + "<!-- " + $b.type + " -->"] end
  end;

def list_like: . as $t | ["bulleted_list_item", "numbered_list_item", "to_do", "toggle",
  "child_page", "child_database", "link_to_page"] | index($t) != null;

def render_blocks_arr($depth; $titles):
  . as $bs
  | reduce range(0; ($bs | length)) as $i (
      {lines: [], num: 0, prev: ""};
      $bs[$i] as $b
      | (if $b.type == "numbered_list_item" then
           (if .prev == "numbered_list_item" then .num + 1 else 1 end)
         else 0 end) as $newnum
      | ($b | render_one($depth; $newnum; $titles)) as $blines
      | (
          if (($b._children // []) | length) > 0
             and ($b.type != "child_page")
             and ($b.type != "child_database")
             and ($b.type != "table")
          then
            (if ($b.type == "column_list" or $b.type == "column" or $b.type == "synced_block")
             then ($b._children | render_blocks_arr($depth; $titles))
             else ($b._children | render_blocks_arr($depth + 1; $titles))
             end)
          else []
          end
        ) as $sub
      # A list that ends needs a blank line before what follows it.
      | (if (.prev | list_like) and ($b.type | list_like | not) then [""] else [] end) as $gap
      | {lines: (.lines + $gap + $blines + $sub), num: $newnum, prev: $b.type}
    )
  | .lines;

# Public: blocks array → markdown string.
def blocks_to_md($titles):
  render_blocks_arr(0; $titles)
  | join("\n")
  | gsub("\n{3,}"; "\n\n")
  | sub("^\n+"; "")
  | sub("\n+$"; "");
