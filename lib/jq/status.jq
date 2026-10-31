# Page status: active | archived | in_trash | unreachable | outside.
# outside is set by the crawler, never by Notion (see lib/status.sh).
# Used as a module (`include "status";`, run jq with -L lib/jq).

# Input: a Notion page, database or search result. API 2025-09-03 returns
# in_trash and archived on all of them, is_archived on pages only; archived
# can be the legacy alias of in_trash, so in_trash is checked first.
def notion_status:
  if .in_trash == true then "in_trash"
  elif .is_archived == true or .archived == true then "archived"
  else "active" end;

# Input: a cache node. Nodes cached before status tracking count as active.
def node_status: .status // "active";

# "2026-10-31" → "31-10-2026"
def dmy: split("-") | reverse | join("-");

# Short Spanish label for listings, e.g. "archivada".
def status_label:
  {archived: "archivada", in_trash: "en la papelera", unreachable: "no accesible",
   outside: "fuera de las raíces"}[.] // "";

# Banner text after "Esta página " / "Esta base de datos ".
def status_phrase:
  {archived: "está archivada en Notion",
   in_trash: "está en la papelera de Notion",
   unreachable: "ya no es accesible en Notion (borrada o sin permiso)",
   outside: "está fuera de las raíces sincronizadas (solo se mencionaba)"}[.] // "";
