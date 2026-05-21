# Cargo (Rust) outdated-global provider.
#
# Cargo itself has no built-in "list outdated global binaries" command; the
# de-facto tool is `cargo-update` (https://crates.io/crates/cargo-update),
# installed via `cargo install cargo-update`. It exposes `cargo install-update
# --list`, which prints a table of the binaries installed via `cargo install`
# and which ones have newer versions on crates.io.
#
# Without cargo-update installed we log and skip — the upstream surface for
# outdated globals isn't there to parse.

_zpun_provider_cargo() {
  emulate -L zsh
  setopt local_options

  (( $+commands[cargo] )) || return 0

  # `cargo install-update` is a separate cargo subcommand. cargo dispatches
  # `cargo install-update …` to a `cargo-install-update` binary on PATH; if
  # it isn't installed, the command exits non-zero with "no such subcommand".
  if ! cargo install-update --version >/dev/null 2>&1; then
    _zpun_debug_log "cargo: cargo-install-update unavailable, skipping"
    return 0
  fi

  local raw
  raw=$(cargo install-update --list 2>/dev/null) || return 0
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

# _zpun_min_age_lookup_cargo <name> <version> — crates.io JSON API.
# crates.io requires a User-Agent header; without one the API returns 403.
_zpun_min_age_lookup_cargo() {
  emulate -L zsh
  setopt local_options

  local name=$1 version=$2
  (( $+commands[curl] && $+commands[jq] )) || return 1

  local json
  json=$(curl -fsSL --max-time 5 \
    -A "zsh-pkg-update-nag (https://github.com/madisonrickert/zsh-pkg-update-nag)" \
    "https://crates.io/api/v1/crates/${name}/${version}" 2>/dev/null) || return 1
  [[ -n $json ]] || return 1

  local iso
  iso=$(print -r -- "$json" | jq -r '.version.created_at // empty' 2>/dev/null)
  [[ -n $iso && $iso != null ]] || return 1
  _zpun_min_age_parse_iso8601 "$iso"
}
