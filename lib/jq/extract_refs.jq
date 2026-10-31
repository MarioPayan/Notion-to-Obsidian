# Walks a blocks tree (with nested _children) and emits every page/database
# reference found anywhere inside it: child_page, child_database, link_to_page,
# and page/database mentions inside rich_text or captions.
#
# Output: deduplicated array of {id, kind, title?}.

def normalize_id: gsub("-"; "") | ascii_downcase;

def walk_blocks:
  . // [] | map(
    # block-level refs
    (
      if .type == "child_page"     then [{id: (.id | normalize_id),                kind: "page",     title: .child_page.title}]
      elif .type == "child_database" then [{id: (.id | normalize_id),              kind: "database", title: .child_database.title}]
      elif .type == "link_to_page" then
        (.link_to_page as $l
         | if   $l.type == "page_id"     then [{id: ($l.page_id | normalize_id),     kind: "page"}]
           elif $l.type == "database_id" then [{id: ($l.database_id | normalize_id), kind: "database"}]
           else [] end)
      else [] end
    )
    +
    # rich_text mentions in body and caption
    (
      ((.[.type].rich_text // []) + (.[.type].caption // []))
      | map(
          if .type == "mention" then
            if .mention.type == "page" and .mention.page.id then
              {id: (.mention.page.id | normalize_id), kind: "page"}
            elif .mention.type == "database" and .mention.database.id then
              {id: (.mention.database.id | normalize_id), kind: "database"}
            else empty end
          else empty end
        )
    )
    +
    # recurse into containers
    ((._children // []) | walk_blocks)
  )
  | add // [];

walk_blocks
| unique_by(.id)
