# macOS dev setup

Companion script of
[My macOS setup: Homebrew, mise and uv, one job each](https://www.kifurax.com/web-tooling/macos-brew-mise-uv).
One owner per layer: **Homebrew** for what the whole machine shares, **mise**
for the runtimes projects pin, **uv** for Python projects.

```sh
./install.sh --dry-run    # see every command, change nothing
./install.sh              # pick profiles, confirm each step
```

## What it installs

First a scan lists what is already on the machine. Then the steps run, numbered
(`[3/8] mise`). A tool that is already there is skipped unless you answer `y`
to its `[y/N]` question:

| Already installed | `y` does |
|---|---|
| Xcode Command Line Tools | Never asked: always kept |
| Homebrew | `brew update` (a reinstall would drop every formula) |
| mise | Its installer again, or `brew reinstall mise` if Homebrew owns it |
| node, bun | `mise install --force node@lts bun@latest` |
| uv, d3k | Their installer again |
| Homebrew formulae | `brew reinstall` |

Always (the base):

1. Apple's Command Line Tools (`xcode-select --install`)
2. Homebrew, with its official installer
3. mise, with its official installer, into `~/.local/bin`

Then the profiles you pick:

| Profile | Installs | Notes |
|---|---|---|
| `js` | node (LTS) and bun, as mise global defaults | Projects pin their own versions in `mise.toml` |
| `python` | uv, with its official installer, into `~/.local/bin` | uv owns Python: `uv python install`, `uv init`, `uv run`. No Python through mise or Homebrew |
| `ai` | dev3000 (`d3k`) with bun, tmux from Homebrew | Run `d3k` in a project instead of the dev script: the agent reads the server logs and browser console as they happen. tmux is for `d3k --with-agent` |
| `services` | PostgreSQL 18 + pgvector, colima + Docker CLI and Compose, cloudflared | Installed, never started. `brew services start postgresql@18`, `colima start`, `cloudflared tunnel --url http://localhost:4321` when a project needs them |

Last, a marked block in your shell's rc file loads Homebrew, `~/.local/bin`
and mise (fish, zsh or bash, from your login shell), plus `~/.bun/bin` where
d3k lives. Running the script again rewrites that block in place instead of
adding a second one, and leaves the file untouched when nothing changed. The
first change keeps a copy as `<rc file>.kifurax.bak`, and a symlinked rc file
(stow, chezmoi, a dotfiles repo) stays a symlink. Skip it with `--no-shell` if
your shell already does this.

Global defaults are always node on LTS and bun on latest: running the script
again sets them back there. Projects pin their own versions in `mise.toml`. A
mise installed with Homebrew is the one the shell block activates.

## Options

| Option | Effect |
|---|---|
| `--dry-run` | Print every command, change nothing |
| `--yes` | No questions; all profiles unless `--profiles` is given |
| `--profiles=js,python,ai,services` | Choose profiles without the menu |
| `--no-shell` | Leave rc files alone |
| `--reinstall` | Answer `y` to every "already installed" question (with `--yes`, those default to `N`) |
| `--help` | Usage |

## The menu

For its checkboxes the script downloads [gum](https://github.com/charmbracelet/gum)
for this run only: a pinned release (2.0.2) into a temporary folder, checked
against the release's `checksums.txt` with `shasum -a 256`, deleted on exit.
It is never installed. If the download or the check fails, or with `--yes`,
the script falls back to plain numbered prompts.

## Tests

```sh
./test.sh    # dry run, rc file handling, failure paths; runs in CI on macOS
```

## Requirements

macOS on Apple Silicon or Intel, the `bash` 3.2 that ships with it, and an
admin account (Homebrew asks for your password once). Run it as yourself, not
with `sudo`: the script stops early otherwise.
