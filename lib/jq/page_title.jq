# Extract a page's title from a /pages/{id} response.
# Looks for the property whose type is "title" (the Notion title column),
# joins all rich_text segments, falls back to "Untitled".

(.properties // {}
 | to_entries
 | map(select(.value.type == "title"))
 | first.value.title // []
 | map(.plain_text // "")
 | join("")
 | if . == "" then "Untitled" else . end)
