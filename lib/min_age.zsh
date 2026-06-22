# Optional minimum-release-age gating for outdated packages.
#
# When zsh_pkg_update_nag_min_age > 0, _zpun_min_age_satisfied returns 1
# for any update whose latest version was published less than N days ago, and
# _zpun_collect_outdated drops the row before it reaches the user.
#
# Failure is always fail-open: if we can't determine an age (network down,
# missing curl/jq, third-party brew tap, malformed API response), we surface
# the update anyway and write a debug-log line. Hiding updates indefinitely
# because of a degraded environment would be strictly worse than current
# behavior.
#
# Publish dates are immutable, so a persistent TSV cache at
# $XDG_STATE_HOME/zsh-pkg-update-nag/age_cache.tsv eliminates repeat lookups.
#
# Per-manager publish-date lookups (`_zpun_min_age_lookup_<m>`) and any
# prefetch hooks (`_zpun_min_age_prefetch_<m>`) live in the corresponding
# `lib/providers/<m>.zsh`. This file keeps only the shared core: threshold
# inheritance, the satisfied/prefetch dispatchers, the ISO-8601 parser, and
# the cache.

# _zpun_min_age_threshold <manager> — print the configured threshold (in days)
# for a given manager. Per-manager overrides shadow the global setting:
#   zsh_pkg_update_nag_min_age_<manager>   if set (even to 0), wins
#   zsh_pkg_update_nag_min_age        otherwise
# Default 0 (off).
_zpun_min_age_threshold() {
  emulate -L zsh
  setopt local_options

  local manager=$1
  local override_var="zsh_pkg_update_nag_min_age_${manager}"
  # ${(P)override_var-fallback}: if the named variable is unset, use fallback.
  # An explicit empty/0 value wins over the global, by design.
  if (( ${(P)+override_var} )); then
    print -r -- "${(P)override_var:-0}"
  else
    print -r -- "${zsh_pkg_update_nag_min_age:-0}"
  fi
}

# _zpun_min_age_satisfied <manager> <name> <version> — 0 if old enough OR if
# we couldn't determine; 1 only when we positively know the update is too new.
_zpun_min_age_satisfied() {
  emulate -L zsh
  setopt local_options

  local manager=$1 name=$2 version=$3
  local threshold
  threshold=$(_zpun_min_age_threshold "$manager")

  (( threshold > 0 )) || return 0

  # The brew provider degrades to "?" for current/latest when jq is missing.
  # Without a real version string we can't ask any registry for an upload time.
  [[ -n $version && $version != '?' ]] || {
    _zpun_debug_log "min_age: ${manager}/${name} has no usable version, fail-open"
    return 0
  }

  local epoch
  epoch=$(_zpun_min_age_cache_get "$manager" "$name" "$version")
  if [[ -z $epoch ]]; then
    local lookup_fn="_zpun_min_age_lookup_${manager}"
    if (( ! $+functions[$lookup_fn] )); then
      _zpun_debug_log "min_age: no lookup for manager ${manager}, fail-open"
      return 0
    fi
    epoch=$( $lookup_fn "$name" "$version" 2>/dev/null )
    if [[ -z $epoch || $epoch != <-> ]]; then
      _zpun_debug_log "min_age: lookup failed for ${manager}/${name}@${version}, fail-open"
      return 0
    fi
    _zpun_min_age_cache_put "$manager" "$name" "$version" "$epoch"
  fi

  local now=$(date +%s)
  local age_seconds=$(( now - epoch ))
  local threshold_seconds=$(( threshold * 86400 ))
  (( age_seconds >= threshold_seconds ))
}

# _zpun_min_age_prefetch <manager> <name1> <version1> [<name2> <version2>...]
# Optional batch hook that a manager can implement to populate the cache for
# many (name, version) pairs in one go. The collector calls this once per
# manager before the per-row gating loop, so cache hits dominate. Managers
# without a hook are a no-op.
_zpun_min_age_prefetch() {
  emulate -L zsh
  setopt local_options

  local manager=$1; shift
  local hook="_zpun_min_age_prefetch_${manager}"
  (( $+functions[$hook] )) || return 0
  $hook "$@"
}

# _zpun_min_age_parse_iso8601 <iso_timestamp> — print the timestamp's epoch
# seconds in UTC. Accepts the variants we see in practice:
#   2024-01-15T12:34:56Z
#   2024-01-15T12:34:56.789Z
#   2024-01-15T12:34:56+00:00
# Falls back across BSD date / GNU date / perl Time::Piece. Same shape as
# _zpun_mtime in lib/rate_limit.zsh.
_zpun_min_age_parse_iso8601() {
  emulate -L zsh
  setopt local_options

  local iso=$1
  iso=${iso%%.*}                                 # drop fractional seconds
  iso=${iso%Z}                                   # drop trailing Z
  iso=${iso%%[+-][0-9][0-9]:[0-9][0-9]}          # drop +HH:MM offset
  iso=${iso%%[+-][0-9][0-9][0-9][0-9]}           # drop +HHMM offset
  [[ -n $iso ]] || return 1

  local epoch
  if epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "$iso" +%s 2>/dev/null) && [[ -n $epoch ]]; then
    print -r -- "$epoch"; return 0
  fi
  if epoch=$(TZ=UTC date -d "$iso" +%s 2>/dev/null) && [[ -n $epoch ]]; then
    print -r -- "$epoch"; return 0
  fi
  if (( $+commands[perl] )); then
    epoch=$(perl -MTime::Piece -e 'print Time::Piece->strptime(shift, "%Y-%m-%dT%H:%M:%S")->epoch' "$iso" 2>/dev/null)
    [[ -n $epoch ]] && { print -r -- "$epoch"; return 0 }
  fi
  return 1
}

# _zpun_min_age_cache_get <manager> <name> <version> — print epoch on hit;
# return 1 on miss. Walks the file linearly; with the 500-row cap that's
# instant in practice.
_zpun_min_age_cache_get() {
  emulate -L zsh
  setopt local_options

  local manager=$1 name=$2 version=$3
  local cache=$(_zpun_age_cache_path)
  [[ -f $cache ]] || return 1

  local key="${manager}"$'\t'"${name}"$'\t'"${version}"$'\t'
  local line found=""
  while IFS= read -r line; do
    [[ $line == "${key}"* ]] && found=${line##*$'\t'}
  done < "$cache"

  [[ -n $found && $found == <-> ]] || return 1
  print -r -- "$found"
}

# _zpun_min_age_cache_put <manager> <name> <version> <epoch> — append a row
# and trim if we're over the cap.
_zpun_min_age_cache_put() {
  emulate -L zsh
  setopt local_options

  local manager=$1 name=$2 version=$3 epoch=$4
  local cache=$(_zpun_age_cache_path)
  local dir=${cache:h}
  [[ -d $dir ]] || mkdir -p "$dir" 2>/dev/null
  print -r -- "${manager}"$'\t'"${name}"$'\t'"${version}"$'\t'"${epoch}" >> "$cache" 2>/dev/null
  _zpun_min_age_cache_trim
}

# _zpun_min_age_cache_trim — keep only the last 500 lines. Newest entries win
# on cache_get conflicts, so trimming oldest is the right policy.
_zpun_min_age_cache_trim() {
  emulate -L zsh
  setopt local_options

  local cache=$(_zpun_age_cache_path)
  [[ -f $cache ]] || return 0

  local count
  count=$(wc -l < "$cache" 2>/dev/null)
  count=${count// /}
  (( ${count:-0} > 500 )) || return 0

  local tmp="${cache}.tmp"
  if tail -n 500 "$cache" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$cache" 2>/dev/null
  fi
  rm -f "$tmp" 2>/dev/null
}

# _zpun_min_age_cache_count — number of entries currently in the cache. Used
# by --check-env. Prints "0" if the cache file doesn't exist.
_zpun_min_age_cache_count() {
  emulate -L zsh
  setopt local_options

  local cache=$(_zpun_age_cache_path)
  [[ -f $cache ]] || { print -r -- 0; return 0 }
  local count
  count=$(wc -l < "$cache" 2>/dev/null)
  count=${count// /}
  print -r -- "${count:-0}"
}

# version_lists cache: per-package (version, epoch, status) lists with a TTL.
# Distinct from age_cache.tsv (immutable single-version epochs, used by the
# brew gate). Resolve-mode managers (npm/pnpm/uv/gem) use this.

_zpun_version_lists_dir() {
  emulate -L zsh
  setopt local_options
  print -r -- "$(_zpun_state_dir)/version_lists"
}

# Deterministic, collision-free, filesystem-safe encoding of a package name.
# Percent-encodes anything outside [A-Za-z0-9._-] (npm scoped names carry / and @).
_zpun_min_age_versions_safe_name() {
  emulate -L zsh
  setopt local_options
  local s=$1 out="" ch i
  for (( i=1; i <= ${#s}; i+=1 )); do
    ch=$s[i]
    if [[ $ch == [A-Za-z0-9._-] ]]; then
      out+=$ch
    else
      out+=$(printf '%%%02X' "'$ch")
    fi
  done
  print -r -- "$out"
}

_zpun_min_age_versions_cache_path() {
  emulate -L zsh
  setopt local_options
  local manager=$1 name=$2
  local safe=$(_zpun_min_age_versions_safe_name "$name")
  print -r -- "$(_zpun_version_lists_dir)/${manager}__${safe}.tsv"
}

# Print cached rows (excluding the header) and return 0 if fresh; else return 1.
_zpun_min_age_versions_cache_get() {
  emulate -L zsh
  setopt local_options
  local manager=$1 name=$2
  local cache=$(_zpun_min_age_versions_cache_path "$manager" "$name")
  [[ -f $cache ]] || return 1

  local -a lines
  lines=( ${(f)"$(<$cache)"} )
  (( ${#lines} >= 1 )) || return 1
  [[ ${lines[1]} == '# fetched_at '* ]] || return 1
  local fetched_at=${lines[1]##* }
  [[ $fetched_at == <-> ]] || return 1

  local ttl=${ZSH_PKG_UPDATE_NAG_MIN_AGE_LIST_TTL:-86400}
  local now=$(date +%s)
  (( now - fetched_at < ttl )) || return 1

  (( ${#lines} >= 2 )) || return 0
  print -rl -- "${lines[2,-1]}"
  return 0
}

# Write header + rows. No-op when no rows (we never cache empty/failed lists).
_zpun_min_age_versions_cache_put() {
  emulate -L zsh
  setopt local_options
  local manager=$1 name=$2
  shift 2
  (( $# )) || return 0
  local cache=$(_zpun_min_age_versions_cache_path "$manager" "$name")
  local dir=${cache:h}
  [[ -d $dir ]] || mkdir -p "$dir" 2>/dev/null
  local now=$(date +%s)
  {
    print -r -- "# fetched_at ${now}"
    local row
    for row in "$@"; do print -r -- "$row"; done
  } > "$cache" 2>/dev/null
  _zpun_min_age_versions_cache_evict
}

# Keep at most 500 cached package files; drop the oldest by mtime.
_zpun_min_age_versions_cache_evict() {
  emulate -L zsh
  setopt local_options
  local dir=$(_zpun_version_lists_dir)
  [[ -d $dir ]] || return 0
  local -a files
  files=( "$dir"/*.tsv(Nom) )   # N: nullglob, om: sort by mtime, newest first
  local cap=500
  (( ${#files} > cap )) || return 0
  local f
  for f in "${files[$((cap+1)),-1]}"; do
    rm -f "$f" 2>/dev/null
  done
}

# _zpun_min_age_resolve_target <manager> <name> <current> <latest>
# Resolve-mode min-age: instead of hiding a too-new latest, find the newest
# stable version that is old enough and in (current, latest].
#   exit 0 + prints <target>  → rewrite the row's latest to <target>
#   exit 1 (no output)        → hide the row (nothing newer qualifies)
#   exit 2 (no output)        → fail-open (caller shows the true latest)
_zpun_min_age_resolve_target() {
  emulate -L zsh
  setopt local_options

  local manager=$1 name=$2 current=$3 latest=$4
  local threshold
  threshold=$(_zpun_min_age_threshold "$manager")
  (( threshold > 0 )) || { print -r -- "$latest"; return 0; }

  # Acquire the version list (cache-first; fetch via the manager hook on miss).
  local -a rows
  rows=( ${(f)"$(_zpun_min_age_versions_cache_get "$manager" "$name")"} )
  if (( ${#rows} == 0 )); then
    local hook="_zpun_min_age_versions_${manager}"
    (( $+functions[$hook] )) || return 2
    rows=( ${(f)"$( $hook "$name" 2>/dev/null )"} )
    (( ${#rows} )) || return 2
    _zpun_min_age_versions_cache_put "$manager" "$name" "${rows[@]}"
  fi

  local now=$(date +%s)
  local threshold_seconds=$(( threshold * 86400 ))
  local line ver epoch vstatus best=""
  for line in "${rows[@]}"; do
    ver=${line%%$'\t'*}
    vstatus=${line##*$'\t'}
    epoch=${${line#*$'\t'}%%$'\t'*}
    [[ $vstatus == stable ]] || continue
    [[ $epoch == <-> ]] || continue
    (( now - epoch >= threshold_seconds )) || continue
    [[ $(_zpun_version_compare "$ver" "$current") == 1 ]] || continue       # ver > current
    [[ $(_zpun_version_compare "$ver" "$latest") != 1 ]] || continue        # ver <= latest
    if [[ -z $best || $(_zpun_version_compare "$ver" "$best") == 1 ]]; then
      best=$ver
    fi
  done

  [[ -n $best ]] || return 1
  print -r -- "$best"
  return 0
}

# _zpun_min_age_emit_versions_from_iso_tsv — read `version\tiso\tstatus` rows on
# stdin, convert each ISO date to epoch seconds, emit `version\tepoch\tstatus`.
# Shared by every resolve-mode versions hook (npm/pnpm via the npm-doc parser,
# uv, gem) so the date-conversion loop lives in exactly one place.
_zpun_min_age_emit_versions_from_iso_tsv() {
  emulate -L zsh
  setopt local_options
  # NOTE: `status` is a read-only special variable in zsh (aliases $?); the
  # per-version state field is read into `vstatus`.
  local ver iso vstatus epoch
  while IFS=$'\t' read -r ver iso vstatus; do
    [[ -n $ver && -n $iso ]] || continue
    epoch=$(_zpun_min_age_parse_iso8601 "$iso") || continue
    [[ -n $epoch && $epoch == <-> ]] || continue
    print -r -- "${ver}"$'\t'"${epoch}"$'\t'"${vstatus}"
  done
}

# _zpun_min_age_emit_versions_from_npm_doc — read an npm/registry JSON doc on
# stdin, emit version\tepoch\tstatus rows. Shared by the npm (CLI) and pnpm
# (curl) versions hooks.
#
# `.versions` shape differs by source: the npm CLI (`npm view <pkg> --json`)
# returns an ARRAY of version strings with no per-version metadata, while the
# registry document (curl https://registry.npmjs.org/<pkg>) returns an OBJECT
# map whose values carry `deprecated`. We handle both: $vset is the set of
# currently-published versions (used to drop unpublished `.time` tombstones),
# and deprecation is only detectable on the object shape — so npm (CLI) excludes
# prereleases and unpublished versions, while pnpm (registry) also excludes
# deprecated ones.
_zpun_min_age_emit_versions_from_npm_doc() {
  emulate -L zsh
  setopt local_options
  (( $+commands[jq] )) || return 1
  local doc
  doc=$(cat)
  [[ -n $doc ]] || return 1
  print -r -- "$doc" | jq -r '
    (.versions // []) as $v
    | (if ($v | type) == "object" then ($v | keys) else $v end) as $vset
    | (.time // {})
    | to_entries[]
    | select(.key != "created" and .key != "modified")
    | .key as $k
    | select($vset | index($k))
    | [$k, .value,
       (if (($v | type) == "object" and ($v[$k].deprecated != null)) then "yanked"
        elif ($k | test("-")) then "prerelease"
        else "stable" end)] | @tsv
  ' 2>/dev/null | _zpun_min_age_emit_versions_from_iso_tsv
}

# _zpun_version_compare <a> <b> — print -1 if a<b, 0 if a==b, 1 if a>b.
# Pure zsh (macOS `sort` has no -V). Splits on '.', compares segments
# numerically (zero-padding the shorter), and falls back to lexical compare
# for non-numeric segments. Intended for stable versions; prereleases are
# excluded before this is called. Exotic PEP 440 forms (epochs, post-
# releases) are best-effort.
_zpun_version_compare() {
  emulate -L zsh
  setopt local_options

  local a=$1 b=$2
  local -a as bs
  as=( ${(s:.:)a} )
  bs=( ${(s:.:)b} )
  local n=$(( ${#as} > ${#bs} ? ${#as} : ${#bs} ))
  local i av bv
  for (( i=1; i <= n; i+=1 )); do
    av=${as[i]:-0}
    bv=${bs[i]:-0}
    if [[ $av == <-> && $bv == <-> ]]; then
      if (( av > bv )); then print -r -- 1; return 0; fi
      if (( av < bv )); then print -r -- -1; return 0; fi
    else
      if [[ $av > $bv ]]; then print -r -- 1; return 0; fi
      if [[ $av < $bv ]]; then print -r -- -1; return 0; fi
    fi
  done
  print -r -- 0
}
