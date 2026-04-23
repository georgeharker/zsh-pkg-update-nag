# Stampfile + atomic lock to keep the nag rate-limited across shells.

_zpun_rate_limit_stamp_path() {
  emulate -L zsh
  setopt local_options
  print -r -- "$(_zpun_state_dir)/last_check"
}

_zpun_rate_limit_lock_path() {
  emulate -L zsh
  setopt local_options
  print -r -- "$(_zpun_state_dir)/lock.d"
}

# Return 0 if there was no existing stampfile (and we just created one in
# "initialized, wait one interval" mode). Return 1 if a stampfile already exists,
# or if FORCE is set (in which case the caller is expected to run the check now).
_zpun_rate_limit_init_if_missing() {
  emulate -L zsh
  setopt local_options

  [[ ${ZSH_PKG_UPDATE_NAG_FORCE:-0} == 1 ]] && return 1

  local stamp=$(_zpun_rate_limit_stamp_path)
  if [[ -e $stamp ]]; then
    return 1
  fi

  local dir=$(_zpun_state_dir)
  mkdir -p "$dir" 2>/dev/null || return 1
  : > "$stamp"
  print -u2 -r -- "zsh-pkg-update-nag: initialized, first check in ${zsh_pkg_update_nag_interval_hours}h (run \`zsh-pkg-update-nag --now\` to check immediately)"
  return 0
}

# Returns 0 if enough time has passed since the last check OR force is set.
_zpun_rate_limit_is_due() {
  emulate -L zsh
  setopt local_options

  [[ ${ZSH_PKG_UPDATE_NAG_FORCE:-0} == 1 ]] && return 0

  local stamp=$(_zpun_rate_limit_stamp_path)
  [[ -e $stamp ]] || return 0

  local interval_seconds=$(( zsh_pkg_update_nag_interval_hours * 3600 ))
  local now=$(date +%s)
  local mtime=$(_zpun_mtime "$stamp")
  (( now - mtime >= interval_seconds ))
}

# Refresh the stampfile's mtime to now. Errors are swallowed.
_zpun_rate_limit_stamp() {
  emulate -L zsh
  setopt local_options

  local stamp=$(_zpun_rate_limit_stamp_path)
  local dir=${stamp:h}
  [[ -d $dir ]] || mkdir -p "$dir" 2>/dev/null
  : > "$stamp" 2>/dev/null
}

# Atomic lock using mkdir (portable, unlike flock(1) on macOS).
_zpun_rate_limit_acquire_lock() {
  emulate -L zsh
  setopt local_options

  local lock=$(_zpun_rate_limit_lock_path)
  local dir=${lock:h}
  [[ -d $dir ]] || mkdir -p "$dir" 2>/dev/null

  # If a stale lock exists (older than 5 minutes), clean it up.
  if [[ -d $lock ]]; then
    local lock_mtime=$(_zpun_mtime "$lock")
    local now=$(date +%s)
    if (( now - lock_mtime > 300 )); then
      rmdir "$lock" 2>/dev/null
    fi
  fi

  mkdir "$lock" 2>/dev/null
}

_zpun_rate_limit_release_lock() {
  emulate -L zsh
  setopt local_options
  rmdir "$(_zpun_rate_limit_lock_path)" 2>/dev/null
}

# _zpun_mtime <path> — portable mtime-in-seconds lookup. macOS stat is BSD; GNU
# coreutils stat is only available via `gstat`. Fall back to perl.
#
# NB: do NOT name the local variable `path` — zsh ties scalar `$path` to the
# `$PATH` array, so shadowing it inside a function breaks every subsequent
# external command lookup in that function body.
_zpun_mtime() {
  emulate -L zsh
  setopt local_options

  local target=$1
  local result

  if result=$(stat -f %m "$target" 2>/dev/null) && [[ -n $result ]]; then
    print -r -- "$result"
    return
  fi
  if result=$(stat -c %Y "$target" 2>/dev/null) && [[ -n $result ]]; then
    print -r -- "$result"
    return
  fi
  if (( $+commands[perl] )); then
    perl -e 'print ((stat shift)[9])' "$target" 2>/dev/null && return
  fi
  print -r -- 0
}
