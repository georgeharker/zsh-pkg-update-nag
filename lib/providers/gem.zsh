# RubyGems outdated-global provider.
#
# `gem outdated` prints lines of the form:
#   pkgname (current < latest)

_zpun_provider_gem() {
  emulate -L zsh
  setopt local_options

  (( $+commands[gem] )) || return 0

  local raw
  raw=$(gem outdated 2>/dev/null) || return 0

  local line name current latest
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if [[ $line =~ '^([A-Za-z0-9_.-]+)[[:space:]]+\(([^<]+)<[[:space:]]*([^)]+)\)' ]]; then
      name=${match[1]}
      current=${match[2]// /}
      latest=${match[3]// /}
      print -r -- "${name}"$'\t'"${current}"$'\t'"${latest}"
    fi
  done <<< "$raw" | _zpun_filter_by_allowlist gem
}
