# kifurax-scripts

The scripts from the posts on [kifurax.com](https://www.kifurax.com), one
folder per post. Each script is explained line by line in its post, runs
with `--dry-run` first, and is checked in CI on every push.

| Script | Post | What it does |
|---|---|---|
| [`macos-dev-setup/install.sh`](macos-dev-setup/) | [My macOS setup: Homebrew, mise and uv, one job each](https://www.kifurax.com/web-tooling/macos-brew-mise-uv) | Sets up a Mac for development: Homebrew for the machine, mise for runtimes, uv for Python, with optional profiles |

## Running a script safely

Read it, then run it with `--dry-run`: it prints every command and changes
nothing. Only then run it for real.

```sh
git clone https://github.com/bastienallain/kifurax-scripts
cd kifurax-scripts/macos-dev-setup
./install.sh --dry-run
./install.sh
```

MIT licensed.
