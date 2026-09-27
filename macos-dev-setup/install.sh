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
#   ./install.sh --reinstall      reinstall what is already there, no questions
#                                 (Homebrew: brew update; Xcode CLT: kept)
#
# Profiles (the base always runs: Xcode Command Line Tools, Homebrew, mise):
#   js        bun and node (LTS) through mise
#   python    uv from its official installer (uv owns Python, not mise)
#   ai        dev3000 (d3k) and tmux, for agents that read logs and console
#   services  PostgreSQL 18 + pgvector, colima + Docker CLI, cloudflared
#             (installed, never started at boot)
#
# Safe to run again: a scan lists what is already there, and each installed
# tool is skipped unless you answer y to [y/N] (reinstall; for Homebrew,
# brew update). The Xcode Command Line Tools are never reinstalled.
# Written for the bash 3.2 that ships with macOS, so it runs on a new Mac.

set -eu -o pipefail

DRY_RUN=0
ASSUME_YES=0
NO_SHELL=0
REINSTALL=0
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
BREW_FORMULAE=""
SERVICES_FORMULAE="postgresql@18 pgvector colima docker docker-compose cloudflared"
STEP_NO=0
STEP_TOTAL=0

# -- output -------------------------------------------------------------------

bold=""; dim=""; coral=""; reset=""
if [ -t 1 ]; then
  bold=$(printf '\033[1m'); dim=$(printf '\033[2m'); coral=$(printf '\033[38;2;255;99;99m'); reset=$(printf '\033[0m')
fi
say()  { printf '%s\n' "$*"; }
header() { printf '\n%s==>%s %s%s%s\n' "$coral" "$reset" "$bold" "$*" "$reset"; }
step() {
  STEP_NO=$((STEP_NO + 1))
  printf '\n%s[%d/%d]%s %s%s%s\n' "$coral" "$STEP_NO" "$STEP_TOTAL" "$reset" "$bold" "$*" "$reset"
}
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
  # The header comment, up to the first line that is not one.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
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
      --reinstall) REINSTALL=1 ;;
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
  if [ "$ARCH" = "arm64" ]; then BREW_PREFIX="/opt/homebrew"; else BREW_PREFIX="/usr/local"; fi
  if [ ! -x "$BREW_PREFIX/bin/brew" ]; then
    case " $(id -Gn) " in *" admin "*) ;; *) die "installing Homebrew needs an admin account; $(id -un) is not in the admin group." ;; esac
  fi
  # Tools from the official installers, mise shims and bun globals, callable
  # for this run even before a new terminal loads the shell block.
  export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$BUN_GLOBAL_BIN:$PATH"
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

# confirm QUESTION DEFAULT: 0 yes, 1 no; DEFAULT (yes|no) is what Enter picks.
# --yes answers yes. Ctrl-C or Esc in gum aborts the run instead of reading
# as "no"; any other gum failure falls back to the plain prompt.
confirm() {
  local question="$1" default="${2:-yes}" status=0 hint answer
  [ "$ASSUME_YES" -eq 1 ] && return 0
  if [ -n "$GUM" ]; then
    if [ "$default" = "yes" ]; then "$GUM" confirm --default=true "$question" || status=$?
    else "$GUM" confirm --default=false "$question" || status=$?
    fi
    case "$status" in
      0|1) return "$status" ;;
      130) die "cancelled." ;;
    esac
  fi
  if [ "$default" = "yes" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf '%s %s ' "$question" "$hint"
  read -r answer </dev/tty || answer=""
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    n|N|no|NO) return 1 ;;
    "") [ "$default" = "yes" ] ;;
    *) return 1 ;;
  esac
}

# For a tool that is already there: N unless the user says y. --reinstall
# answers y, --yes alone keeps the default (skip).
ask_reinstall() {
  [ "$REINSTALL" -eq 1 ] && return 0
  [ "$ASSUME_YES" -eq 1 ] && return 1
  confirm "$1" no
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

# -- scan ---------------------------------------------------------------------
# What is already on the machine, checked once before anything runs. Every
# step reuses these checks: present means skipped unless you answer y.

has_xcode() { xcode-select -p >/dev/null 2>&1; }
has_brew()  { [ -x "$BREW_PREFIX/bin/brew" ]; }
has_uv()    { command -v uv >/dev/null 2>&1; }
has_d3k()   { command -v d3k >/dev/null 2>&1; }

# One `brew list` for the whole run instead of one per formula.
load_brew_formulae() {
  BREW_FORMULAE=""
  if has_brew; then BREW_FORMULAE=$("$BREW_PREFIX/bin/brew" list --formula -1 2>/dev/null) || BREW_FORMULAE=""; fi
}
brew_has() { case "
$BREW_FORMULAE
" in *"
$1
"*) return 0 ;; *) return 1 ;; esac; }

# mise can come from its installer (~/.local/bin) or from Homebrew: the shell
# block must point at the one that exists, not assume the installer's path.
find_mise() {
  if [ -x "$HOME/.local/bin/mise" ]; then MISE_BIN="$HOME/.local/bin/mise"
  elif command -v mise >/dev/null 2>&1; then MISE_BIN=$(command -v mise)
  else MISE_BIN=""
  fi
}

# True when the global mise config asks for $1@$2 and that version is installed.
mise_tool_ok() {
  local cfg="${MISE_GLOBAL_CONFIG_FILE:-$HOME/.config/mise/config.toml}"
  [ -n "$MISE_BIN" ] || return 1
  [ "$("$MISE_BIN" config get -f "$cfg" "tools.$1" 2>/dev/null)" = "$2" ] || return 1
  "$MISE_BIN" where "$1@$2" >/dev/null 2>&1
}

scan_line() {
  if [ "$2" = "missing" ]; then
    printf '    %-16s %s%-30s%s %s\n' "$1" "$coral" "missing" "$reset" "install"
  else
    printf '    %-16s %-30s %s%s%s\n' "$1" "$2" "$dim" "$3" "$reset"
  fi
}

scan() {
  header "Scan"
  local f
  if has_xcode; then scan_line "Xcode CLT" "installed" "kept"; else scan_line "Xcode CLT" missing; fi
  if has_brew; then scan_line "Homebrew" "$("$BREW_PREFIX/bin/brew" --version 2>/dev/null | head -n 1)" "y: brew update"; else scan_line "Homebrew" missing; fi
  if [ -n "$MISE_BIN" ]; then scan_line "mise" "$("$MISE_BIN" --version 2>/dev/null | awk '{print $1}')" "y: reinstall"; else scan_line "mise" missing; fi
  if has_profile js; then
    if mise_tool_ok node lts; then scan_line "node" "lts" "y: reinstall"; else scan_line "node" missing; fi
    if mise_tool_ok bun latest; then scan_line "bun" "latest" "y: reinstall"; else scan_line "bun" missing; fi
  fi
  if has_profile python; then
    if has_uv; then scan_line "uv" "$(uv --version 2>/dev/null | awk '{print $2}')" "y: reinstall"; else scan_line "uv" missing; fi
  fi
  if has_profile ai; then
    if brew_has tmux; then scan_line "tmux" "installed" "y: reinstall"; else scan_line "tmux" missing; fi
    if has_d3k; then scan_line "d3k" "$(d3k --version 2>/dev/null)" "y: reinstall"; else scan_line "d3k" missing; fi
  fi
  if has_profile services; then
    for f in $SERVICES_FORMULAE; do
      if brew_has "$f"; then scan_line "$f" "installed" "y: reinstall"; else scan_line "$f" missing; fi
    done
  fi
  if [ "$REINSTALL" -eq 1 ]; then note "--reinstall: every installed tool is reinstalled (Homebrew: brew update)"; fi
}

# -- base ---------------------------------------------------------------------

xcode_clt() {
  step "Xcode Command Line Tools"
  if has_xcode; then
    # Reinstalling means deleting /Library/Developer/CommandLineTools as root
    # and going through Apple's window again: never worth it from here.
    note "already installed: $(xcode-select -p), kept"; skipped_step "Xcode CLT (present, kept)"; return 0
  fi
  confirm "Install Apple's Command Line Tools (compilers, git)?" yes || die "Homebrew needs the Command Line Tools."
  run xcode-select --install
  [ "$DRY_RUN" -eq 1 ] || die "finish the Command Line Tools installer window, then run this script again."
}

homebrew() {
  step "Homebrew"
  if has_brew; then
    # Reinstalling Homebrew would drop every formula: y updates it instead.
    note "already installed: $("$BREW_PREFIX/bin/brew" --version 2>/dev/null | head -n 1)"
    if ask_reinstall "Homebrew is installed. Update it (brew update)?"; then
      run "$BREW_PREFIX/bin/brew" update || die "brew update failed."
      done_step "Homebrew updated"
    else
      skipped_step "Homebrew (present)"
    fi
  else
    confirm "Install Homebrew with its official installer (asks for your password)?" yes || die "the rest needs Homebrew."
    if [ "$ASSUME_YES" -eq 1 ]; then
      # The installer stops on "Press RETURN" unless NONINTERACTIVE is set,
      # and in that mode it needs sudo already unlocked: ask once, up front.
      run sudo -v
      run 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    else
      run '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    fi
    [ "$DRY_RUN" -eq 1 ] || has_brew || die "the Homebrew installer finished but $BREW_PREFIX/bin/brew is missing."
    done_step "Homebrew"
  fi
  if has_brew; then eval "$("$BREW_PREFIX/bin/brew" shellenv)"; fi
  load_brew_formulae
}

# Install the missing formulae; offer to reinstall the ones already there.
brew_formulae() {
  local label="$1" missing="" present="" f
  shift
  for f in "$@"; do
    if brew_has "$f"; then present="$present $f"; else missing="$missing $f"; fi
  done
  if [ -n "$missing" ]; then
    run brew install"$missing" || die "brew install$missing failed."
    done_step "$label:$missing"
  fi
  if [ -n "$present" ]; then
    note "already installed:$present"
    if ask_reinstall "Reinstall$present?"; then
      run brew reinstall"$present" || die "brew reinstall$present failed."
      done_step "$label reinstalled:$present"
    else
      skipped_step "$label (present:$present)"
    fi
  fi
}

mise_install() {
  step "mise"
  if [ -n "$MISE_BIN" ]; then
    note "already installed: $("$MISE_BIN" --version 2>/dev/null) ($MISE_BIN)"
    if ask_reinstall "mise is installed. Reinstall it?"; then
      case "$MISE_BIN" in
        "$HOME/.local/bin/mise") run 'curl -fsSL --proto "=https" https://mise.run | sh' || die "the mise installer failed." ;;
        "$BREW_PREFIX"/*) run brew reinstall mise || die "brew reinstall mise failed." ;;
        *) die "mise at $MISE_BIN comes from neither its installer nor Homebrew: reinstall it the way you installed it." ;;
      esac
      done_step "mise reinstalled"
    else
      skipped_step "mise (present)"
    fi
    return 0
  fi
  confirm "Install mise with its official installer (into ~/.local/bin, outside Homebrew)?" yes || {
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
}

# -- profiles -----------------------------------------------------------------

# node on LTS, bun on latest, as global defaults. Projects pin their own
# versions in mise.toml.
profile_js() {
  step "Profile js: bun + node LTS"
  if mise_tool_ok node lts && mise_tool_ok bun latest; then
    note "already installed: node (lts) and bun (latest)"
    if ask_reinstall "Reinstall node (lts) and bun (latest)?"; then
      run mise install --force node@lts bun@latest || die "mise install --force node@lts bun@latest failed."
      done_step "node (lts) and bun (latest) reinstalled"
    else
      skipped_step "node and bun (present)"
    fi
    return 0
  fi
  run mise use --global node@lts bun@latest || die "mise use --global node@lts bun@latest failed."
  done_step "node (LTS) and bun (latest), global defaults in ~/.config/mise/config.toml"
}

profile_python() {
  step "Profile python: uv"
  if has_uv; then
    note "already installed: $(uv --version)"
    if ask_reinstall "uv is installed. Reinstall it?"; then
      run 'curl -LsSf --proto "=https" https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh' || die "the uv installer failed."
      done_step "uv reinstalled"
    else
      skipped_step "uv (present)"
    fi
    return 0
  fi
  confirm "Install uv with its official installer (into ~/.local/bin)?" yes || { skipped_step "uv (declined)"; return 0; }
  run 'curl -LsSf --proto "=https" https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh'
  [ "$DRY_RUN" -eq 1 ] || [ -x "$HOME/.local/bin/uv" ] || die "the uv installer finished but ~/.local/bin/uv is missing."
  done_step "uv (Python is uv's: uv python install, uv init, uv run)"
}

profile_ai() {
  step "Profile ai: d3k (dev3000) + tmux"
  brew_formulae "tmux" tmux
  if ! has_profile js && ! command -v bun >/dev/null 2>&1; then
    note "d3k installs with bun: adding bun through mise"
    run mise use --global bun@latest || die "mise use --global bun@latest failed."
  fi
  if has_d3k; then
    note "already installed: d3k $(d3k --version 2>/dev/null)"
    if ask_reinstall "d3k is installed. Reinstall it?"; then
      run mise exec bun -- bun add --global dev3000 || die "bun add --global dev3000 failed."
      done_step "d3k reinstalled"
    else
      skipped_step "d3k (present)"
    fi
    return 0
  fi
  run mise exec bun -- bun add --global dev3000 || die "bun add --global dev3000 failed."
  done_step "d3k (dev3000) in ~/.bun/bin: run it in a project instead of the dev script"
}

profile_services() {
  step "Profile services: Postgres 18 + pgvector, colima + Docker, cloudflared"
  # shellcheck disable=SC2086 # one word per formula
  brew_formulae "services" $SERVICES_FORMULAE
  note "nothing is started. When a project needs them:"
  note "  brew services start postgresql@18    colima start    cloudflared tunnel --url http://localhost:4321"
  note "docker compose: see 'brew info docker-compose' for the one-line plugin setting"
}

# -- main ---------------------------------------------------------------------

next_steps() {
  local next="open a new terminal"
  if has_profile js; then next="$next; in a project: mise use node@lts (pin a runtime)"; fi
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

  # Xcode CLT, Homebrew, mise, shell integration, then one step per profile.
  local p
  STEP_TOTAL=4
  for p in $PROFILES; do STEP_TOTAL=$((STEP_TOTAL + 1)); done

  if has_brew; then eval "$("$BREW_PREFIX/bin/brew" shellenv)"; fi
  load_brew_formulae
  find_mise
  scan

  xcode_clt
  homebrew
  mise_install
  if has_profile js; then profile_js; fi
  if has_profile python; then profile_python; fi
  if has_profile ai; then profile_ai; fi
  if has_profile services; then profile_services; fi
  shell_integration

  header "Summary"
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
