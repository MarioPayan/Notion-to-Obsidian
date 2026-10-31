# Notion-to-Obsidian

Mirrors one or more Notion pages, with everything under them, into a folder of
markdown notes you can grep, read or open in [Obsidian](https://obsidian.md/).
It only reads from Notion: the mirror is a read-only copy, never a place to edit.

Pure bash + `curl` + `jq`. No runtime and no install step.

## What it does

- Walks each root page: child pages, inline and full-page databases, and every
  database row (rows are pages too, with their properties).
- Caches each page or database as raw JSON in the cache folder.
- Writes the vault: one note per page or database, in folders that follow the
  Notion hierarchy, linked with `[[Title]]` wiki-links. Page mentions,
  relations and tables become wiki-links and markdown tables.
- Writes `output/`: one simplified JSON file per page or database.
- Files stored in Notion appear by name only (`📎 receipt.pdf (en Notion)`):
  Notion's download links expire after an hour, so they are never written.
- Never deletes a note because its page disappeared from Notion: the note is
  kept and marked with the page's status (see [Page status](#page-status-archivedtrashunreachable)).

## Requirements

- `bash` 4+, `curl`, `jq` 1.7+ (needs `--raw-output0`), GNU `date`.
- A Notion integration token that can read the pages you mirror.

## Setup

1. **Create an integration.** At <https://www.notion.so/my-integrations>, create
   an internal integration with *Read content* capability and copy its token
   (`ntn_…`).
2. **Connect it to the root page.** Open the page in Notion → `•••` →
   *Connections* → add the integration. It then sees that page and everything
   under it. Pages it is not connected to return 404 and are skipped.
3. **Give the script the token.** Put it in `.env` (gitignored) or export it:

   ```sh
   # .env
   NOTION_TOKEN=ntn_...
   ```

4. **Run it** with a profile (next section).

## Profiles (`--name`/`--root`)

A profile is a name plus one or more root URLs, all on the command line:

```sh
./fetch.sh --name work --root https://www.notion.so/Example-Page-00000000000000000000000000000000
./fetch.sh --name work --root <url> --root <another-url>   # several roots
./fetch.sh --name work --root <url> --full                 # full crawl
```

Each profile writes everything under `mirrors/<name>/` (`cache/`, `output/`,
`vault/`), which is gitignored, so profiles never share a cache. A `?v=` view
URL is treated as a database. Nothing about your workspace needs to live in
the repo.

**Default mode.** `./fetch.sh` with no `--name` reads the roots from
`urls.json` (gitignored; copy `urls.example.json`) and writes to `.cache/`,
`output/` and `vault/`, or to the folders set in `config.json`.

## Usage

```sh
./fetch.sh --name NAME --root URL         # incremental sync (full crawl on the first run)
./fetch.sh --name NAME --root URL --full  # full crawl; also re-checks pages it no longer reaches
DEBUG=true ./fetch.sh --name NAME --root URL   # log every request
./fetch.sh --help
```

**Incremental sync.** After a run that ends without errors, the start time is
saved in `<cache>/_sync_state.json`. The next run asks Notion's search API for
pages and data sources edited since then (minus `sync_margin_minutes`, because
Notion timestamps are minute-granular), and refetches only those that sit under
a configured root: changed pages, new pages whose parent is already mirrored,
and new or changed database rows (their database is re-listed; unchanged rows
are not fetched again). The whole vault is then re-rendered from the cache,
which takes about a second. A run with nothing changed makes two API calls.

A full crawl runs instead when there is no state, when the set of roots
changed, or when you pass `--full`.

**Limits of incremental sync:**

- Pages sent to the trash, permanent deletions and pages moved out of every
  root are only detected by `--full`: Notion search leaves trashed pages out,
  and trashing a child does not change its parent's edit time. Until then
  their notes show the last known content as active.
- It relies on Notion search, which lagged about 1–2 minutes behind a new page
  in testing (the 5-minute `sync_margin_minutes` covers that), and only returns
  what the integration can see.
- A run with errors does not advance the saved time, so the next run retries
  the same window.

Ctrl-C is safe: every cache file is written atomically, and the next run
resumes.

## Page status (archived/trash/unreachable)

Every note carries its page's status in the frontmatter:

```yaml
notion_status: active        # active | archived | in_trash | unreachable
status_since: 2026-01-15     # date it took that status
```

- **Incremental run:** every note that is not `active` is re-checked with a
  GET (usually zero or a few), so a page restored from the trash goes back to
  `active` right away. Restoring does not change a page's edit time, so search
  alone would never report it. New trash/archive events need `--full` (see
  above).
- **Full run:** every cached page the crawl did not reach is checked with a
  GET. Notion's `in_trash` / `archived` / `is_archived` flags set `in_trash` or
  `archived`; a 404 or 403 sets `unreachable` (deleted, or no longer shared
  with the integration). A page moved out of every root is still reachable
  and stays `active`, with its last known content.

A note whose page is not active keeps its content and gets a banner on top
(in Spanish, like the rest of the generated text):

```markdown
> ⚠️ Esta página está archivada en Notion desde 15-01-2026
```

Database row and child listings mark those notes, e.g. `[[Old task]] (archivada)`,
and `_estado.md` at the vault root lists every non-active note with its status
and date (or says that everything is active).

Notes are only ever deleted when a page is renamed or moved inside the
mirror: its old file is removed so there is no duplicate. To drop notes for
good, delete them by hand or delete the profile folder and run again.

## Config

`config.json` is optional; missing keys use these defaults:

| Key                   | Default  | Notes                                               |
| --------------------- | -------- | --------------------------------------------------- |
| `concurrency`         | `3`      | Root URLs crawled in parallel.                      |
| `sync_margin_minutes` | `5`      | Look-back added to each incremental window.         |
| `debug`               | `false`  | Verbose logs (or `DEBUG=true` in the environment).  |
| `cache_dir`           | `.cache` | Default mode only: raw cache and sync state.        |
| `output_dir`          | `output` | Default mode only: simplified JSON.                 |
| `vault_dir`           | `vault`  | Default mode only: markdown notes.                  |

With `--name`, the three folders are always `mirrors/<name>/{cache,output,vault}`.

## Output layout

```
mirrors/<name>/
  vault/
    My Workspace.md                  # root page
    My Workspace/
      Project · Example.md           # child page
      Project · Example/
        Tasks.md                     # database: schema + list of rows
        Tasks/
          Write the first draft.md   # row: properties + content
    _estado.md                       # pages that are no longer active
  output/<id>.json                   # {id, kind, title, last_edited, parentId, status, status_since, properties|schema, childRefs}
  cache/page_<id>.json, db_<id>.json # raw Notion responses (blocks included) + status
  cache/_sync_state.json             # last successful run, per root
```

Every note starts with frontmatter (`id`, `kind`, `last_edited`, `parent`,
`notion_status`, `status_since`), then `## Properties`, `## Content` and
`## Linked` (child pages and databases). A linked database view renders as
`[[Tasks]] (vista)` and gets no note of its own. `vault/.notion-paths` and
`output/.notion-paths` record where each page was last written.

## Using it from an AI assistant

- **Sync right before reading:** run `./fetch.sh --name NAME --root URL`, then
  read `mirrors/NAME/vault/` with grep or a file reader. Start from the root
  page's note and follow the folders; check `_estado.md` for pages that are
  gone from Notion.
- **The mirror is read-only.** Never edit files in the vault, output or cache
  folders; the next run overwrites them.
- **Write through Notion** (an MCP server, the API or the app), then sync
  again if you need to read the result.
- **Keep personal settings outside the repo:** root URLs, profile names and
  paths belong in your assistant's own instructions, for example a page in
  your own Notion that it reads first, not in files committed here.
- The `id` in each note's frontmatter is the Notion page id, ready for the
  Notion API or MCP tools.

There is intentionally no CI workflow: a scheduled sync in a public repo
would publish your vault.

## Troubleshooting

| Symptom | Fix |
| ------- | --- |
| `NOTION_TOKEN is not set` | Create `.env` or export the token. |
| `Could not resolve <url>` or HTTP 404 | The integration is not connected to that page (Setup step 2). |
| An edit does not show up | Search can lag; run again in a minute, or add `--full`. |
| A deleted page still looks active | Run with `--full`; it is then marked `unreachable`. |
| `jq: Unknown arguments: --raw-output0` | Upgrade jq to 1.7 or newer. |
| Something looks stale or corrupt | Delete the profile's `cache/` and run again (full crawl). |

## Code layout

```
fetch.sh          entry point: arguments, config, full vs incremental, retries, render
lib/notion.sh     curl wrappers with 429/5xx backoff; search; pagination
lib/crawl.sh      recursive crawl of pages and databases into the cache
lib/sync.sh       sync state and the incremental pass
lib/status.sh     page status: backfill, re-checks after --full
lib/render.sh     cache → output/ and vault/
lib/log.sh        progress line, counters, failure list
lib/jq/           jq filters: vault.jq (notes), status, blocks_to_md, rich_text, simplify
```
