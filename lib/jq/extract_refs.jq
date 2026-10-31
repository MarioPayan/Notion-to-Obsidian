# Module: child_refs walks a blocks tree (with nested _children) and emits the
# pages and databases it contains: child_page and child_database blocks, at
# any depth (inside columns, toggles, synced blocks).
#
# link_to_page blocks and page/database mentions are references, not
# containment: they render as wikilinks but are never crawled, so a page is
# only mirrored under its real Notion parent.
#
# Output: deduplicated array of {id, kind, title}.

def normalize_id: gsub("-"; "") | ascii_downcase;

def walk_children:
  . // [] | map(
    (if .type == "child_page" then [{id: (.id | normalize_id), kind: "page", title: .child_page.title}]
     elif .type == "child_database" then [{id: (.id | normalize_id), kind: "database", title: .child_database.title}]
     else [] end)
    + ((._children // []) | walk_children)
  )
  | add // [];

def child_refs: walk_children | unique_by(.id);
