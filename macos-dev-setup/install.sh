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

set -eu -o pipefail

DRY_RUN=0
ASSUME_YES=0
NO_SHELL=0
PROFILES=""
KNOWN_PROFILES="js python ai services"
GUM=""
GUM_VERSION="2.0.2"
TMP_DIR=""
MARK_BEGIN="# >>> kifurax-scripts macos-dev-setup >>>"
MARK_END="# <<< kifurax-scripts macos-dev-setup <<<"
DONE_STEPS=""
SKIPPED_STEPS=""
MISE_BIN=""
BUN_GLOBAL_BIN="$HOME/.bun/bin"

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
  sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

# -- arguments ----------------------------------------------------------------

parse_args() {
  local arg p
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
  # A typo like --profiles=javascript would otherwise install nothing, silently.
  for p in $PROFILES; do
    case " $KNOWN_PROFILES " in *" $p "*) ;; *) die "unknown profile: $p (choose from: $KNOWN_PROFILES)" ;; esac
  done
}

# -- preflight ----------------------------------------------------------------

preflight() {
  [ "$(uname -s)" = "Darwin" ] || die "this script is for macOS only."
  [ "$(id -u)" -ne 0 ] || die "run it as your own user, not with sudo: Homebrew refuses root, and mise and uv would land in root's home."
  ARCH=$(uname -m)
  # A Terminal opened with Rosetta reports x86_64 on Apple Silicon, which would
  # put Homebrew in /usr/local and every tool in the Intel build.
  if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
    die "this shell runs under Rosetta. Open Terminal without 'Open using Rosetta' and run again."
  fi
  if [ "$ARCH" = "arm64" ]; then BREW_PREFIX="/opt/homebrew"; else BREW_PREFIX="/usr/local"; fi
  if [ ! -x "$BREW_PREFIX/bin/brew" ]; then
    case " $(id -Gn) " in *" admin "*) ;; *) die "installing Homebrew needs an admin account; $(id -un) is not in the admin group." ;; esac
  fi
}

# -- gum, downloaded for this run only ----------------------------------------
# A pinned release in a temp folder, checked against the release's own
# checksums.txt with shasum, deleted on exit. Any failure falls back to plain
# prompts, so the script never depends on it.

cleanup() { if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi; }

fetch_gum() {
  [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ] && [ -t 1 ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local asset base sum
  if [ "$ARCH" = "arm64" ]; then asset="gum_${GUM_VERSION}_Darwin_arm64.tar.gz"; else asset="gum_${GUM_VERSION}_Darwin_x86_64.tar.gz"; fi
  base="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}"
  TMP_DIR=$(mktemp -d)
  curl -fsSL --proto '=https' "$base/$asset" -o "$TMP_DIR/$asset" 2>/dev/null || return 0
  curl -fsSL --proto '=https' "$base/checksums.txt" -o "$TMP_DIR/checksums.txt" 2>/dev/null || return 0
  sum=$(grep " $asset\$" "$TMP_DIR/checksums.txt" | cut -d' ' -f1) || true
  [ -n "$sum" ] || return 0
  printf '%s  %s\n' "$sum" "$TMP_DIR/$asset" | shasum -a 256 -c - >/dev/null 2>&1 || { note "gum checksum mismatch, using plain prompts"; return 0; }
  tar -xzf "$TMP_DIR/$asset" -C "$TMP_DIR" 2>/dev/null || return 0
  GUM=$(find "$TMP_DIR" -type f -name gum -perm -u+x | head -n 1) || GUM=""
}

# 0 yes, 1 no. Ctrl-C or Esc in gum aborts the whole run instead of reading as "no".
confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  if [ -n "$GUM" ]; then
    local status=0
    "$GUM" confirm "$1" || status=$?
    [ "$status" -le 1 ] || die "cancelled."
    return "$status"
  else
    printf '%s [y/N] ' "$1"
    read -r answer </dev/tty || return 1
    case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
  fi
}

choose_profiles() {
  [ -n "$PROFILES" ] && return 0
  if [ "$ASSUME_YES" -eq 1 ]; then
    PROFILES="$KNOWN_PROFILES"
    return 0
  fi
  if [ -n "$GUM" ]; then
    PROFILES=$("$GUM" choose --no-limit --header "Profiles to install (space to select, enter to confirm)" \
      "js        bun + node LTS via mise" \
      "python    uv (owns Python)" \
      "ai        d3k (dev3000) + tmux" \
      "services  Postgres 18 + pgvector, colima + Docker, cloudflared" | awk '{print $1}' | tr '\n' ' ') || die "cancelled."
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

login_shell() {
  local sh
  sh=$(dscl . -read "$HOME" UserShell 2>/dev/null | awk '{print $2}') || sh=""
  basename "${sh:-${SHELL:-zsh}}"
}

# Replace the marked block of $1 with $2, or append it. The file is written
# through, not replaced, so a symlinked rc file (stow, chezmoi, a dotfiles
# repo) stays a symlink and keeps its permissions. The first change also
# leaves a one-time backup next to it.
write_block() {
  local file="$1" body="$2" tmp
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s    %s: shell block (Homebrew, ~/.local/bin, mise)%s\n' "$dim" "$file" "$reset"
    printf '%s%s\n%s\n%s%s\n' "$dim" "$MARK_BEGIN" "$body" "$MARK_END" "$reset"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  [ -e "$file" ] || : > "$file"
  tmp=$(mktemp)
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$file" > "$tmp"
  printf '%s\n%s\n%s\n' "$MARK_BEGIN" "$body" "$MARK_END" >> "$tmp"
  if cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
    note "$file: shell block unchanged"
    return 0
  fi
  if [ -s "$file" ] && [ ! -e "$file.kifurax.bak" ]; then
    cp -p "$file" "$file.kifurax.bak"
    note "$file: backup in $file.kifurax.bak"
  fi
  cat "$tmp" > "$file"
  rm -f "$tmp"
  note "$file: shell block written"
}

shell_integration() {
  step "Shell integration"
  if [ "$NO_SHELL" -eq 1 ]; then note "--no-shell: rc files left alone"; skipped_step "shell integration (--no-shell)"; return 0; fi
  local sh bun_line=""
  sh=$(login_shell)
  # d3k and other `bun add --global` tools land in ~/.bun/bin.
  if has_profile ai || [ -d "$BUN_GLOBAL_BIN" ]; then bun_line=1; fi
  case "$sh" in
    fish)
      write_block "$HOME/.config/fish/config.fish" "$BREW_PREFIX/bin/brew shellenv | source
fish_add_path -g \$HOME/.local/bin${bun_line:+
fish_add_path -g \$HOME/.bun/bin}${MISE_BIN:+
$MISE_BIN activate fish | source}" ;;
    bash)
      write_block "$HOME/.bash_profile" "eval \"\$($BREW_PREFIX/bin/brew shellenv)\"
export PATH=\"\$HOME/.local/bin:\$PATH\"${bun_line:+
export PATH=\"\$HOME/.bun/bin:\$PATH\"}${MISE_BIN:+
eval \"\$($MISE_BIN activate bash)\"}" ;;
    *)
      write_block "$HOME/.zprofile" "eval \"\$($BREW_PREFIX/bin/brew shellenv)\"
export PATH=\"\$HOME/.local/bin:\$PATH\"${bun_line:+
export PATH=\"\$HOME/.bun/bin:\$PATH\"}"
      if [ -n "$MISE_BIN" ]; then
        write_block "$HOME/.zshrc" "eval \"\$($MISE_BIN activate zsh)\""
      fi ;;
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
    note "already installed: $("$BREW_PREFIX/bin/brew" --version 2>/dev/null | head -n 1)"; skipped_step "Homebrew (present)"
  else
    confirm "Install Homebrew with its official installer (asks for your password)?" || die "the rest needs Homebrew."
    if [ "$ASSUME_YES" -eq 1 ]; then
      # The installer stops on "Press RETURN" unless NONINTERACTIVE is set,
      # and in that mode it needs sudo already unlocked: ask once, up front.
      run sudo -v
      run 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    else
      run '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    fi
    [ "$DRY_RUN" -eq 1 ] || [ -x "$BREW_PREFIX/bin/brew" ] || die "the Homebrew installer finished but $BREW_PREFIX/bin/brew is missing."
    done_step "Homebrew"
  fi
  if [ "$DRY_RUN" -eq 0 ]; then eval "$("$BREW_PREFIX/bin/brew" shellenv)"; fi
}

# Install the missing formulae. Returns 0 when it installed some, 1 when all
# were there. A failed install stops the script: callers test this function
# in an `if`, where set -e does not apply.
brew_install() {
  local missing="" f
  for f in "$@"; do
    if command -v brew >/dev/null 2>&1 && brew list --formula "$f" >/dev/null 2>&1; then note "$f already installed"; else missing="$missing $f"; fi
  done
  [ -z "$missing" ] && return 1
  run brew install"$missing" || die "brew install$missing failed."
  return 0
}

# mise can come from its installer (~/.local/bin) or from Homebrew: the shell
# block must point at the one that exists, not assume the installer's path.
find_mise() {
  if [ -x "$HOME/.local/bin/mise" ]; then MISE_BIN="$HOME/.local/bin/mise"
  elif command -v mise >/dev/null 2>&1; then MISE_BIN=$(command -v mise)
  else MISE_BIN=""
  fi
}

mise_install() {
  step "mise"
  find_mise
  if [ -n "$MISE_BIN" ]; then
    note "already installed: $("$MISE_BIN" --version 2>/dev/null) ($MISE_BIN)"; skipped_step "mise (present)"
  else
    confirm "Install mise with its official installer (into ~/.local/bin, outside Homebrew)?" || {
      has_profile js && die "the js profile needs mise."
      has_profile ai && die "the ai profile needs mise (d3k installs with bun)."
      skipped_step "mise (declined)"; return 0
    }
    run 'curl -fsSL --proto "=https" https://mise.run | sh'
    if [ "$DRY_RUN" -eq 1 ]; then
      MISE_BIN="$HOME/.local/bin/mise"
    else
      find_mise
      [ -n "$MISE_BIN" ] || die "the mise installer finished but mise is missing from ~/.local/bin."
    fi
    done_step "mise"
  fi
  # Shims make the runtimes mise manages callable for the rest of this run.
  export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$BUN_GLOBAL_BIN:$PATH"
}

# -- profiles -----------------------------------------------------------------

# Set a global default only for tools that have none: a rerun must not
# replace a node@22 the user pinned with node@lts.
mise_global_default() {
  local tool="$1" version="$2"
  if [ -n "$MISE_BIN" ] && [ -n "$("$MISE_BIN" ls --global "$tool" 2>/dev/null)" ]; then
    note "$tool already has a global version, kept: $("$MISE_BIN" ls --global "$tool" 2>/dev/null | awk '{print $2}' | head -n 1)"
    return 1
  fi
  run mise use --global "$tool@$version" || die "mise use --global $tool@$version failed."
}

profile_js() {
  step "Profile js: bun + node LTS"
  local added=""
  if mise_global_default node lts; then added="node (LTS)"; fi
  if mise_global_default bun latest; then added="${added:+$added and }bun"; fi
  if [ -n "$added" ]; then
    done_step "$added, global defaults in ~/.config/mise/config.toml"
  else
    skipped_step "node and bun (global versions present, kept)"
  fi
}

profile_python() {
  step "Profile python: uv"
  if command -v uv >/dev/null 2>&1; then
    note "already installed: $(uv --version)"; skipped_step "uv (present, update with: uv self update)"; return 0
  fi
  confirm "Install uv with its official installer (into ~/.local/bin)?" || { skipped_step "uv (declined)"; return 0; }
  run 'curl -LsSf --proto "=https" https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh'
  [ "$DRY_RUN" -eq 1 ] || [ -x "$HOME/.local/bin/uv" ] || die "the uv installer finished but ~/.local/bin/uv is missing."
  done_step "uv (Python is uv's: uv python install, uv init, uv run)"
}

profile_ai() {
  step "Profile ai: d3k (dev3000) + tmux"
  if brew_install tmux; then done_step "tmux (for d3k --with-agent split screen)"; else skipped_step "tmux (present)"; fi
  if ! has_profile js && ! command -v bun >/dev/null 2>&1; then
    note "d3k installs with bun: adding bun through mise"
    mise_global_default bun latest || true
  fi
  if command -v d3k >/dev/null 2>&1; then
    note "already installed: d3k $(d3k --version 2>/dev/null)"; skipped_step "d3k (present, update with: d3k upgrade)"
  else
    run mise exec bun -- bun add --global dev3000
    done_step "d3k (dev3000) in ~/.bun/bin: run it in a project instead of the dev script"
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

next_steps() {
  local next="open a new terminal"
  if has_profile js; then next="$next; in a project: mise use node@22 (pin a runtime)"; fi
  if has_profile python; then next="$next; uv init (Python)"; fi
  if has_profile ai; then next="$next; d3k (dev server for agents)"; fi
  say "Next: $next."
}

main() {
  parse_args "$@"
  preflight
  trap cleanup EXIT

  say "${bold}kifurax macOS dev setup${reset}  ${dim}($ARCH, macOS $(sw_vers -productVersion))${reset}"
  if [ "$DRY_RUN" -eq 1 ]; then note "dry run: commands are printed, nothing is changed"; fi
  fetch_gum
  choose_profiles
  note "profiles:${PROFILES:- none}"

  xcode_clt
  homebrew
  mise_install
  if has_profile js; then profile_js; fi
  if has_profile python; then profile_python; fi
  if has_profile ai; then profile_ai; fi
  if has_profile services; then profile_services; fi
  shell_integration

  step "Summary"
  local done_title="Done:"
  if [ "$DRY_RUN" -eq 1 ]; then done_title="Would do:"; fi
  if [ -n "$DONE_STEPS" ]; then say "$done_title"; printf '%s' "$DONE_STEPS"; fi
  if [ -n "$SKIPPED_STEPS" ]; then say "Already there or skipped:"; printf '%s' "$SKIPPED_STEPS"; fi
  say ""
  next_steps
}

# Sourced by test.sh for its unit tests; run as a script otherwise.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
