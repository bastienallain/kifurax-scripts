#!/bin/bash
# macOS dev setup: Homebrew for the machine, mise for runtimes, uv for Python.
# Companion script of https://www.kifurax.com/web-tooling/macos-brew-mise-uv
#
# Usage:
#   ./install.sh                  interactive: pick profiles, confirm each step
#   ./install.sh --dry-run        print every command, change nothing
#   ./install.sh --yes --profiles=js,python
#                                 no questions, the listed profiles only
#   ./install.sh --no-shell       leave your shell rc files alone (you already
#                                 load Homebrew, ~/.local/bin and mise)
#
# Profiles (the base always runs: Xcode Command Line Tools, Homebrew, mise):
#   js        bun and node (LTS) through mise
#   python    uv from its official installer (uv owns Python, not mise)
#   ai        dev3000 (d3k) and tmux, for agents that read logs and console
#   services  PostgreSQL 18 + pgvector, colima + Docker CLI, cloudflared
#             (installed, never started at boot)
#
# Safe to run again: every step checks what is already there first.
# Written for the bash 3.2 that ships with macOS, so it runs on a new Mac.

set -eu

DRY_RUN=0
ASSUME_YES=0
NO_SHELL=0
PROFILES=""
GUM=""
GUM_VERSION="2.0.2"
TMP_DIR=""
MARK_BEGIN="# >>> kifurax-scripts macos-dev-setup >>>"
MARK_END="# <<< kifurax-scripts macos-dev-setup <<<"
DONE_STEPS=""
SKIPPED_STEPS=""

# -- output -------------------------------------------------------------------

bold=""; dim=""; coral=""; reset=""
if [ -t 1 ]; then
  bold=$(printf '\033[1m'); dim=$(printf '\033[2m'); coral=$(printf '\033[38;2;255;99;99m'); reset=$(printf '\033[0m')
fi
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s%s%s\n' "$coral" "$reset" "$bold" "$*" "$reset"; }
note() { printf '%s    %s%s\n' "$dim" "$*" "$reset"; }
die()  { printf '%serror:%s %s\n' "$coral" "$reset" "$*" >&2; exit 1; }
done_step()    { DONE_STEPS="${DONE_STEPS}  - $*
"; }
skipped_step() { SKIPPED_STEPS="${SKIPPED_STEPS}  - $*
"; }

# Print a command, then run it unless this is a dry run.
run() {
  printf '%s    $ %s%s\n' "$dim" "$*" "$reset"
  if [ "$DRY_RUN" -eq 0 ]; then
    eval "$*"
  fi
}

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# -- arguments ----------------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --no-shell) NO_SHELL=1 ;;
    --profiles=*) PROFILES=$(printf '%s' "${arg#--profiles=}" | tr ',' ' ') ;;
    --help|-h) usage ;;
    *) die "unknown option: $arg (see --help)" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "this script is for macOS only."
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then BREW_PREFIX="/opt/homebrew"; else BREW_PREFIX="/usr/local"; fi

# -- gum, downloaded for this run only ----------------------------------------
# A pinned release in a temp folder, checked against the release's own
# checksums.txt with shasum, deleted on exit. Any failure falls back to plain
# prompts, so the script never depends on it.

cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

fetch_gum() {
  [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ] && [ -t 1 ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local asset base sum
  if [ "$ARCH" = "arm64" ]; then asset="gum_${GUM_VERSION}_Darwin_arm64.tar.gz"; else asset="gum_${GUM_VERSION}_Darwin_x86_64.tar.gz"; fi
  base="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}"
  TMP_DIR=$(mktemp -d)
  curl -fsSL "$base/$asset" -o "$TMP_DIR/$asset" 2>/dev/null || return 0
  curl -fsSL "$base/checksums.txt" -o "$TMP_DIR/checksums.txt" 2>/dev/null || return 0
  sum=$(grep " $asset\$" "$TMP_DIR/checksums.txt" | cut -d' ' -f1)
  [ -n "$sum" ] || return 0
  printf '%s  %s\n' "$sum" "$TMP_DIR/$asset" | shasum -a 256 -c - >/dev/null 2>&1 || { note "gum checksum mismatch, using plain prompts"; return 0; }
  tar -xzf "$TMP_DIR/$asset" -C "$TMP_DIR" 2>/dev/null || return 0
  GUM=$(find "$TMP_DIR" -type f -name gum -perm -u+x | head -n 1)
}

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  if [ -n "$GUM" ]; then
    "$GUM" confirm "$1"
  else
    printf '%s [y/N] ' "$1"
    read -r answer </dev/tty || return 1
    case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
  fi
}

choose_profiles() {
  [ -n "$PROFILES" ] && return 0
  if [ "$ASSUME_YES" -eq 1 ]; then
    PROFILES="js python ai services"
    return 0
  fi
  if [ -n "$GUM" ]; then
    PROFILES=$("$GUM" choose --no-limit --header "Profiles to install (space to select, enter to confirm)" \
      "js        bun + node LTS via mise" \
      "python    uv (owns Python)" \
      "ai        d3k (dev3000) + tmux" \
      "services  Postgres 18 + pgvector, colima + Docker, cloudflared" | awk '{print $1}' | tr '\n' ' ')
  else
    say "Profiles (the base always runs: Xcode CLT, Homebrew, mise):"
    say "  1) js        bun + node LTS via mise"
    say "  2) python    uv (owns Python)"
    say "  3) ai        d3k (dev3000) + tmux"
    say "  4) services  Postgres 18 + pgvector, colima + Docker, cloudflared"
    printf 'Numbers separated by spaces (e.g. 1 2 3), empty for none: '
    read -r picks </dev/tty || picks=""
    for n in $picks; do
      case "$n" in
        1) PROFILES="$PROFILES js" ;;
        2) PROFILES="$PROFILES python" ;;
        3) PROFILES="$PROFILES ai" ;;
        4) PROFILES="$PROFILES services" ;;
        *) note "ignored: $n" ;;
      esac
    done
  fi
}

has_profile() { case " $PROFILES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# -- shell integration --------------------------------------------------------
# One marked block per rc file, rewritten in place on every run.

login_shell() { basename "$(dscl . -read "$HOME" UserShell 2>/dev/null | awk '{print $2}')" 2>/dev/null || basename "${SHELL:-zsh}"; }

write_block() {
  local file="$1" body="$2"
  printf '%s    %s: shell block (Homebrew, ~/.local/bin, mise)%s\n' "$dim" "$file" "$reset"
  [ "$DRY_RUN" -eq 1 ] && { printf '%s%s\n%s\n%s%s\n' "$dim" "$MARK_BEGIN" "$body" "$MARK_END" "$reset"; return 0; }
  mkdir -p "$(dirname "$file")"
  touch "$file"
  local tmp
  tmp=$(mktemp)
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$file" > "$tmp"
  printf '%s\n%s\n%s\n' "$MARK_BEGIN" "$body" "$MARK_END" >> "$tmp"
  mv "$tmp" "$file"
}

shell_integration() {
  step "Shell integration"
  if [ "$NO_SHELL" -eq 1 ]; then note "--no-shell: rc files left alone"; skipped_step "shell integration (--no-shell)"; return 0; fi
  local sh
  sh=$(login_shell)
  case "$sh" in
    fish)
      write_block "$HOME/.config/fish/config.fish" "$BREW_PREFIX/bin/brew shellenv | source
fish_add_path -g \$HOME/.local/bin
\$HOME/.local/bin/mise activate fish | source" ;;
    bash)
      write_block "$HOME/.bash_profile" "eval \"\$($BREW_PREFIX/bin/brew shellenv)\"
export PATH=\"\$HOME/.local/bin:\$PATH\"
eval \"\$(\$HOME/.local/bin/mise activate bash)\"" ;;
    *)
      write_block "$HOME/.zprofile" "eval \"\$($BREW_PREFIX/bin/brew shellenv)\"
export PATH=\"\$HOME/.local/bin:\$PATH\""
      write_block "$HOME/.zshrc" "eval \"\$(\$HOME/.local/bin/mise activate zsh)\"" ;;
  esac
  done_step "shell integration for $sh (open a new terminal to use it)"
}

# -- base ---------------------------------------------------------------------

xcode_clt() {
  step "Xcode Command Line Tools"
  if xcode-select -p >/dev/null 2>&1; then
    note "already installed: $(xcode-select -p)"; skipped_step "Xcode CLT (present)"; return 0
  fi
  confirm "Install Apple's Command Line Tools (compilers, git)?" || die "Homebrew needs the Command Line Tools."
  run xcode-select --install
  [ "$DRY_RUN" -eq 1 ] || die "finish the Command Line Tools installer window, then run this script again."
}

homebrew() {
  step "Homebrew"
  if [ -x "$BREW_PREFIX/bin/brew" ]; then
    note "already installed: $("$BREW_PREFIX/bin/brew" --version | head -n 1)"; skipped_step "Homebrew (present)"
  else
    confirm "Install Homebrew with its official installer (asks for your password)?" || die "the rest needs Homebrew."
    run '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    done_step "Homebrew"
  fi
  if [ "$DRY_RUN" -eq 0 ]; then eval "$("$BREW_PREFIX/bin/brew" shellenv)"; fi
}

brew_install() {
  local missing="" f
  for f in "$@"; do
    if command -v brew >/dev/null 2>&1 && brew list --formula "$f" >/dev/null 2>&1; then note "$f already installed"; else missing="$missing $f"; fi
  done
  [ -z "$missing" ] && return 1
  run brew install$missing
}

mise_install() {
  step "mise"
  if [ -x "$HOME/.local/bin/mise" ] || command -v mise >/dev/null 2>&1; then
    note "already installed: $(mise --version 2>/dev/null || "$HOME/.local/bin/mise" --version)"; skipped_step "mise (present)"
  else
    confirm "Install mise with its official installer (into ~/.local/bin, outside Homebrew)?" || { skipped_step "mise (declined)"; return 0; }
    run 'curl -fsSL https://mise.run | sh'
    done_step "mise"
  fi
  export PATH="$HOME/.local/bin:$PATH"
}

# -- profiles -----------------------------------------------------------------

profile_js() {
  step "Profile js: bun + node LTS"
  run mise use --global node@lts bun@latest
  done_step "node (LTS) and bun, global defaults in ~/.config/mise/config.toml"
}

profile_python() {
  step "Profile python: uv"
  if command -v uv >/dev/null 2>&1; then
    note "already installed: $(uv --version)"; skipped_step "uv (present, update with: uv self update)"; return 0
  fi
  confirm "Install uv with its official installer (into ~/.local/bin)?" || { skipped_step "uv (declined)"; return 0; }
  run 'curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh'
  done_step "uv (Python is uv's: uv python install, uv init, uv run)"
}

profile_ai() {
  step "Profile ai: d3k (dev3000) + tmux"
  if brew_install tmux; then done_step "tmux (for d3k --with-agent split screen)"; else skipped_step "tmux (present)"; fi
  if ! command -v bun >/dev/null 2>&1 && ! has_profile js; then
    note "d3k installs with bun: adding bun through mise"
    run mise use --global bun@latest
  fi
  if command -v d3k >/dev/null 2>&1; then
    note "already installed: d3k $(d3k --version 2>/dev/null)"; skipped_step "d3k (present, update with: d3k upgrade)"
  else
    run mise exec bun -- bun add --global dev3000
    done_step "d3k (dev3000): run it in a project instead of the dev script"
  fi
}

profile_services() {
  step "Profile services: Postgres 18 + pgvector, colima + Docker, cloudflared"
  if brew_install postgresql@18 pgvector colima docker docker-compose cloudflared; then
    done_step "services installed, all stopped"
  else
    skipped_step "services (all present, all stopped)"
  fi
  note "nothing is started. When a project needs them:"
  note "  brew services start postgresql@18    colima start    cloudflared tunnel --url http://localhost:4321"
  note "docker compose: see 'brew info docker-compose' for the one-line plugin setting"
}

# -- main ---------------------------------------------------------------------

say "${bold}kifurax macOS dev setup${reset}  ${dim}($ARCH, macOS $(sw_vers -productVersion))${reset}"
[ "$DRY_RUN" -eq 1 ] && note "dry run: commands are printed, nothing is changed"
fetch_gum
choose_profiles
note "profiles:${PROFILES:- none}"

xcode_clt
homebrew
mise_install
has_profile js && profile_js
has_profile python && profile_python
has_profile ai && profile_ai
has_profile services && profile_services
shell_integration

step "Summary"
if [ "$DRY_RUN" -eq 1 ]; then done_title="Would do:"; else done_title="Done:"; fi
[ -n "$DONE_STEPS" ] && { say "$done_title"; printf '%s' "$DONE_STEPS"; }
[ -n "$SKIPPED_STEPS" ] && { say "Already there or skipped:"; printf '%s' "$SKIPPED_STEPS"; }
say ""
say "Next: open a new terminal, then in a project: mise use node@22 (pin a runtime), uv init (Python), d3k (dev server for agents)."
