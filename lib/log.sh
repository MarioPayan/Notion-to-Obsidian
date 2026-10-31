# Logging utilities. Call set_debug true / set_debug false to toggle verbose mode.
# Progress counters are stored in files so they survive across subshells.

: "${LOG_STATE_DIR:=${TMPDIR:-/tmp}/notion-fetcher-$$}"
mkdir -p "$LOG_STATE_DIR"

LOG_DEBUG=false
LOG_LAST_AT_FILE="$LOG_STATE_DIR/last_log_at"
LOG_FETCHED_FILE="$LOG_STATE_DIR/fetched"
LOG_CACHED_FILE="$LOG_STATE_DIR/cached"
LOG_ERRORS_FILE="$LOG_STATE_DIR/errors"
LOG_LABEL_FILE="$LOG_STATE_DIR/label"
LOG_FAILED_FILE="$LOG_STATE_DIR/failed"
LOG_HEARTBEAT_PID_FILE="$LOG_STATE_DIR/heartbeat.pid"

: > "$LOG_LAST_AT_FILE"
date +%s > "$LOG_LAST_AT_FILE"
echo 0 > "$LOG_FETCHED_FILE"
echo 0 > "$LOG_CACHED_FILE"
echo 0 > "$LOG_ERRORS_FILE"
: > "$LOG_LABEL_FILE"
: > "$LOG_FAILED_FILE"

# ANSI colors (disabled if not a TTY)
if [ -t 2 ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
  C_GREY=$'\033[90m'
  TTY=1
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_GREY=""
  TTY=0
fi

set_debug() { LOG_DEBUG="$1"; }
is_debug()  { [ "$LOG_DEBUG" = "true" ]; }

# Time-driven braille spinner. The frame is a pure function of the current
# millisecond, so concurrent workers + the animator all agree without sharing
# state. 10 frames over 1s = 10fps rotation.
LOG_SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
_spin_frame() {
  local idx=0
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local us="${EPOCHREALTIME#*.}"
    idx=$(( (10#${us:0:3} / 100) % 10 ))
  else
    idx=$(( $(date +%s) % 10 ))
  fi
  printf '%s' "${LOG_SPIN_FRAMES[idx]}"
}

# Clear any in-flight progress line so the next standalone log starts clean.
_clear_progress_line() {
  [ "$TTY" = "1" ] && printf '\r\033[K' >&2 || true
}

_emit() {
  local color="$1" icon="$2" msg="$3"
  _clear_progress_line
  printf '%s%s%s %s\n' "$color" "$icon" "$C_RESET" "$msg" >&2
  date +%s > "$LOG_LAST_AT_FILE"
}

log_info()  { _emit "$C_BLUE"           "ℹ" "$1"; }
log_ok()    { _emit "$C_GREEN$C_BOLD"   "✓" "$1"; }
log_warn()  { _emit "$C_YELLOW"         "⚠" "$1"; }
log_error() { _emit "$C_RED$C_BOLD"     "✗" "$1"; }
log_debug() { is_debug && _emit "$C_DIM" "›" "$1" || true; }

# Print a section divider ("rule") with an optional bold label.
log_rule() {
  local label="${1:-}"
  _clear_progress_line
  if [ -n "$label" ]; then
    printf '\n%s━━━━━━━━━━  %s%s%s  %s━━━━━━━━━━%s\n' \
      "$C_MAGENTA" "$C_BOLD" "$label" "$C_RESET" "$C_MAGENTA" "$C_RESET" >&2
  else
    printf '%s──────────────────────────────────────%s\n' "$C_MAGENTA" "$C_RESET" >&2
  fi
}

_bump_file() {
  local f="$1"
  (
    flock -x 9
    local v
    v="$(cat "$f" 2>/dev/null || echo 0)"
    echo $((v + 1)) > "$f"
  ) 9>"$f.lock"
}

bump_fetched() { _bump_file "$LOG_FETCHED_FILE"; _render_progress "$1"; }
bump_cached()  { _bump_file "$LOG_CACHED_FILE";  _render_progress "$1"; }
bump_error()   { _bump_file "$LOG_ERRORS_FILE";  _render_progress "$1"; }

progress_fetched() { cat "$LOG_FETCHED_FILE" 2>/dev/null || echo 0; }
progress_cached()  { cat "$LOG_CACHED_FILE"  2>/dev/null || echo 0; }
progress_errors()  { cat "$LOG_ERRORS_FILE"  2>/dev/null || echo 0; }

# Reset counters (used between the main crawl and the retry pass).
reset_counters() {
  echo 0 > "$LOG_FETCHED_FILE"
  echo 0 > "$LOG_CACHED_FILE"
  echo 0 > "$LOG_ERRORS_FILE"
  : > "$LOG_LABEL_FILE"
}

_truncate() {
  local s="$1" n="$2"
  if [ "${#s}" -le "$n" ]; then printf '%s' "$s"
  else printf '%s…' "${s:0:$((n - 1))}"
  fi
}

# Compose the progress line text (no leading \r, no trailing newline).
_compose_progress_line() {
  local label="$1" idle_secs="${2:-0}"
  local f c e done err_color idle_suffix=""
  f="$(progress_fetched)"; c="$(progress_cached)"; e="$(progress_errors)"
  done=$((f + c))
  err_color="$C_GREY"
  [ "$e" -gt 0 ] && err_color="$C_RED"
  [ "$idle_secs" -gt 4 ] && idle_suffix="$(printf '  %s(idle %ds)%s' "$C_DIM" "$idle_secs" "$C_RESET")"
  printf '%s%s%s  %s%d done%s  %s✓ %d%s  %s● %d%s  %s✗ %d%s  %s· %s%s%s' \
    "$C_CYAN"    "$(_spin_frame)" "$C_RESET" \
    "$C_BOLD"    "$done"          "$C_RESET" \
    "$C_GREEN"   "$f"             "$C_RESET" \
    "$C_BLUE"    "$c"             "$C_RESET" \
    "$err_color" "$e"             "$C_RESET" \
    "$C_DIM"     "$(_truncate "$label" 60)" "$C_RESET" \
    "$idle_suffix"
}

_render_progress() {
  local label="$1"
  echo "$label" > "$LOG_LABEL_FILE.tmp" 2>/dev/null \
    && mv "$LOG_LABEL_FILE.tmp" "$LOG_LABEL_FILE" 2>/dev/null
  local line
  line="$(_compose_progress_line "$label" 0)"
  if [ "$TTY" = "1" ]; then
    printf '\r\033[K%s' "$line" >&2
  else
    printf '%s\n' "$line" >&2
  fi
  date +%s > "$LOG_LAST_AT_FILE"
}

finish_progress_line() {
  [ "$TTY" = "1" ] && printf '\r\033[K' >&2 || true
}

# On TTY: tick a ~100ms animator that constantly redraws the progress line
# with a rotating spinner and an "(idle Ns)" suffix once activity pauses.
# On non-TTY: fall back to the 5s "still working" pinger.
start_heartbeat() {
  stop_heartbeat
  if [ "$TTY" = "1" ]; then
    _start_tty_animator
  else
    _start_idle_pinger
  fi
}

_start_tty_animator() {
  (
    while sleep 0.1; do
      local label="" f=0 c=0 e=0 last=0 now delta
      [ -f "$LOG_LABEL_FILE" ]   && IFS= read -r label < "$LOG_LABEL_FILE"   2>/dev/null
      [ -f "$LOG_LAST_AT_FILE" ] && IFS= read -r last  < "$LOG_LAST_AT_FILE" 2>/dev/null
      printf -v now '%(%s)T' -1
      [ -z "$last" ] && last="$now"
      delta=$((now - last))
      printf '\r\033[K%s' "$(_compose_progress_line "$label" "$delta")" >&2
    done
  ) &
  echo $! > "$LOG_HEARTBEAT_PID_FILE"
  disown $! 2>/dev/null || true
}

_start_idle_pinger() {
  (
    while sleep 5; do
      local now last delta
      now="$(date +%s)"
      last="$(cat "$LOG_LAST_AT_FILE" 2>/dev/null || echo "$now")"
      delta=$((now - last))
      if [ "$delta" -gt 4 ]; then
        local f c e
        f="$(progress_fetched)"; c="$(progress_cached)"; e="$(progress_errors)"
        printf '%s%s%s  %s… still working (idle %ds)%s  %s✓ %d · ● %d · ✗ %d%s\n' \
          "$C_CYAN" "$(_spin_frame)"   "$C_RESET" \
          "$C_DIM"  "$delta"           "$C_RESET" \
          "$C_DIM"  "$f" "$c" "$e"     "$C_RESET" >&2
        date +%s > "$LOG_LAST_AT_FILE"
      fi
    done
  ) &
  echo $! > "$LOG_HEARTBEAT_PID_FILE"
  disown $! 2>/dev/null || true
}

stop_heartbeat() {
  if [ -f "$LOG_HEARTBEAT_PID_FILE" ]; then
    local pid
    pid="$(cat "$LOG_HEARTBEAT_PID_FILE")"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$LOG_HEARTBEAT_PID_FILE"
  fi
}

cleanup_log_state() {
  stop_heartbeat
  rm -rf "$LOG_STATE_DIR" 2>/dev/null || true
}

# --- Failure tracking ------------------------------------------------------
# Records ids whose API fetch failed so the retry pass can re-attempt them.
# Lines are "KIND\tID\tPARENT_ID" (parent may be empty for roots).

record_failure() {
  local kind="$1" id="$2" parent="${3:-}"
  printf '%s\t%s\t%s\n' "$kind" "$id" "$parent" >> "$LOG_FAILED_FILE"
}

clear_failure() {
  local id="$1"
  [ -f "$LOG_FAILED_FILE" ] || return 0
  grep -v $'\t'"$id"$'\t' "$LOG_FAILED_FILE" > "$LOG_FAILED_FILE.tmp" 2>/dev/null
  mv "$LOG_FAILED_FILE.tmp" "$LOG_FAILED_FILE" 2>/dev/null || : > "$LOG_FAILED_FILE"
}

# Print unique failures as "KIND\tID\tPARENT_ID" lines, one per id.
list_failures() {
  [ -s "$LOG_FAILED_FILE" ] || return 0
  # Dedupe by id (field 2) — first occurrence wins (keeps original parent).
  awk -F'\t' '!seen[$2]++' "$LOG_FAILED_FILE"
}

count_failures() {
  local n
  n="$(list_failures | grep -c . 2>/dev/null || true)"
  printf '%s\n' "${n:-0}"
}

reset_failures() {
  : > "$LOG_FAILED_FILE"
}
