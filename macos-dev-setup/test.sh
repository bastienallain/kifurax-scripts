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
[ "$1" = "list" ] && exit 1
[ "$1" = "install" ] && exit 1
EOF
chmod +x "$stubs/brew"
out=$(PATH="$stubs:$PATH" in_script 'DRY_RUN=0; if brew_install tmux; then echo installed; else echo present; fi')
check "failed brew install stops the run" grep -q "brew install tmux failed" <<<"$out"
check "failed brew install is not reported as present" eval '! grep -q present <<<"$out"'

cat > "$SANDBOX/fake-mise" <<'EOF'
#!/bin/bash
[ "$1" = "ls" ] && [ "$3" = "node" ] && echo "node  22.1.0  ~/.config/mise/config.toml  22"
exit 0
EOF
chmod +x "$SANDBOX/fake-mise"
out=$(in_script "DRY_RUN=1; MISE_BIN='$SANDBOX/fake-mise'; mise_global_default node lts; echo rc=\$?; mise_global_default bun latest; echo rc=\$?")
check "existing global node pin is kept" grep -q "rc=1" <<<"$out"
check "missing global bun is set" grep -q 'mise use --global bun@latest' <<<"$out"
check "kept pin is never overwritten" eval '! grep -q "mise use --global node@lts" <<<"$out"'

out=$(in_script "DRY_RUN=1; NO_SHELL=0; BREW_PREFIX=/opt/homebrew; PROFILES=js; MISE_BIN=/opt/homebrew/bin/mise; login_shell() { echo zsh; }; shell_integration")
check "shell block uses the mise that exists" grep -q '/opt/homebrew/bin/mise activate zsh' <<<"$out"
out=$(in_script "DRY_RUN=1; NO_SHELL=0; BREW_PREFIX=/opt/homebrew; PROFILES=ai; MISE_BIN=''; login_shell() { echo fish; }; shell_integration")
check "no mise, no mise line" eval '! grep -q "mise activate" <<<"$out"'
check "ai profile puts ~/.bun/bin on PATH" grep -q 'fish_add_path -g $HOME/.bun/bin' <<<"$out"

out=$(in_script 'PROFILES=""; next_steps; echo rc=$?')
check "next steps succeeds with no profile" grep -q "rc=0" <<<"$out"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
