# Homebrew outdated-package provider.

_zpun_provider_brew() {
  emulate -L zsh
  setopt local_options

  (( $+commands[brew] )) || return 0

  local raw
  if (( $+commands[jq] )); then
    raw=$(brew outdated --json=v2 --formula 2>/dev/null) || return 0
    local parsed
    parsed=$(print -r -- "$raw" | jq -r '
      .formulae[]? |
      [.name, (.installed_versions[0] // "?"), .current_version] |
      @tsv
    ' 2>/dev/null) || return 0
    print -r -- "$parsed" | _zpun_filter_by_allowlist brew
  else
    # No jq: degrade to names-only, version fields become "?".
    local name
    raw=$(brew outdated --quiet --formula 2>/dev/null) || return 0
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      print -r -- "${name}"$'\t?\t?'
    done <<< "$raw" | _zpun_filter_by_allowlist brew
    return
  fi
}
