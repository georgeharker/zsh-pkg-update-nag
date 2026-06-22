#!/usr/bin/env bats

load helpers

setup()    { setup_env ; }
teardown() { teardown_env ; }

@test "version_compare: equal versions" {
  run run_plugin_zsh "_zpun_version_compare 1.2.3 1.2.3"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "version_compare: greater major" {
  run run_plugin_zsh "_zpun_version_compare 2.0.0 1.9.9"
  [ "$output" = "1" ]
}

@test "version_compare: lesser patch" {
  run run_plugin_zsh "_zpun_version_compare 1.0.0 1.0.1"
  [ "$output" = "-1" ]
}

@test "version_compare: numeric not lexical (1.10 > 1.9)" {
  run run_plugin_zsh "_zpun_version_compare 1.10.0 1.9.0"
  [ "$output" = "1" ]
}

@test "version_compare: differing segment counts pad with zero" {
  run run_plugin_zsh "_zpun_version_compare 1.2 1.2.0"
  [ "$output" = "0" ]
  run run_plugin_zsh "_zpun_version_compare 1.2 1.2.1"
  [ "$output" = "-1" ]
}

@test "version_compare: held-back vs latest (14.0.0 < 14.1.0)" {
  run run_plugin_zsh "_zpun_version_compare 14.0.0 14.1.0"
  [ "$output" = "-1" ]
}
