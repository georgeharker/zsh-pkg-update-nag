# Cargo (Rust) outdated-global provider.
#
# Cargo itself has no built-in "list outdated global binaries" command; the
# de-facto tool is `cargo-update` (https://crates.io/crates/cargo-update),
# installed via `cargo install cargo-update`. It exposes `cargo install-update
# --list`, which prints a table of the binaries installed via `cargo install`
# and which ones have newer versions on crates.io.
#
# Min-age is handled natively by cargo-update via `--cooldown <duration>`
# (cargo-update ≥ 20.0.0) — we forward our configured threshold to that flag and
# let the upstream tool do the filtering. No per-package crates.io call from
# us. When cargo-update is too old to know `--cooldown`, we log and proceed
# without filtering so the rest of the scan still surfaces updates.
#
# Without cargo-update installed at all, we log and skip — the upstream
# surface for outdated globals isn't there to parse.

_zpun_provider_cargo() {
  emulate -L zsh
  setopt local_options

  (( $+commands[cargo] )) || return 0

  # `cargo install-update` is a separate cargo subcommand (cargo dispatches
  # `cargo install-update …` to a `cargo-install-update` binary on PATH). A
  # single `--version` call doubles as both an existence check and the
  # source-of-truth for feature detection — `--cooldown` was added in
  # cargo-install-update v20.0.0 (2026-04-06 release), so we just compare
  # the major rather than spawning a second `--help | grep`.
  #
  # Output shape: "cargo-install-update X.Y.Z" → take the trailing word,
  # drop everything from the first dot, and treat anything that isn't a
  # plain integer as "legacy" (major 0).
  local version_line major
  version_line=$(cargo install-update --version 2>/dev/null) || {
    _zpun_debug_log "cargo: cargo-install-update unavailable, skipping"
    return 0
  }
  major=${${version_line##* }%%.*}
  [[ $major == <-> ]] || major=0

  # cargo takes an exclusive flock on $CARGO_HOME/.package-cache for any
  # operation that touches the registry index — and `install-update --list`
  # is such an operation, because it refreshes the index to compute "latest".
  # cargo blocks indefinitely on that lock (it prints "Blocking waiting for
  # file lock on package cache" to stderr), so a concurrent `cargo install`
  # or `cargo install-update -a` in another shell would freeze our scan
  # until it finishes. Probe the lock non-blockingly via zsh/system's flock;
  # if it's held, skip the provider this run.
  #
  # The probe is deliberately best-effort, not race-free: it acquires and
  # immediately releases the lock (subshell scope), so a process can still
  # grab the lock in the window between the probe and the `--list` call
  # below, leaving `--list` to block. We can't close that window by holding
  # the lock across `--list` — cargo's own `--list` would then deadlock
  # waiting on us. The real guarantee is the per-provider `timeout` wrapper
  # in _zpun_collect_outdated, which kills a blocked `--list`; the probe just
  # turns the common contended case into an instant, clean skip instead of a
  # full-timeout stall on the background scan.
  local lock_file="${CARGO_HOME:-$HOME/.cargo}/.package-cache"
  if [[ -f $lock_file ]] && zmodload zsh/system 2>/dev/null; then
    if ! ( zsystem flock -t 0 "$lock_file" ) 2>/dev/null; then
      _zpun_debug_log "cargo: package-cache lock held by another process, skipping"
      return 0
    fi
  fi

  # Resolve the per-manager min-age threshold inline. _zpun_min_age_threshold
  # isn't necessarily available here (the provider runs in a per-manager
  # timeout subshell that only sources config.zsh + this file), so mirror
  # the inheritance rule directly: per-manager override wins over the global,
  # even when it's set to 0.
  local threshold
  if (( ${+zsh_pkg_update_nag_min_age_cargo} )); then
    threshold=${zsh_pkg_update_nag_min_age_cargo:-0}
  else
    threshold=${zsh_pkg_update_nag_min_age:-0}
  fi

  local -a list_cmd
  list_cmd=( cargo install-update --list )
  if (( threshold > 0 )); then
    if (( major >= 20 )); then
      list_cmd+=( --cooldown "${threshold}d" )
    else
      _zpun_debug_log "cargo: cargo-install-update ${version_line##* } lacks --cooldown (need ≥ 20.0.0); min_age not enforced"
    fi
  fi

  local raw
  raw=$("${list_cmd[@]}" 2>/dev/null) || return 0
  [[ -n $raw ]] || return 0

  # Output looks like:
  #   Package        Installed  Latest    Needs update
  #   ripgrep        v13.0.0    v14.1.0   Yes
  #   cargo-update   v12.0.0    v12.0.0   No
  #
  # We only emit rows tagged "Yes". The version columns may or may not have a
  # leading `v` depending on cargo-update version, so strip it. Skip the
  # header line and any progress/log lines by requiring the "Yes" trailer.
  local line name current latest
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if [[ $line =~ '^[[:space:]]*([A-Za-z0-9_.-]+)[[:space:]]+v?([^[:space:]]+)[[:space:]]+v?([^[:space:]]+)[[:space:]]+Yes[[:space:]]*$' ]]; then
      name=${match[1]}
      current=${match[2]}
      latest=${match[3]}
      [[ -n $name && -n $current && -n $latest && $current != "$latest" ]] || continue
      print -r -- "${name}"$'\t'"${current}"$'\t'"${latest}"
    fi
  done <<< "$raw" | _zpun_filter_by_allowlist cargo
}

# No _zpun_min_age_lookup_cargo — cargo-update's --cooldown does the filtering
# at the provider level, so per-row gating in _zpun_min_age_satisfied is a
# no-op (it fails-open when the lookup function is undefined, which is
# exactly what we want once the provider has already filtered).
