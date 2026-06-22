#!/usr/bin/env bats

load helpers

setup()    { setup_env ; }
teardown() { teardown_env ; }

# Helper: define a fake versions hook inline. Epoch 1000000000 (~2001) is
# always "old enough"; epoch 9999999999 (~2286) is always "too new".
FAKE='
_zpun_min_age_versions_demo() {
  print -r -- $'\''14.1.0\t9999999999\tstable'\''
  print -r -- $'\''14.0.0\t1000000000\tstable'\''
  print -r -- $'\''13.5.0\t1000000000\tstable'\''
  print -r -- $'\''13.0.0\t1000000000\tstable'\''
}
'

@test "resolve_target: picks newest old-enough below too-new latest" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_demo=7
    $FAKE
    _zpun_min_age_resolve_target demo pkg 13.0.0 14.1.0
  "
  [ "$status" -eq 0 ]
  [ "$output" = "14.0.0" ]
}

@test "resolve_target: excludes prereleases" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_demo=7
    _zpun_min_age_versions_demo() {
      print -r -- \$'14.0.0\t1000000000\tprerelease'
      print -r -- \$'13.5.0\t1000000000\tstable'
    }
    _zpun_min_age_resolve_target demo pkg 13.0.0 14.0.0
  "
  [ "$status" -eq 0 ]
  [ "$output" = "13.5.0" ]
}

@test "resolve_target: excludes yanked" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_demo=7
    _zpun_min_age_versions_demo() {
      print -r -- \$'14.0.0\t1000000000\tyanked'
      print -r -- \$'13.5.0\t1000000000\tstable'
    }
    _zpun_min_age_resolve_target demo pkg 13.0.0 14.0.0
  "
  [ "$status" -eq 0 ]
  [ "$output" = "13.5.0" ]
}

@test "resolve_target: hides (exit 1) when nothing newer qualifies" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_demo=7
    _zpun_min_age_versions_demo() {
      print -r -- \$'14.1.0\t9999999999\tstable'
      print -r -- \$'13.0.0\t1000000000\tstable'
    }
    _zpun_min_age_resolve_target demo pkg 13.0.0 14.1.0
  "
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "resolve_target: fail-open (exit 2) when no versions hook" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_nohook=7
    _zpun_min_age_resolve_target nohook pkg 1.0.0 2.0.0
  "
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "resolve_target: fail-open (exit 2) when hook returns nothing" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_demo=7
    _zpun_min_age_versions_demo() { return 1 }
    _zpun_min_age_resolve_target demo pkg 1.0.0 2.0.0
  "
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "resolve_target: ignores versions above latest" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_demo=7
    _zpun_min_age_versions_demo() {
      print -r -- \$'15.0.0\t1000000000\tstable'
      print -r -- \$'14.0.0\t1000000000\tstable'
    }
    _zpun_min_age_resolve_target demo pkg 13.0.0 14.0.0
  "
  [ "$status" -eq 0 ]
  [ "$output" = "14.0.0" ]
}

@test "resolve_target: threshold 0 returns latest unchanged" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_demo=0
    _zpun_min_age_resolve_target demo pkg 13.0.0 14.1.0
  "
  [ "$status" -eq 0 ]
  [ "$output" = "14.1.0" ]
}
