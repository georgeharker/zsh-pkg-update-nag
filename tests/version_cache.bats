#!/usr/bin/env bats

load helpers

setup()    { setup_env ; }
teardown() { teardown_env ; }

@test "versions cache: put then get returns rows within TTL" {
  run run_plugin_zsh "
    _zpun_min_age_versions_cache_put uv ruff \$'0.6.4\t1577000000\tstable' \$'0.6.0\t1576000000\tstable'
    _zpun_min_age_versions_cache_get uv ruff
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *$'0.6.4\t1577000000\tstable'* ]]
  [[ "$output" == *$'0.6.0\t1576000000\tstable'* ]]
}

@test "versions cache: get misses when TTL is zero" {
  ZSH_PKG_UPDATE_NAG_MIN_AGE_LIST_TTL=0 run run_plugin_zsh "
    _zpun_min_age_versions_cache_put uv ruff \$'0.6.4\t1577000000\tstable'
    _zpun_min_age_versions_cache_get uv ruff
  "
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "versions cache: safe_name encodes scoped npm names" {
  run run_plugin_zsh "_zpun_min_age_versions_safe_name '@types/node'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"/"* ]]
  [[ "$output" != *"@"* ]]
}

@test "versions cache: scoped name round-trips through put/get" {
  run run_plugin_zsh "
    _zpun_min_age_versions_cache_put npm '@types/node' \$'20.0.0\t1577000000\tstable'
    _zpun_min_age_versions_cache_get npm '@types/node'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *$'20.0.0\t1577000000\tstable'* ]]
}
