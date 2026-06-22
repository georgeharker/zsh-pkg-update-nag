# Design: min-age resolves to the newest allowed version (not hide)

- Date: 2026-06-22
- Branch: `min-age-show-newest-allowed-version`
- Status: design / awaiting implementation plan

## Motivation

Today the `min_age` feature is a binary gate. When a package's *latest* version
was published less than `N` days ago, the whole row is hidden until that latest
ages past the threshold (or a newer one ships). The user sees nothing in the
meantime, even when there is a perfectly good slightly-older release worth
installing.

The cargo provider (PR #3) got better behavior for free: `cargo install-update
--list --cooldown <Nd>` re-resolves "latest" to the newest version that is old
enough, so the user is offered the safe older release instead of nothing. This
design brings that "downgrade to the newest allowed version" behavior to the
managers whose registries let us compute it cheaply.

### Goal

For an outdated package whose true latest is too new, offer the **highest stable
version that is both newer than what is installed and at least `N` days old**,
instead of hiding the update.

## Scope

In scope (resolve mode): **npm, pnpm, uv, gem**. Their registries return the
full version history with publish dates in a single API call we already make.

Out of scope (unchanged): **brew** keeps the existing binary gate
(`_zpun_min_age_satisfied`). Homebrew exposes only the latest formula commit
date; enumerating prior versions with dates would require walking each formula's
git history over the GitHub API, which is too expensive for this project's
startup-latency priorities. **cargo** already does this upstream via
`--cooldown`; no change here.

Non-goal: changing the threshold configuration. `zsh_pkg_update_nag_min_age` and
the per-manager `zsh_pkg_update_nag_min_age_<m>` overrides keep their current
meaning and inheritance.

## Current behavior (recap)

- Each `_zpun_provider_<m>` emits `name<TAB>current<TAB>latest` (latest as the
  manager reports it).
- `_zpun_collect_outdated`, when min-age is active, calls
  `_zpun_min_age_satisfied <m> <name> <latest>` per row. It returns 0 (keep) if
  the latest version is old enough OR undeterminable (fail-open), 1 (drop) if
  positively too new.
- `_zpun_min_age_lookup_<m> <name> <version>` returns one version's epoch.
  Epochs are cached forever in `age_cache.tsv` (immutable facts).
- `_zpun_run_upgrade <manager> <pkg>` installs `@latest` (npm/pnpm), upgrades to
  latest (uv/gem/brew). No version is pinned.

## New behavior

### Selection algorithm (resolve mode)

Given a manager `m`, package `name`, installed `current`, reported `latest`, and
threshold `N` days:

1. Obtain the version list: rows of `(version, epoch, status)` where `status` is
   one of `stable | prerelease | yanked`.
2. Candidate filter, keep a version `v` iff:
   - `status == stable`, and
   - `age(v) >= N days` (i.e. `now - epoch(v) >= N*86400`), and
   - `v > current` and `v <= latest` (compare with `_zpun_version_compare`).
3. Target = the maximum candidate by `_zpun_version_compare`.
4. Outcomes:
   - **Target found:** rewrite the row's `latest` field to the target. The rest
     of the pipeline (summary, prompt, upgrade) treats it as the upgrade target.
   - **No candidate (success, but everything newer is too new / prerelease /
     yanked, or current is already the newest allowed):** drop the row (same
     visible result as today's hide).
   - **Lookup failed (network down, missing curl/jq, malformed response):**
     fail-open. Leave the row unchanged (show the provider's true latest) and
     write a debug-log line. This matches the project's existing fail-open
     philosophy: a degraded environment must never silently hide updates.

The distinction between "success but empty" (hide) and "failure" (fail-open
show latest) is deliberate and must be preserved.

### Display

The resolved target occupies the existing `latest` column. No new columns, no
annotation of the held-back true-latest. `_zpun_ui_*` summary/prompt code is
unchanged.

### Pinned upgrades

Because the shown target may be older than true latest, the upgrade must pin to
the shown version, or accepting the prompt would install the too-new release and
defeat the feature. `_zpun_run_upgrade` gains a target-version argument:

| Manager | Command (pinned) |
|---|---|
| npm  | `npm install -g <name>@<ver>` |
| pnpm | `pnpm add -g <name>@<ver>` |
| uv   | `uv tool install '<name>==<ver>'` (verify `--force`/`--reinstall` need at implementation time, since the tool is already installed) |
| gem  | `gem install <name> -v <ver>` |
| brew | `brew upgrade <name>` (unchanged; brew is gate-mode, target always == true latest) |
| cargo | `cargo install-update <name>` (unchanged; see Known gaps) |

Pinning to the shown version is correct even when no downgrade happened (the
shown version then equals true latest), so npm/pnpm/uv/gem pin unconditionally.

`_zpun_ui_upgrade_all` and `_zpun_ui_upgrade_individually` already have the row's
4th field (`latest`/target) in scope; they pass it to `_zpun_run_upgrade`.

## Components

### Per-manager hook: `_zpun_min_age_versions_<m> <name>`

Defined in `lib/providers/<m>.zsh` for npm, pnpm, uv, gem. Emits TSV to stdout,
one row per known version:

```
<version>\t<epoch>\t<status>
```

- `epoch`: integer seconds (UTC) of the version's publish time, via the existing
  `_zpun_min_age_parse_iso8601`.
- `status`: `stable`, `prerelease`, or `yanked`. The provider classifies,
  because prerelease/yank semantics are ecosystem-specific.
- A row with an unparseable date is omitted (it can never satisfy the age
  filter anyway).
- Non-zero exit or empty output signals "could not determine" (caller
  fail-opens).

The presence of this function is the capability signal: a manager that defines
`_zpun_min_age_versions_<m>` runs in resolve mode; one that defines only
`_zpun_min_age_lookup_<m>` (brew) runs in gate mode.

#### Per-manager specifics

| Manager | Source (one call) | Stable vs prerelease | Yanked / deprecated |
|---|---|---|---|
| npm  | `npm view <name> --json` (config-aware via the npm CLI; `.time` map + `.versions` **array** of strings) | semver: prerelease iff version contains `-` | not available — `npm view --json` exposes no per-version `deprecated`; only unpublished versions are excluded (a `.time` key absent from the `.versions` array) |
| pnpm | `https://registry.npmjs.org/<name>` via curl + jq (`.time`, `.versions` **object**) | same as npm | `.versions[v].deprecated` present → yanked |
| uv   | `https://pypi.org/pypi/<name>/json` via curl + jq (`.releases`) | PEP 440 heuristic: prerelease iff version matches `a|b|rc|dev` markers | `.releases[v][].yanked == true` → yanked |
| gem  | `https://rubygems.org/api/v1/versions/<name>.json` via curl + jq | `.[].prerelease == true` | RubyGems omits yanked versions from this list (naturally absent) |

Note: the shared `_zpun_min_age_emit_versions_from_npm_doc` parser handles both
`.versions` shapes. `npm view <name> --json` (npm CLI, registry/proxy/auth
aware) returns `.versions` as an array of version strings with no per-version
metadata, so npm excludes prereleases and unpublished versions but cannot detect
deprecation. The registry document (`https://registry.npmjs.org/<name>`, used by
the pnpm hook) returns `.versions` as an object whose manifests carry
`deprecated`, so pnpm additionally excludes deprecated versions. npm stays on the
CLI for consistency with `npm outdated -g` and to work on private registries
(where curling the public registry would 404 and fail open). Empirically
verified end-to-end against the live npm registry, including scoped packages.

### Shared selector: `_zpun_min_age_resolve_target <m> <name> <current> <latest>`

Lives in `lib/min_age.zsh`. Reads the version list (cache-first, see Cache),
applies the Selection algorithm, and prints the resolved target version on
success, prints nothing and returns non-zero on "no candidate" (caller hides),
or returns a distinct sentinel for "lookup failed" (caller fail-opens). Concrete
contract:

- exit 0 + prints `<target>` → rewrite row.
- exit 1 + no output → hide row (no qualifying upgrade).
- exit 2 + no output → fail-open (leave row as provider reported).

### Portable version comparator: `_zpun_version_compare a b`

Lives in `lib/min_age.zsh`. Pure zsh (no `sort -V`; macOS `sort` lacks it).
Prints `-1 | 0 | 1` for `a<b | a==b | a>b`. Algorithm: split each on `.`,
compare segment-by-segment numerically (zero-pad the shorter), and for any
non-numeric segment fall back to lexical comparison of that segment. Operates
only on stable versions (prereleases are excluded before comparison).

Known limitation: exotic PEP 440 forms (epochs `1!2.3`, post-releases
`1.2.post1`) are compared best-effort. Global Python *tools* almost always use
plain `X.Y.Z`; documented as a limitation rather than fully solved.

### Collector dispatch (`_zpun_collect_outdated`)

After a provider returns its rows and when min-age is active for that manager:

- If `_zpun_min_age_versions_<m>` is defined → resolve mode: for each row, call
  `_zpun_min_age_resolve_target` and act on its exit code (rewrite / hide /
  fail-open).
- Else → gate mode: existing `_zpun_min_age_satisfied` path (brew).

The existing per-manager source-on-demand and `_zpun_min_age_active` gating are
reused unchanged; resolve mode is just a different branch inside the same loop.
Resolve mode does not use the `_zpun_min_age_prefetch` dispatcher (there is no
cross-package batch for per-registry endpoints); each row's
`_zpun_min_age_resolve_target` call is cache-first and self-contained. The
prefetch dispatcher remains for brew's GraphQL batch.

### Cache: per-package version-list with TTL

- Location: `$(_zpun_state_dir)/version_lists/<manager>__<safe_name>.tsv`, where
  `safe_name` encodes filesystem-unsafe characters in the package name (npm
  scoped packages like `@types/node` contain `/` and `@`). `safe_name` is
  computed deterministically from the name at both write and read time (e.g.
  percent-encode `/`, `@`, and other non-`[A-Za-z0-9._-]` bytes). Lookups
  recompute it from the known name, so the scheme only needs to be deterministic
  and collision-free, not reversible.
- Format: first line `# fetched_at <epoch>`, then the `version\tepoch\tstatus`
  rows verbatim.
- Read path: if the file exists and `now - fetched_at < TTL`, use it; else
  fetch via `_zpun_min_age_versions_<m>`, write the file, use the result.
- TTL: `ZSH_PKG_UPDATE_NAG_MIN_AGE_LIST_TTL` (seconds), default `86400` (24h).
  Rationale: a version that has just crossed the age threshold is picked up on
  the next refresh; with scans rate-limited to `interval_hours` (default 4h) and
  a 24h TTL, at most one list fetch per package per day. Thresholds are in whole
  days, so up-to-24h slack on "newly aged" is acceptable.
- Eviction: cap the number of cached package files (e.g. 500, mirroring the
  existing `age_cache.tsv` row cap); delete the oldest by mtime beyond the cap.
- The immutable `age_cache.tsv` remains for brew gate mode. Resolve-mode
  managers use the list cache exclusively.

### Config / env

- Threshold: unchanged (`zsh_pkg_update_nag_min_age[_<m>]`).
- New: `ZSH_PKG_UPDATE_NAG_MIN_AGE_LIST_TTL` (default 86400).
- No new per-manager enable/disable knob; resolve mode is implied by the
  manager being min-age-active and having a `_versions` hook.

## Error handling

- Every network/parse failure in `_zpun_min_age_versions_<m>` → empty/non-zero →
  `_zpun_min_age_resolve_target` returns the fail-open sentinel → row shown with
  true latest. Never hide on failure.
- Cache write failures are non-fatal (best-effort, like existing cache puts).
- The whole resolve path runs inside the existing per-provider `timeout`
  wrapper, so a hung fetch cannot extend the scan.

## Performance

- Resolve mode makes the same one-call-per-package the current npm/uv/gem
  lookups already make, now cached as a list with a TTL instead of a single
  epoch cached forever. Steady-state stays near-zero within the TTL window.
- No new work on the shell-startup critical path: all of this runs in the
  deferred background scan, exactly as today. `lib/min_age.zsh` and providers
  stay lazily sourced.
- The version comparator is pure-zsh string work on a handful of candidate
  versions per package; negligible.
- README performance/min-age tables get a row update describing the new
  list-fetch + TTL cost, per the project's "document the cost" rule.

## Testing

New/updated `bats` coverage (match existing fixture style):

- `_zpun_version_compare`: ordering across equal, shorter/longer, multi-digit
  segments; a couple of documented PEP 440 edge cases.
- Selector: picks the held-back target; excludes prereleases; excludes
  yanked/deprecated; hides when no candidate qualifies; fail-opens (shows true
  latest) on fetch failure; respects `(current, latest]` bounds.
- Per-manager `_zpun_min_age_versions_<m>`: parses each registry's fixture into
  correct `version/epoch/status` rows (prerelease + yank classification).
- Cache: TTL hit avoids refetch; TTL miss refetches; eviction cap.
- Pinned upgrades: `_zpun_run_upgrade` emits the pinned command per manager
  (extend the existing "builds correct command per manager" integration test).
- Collector: resolve mode rewrites the row to the target; gate mode (brew)
  unchanged.

Fixtures: extend the curl/npm shims to serve canned version JSON per manager,
following `tests/fixtures/` conventions.

## Known gaps / follow-ups (not this spec)

- **cargo upgrade is not cooldown-pinned.** `cargo install-update <pkg>`
  installs the true latest even though `--list --cooldown` filtered the listing.
  Same class of "shown X, install Y" drift this spec fixes for the four
  managers. cargo can be brought in line separately (pin via
  `cargo install <pkg> --version <ver>` or similar) once PR #3 lands.
- **brew downgrade** remains unimplemented by design (cost).

## Open questions

None blocking. The uv pin command's exact flag (`--force` vs `--reinstall` vs
plain `uv tool install pkg==ver` when already installed) is verified during
implementation, not design.
