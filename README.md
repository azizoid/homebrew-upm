# brew upm

[![Tests](https://github.com/azizoid/brew-upm/actions/workflows/tests.yml/badge.svg)](https://github.com/azizoid/brew-upm/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Upgrade your Homebrew packages. Skip patch updates for the ones on your list.

```sh
brew upm                         # refresh metadata, then upgrade
brew upm add docker-desktop wget  # skip these packages' patch updates
brew upm list
brew upm remove wget
brew upm --dry-run               # preview; no metadata or package changes
```

Unlisted formulae and casks upgrade normally. Listed packages upgrade when their
major or minor version increases: `4.93.0 → 4.94.0` qualifies;
`4.93.0 → 4.93.1` does not. A qualifying upgrade installs Homebrew's latest
version, including its patches.

## Install

Requires macOS, a recent Homebrew with cask pin support, and Python 3.9 or newer.
No Python dependencies. `upm` is a custom Homebrew command.

Clone the repository and link the command into Homebrew's existing `PATH`:

```sh
git clone https://github.com/azizoid/brew-upm.git
cd brew-upm
ln -s "$PWD/brew-upm" "$(brew --prefix)/bin/brew-upm"
brew upm add docker-desktop
brew upm --dry-run
```

Homebrew exposes executables named `brew-NAME` on `PATH` as `brew NAME`.
Alternatively add this repository's directory to `PATH`.

To update the tool, run `git pull --ff-only` from its clone. To uninstall,
remove the `brew-upm` symlink from `$(brew --prefix)/bin`. Your package list
stays in your configuration directory.

## Your list

The list lives outside the repository at `~/.config/brew-upm/packages.txt`.
`XDG_CONFIG_HOME` changes the config root; `BREW_UPM_CONFIG` overrides the file.
Fresh installations start with an empty list. `packages.example.txt` shows the
format, with optional comments and one `formula:name` or `cask:name` per line.

`add` accepts installed Homebrew names and stores their package type. If a name
matches both types, use `brew upm add cask:name` or `formula:name`.
`remove` also works after a package has been uninstalled. Formulae from third
party taps retain their full names. Existing Homebrew pins remain in effect;
unpin a package if you want this tool to manage its updates.

## Version and dependency behavior

Listed packages must have numeric versions with at least major and minor
components. Patch/build components, Homebrew `_revision` suffixes, and
comma-suffixed app build numbers do not trigger an upgrade. Prereleases and
unknown versions are skipped with an explanation. When Homebrew reports
multiple installed versions, the newest is used for comparison.
Listed packages skip every patch release, including security fixes, until a
major or minor update is available.

Homebrew's normal cask eligibility applies: this does not force upgrades of
apps with their own updater or `latest` versions. Apps can still update
themselves outside Homebrew.

Skipped outdated packages are temporarily pinned while eligible upgrades run,
so automatic dependency or dependent upgrades cannot silently bypass the list.
If another package requires a skipped dependency's newer version, Homebrew
rejects that upgrade. Earlier upgrades may already have completed; resolve the
dependency or remove it from the list and rerun. Original pins are preserved;
temporary pins are removed on success, failure, Ctrl-C, and SIGTERM.
Avoid running other Homebrew upgrades at the same time.

After a forced kill or power loss, temporary pins may remain. Check
`brew list --pinned` and unpin affected packages with `brew unpin --formula NAME`
or `brew unpin --cask NAME`. Concurrent `upm` upgrade runs using the same config
are prevented. Plain `brew upgrade` ignores this tool's list.

## Development

```sh
python3 -m unittest -v
```

Tests mock Homebrew: they never install, upgrade, pin, or unpin real packages.
See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines.

## License

[MIT](LICENSE) © 2026 azizoid.
