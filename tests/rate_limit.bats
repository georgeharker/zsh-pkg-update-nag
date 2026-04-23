#!/usr/bin/env bats

load helpers

setup()    { setup_env ; }
teardown() { teardown_env ; }

@test "first run initializes stampfile and exits silently" {
  run run_plugin_zsh "_zpun_rate_limit_init_if_missing && echo INIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INIT"* ]]
  [ -e "$XDG_STATE_HOME/zsh-pkg-update-nag/last_check" ]
}

@test "second run does not reinitialize" {
  run_plugin_zsh "_zpun_rate_limit_init_if_missing"
  run run_plugin_zsh "_zpun_rate_limit_init_if_missing || echo EXISTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXISTS"* ]]
}

@test "rate-limit blocks within interval" {
  run_plugin_zsh "_zpun_rate_limit_init_if_missing"
  # Fresh stamp means not due yet.
  run run_plugin_zsh "_zpun_rate_limit_is_due && echo DUE || echo NOT_DUE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT_DUE"* ]]
}

@test "FORCE overrides rate-limit" {
  run_plugin_zsh "_zpun_rate_limit_init_if_missing"
  ZSH_PKG_UPDATE_NAG_FORCE=1 run run_plugin_zsh "_zpun_rate_limit_is_due && echo DUE || echo NOT_DUE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DUE"* ]]
}

@test "stamp refresh updates mtime" {
  run_plugin_zsh "_zpun_rate_limit_init_if_missing"
  local stamp="$XDG_STATE_HOME/zsh-pkg-update-nag/last_check"
  # Backdate the stamp to force a gap, then refresh.
  touch -t 202001010000 "$stamp"
  local before=$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp")
  run_plugin_zsh "_zpun_rate_limit_stamp"
  local after=$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp")
  [ "$after" -gt "$before" ]
}

@test "lock prevents concurrent runs" {
  run_plugin_zsh "_zpun_rate_limit_acquire_lock && echo ONE"
  run run_plugin_zsh "_zpun_rate_limit_acquire_lock && echo TWO || echo LOCKED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOCKED"* ]]
  run_plugin_zsh "_zpun_rate_limit_release_lock"
  run run_plugin_zsh "_zpun_rate_limit_acquire_lock && echo FREE"
  [[ "$output" == *"FREE"* ]]
}
