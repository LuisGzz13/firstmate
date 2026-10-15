#!/usr/bin/env bash
# fm-local-classify-lib.sh - our local layer over bin/fm-classify-lib.sh.
#
# Part of the local layer (docs/local-layer.md): upstream Firstmate does not
# have this file, and bin/fm-classify-lib.sh sources it, when present, as its
# last step, so every function below can build on the upstream definitions.
#
# FM_OPEN_DECISIONS_CURSOR_PEEK=1 lets a read-only caller that cannot afford a
# whole-file fold of a long status log (bin/fm-local-voice-fleet-states.sh)
# answer status_open_decisions from the incremental fold's persisted cursor
# instead: the persisted open set plus the bytes appended since, folded in
# memory through upstream's _fm_decision_fold_line, so the answer is the one
# status_open_decisions_incremental would give without its cursor rewrite.
# It is the same set, never a cursor write, and upstream's whole-file fold
# whenever the cursor cannot serve.
#
# The wrap is installed only when the variable is 1 at source time, so every
# other process gets upstream's status_open_decisions untouched.
# The cursor reader mirrors status_open_decisions_incremental's cursor format at
# fold version _FM_LOCAL_PEEK_FOLD_VERSION and steps aside to the whole-file
# fold whenever upstream's FM_OPEN_DECISIONS_FOLD_VERSION differs, so an
# upstream change to the fold or its cursor costs speed, never correctness.

# The upstream fold version this cursor reader was written against.
_FM_LOCAL_PEEK_FOLD_VERSION=9

# Print <status-file>'s open set from its cursor, or return 1, printing
# nothing, whenever the cursor cannot vouch for the file - absent, a different
# fold version or kind, a different file identity, a shrunk file, or any read
# failure. Writes nothing, not even the incremental fold's scratch chunk.
_fm_local_open_decisions_cursor_peek() {  # <status-file> <kind>
  local f=$1 kind=$2 cf data first rest offset ident open='' cur_ident size span line resolve held
  [ "${FM_OPEN_DECISIONS_FOLD_VERSION:-}" = "$_FM_LOCAL_PEEK_FOLD_VERSION" ] || return 1
  cf=$(_fm_open_decisions_cursor_path "$f") || return 1
  [ -f "$cf" ] && [ -r "$cf" ] && [ ! -L "$cf" ] || return 1
  data=$(LC_ALL=C command cat "$cf" 2>/dev/null) || return 1
  first=${data%%$'\n'*}
  [ "$first" = "version=$FM_OPEN_DECISIONS_FOLD_VERSION:$kind" ] || return 1
  case "$data" in *$'\n'*) rest=${data#*$'\n'} ;; *) return 1 ;; esac
  offset=${rest%%$'\n'*}
  case "$offset" in offset=*) offset=${offset#offset=} ;; *) return 1 ;; esac
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  case "$rest" in *$'\n'*) rest=${rest#*$'\n'} ;; *) return 1 ;; esac
  ident=${rest%%$'\n'*}
  case "$ident" in ident=*) ident=${ident#ident=} ;; *) return 1 ;; esac
  [ -n "$ident" ] || return 1
  case "$rest" in *$'\n'*) open=${rest#*$'\n'} ;; esac
  cur_ident=$(_fm_open_decisions_file_ident "$f") || return 1
  [ "$cur_ident" = "$ident" ] || return 1
  size=$(_fm_status_file_size "$f") || return 1
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$offset" -le "$size" ] || return 1
  # The same test-only seam the incremental fold records its folded bytes in.
  [ -n "${FM_OPEN_DECISIONS_READ_PROBE:-}" ] \
    && printf '%s\t%s\n' "$f" "$((size - offset))" >> "$FM_OPEN_DECISIONS_READ_PROBE"
  if [ "$offset" -lt "$size" ]; then
    span=$(_fm_status_read_span "$f" "$offset" "$((size - offset))") || return 1
    resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
    held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
    while IFS= read -r line || [ -n "$line" ]; do
      open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held" "$kind") || return 1
    done <<SPAN
$span
SPAN
  fi
  printf '%s' "$open"
}

# Wrap status_open_decisions for an opted-in reader. Upstream's definition is
# kept under another name for every case the cursor cannot serve; a second
# source of this file without a fresh upstream definition leaves the wrap as is.
_fm_local_classify_wrap_open_decisions() {
  local def
  def=$(declare -f status_open_decisions) || return 0
  case "$def" in *_fm_local_upstream_status_open_decisions*) return 0 ;; esac
  eval "_fm_local_upstream_status_open_decisions${def#status_open_decisions}"
  status_open_decisions() {  # <status-file> [<kind>]
    local f=$1 kind=${2:-} open
    if [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ]; then
      kind=$(_fm_status_kind "$f" "$kind")
      if open=$(_fm_local_open_decisions_cursor_peek "$f" "$kind"); then
        printf '%s' "$open"
        return 0
      fi
    fi
    _fm_local_upstream_status_open_decisions "$@"
  }
}

if [ "${FM_OPEN_DECISIONS_CURSOR_PEEK:-0}" = 1 ]; then
  _fm_local_classify_wrap_open_decisions
fi
