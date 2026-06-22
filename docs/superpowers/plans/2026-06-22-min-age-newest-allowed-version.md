# min-age resolves to newest allowed version — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an outdated package's latest version is too new under `min_age`, offer the newest stable version that *is* old enough (instead of hiding the row) for npm/pnpm/uv/gem; brew keeps its existing hide-if-too-new gate.

**Architecture:** Add a per-manager `_zpun_min_age_versions_<m>` hook returning the full `(version, epoch, status)` list, a shared `_zpun_min_age_resolve_target` selector backed by a portable `_zpun_version_compare` and a TTL'd per-package list cache, and capability-based dispatch in `_zpun_collect_outdated` (resolve when a versions hook exists, else the existing gate). Upgrades pin the resolved version.

**Tech Stack:** zsh (explicit, portable; `emulate -L zsh; setopt local_options` per function), `jq`, `curl`, `npm`/`uv`/`gem` CLIs, `bats` tests with shim fixtures under `tests/fixtures/`.

## Global Constraints

- Explicit, portable zsh. No bashisms. Every function opens with `emulate -L zsh; setopt local_options`. (CLAUDE.md §2)
- Never name a local `path` (zsh ties it to `$PATH`). Use `pkg_path`, `state_path`, etc. (CLAUDE.md known pitfalls)
- Declare loop-locals once before the loop (or `local foo=`) to avoid the re-declare-prints-previous-value pitfall. (CLAUDE.md known pitfalls)
- Nothing new on the shell-startup critical path: `lib/min_age.zsh` and `lib/providers/*.zsh` stay lazily sourced. All new work runs in the deferred background scan. (CLAUDE.md §1)
- No `sort -V` (absent on macOS `sort`). Version comparison is pure zsh.
- Fail-open: a degraded environment must never silently hide updates. Could-not-determine → show the provider's true latest.
- New behavior is npm/pnpm/uv/gem only. brew and cargo are untouched.
- Tests are mandatory for new behavior; match existing `tests/*.bats` style and the shim-fixture conventions in `tests/fixtures/`.
- README documents the cost of the new feature and the new env var. No em dashes in README prose (public-facing); en dashes for ranges are fine.
- Spec: `docs/superpowers/specs/2026-06-22-min-age-newest-allowed-version-design.md`.

---

### Task 1: Portable version comparator `_zpun_version_compare`

**Files:**
- Modify: `lib/min_age.zsh` (append a new function)
- Test: `tests/version_compare.bats` (create)

**Interfaces:**
- Produces: `_zpun_version_compare <a> <b>` → prints `-1` if a<b, `0` if a==b, `1` if a>b. Dot-separated segments compared numerically (zero-padded); non-numeric segments compared lexically.

- [ ] **Step 1: Write the failing test**

Create `tests/version_compare.bats`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/version_compare.bats`
Expected: FAIL — `_zpun_version_compare: command not found` / non-zero.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/min_age.zsh`:

```zsh
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/version_compare.bats`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
cd /tmp/zpun-min-age-downgrade-wt
git add lib/min_age.zsh tests/version_compare.bats
git commit -m "feat(min-age): add portable _zpun_version_compare"
```

---

### Task 2: Per-package version-list cache (TTL + eviction)

**Files:**
- Modify: `lib/min_age.zsh` (append cache helpers)
- Test: `tests/version_cache.bats` (create)

**Interfaces:**
- Consumes: `_zpun_state_dir` (existing, `lib/config.zsh`).
- Produces:
  - `_zpun_version_lists_dir` → prints `$(_zpun_state_dir)/version_lists`.
  - `_zpun_min_age_versions_safe_name <name>` → filesystem-safe encoding of a package name.
  - `_zpun_min_age_versions_cache_path <manager> <name>` → cache file path.
  - `_zpun_min_age_versions_cache_get <manager> <name>` → prints the cached `version\tepoch\tstatus` rows (no header) and returns 0 when present and within TTL; returns 1 otherwise.
  - `_zpun_min_age_versions_cache_put <manager> <name> <row>...` → writes `# fetched_at <epoch>` + rows; evicts oldest beyond 500 files. No-op if no rows.
  - TTL env: `ZSH_PKG_UPDATE_NAG_MIN_AGE_LIST_TTL` (seconds, default 86400).

- [ ] **Step 1: Write the failing test**

Create `tests/version_cache.bats`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/version_cache.bats`
Expected: FAIL — cache functions not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/min_age.zsh`:

```zsh
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/version_cache.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd /tmp/zpun-min-age-downgrade-wt
git add lib/min_age.zsh tests/version_cache.bats
git commit -m "feat(min-age): add TTL'd per-package version-list cache"
```

---

### Task 3: Shared selector `_zpun_min_age_resolve_target`

**Files:**
- Modify: `lib/min_age.zsh` (append selector)
- Test: `tests/resolve_target.bats` (create)

**Interfaces:**
- Consumes: `_zpun_min_age_threshold` (existing), `_zpun_version_compare` (Task 1), `_zpun_min_age_versions_cache_get`/`_put` (Task 2), and a per-manager `_zpun_min_age_versions_<m> <name>` hook (Tasks 4–7; in tests, injected).
- Produces: `_zpun_min_age_resolve_target <manager> <name> <current> <latest>`:
  - exit 0 + prints `<target>` → caller rewrites the row's latest to `<target>`.
  - exit 1 + no output → caller hides the row (no qualifying upgrade).
  - exit 2 + no output → caller fail-opens (shows the provider's true latest).
  - When the threshold is 0 it prints `<latest>` and returns 0 (no gating).

- [ ] **Step 1: Write the failing test**

Create `tests/resolve_target.bats`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/resolve_target.bats`
Expected: FAIL — `_zpun_min_age_resolve_target` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/min_age.zsh`:

```zsh
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
  local line ver epoch status best=""
  for line in "${rows[@]}"; do
    ver=${line%%$'\t'*}
    status=${line##*$'\t'}
    epoch=${${line#*$'\t'}%%$'\t'*}
    [[ $status == stable ]] || continue
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/resolve_target.bats`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
cd /tmp/zpun-min-age-downgrade-wt
git add lib/min_age.zsh tests/resolve_target.bats
git commit -m "feat(min-age): add resolve-mode target selector"
```

---

### Task 4: npm versions hook + shared npm-doc parser

**Files:**
- Modify: `lib/min_age.zsh` (append shared npm-doc parser)
- Modify: `lib/providers/npm.zsh` (append `_zpun_min_age_versions_npm`)
- Modify: `tests/fixtures/npm` (handle `npm view <name> --json`)
- Modify: `tests/helpers.bash` (pass `ZPUN_FIXTURE_NPM_VERSIONS`)
- Test: `tests/providers.bats` (append)

**Interfaces:**
- Consumes: `_zpun_min_age_parse_iso8601` (existing).
- Produces:
  - `_zpun_min_age_emit_versions_from_npm_doc` — reads an npm/registry JSON document on stdin, emits `version\tepoch\tstatus` rows. Status: `yanked` if `.versions[v].deprecated` is set, else `prerelease` if the version contains `-`, else `stable`.
  - `_zpun_min_age_versions_npm <name>` — `npm view <name> --json` piped through the shared parser.

- [ ] **Step 1: Write the failing test**

Append to `tests/providers.bats`:

```bash
@test "npm versions hook classifies stable/prerelease/yanked" {
  run run_plugin_zsh "_zpun_min_age_versions_npm typescript"
  [ "$status" -eq 0 ]
  # stable release
  [[ "$output" == *$'5.4.5\t'*$'\tstable'* ]]
  # prerelease (semver -)
  [[ "$output" == *$'5.5.0-rc.1\t'*$'\tprerelease'* ]]
  # deprecated → yanked
  [[ "$output" == *$'5.4.0\t'*$'\tyanked'* ]]
  # header keys must not leak as versions
  [[ "$output" != *"created"* ]]
  [[ "$output" != *"modified"* ]]
}

@test "npm versions hook returns non-zero on fetch failure" {
  ZPUN_FIXTURE_NPM_VERSIONS=fail run run_plugin_zsh "_zpun_min_age_versions_npm typescript"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/providers.bats -f "npm versions hook"`
Expected: FAIL — hook not defined.

- [ ] **Step 3: Write minimal implementation**

3a. Append the shared parser to `lib/min_age.zsh`:

```zsh
# _zpun_min_age_emit_versions_from_npm_doc — read an npm/registry JSON doc on
# stdin, emit version\tepoch\tstatus rows. Shared by the npm (CLI) and pnpm
# (curl) versions hooks: both registries use the same packument shape.
_zpun_min_age_emit_versions_from_npm_doc() {
  emulate -L zsh
  setopt local_options
  (( $+commands[jq] )) || return 1
  local doc
  doc=$(cat)
  [[ -n $doc ]] || return 1
  local ver iso status epoch
  while IFS=$'\t' read -r ver iso status; do
    [[ -n $ver && -n $iso ]] || continue
    epoch=$(_zpun_min_age_parse_iso8601 "$iso") || continue
    [[ -n $epoch && $epoch == <-> ]] || continue
    print -r -- "${ver}"$'\t'"${epoch}"$'\t'"${status}"
  done < <(print -r -- "$doc" | jq -r '
    (.versions // {}) as $v
    | (.time // {})
    | to_entries[]
    | select(.key != "created" and .key != "modified")
    | .key as $k
    | [$k, .value,
       (if ($v[$k].deprecated != null) then "yanked"
        elif ($k | test("-")) then "prerelease"
        else "stable" end)] | @tsv
  ' 2>/dev/null)
}
```

3b. Append the hook to `lib/providers/npm.zsh`:

```zsh
# _zpun_min_age_versions_npm <name> — full version history via the npm CLI
# (`npm view <name> --json` returns the packument: a .time map plus per-version
# .versions objects carrying `deprecated`). Resolve-mode (see lib/min_age.zsh).
_zpun_min_age_versions_npm() {
  emulate -L zsh
  setopt local_options

  local name=$1
  (( $+commands[npm] && $+commands[jq] )) || return 1
  local doc
  doc=$(npm view "$name" --json 2>/dev/null) || return 1
  [[ -n $doc ]] || return 1
  print -r -- "$doc" | _zpun_min_age_emit_versions_from_npm_doc
}
```

3c. Extend `tests/fixtures/npm`. Inside the `"view "*` case, BEFORE the existing
`ZPUN_FIXTURE_NPM_AGE` block, add a branch for the full-doc call (`$3 == --json`):

```sh
  "view "*)
    # `npm view <pkg> --json` — full packument for the versions hook.
    if [ "$3" = "--json" ]; then
      case "${ZPUN_FIXTURE_NPM_VERSIONS:-default}" in
        fail) exit 1 ;;
        *)
          now=$(date -u +'%Y-%m-%dT%H:%M:%S.000Z')
          old='2020-01-15T12:34:56.000Z'
          # When NPM_AGE=fresh, make every prior version "now" too, so resolve
          # mode finds no old-enough candidate and hides the row (this mirrors
          # the gate-era "fresh updates are dropped" integration test).
          [ "${ZPUN_FIXTURE_NPM_AGE:-}" = "fresh" ] && old="$now"
          printf '{"time":{'
          printf '"created":"2012-10-01T15:35:39.553Z",'
          printf '"modified":"%s",' "$now"
          printf '"5.5.0":"%s",' "$now"
          printf '"5.5.0-rc.1":"%s",' "$old"
          printf '"5.4.5":"%s",' "$old"
          printf '"5.4.0":"%s",' "$old"
          printf '"9.5.1":"%s",' "$now"
          printf '"9.0.0":"%s"' "$old"
          printf '},"versions":{'
          printf '"5.5.0":{},'
          printf '"5.5.0-rc.1":{},'
          printf '"5.4.5":{},'
          printf '"5.4.0":{"deprecated":"use 5.4.5"},'
          printf '"9.5.1":{},'
          printf '"9.0.0":{}'
          printf '}}\n'
          exit 0
          ;;
      esac
    fi
    # ...existing `npm view <pkg> time --json` handling continues below...
```

3d. Add `ZPUN_FIXTURE_NPM_VERSIONS` passthrough in `tests/helpers.bash` `run_plugin_zsh`, next to the existing `ZPUN_FIXTURE_NPM_AGE` line:

```bash
    ZPUN_FIXTURE_NPM_VERSIONS="${ZPUN_FIXTURE_NPM_VERSIONS:-}" \
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/providers.bats -f "npm versions hook"`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd /tmp/zpun-min-age-downgrade-wt
git add lib/min_age.zsh lib/providers/npm.zsh tests/fixtures/npm tests/helpers.bash tests/providers.bats
git commit -m "feat(min-age): add npm versions hook + shared npm-doc parser"
```

---

### Task 5: pnpm versions hook

**Files:**
- Modify: `lib/providers/pnpm.zsh` (append `_zpun_min_age_versions_pnpm`)
- Modify: `tests/fixtures/curl` (enrich the `registry.npmjs.org` response with `.versions` + a deprecated entry + a prerelease)
- Test: `tests/providers.bats` (append)

**Interfaces:**
- Consumes: `_zpun_min_age_emit_versions_from_npm_doc` (Task 4).
- Produces: `_zpun_min_age_versions_pnpm <name>` — `curl https://registry.npmjs.org/<name>` piped through the shared npm-doc parser.

- [ ] **Step 1: Write the failing test**

Append to `tests/providers.bats`:

```bash
@test "pnpm versions hook classifies stable/prerelease/yanked from registry" {
  run run_plugin_zsh "_zpun_min_age_versions_pnpm rollup"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'5.1.0\t'*$'\tstable'* ]]
  [[ "$output" == *$'5.2.0-rc.1\t'*$'\tprerelease'* ]]
  [[ "$output" == *$'4.0.0\t'*$'\tyanked'* ]]
}

@test "pnpm versions hook returns non-zero on curl failure" {
  ZPUN_FIXTURE_CURL=fail run run_plugin_zsh "_zpun_min_age_versions_pnpm rollup"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/providers.bats -f "pnpm versions hook"`
Expected: FAIL — hook not defined / fixture lacks `.versions`.

- [ ] **Step 3: Write minimal implementation**

3a. Append the hook to `lib/providers/pnpm.zsh`:

```zsh
# _zpun_min_age_versions_pnpm <name> — full version history from the npm
# registry (pnpm resolves from the same registry). Same packument shape as
# npm, so we reuse the shared parser. Resolve-mode (see lib/min_age.zsh).
_zpun_min_age_versions_pnpm() {
  emulate -L zsh
  setopt local_options

  local name=$1
  (( $+commands[curl] && $+commands[jq] )) || return 1
  local json
  json=$(curl -fsSL --max-time 5 "https://registry.npmjs.org/${name}" 2>/dev/null) || return 1
  [[ -n $json ]] || return 1
  print -r -- "$json" | _zpun_min_age_emit_versions_from_npm_doc
}
```

3b. In `tests/fixtures/curl`, replace the `*registry.npmjs.org/*` non-missing
branch body so it includes `.versions` (with a deprecated entry) and a
prerelease in `.time`:

```sh
  *registry.npmjs.org/*)
    if [ "$mode" = "missing" ]; then
      printf '{"time":{"created":"%sZ","modified":"%sZ"}}\n' "$ts" "$ts"
    else
      printf '{"time":{'
      printf '"created":"%sZ",' "$ts"
      printf '"modified":"%sZ",' "$ts"
      printf '"4.0.0":"%sZ",' "$ts"
      printf '"4.31.0":"%sZ",' "$ts"
      printf '"5.1.0":"%sZ",'  "$ts"
      printf '"5.2.0-rc.1":"%sZ",' "$ts"
      printf '"1.0.0":"%sZ"'   "$ts"
      printf '},"versions":{'
      printf '"4.0.0":{"deprecated":"old"},'
      printf '"4.31.0":{},'
      printf '"5.1.0":{},'
      printf '"5.2.0-rc.1":{},'
      printf '"1.0.0":{}'
      printf '}}\n'
    fi
    ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/providers.bats -f "pnpm versions hook"`
Expected: PASS (2 tests). Also confirm no regression: `bats tests/providers.bats -f "pnpm"`.

- [ ] **Step 5: Commit**

```bash
cd /tmp/zpun-min-age-downgrade-wt
git add lib/providers/pnpm.zsh tests/fixtures/curl tests/providers.bats
git commit -m "feat(min-age): add pnpm versions hook"
```

---

### Task 6: uv versions hook

**Files:**
- Modify: `lib/providers/uv.zsh` (append `_zpun_min_age_versions_uv`)
- Modify: `tests/fixtures/curl` (enrich the PyPI response with prerelease + yanked releases)
- Test: `tests/providers.bats` (append)

**Interfaces:**
- Consumes: `_zpun_min_age_parse_iso8601` (existing).
- Produces: `_zpun_min_age_versions_uv <name>` — `curl https://pypi.org/pypi/<name>/json`, parsed to `version\tepoch\tstatus`. Status: `yanked` if `.releases[v][0].yanked == true`, else `prerelease` by PEP 440 marker heuristic, else `stable`.

- [ ] **Step 1: Write the failing test**

Append to `tests/providers.bats`:

```bash
@test "uv versions hook classifies stable/prerelease/yanked from pypi" {
  run run_plugin_zsh "_zpun_min_age_versions_uv ruff"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'0.6.4\t'*$'\tstable'* ]]
  [[ "$output" == *$'0.7.0a1\t'*$'\tprerelease'* ]]
  [[ "$output" == *$'0.5.0\t'*$'\tyanked'* ]]
}

@test "uv versions hook returns non-zero on curl failure" {
  ZPUN_FIXTURE_CURL=fail run run_plugin_zsh "_zpun_min_age_versions_uv ruff"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/providers.bats -f "uv versions hook"`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

3a. Append the hook to `lib/providers/uv.zsh`:

```zsh
# _zpun_min_age_versions_uv <name> — full version history from PyPI's JSON API.
# Status: yanked from the release's `yanked` flag; prerelease via a PEP 440
# marker heuristic (a/b/rc/alpha/beta/dev/pre suffix); else stable.
# Resolve-mode (see lib/min_age.zsh).
_zpun_min_age_versions_uv() {
  emulate -L zsh
  setopt local_options

  local name=$1
  (( $+commands[curl] && $+commands[jq] )) || return 1
  local json
  json=$(curl -fsSL --max-time 5 "https://pypi.org/pypi/${name}/json" 2>/dev/null) || return 1
  [[ -n $json ]] || return 1

  local ver iso status epoch
  while IFS=$'\t' read -r ver iso status; do
    [[ -n $ver && -n $iso ]] || continue
    epoch=$(_zpun_min_age_parse_iso8601 "$iso") || continue
    [[ -n $epoch && $epoch == <-> ]] || continue
    print -r -- "${ver}"$'\t'"${epoch}"$'\t'"${status}"
  done < <(print -r -- "$json" | jq -r '
    .releases // {}
    | to_entries[]
    | select((.value | length) > 0)
    | .key as $k
    | (.value[0].upload_time // .value[0].upload_time_iso_8601 // empty) as $t
    | select($t != null)
    | [$k, $t,
       (if (.value[0].yanked == true) then "yanked"
        elif ($k | test("(?i)(a|b|rc|alpha|beta|dev|pre)[0-9]*$")) then "prerelease"
        else "stable" end)] | @tsv
  ' 2>/dev/null)
}
```

3b. In `tests/fixtures/curl`, replace the `*pypi.org/pypi/*/json` non-missing
branch body to add a prerelease and a yanked release:

```sh
  *pypi.org/pypi/*/json)
    if [ "$mode" = "missing" ]; then
      printf '{"releases":{"0.0.0":[{"upload_time":"%s"}]}}\n' "$ts"
    else
      printf '{"releases":{'
      printf '"0.6.0":[{"upload_time":"%s","yanked":false}],' "$ts"
      printf '"0.6.4":[{"upload_time":"%s","yanked":false}],' "$ts"
      printf '"0.7.0a1":[{"upload_time":"%s","yanked":false}],' "$ts"
      printf '"0.5.0":[{"upload_time":"%s","yanked":true}],' "$ts"
      printf '"1.0.0":[{"upload_time":"%s"}]'  "$ts"
      printf '}}\n'
    fi
    ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/providers.bats -f "uv versions hook"`
Expected: PASS (2 tests). Confirm no regression: `bats tests/providers.bats -f "uv"`.

- [ ] **Step 5: Commit**

```bash
cd /tmp/zpun-min-age-downgrade-wt
git add lib/providers/uv.zsh tests/fixtures/curl tests/providers.bats
git commit -m "feat(min-age): add uv versions hook"
```

---

### Task 7: gem versions hook

**Files:**
- Modify: `lib/providers/gem.zsh` (append `_zpun_min_age_versions_gem`)
- Modify: `tests/fixtures/curl` (add a `prerelease` flag + a prerelease entry to the RubyGems response)
- Test: `tests/providers.bats` (append)

**Interfaces:**
- Consumes: `_zpun_min_age_parse_iso8601` (existing).
- Produces: `_zpun_min_age_versions_gem <name>` — `curl https://rubygems.org/api/v1/versions/<name>.json`, parsed to `version\tepoch\tstatus`. Status: `prerelease` from the `prerelease` flag, else `stable` (RubyGems omits yanked versions).

- [ ] **Step 1: Write the failing test**

Append to `tests/providers.bats`:

```bash
@test "gem versions hook classifies stable/prerelease from rubygems" {
  run run_plugin_zsh "_zpun_min_age_versions_gem rails"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'7.2.0\t'*$'\tstable'* ]]
  [[ "$output" == *$'7.3.0.beta1\t'*$'\tprerelease'* ]]
}

@test "gem versions hook returns non-zero on curl failure" {
  ZPUN_FIXTURE_CURL=fail run run_plugin_zsh "_zpun_min_age_versions_gem rails"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/providers.bats -f "gem versions hook"`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

3a. Append the hook to `lib/providers/gem.zsh`:

```zsh
# _zpun_min_age_versions_gem <name> — full version history from RubyGems.
# `versions.json` carries a `prerelease` boolean per version; yanked versions
# are omitted by the API. Resolve-mode (see lib/min_age.zsh).
_zpun_min_age_versions_gem() {
  emulate -L zsh
  setopt local_options

  local name=$1
  (( $+commands[curl] && $+commands[jq] )) || return 1
  local json
  json=$(curl -fsSL --max-time 5 "https://rubygems.org/api/v1/versions/${name}.json" 2>/dev/null) || return 1
  [[ -n $json ]] || return 1

  local ver iso status epoch
  while IFS=$'\t' read -r ver iso status; do
    [[ -n $ver && -n $iso ]] || continue
    epoch=$(_zpun_min_age_parse_iso8601 "$iso") || continue
    [[ -n $epoch && $epoch == <-> ]] || continue
    print -r -- "${ver}"$'\t'"${epoch}"$'\t'"${status}"
  done < <(print -r -- "$json" | jq -r '
    .[]
    | [.number, .created_at,
       (if (.prerelease == true) then "prerelease" else "stable" end)] | @tsv
  ' 2>/dev/null)
}
```

3b. In `tests/fixtures/curl`, replace the `*rubygems.org/api/v1/versions/*.json`
non-missing branch body to add the `prerelease` flag and a prerelease entry:

```sh
  *rubygems.org/api/v1/versions/*.json)
    if [ "$mode" = "missing" ]; then
      printf '[{"number":"0.0.0","created_at":"%s","prerelease":false}]\n' "$ts"
    else
      printf '['
      printf '{"number":"7.2.0","created_at":"%s","prerelease":false},' "$ts"
      printf '{"number":"3.13.0","created_at":"%s","prerelease":false},' "$ts"
      printf '{"number":"7.3.0.beta1","created_at":"%s","prerelease":true},' "$ts"
      printf '{"number":"1.0.0","created_at":"%s","prerelease":false}'   "$ts"
      printf ']\n'
    fi
    ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/providers.bats -f "gem versions hook"`
Expected: PASS (2 tests). Confirm no regression: `bats tests/providers.bats`.

- [ ] **Step 5: Commit**

```bash
cd /tmp/zpun-min-age-downgrade-wt
git add lib/providers/gem.zsh tests/fixtures/curl tests/providers.bats
git commit -m "feat(min-age): add gem versions hook"
```

---

### Task 8: Collector dispatch (resolve mode vs gate mode)

**Files:**
- Modify: `zsh-pkg-update-nag.plugin.zsh` (`_zpun_collect_outdated`, the per-row min-age block)
- Test: `tests/integration.bats` (append)

**Interfaces:**
- Consumes: `_zpun_min_age_resolve_target` (Task 3), the per-manager versions hooks (Tasks 4–7), existing `_zpun_min_age_satisfied`.
- Produces: rows where resolve-mode managers have their `latest` field rewritten to the resolved target (or dropped); gate-mode managers (brew) behave exactly as before.

- [ ] **Step 1: Write the failing test**

Append to `tests/integration.bats`:

```bash
@test "collect resolve-mode rewrites npm row to held-back target" {
  # npm --json fixture: typescript 5.5.0 is "now" (too new), 5.4.5 is 2020
  # (old enough), current is 5.4.0. With a large npm threshold the row should
  # be rewritten to the held-back 5.4.5 rather than hidden.
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_npm=999
    _zpun_collect_outdated
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *$'npm\ttypescript\t5.4.0\t5.4.5'* ]]
  # pnpm 9.5.1 is the only version above current 9.0.0 and it's too new → hidden.
  local re=$'(^|\n)npm\tpnpm\t'
  [[ ! "$output" =~ $re ]]
}

@test "collect gate-mode (brew) is unaffected by npm resolve threshold" {
  run run_plugin_zsh "
    zsh_pkg_update_nag_min_age_npm=999
    _zpun_collect_outdated
  "
  [ "$status" -eq 0 ]
  # brew has no min_age set → its rows pass through unchanged (gate mode).
  [[ "$output" == *$'brew\tgh\t2.60.0\t2.62.0'* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/integration.bats -f "resolve-mode"`
Expected: FAIL — rows still hidden (old gate path) rather than rewritten.

- [ ] **Step 3: Write minimal implementation**

In `zsh-pkg-update-nag.plugin.zsh`, inside `_zpun_collect_outdated`, the current
per-row block reads:

```zsh
      for line in "${outdated_rows[@]}"; do
        pkg_name=${line%%$'\t'*}
        pkg_latest=${line##*$'\t'}
        if (( _have_min_age )); then
          _zpun_min_age_satisfied "$manager" "$pkg_name" "$pkg_latest" || continue
        fi
        print -r -- "${manager}"$'\t'"${line}"
      done
```

Replace it with (adds `pkg_current` extraction and resolve/gate dispatch):

```zsh
      local pkg_current pkg_rest target rc
      for line in "${outdated_rows[@]}"; do
        pkg_name=${line%%$'\t'*}
        pkg_latest=${line##*$'\t'}
        pkg_rest=${line#*$'\t'}
        pkg_current=${pkg_rest%%$'\t'*}
        if (( _have_min_age )); then
          if (( $+functions[_zpun_min_age_versions_${manager}] )); then
            # Resolve mode: rewrite latest to the newest old-enough version,
            # hide when nothing qualifies, fail-open on lookup failure.
            target=$(_zpun_min_age_resolve_target "$manager" "$pkg_name" "$pkg_current" "$pkg_latest")
            rc=$?
            case $rc in
              0) line="${pkg_name}"$'\t'"${pkg_current}"$'\t'"${target}" ;;
              1) continue ;;
              *) : ;;   # fail-open: leave the row as the provider reported it
            esac
          else
            # Gate mode (brew): hide when the latest is positively too new.
            _zpun_min_age_satisfied "$manager" "$pkg_name" "$pkg_latest" || continue
          fi
        fi
        print -r -- "${manager}"$'\t'"${line}"
      done
```

Note: declare `pkg_current pkg_rest target rc` once before the loop (done
above) to avoid the zsh loop-local print pitfall.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/integration.bats -f "resolve-mode|gate-mode"`
Expected: PASS (2 tests). Then run the whole integration file to check the
existing min-age tests still pass: `bats tests/integration.bats`.

Note: the existing test "min-age threshold drops fresh updates from the
aggregated output" sets `min_age_npm/uv/gem=999` with `ZPUN_FIXTURE_NPM_AGE=fresh`
and `ZPUN_FIXTURE_CURL=fresh`. Under resolve mode those rows now go through
`_zpun_min_age_resolve_target`. Because both fixtures emit "now" for every
version under their `fresh` mode (the npm `--json` branch added in Task 4 sets
`old="$now"` when `NPM_AGE=fresh`; the curl branches use a single `$ts` that is
"now" under `fresh`), no candidate is old enough, the selector returns exit 1
(hide), and the rows still do not appear. The test's assertions (npm/uv/gem rows
absent, brew present) remain correct unchanged — confirm by running
`bats tests/integration.bats` after this task.

- [ ] **Step 5: Commit**

```bash
cd /tmp/zpun-min-age-downgrade-wt
git add zsh-pkg-update-nag.plugin.zsh tests/integration.bats
git commit -m "feat(min-age): dispatch resolve vs gate mode in collector"
```

---

### Task 9: Pinned upgrades

**Files:**
- Modify: `zsh-pkg-update-nag.plugin.zsh` (`_zpun_run_upgrade`)
- Modify: `lib/ui.zsh` (`_zpun_ui_upgrade_all`, `_zpun_ui_upgrade_individually` pass the target version)
- Modify: `tests/fixtures/uv` (handle `uv tool install`)
- Modify: `tests/fixtures/gem` (handle `gem install`)
- Test: `tests/integration.bats` (update the per-manager command test)

**Interfaces:**
- Consumes: the row's 4th field (resolved target/latest).
- Produces: `_zpun_run_upgrade <manager> <pkg> [<version>]` — pins the version for npm/pnpm/uv/gem; brew unchanged. Backward compatible: omitting the version falls back to the prior latest-tracking commands.

- [ ] **Step 1: Write the failing test**

Replace the existing `@test "_zpun_run_upgrade builds correct command per manager"` in `tests/integration.bats` with:

```bash
@test "_zpun_run_upgrade builds correct pinned command per manager" {
  run run_plugin_zsh "
    _zpun_run_upgrade brew pnpm
    _zpun_run_upgrade npm typescript 5.4.5
    _zpun_run_upgrade pnpm rollup 4.30.5
    _zpun_run_upgrade uv ruff 0.6.3
    _zpun_run_upgrade gem rails 7.1.5
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew upgrade pnpm"* ]]
  [[ "$output" == *"npm install -g typescript@5.4.5"* ]]
  [[ "$output" == *"pnpm add -g rollup@4.30.5"* ]]
  [[ "$output" == *"uv tool install --force ruff==0.6.3"* ]]
  [[ "$output" == *"gem install rails -v 7.1.5"* ]]
}

@test "_zpun_run_upgrade without a version falls back to latest-tracking" {
  run run_plugin_zsh "_zpun_run_upgrade npm typescript; _zpun_run_upgrade gem rails"
  [ "$status" -eq 0 ]
  [[ "$output" == *"npm install -g typescript@latest"* ]]
  [[ "$output" == *"gem update rails"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/integration.bats -f "_zpun_run_upgrade"`
Expected: FAIL — current `_zpun_run_upgrade` ignores a 3rd arg and emits `@latest`.

- [ ] **Step 3: Write minimal implementation**

3a. In `zsh-pkg-update-nag.plugin.zsh`, replace `_zpun_run_upgrade`'s body:

```zsh
_zpun_run_upgrade() {
  emulate -L zsh
  setopt local_options

  local manager=$1 pkg=$2 version=${3:-}
  local -a cmd
  case $manager in
    brew) cmd=(brew upgrade "$pkg") ;;
    npm)  cmd=(npm install -g "${pkg}@${version:-latest}") ;;
    pnpm) cmd=(pnpm add -g "${pkg}@${version:-latest}") ;;
    uv)   if [[ -n $version ]]; then cmd=(uv tool install --force "${pkg}==${version}")
          else cmd=(uv tool upgrade "$pkg"); fi ;;
    gem)  if [[ -n $version ]]; then cmd=(gem install "$pkg" -v "$version")
          else cmd=(gem update "$pkg"); fi ;;
    *)    _zpun_ui_error "unknown manager: $manager"; return 2 ;;
  esac

  _zpun_ui_info "→ ${cmd[*]}"
  "${cmd[@]}"
}
```

3b. In `lib/ui.zsh`, `_zpun_ui_upgrade_all`: extract and pass the target. Change:

```zsh
  local line manager pkg
  for line in "$@"; do
    (( ${_ZPUN_INTERRUPTED:-0} )) && { _zpun_ui_info "Stopped (Ctrl-C)."; return; }
    manager=${${(s:	:)line}[1]}
    pkg=${${(s:	:)line}[2]}
    _zpun_run_upgrade "$manager" "$pkg" || _zpun_ui_error "  upgrade failed for ${manager} ${pkg}"
  done
```

to:

```zsh
  local line manager pkg ver
  for line in "$@"; do
    (( ${_ZPUN_INTERRUPTED:-0} )) && { _zpun_ui_info "Stopped (Ctrl-C)."; return; }
    manager=${${(s:	:)line}[1]}
    pkg=${${(s:	:)line}[2]}
    ver=${${(s:	:)line}[4]}
    _zpun_run_upgrade "$manager" "$pkg" "$ver" || _zpun_ui_error "  upgrade failed for ${manager} ${pkg}"
  done
```

3c. In `lib/ui.zsh`, `_zpun_ui_upgrade_individually`, the loop already extracts
`lat=${${(s:	:)line}[4]}`. Change the upgrade call from:

```zsh
      _zpun_run_upgrade "$manager" "$pkg" || _zpun_ui_error "  upgrade failed for ${manager} ${pkg}"
```

to:

```zsh
      _zpun_run_upgrade "$manager" "$pkg" "$lat" || _zpun_ui_error "  upgrade failed for ${manager} ${pkg}"
```

3d. In `tests/fixtures/uv`, add an `install` branch under the `tool)` case:

```sh
  tool)
    if [ "$2" = "install" ]; then
      echo "uv fixture installed: $*"
      exit 0
    fi
    if [ "$2" = "upgrade" ]; then
      echo "uv fixture upgraded: $3"
      exit 0
    fi
    ;;
```

3e. In `tests/fixtures/gem`, add an `install` branch:

```sh
  install)
    echo "gem fixture installed: $*"
    exit 0
    ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/integration.bats -f "_zpun_run_upgrade"`
Expected: PASS (2 tests). Then run the whole integration file: `bats tests/integration.bats` (the tier-1/tier-2 upgrade tests now emit pinned `npm install -g pnpm@9.5.1`, which still matches their `"npm fixture installed"` assertions).

- [ ] **Step 5: Commit**

```bash
cd /tmp/zpun-min-age-downgrade-wt
git add zsh-pkg-update-nag.plugin.zsh lib/ui.zsh tests/fixtures/uv tests/fixtures/gem tests/integration.bats
git commit -m "feat(min-age): pin upgrades to the resolved target version"
```

---

### Task 10: Documentation (README + env var)

**Files:**
- Modify: `README.md` (min-age section, performance table, env/config docs)
- Test: full suite green (no new bats; documentation task)

**Interfaces:** none (docs only).

- [ ] **Step 1: Update the min-age behavior description**

In `README.md`, find the min-age section that explains hiding too-new updates.
Add a paragraph after it describing the new resolve behavior verbatim:

```markdown
For **npm**, **pnpm**, **uv**, and **gem**, when the latest release is younger
than your `min_age` threshold the plugin does not hide the package. It offers the
newest stable version that is old enough instead (prereleases and
yanked/deprecated versions are skipped), and the upgrade is pinned to that exact
version. If nothing newer than what you have is old enough, the row is hidden,
same as before. **brew** keeps the simpler behavior: a too-new latest is hidden
until it ages past the threshold.
```

- [ ] **Step 2: Update the min-age "native support" table row**

In the min-age table, leave npm/pnpm/uv/gem native-tool guidance as-is but ensure
the surrounding prose notes that, absent the native setting, this plugin now
resolves to the newest allowed version rather than hiding. (One sentence; no em
dashes.)

- [ ] **Step 3: Update the performance table**

In the performance table, update the npm/pnpm/uv/gem rows (or add a note under
the table) to state that resolve mode fetches the full version list once per
package and caches it with a TTL:

```markdown
Resolve mode (npm/pnpm/uv/gem) fetches each outdated package's full version list
once and caches it under `version_lists/` with a TTL
(`ZSH_PKG_UPDATE_NAG_MIN_AGE_LIST_TTL`, default 24h / 86400s), so steady-state
cost stays near zero within the TTL window. This is the same single registry call
the prior per-version lookup already made.
```

- [ ] **Step 4: Document the new env var**

Wherever environment variables are documented (e.g. the configuration/env
section), add:

```markdown
- `ZSH_PKG_UPDATE_NAG_MIN_AGE_LIST_TTL` (default `86400`): seconds to cache a
  package's version list in resolve mode before refetching. Lower values pick up
  newly-aged releases sooner at the cost of more registry calls.
```

- [ ] **Step 5: Run the full suite and commit**

```bash
cd /tmp/zpun-min-age-downgrade-wt
bats tests/
git add README.md
git commit -m "docs(min-age): document resolve-to-newest-allowed behavior + TTL"
```

Expected: full suite PASS.

---

## Final verification

- [ ] Run the complete suite: `cd /tmp/zpun-min-age-downgrade-wt && bats tests/` — all green.
- [ ] Measure startup is unchanged (no load-time additions): `time ( ZSH_PKG_UPDATE_NAG_NO_AUTORUN=1 source ./zsh-pkg-update-nag.plugin.zsh )` — comparable to `main`.
- [ ] Sanity-check resolve mode by hand if a real npm global is outdated, with `ZSH_PKG_UPDATE_NAG_DEBUG=1` and a `zsh_pkg_update_nag_min_age_npm` set, confirming the debug log shows the resolve path and the prompt offers a pinned version.

## Known gaps recorded (not in this plan)

- cargo's upgrade is not cooldown-pinned (PR #3). Bring it in line after PR #3 lands; same "shown X, install Y" class this plan fixes for the four managers.
- brew resolve-mode (downgrade) intentionally not implemented (cost).
