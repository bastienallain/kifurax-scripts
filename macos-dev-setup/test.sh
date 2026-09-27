#!/bin/bash
# Tests for install.sh: runs the real script in dry-run mode, and sources it to
# exercise its functions against a throwaway HOME and stub commands.
# Usage: ./test.sh   (macOS, bash 3.2)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$HERE/install.sh"
PASSED=0
FAILED=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

ok()   { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }

# Run a snippet in a fresh bash that sourced install.sh, with HOME in the sandbox.
in_script() {
  local home="$SANDBOX/home.$RANDOM"
  mkdir -p "$home"
  HOME="$home" /bin/bash -c "source '$SCRIPT'; set +e; $1" 2>&1
}

count_lines() { grep -c -- "$1" "$2" || true; }

echo "install.sh"

# -- the script as a whole ----------------------------------------------------

/bin/bash "$SCRIPT" --dry-run --yes --no-shell --profiles=js,python,ai,services >/dev/null 2>&1
check "dry run exits 0" [ $? -eq 0 ]

out=$(/bin/bash "$SCRIPT" --dry-run --yes --profiles=javascript 2>&1)
check "unknown profile is refused" [ $? -ne 0 ]
check "unknown profile names the typo" grep -q "unknown profile: javascript" <<<"$out"

/bin/bash "$SCRIPT" --bogus >/dev/null 2>&1
check "unknown option is refused" [ $? -ne 0 ]

# -- write_block --------------------------------------------------------------

rc="$SANDBOX/rc"
printf 'alias ll="ls -l"\n' > "$rc"
out=$(in_script "DRY_RUN=0; write_block '$rc' 'line one'; write_block '$rc' 'line one'")
check "block written once after two runs" [ "$(count_lines 'kifurax-scripts macos-dev-setup >>>' "$rc")" -eq 1 ]
check "content outside the block kept" grep -q 'alias ll=' "$rc"
check "second run reports unchanged" grep -q "unchanged" <<<"$out"
check "backup made on first change" [ -f "$rc.kifurax.bak" ]

in_script "DRY_RUN=0; write_block '$rc' 'line two'" >/dev/null
check "block body replaced in place" [ "$(count_lines 'line' "$rc")" -eq 1 ]
check "backup keeps the original file" [ "$(cat "$rc.kifurax.bak")" = 'alias ll="ls -l"' ]

target="$SANDBOX/dotfiles-zshrc"
link="$SANDBOX/zshrc-link"
printf 'export EDITOR=vim\n' > "$target"
ln -s "$target" "$link"
in_script "DRY_RUN=0; write_block '$link' 'body'" >/dev/null
check "symlinked rc file stays a symlink" [ -L "$link" ]
check "symlink target gets the block" grep -q 'body' "$target"

before=$(cat "$rc")
in_script "DRY_RUN=1; write_block '$rc' 'other body'" >/dev/null
check "dry run leaves rc file alone" [ "$(cat "$rc")" = "$before" ]

# -- profiles and helpers -----------------------------------------------------

out=$(in_script 'PROFILES="js ai"; has_profile ai && echo yes; has_profile python || echo no; has_profile j || echo partial-no')
check "has_profile matches whole names" [ "$out" = "yes
no
partial-no" ]

stubs="$SANDBOX/bin"
mkdir -p "$stubs"
cat > "$stubs/brew" <<'EOF'
#!/bin/bash
[ "$1" = "install" ] && exit 1
exit 0
EOF
chmod +x "$stubs/brew"
out=$(PATH="$stubs:$PATH" in_script 'DRY_RUN=0; BREW_FORMULAE=""; brew_formulae tmux tmux; echo reached')
check "failed brew install stops the run" grep -q "brew install tmux failed" <<<"$out"
check "failed brew install is not reported as done" eval '! grep -q reached <<<"$out"'

out=$(in_script 'DRY_RUN=1; ASSUME_YES=1; BREW_FORMULAE="git
tmux"; brew_formulae tmux tmux colima; printf "%s" "$DONE_STEPS$SKIPPED_STEPS"')
check "brew_has matches a whole formula name" eval '! grep -q "brew install tmux" <<<"$out"'
check "missing formula is installed" grep -q 'brew install colima' <<<"$out"
check "--yes skips what is installed" grep -q 'tmux (present: tmux)' <<<"$out"
check "--yes never reinstalls" eval '! grep -q "brew reinstall" <<<"$out"'

out=$(in_script 'DRY_RUN=1; REINSTALL=1; BREW_FORMULAE="tmux"; brew_formulae tmux tmux')
check "--reinstall reinstalls what is installed" grep -q 'brew reinstall tmux' <<<"$out"

prefix="$SANDBOX/brewprefix"
mkdir -p "$prefix/bin"
cat > "$prefix/bin/brew" <<'EOF'
#!/bin/bash
[ "$1" = "--version" ] && echo "Homebrew 9.9.9"
exit 0
EOF
chmod +x "$prefix/bin/brew"
out=$(in_script "DRY_RUN=1; REINSTALL=1; BREW_PREFIX='$prefix'; homebrew")
check "installed Homebrew is updated, not reinstalled" grep -q "$prefix/bin/brew update" <<<"$out"
check "installed Homebrew never runs its installer" eval '! grep -q "Homebrew/install" <<<"$out"'
out=$(in_script "DRY_RUN=1; ASSUME_YES=1; BREW_PREFIX='$prefix'; homebrew")
check "--yes leaves Homebrew as is" eval '! grep -q "brew update" <<<"$out"'

cat > "$stubs/xcode-select" <<'EOF'
#!/bin/bash
[ "$1" = "-p" ] && echo /Library/Developer/CommandLineTools
exit 0
EOF
chmod +x "$stubs/xcode-select"
out=$(PATH="$stubs:$PATH" in_script 'DRY_RUN=1; REINSTALL=1; xcode_clt')
check "Xcode CLT is kept even with --reinstall" eval '! grep -q "xcode-select --install" <<<"$out"'

cat > "$SANDBOX/fake-mise" <<'EOF'
#!/bin/bash
case "$1" in
  config) case "$5" in tools.node) echo lts ;; tools.bun) echo latest ;; *) exit 1 ;; esac ;;
  where) exit 0 ;;
esac
exit 0
EOF
chmod +x "$SANDBOX/fake-mise"
out=$(in_script "DRY_RUN=1; ASSUME_YES=1; MISE_BIN='$SANDBOX/fake-mise'; profile_js")
check "node lts and bun latest in place: skipped" eval '! grep -q "mise use" <<<"$out"'
out=$(in_script "DRY_RUN=1; REINSTALL=1; MISE_BIN='$SANDBOX/fake-mise'; profile_js")
check "--reinstall forces node and bun" grep -q 'mise install --force node@lts bun@latest' <<<"$out"
out=$(in_script "DRY_RUN=1; profile_js")
check "js profile sets node lts and bun latest" grep -q 'mise use --global node@lts bun@latest' <<<"$out"

out=$(in_script 'STEP_TOTAL=2; step one; step two')
check "steps are numbered" eval 'grep -q "\[1/2\] one" <<<"$out" && grep -q "\[2/2\] two" <<<"$out"'

out=$(PATH="$stubs:$PATH" in_script "PROFILES='ai services'; BREW_PREFIX='$prefix'; BREW_FORMULAE='tmux'; scan")
check "scan lists an installed formula" grep -q 'tmux .*installed' <<<"$out"
check "scan lists a missing formula" grep -q 'colima .*missing' <<<"$out"
check "scan shows Homebrew's version" grep -q 'Homebrew 9.9.9' <<<"$out"

out=$(in_script "DRY_RUN=1; NO_SHELL=0; BREW_PREFIX=/opt/homebrew; PROFILES=js; MISE_BIN=/opt/homebrew/bin/mise; login_shell() { echo zsh; }; shell_integration")
check "shell block uses the mise that exists" grep -q '/opt/homebrew/bin/mise activate zsh' <<<"$out"
out=$(in_script "DRY_RUN=1; NO_SHELL=0; BREW_PREFIX=/opt/homebrew; PROFILES=ai; MISE_BIN=''; login_shell() { echo fish; }; shell_integration")
check "no mise, no mise line" eval '! grep -q "mise activate" <<<"$out"'
check "ai profile puts ~/.bun/bin on PATH" grep -q 'fish_add_path -g $HOME/.bun/bin' <<<"$out"

out=$(in_script 'PROFILES=""; next_steps; echo rc=$?')
check "next steps succeeds with no profile" grep -q "rc=0" <<<"$out"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
