# Shared helpers: rich text → markdown, mention titles, Notion-hosted files.
# Used as a module (`include "rich_text";`, run jq with -L lib/jq).

def normalize_id: gsub("-"; "") | ascii_downcase;

def meaningful: type == "string" and . != "" and . != "Untitled" and . != "Untitled DB";

# Title for a mentioned/related id: cached title, else the mention's own
# plain_text, else the bare id.
def title_for($titles; $id; $plain):
  ($id | normalize_id) as $nid
  | ($titles[$nid]) as $t
  | if ($t | meaningful) then $t
    elif ($plain | meaningful) then $plain
    else $nid end;

def wikilink($titles; $id; $plain): "[[" + title_for($titles; $id; $plain) + "]]";

# Signed S3 URLs for files stored in Notion expire within an hour; never emit them.
def is_signed_url: type == "string" and (test("X-Amz-") or test("prod-files-secure"));

# Percent-decode (UTF-8 aware) so "recibo%20pago.pdf" reads as a name.
def url_decode:
  def hexval: ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | .[0] * 16 + .[1];
  [ scan("%[0-9A-Fa-f]{2}|.") | if length == 3 and startswith("%") then {b: (.[1:] | hexval)} else {c: (explode[0])} end ]
  | reduce .[] as $x ({out: [], cp: 0, need: 0};
      if $x.c then .out += [$x.c] | .need = 0
      elif .need > 0 then
        .cp = .cp * 64 + ($x.b % 64) | .need -= 1
        | if .need == 0 then .out += [.cp] else . end
      elif $x.b < 128 then .out += [$x.b]
      elif $x.b >= 240 then .cp = $x.b % 8  | .need = 3
      elif $x.b >= 224 then .cp = $x.b % 16 | .need = 2
      elif $x.b >= 192 then .cp = $x.b % 32 | .need = 1
      else . end)
  | .out | implode;

def url_basename: sub("[?#].*$"; "") | sub("/+$"; "") | split("/") | last // "" | url_decode;

# Input: a Notion file object (block body or `files` property entry).
# Output: markdown; hosted files show only their name.
def file_md($label; $caption):
  (.type // "") as $kind
  | (if $kind == "external" then .external.url
     elif $kind == "file" then .file.url
     else null end) as $url
  | ([.name, ($url // "" | url_basename), $label] | map(select(meaningful)) | first // "file") as $name
  | if $kind == "external" and ($url | is_signed_url | not) then
      "[" + (if ($caption | meaningful) then $caption else $name end) + "](" + $url + ")"
    else
      "📎 " + $name + " (en Notion)" + (if ($caption | meaningful) then " — " + $caption else "" end)
    end;

def render_rt($titles):
  . // [] | map(
    if .type == "mention" then
      (.mention) as $m
      | (.plain_text // "") as $plain
      | if   ($m.type == "page")     and ($m.page.id     != null) then wikilink($titles; $m.page.id; $plain)
        elif ($m.type == "database") and ($m.database.id != null) then wikilink($titles; $m.database.id; $plain)
        elif ($m.type == "user") then "@" + ($m.user.name // $m.user.id // "user")
        elif ($m.type == "date") then ($m.date.start // "") + (if $m.date.end then " → " + $m.date.end else "" end)
        elif ($m.type == "link_mention") and ($m.link_mention.href | is_signed_url | not) then
          "[" + ($m.link_mention.title // $plain) + "](" + $m.link_mention.href + ")"
        elif ($m.type == "link_preview") and ($m.link_preview.url | is_signed_url | not) then
          "[" + $plain + "](" + $m.link_preview.url + ")"
        else $plain end
    else
      (.plain_text // "") as $s
      | (.annotations // {}) as $a
      | (if $a.code          then "`"  + $s + "`"  else $s end) as $s
      | (if $a.bold          then "**" + $s + "**" else $s end) as $s
      | (if $a.italic        then "*"  + $s + "*"  else $s end) as $s
      | (if $a.strikethrough then "~~" + $s + "~~" else $s end) as $s
      | (if .href and (.href | is_signed_url | not) then "[" + $s + "](" + .href + ")" else $s end)
    end
  ) | join("");
