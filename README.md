# zsh-pkg-update-nag

A zsh plugin that, at the start of a fresh interactive session, checks whether any of your globally-installed packages have updates available and offers to install them behind a quick `Y/n/s` confirmation. Rate-limited to every 4 hours (configurable) so it stays useful without becoming annoying.

Supports **Homebrew**, **npm (global)**, **uv tools**, and **RubyGems**. Managers are enabled independently, each with a choice of `all` (scan everything), `off`, or an explicit allowlist.

## Install

### oh-my-zsh

```sh
git clone https://github.com/<your-user>/zsh-pkg-update-nag \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-pkg-update-nag"
```

Then add `zsh-pkg-update-nag` to your `plugins=(...)` array in `~/.zshrc`.

### Standalone (any zsh)

```sh
git clone https://github.com/<your-user>/zsh-pkg-update-nag ~/.zsh-pkg-update-nag
echo 'source ~/.zsh-pkg-update-nag/zsh-pkg-update-nag.plugin.zsh' >> ~/.zshrc
```

Open a new terminal. On first run, the plugin writes a stampfile and exits silently — the first real check happens one interval later. Run `zsh-pkg-update-nag --now` to check immediately.

## What you'll see

When something's outdated:

```
▲ 3 updates available

  Homebrew
    gh      2.60.0 → 2.62.0
    fd      10.1.0 → 10.2.0
  npm (global)
    pnpm    9.0.0  → 9.5.1

  Update all? [Y/n/s] ›
```

- **`Y`** (or Enter) — runs every upgrade in sequence.
- **`n`** — skips everything; no re-nag for the rest of the interval.
- **`s`** — drops into per-package `Y/n` across all managers.

## Configuration

All options are optional. Defaults are sensible.

File location: `${XDG_CONFIG_HOME:-$HOME/.config}/zsh-pkg-update-nag/config.zsh` (override with `$ZSH_PKG_UPDATE_NAG_CONFIG`).

```zsh
# ~/.config/zsh-pkg-update-nag/config.zsh

# How often to check (hours). Default: 4.
zsh_pkg_update_nag_interval_hours=4

# Per-manager: "off", "all", or a zsh array / whitespace-separated string of
# package names to watch. Default shown.
zsh_pkg_update_nag_brew=all
zsh_pkg_update_nag_npm=all
zsh_pkg_update_nag_uv=all
zsh_pkg_update_nag_gem=off

# Example: watch only two npm globals.
# zsh_pkg_update_nag_npm=(claude-code pnpm)
```

### Environment variables

| Variable | Purpose |
|---|---|
| `ZSH_PKG_UPDATE_NAG_DISABLE=1` | Disable the plugin entirely (no check on shell start). |
| `ZSH_PKG_UPDATE_NAG_FORCE=1` | Ignore the rate-limit for this shell. |
| `ZSH_PKG_UPDATE_NAG_SSH=1` | Opt in under SSH sessions (default: skipped). |
| `ZSH_PKG_UPDATE_NAG_DEBUG=1` | Append diagnostics to `$XDG_STATE_HOME/zsh-pkg-update-nag/debug.log`. |
| `ZSH_PKG_UPDATE_NAG_PROVIDER_TIMEOUT` | Per-provider timeout in seconds (default `10`). |
| `ZSH_PKG_UPDATE_NAG_CONFIG` | Override config file path. |
| `NO_COLOR=1` | Disable color output (respected per the [NO_COLOR](https://no-color.org) spec). |

## Subcommands

```sh
zsh-pkg-update-nag --now         # run the check immediately
zsh-pkg-update-nag --check-env   # show detected managers, config, and next-check time
zsh-pkg-update-nag --help
```

## When the plugin does nothing

By design, the check is skipped in any of these cases:

- Non-interactive shells (scripts, here-docs).
- Dumb terminals (`TERM=dumb`), non-TTY stdin/stdout, `INSIDE_EMACS` set.
- `CI` environment variable set.
- SSH sessions, unless you opt in with `ZSH_PKG_UPDATE_NAG_SSH=1`.
- Within the rate-limit window.
- Another shell is mid-check (file-lock held).

## Uninstall

```sh
# oh-my-zsh
rm -rf "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-pkg-update-nag"
# remove the entry from your plugins=(...) in ~/.zshrc

# standalone
rm -rf ~/.zsh-pkg-update-nag
# remove the `source` line from ~/.zshrc

# optional: wipe state + config
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/zsh-pkg-update-nag"
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/zsh-pkg-update-nag"
```

## Troubleshooting

Nothing happens on shell start?

1. `ZSH_PKG_UPDATE_NAG_FORCE=1 zsh-pkg-update-nag --now` to bypass the rate-limit.
2. `zsh-pkg-update-nag --check-env` to confirm managers are detected and configured.
3. `ZSH_PKG_UPDATE_NAG_DEBUG=1 zsh-pkg-update-nag --now` and then `cat ~/.local/state/zsh-pkg-update-nag/debug.log`.

## Requirements

- zsh 5.0 or newer.
- Optional: `jq` (improves Homebrew version-delta display), `timeout`/`gtimeout` (wraps provider calls).

## Contributing

Issues and PRs welcome. Tests use [bats-core](https://github.com/bats-core/bats-core):

```sh
brew install bats-core
bats tests/
```

Run `shellcheck` on the library files (note: most of the plugin is zsh-only, so some shellcheck warnings are expected and silenced via inline directives where appropriate).

## License

MIT — see [LICENSE](LICENSE).
