# brew upm

[![Tests](https://github.com/azizoid/homebrew-upm/actions/workflows/tests.yml/badge.svg)](https://github.com/azizoid/homebrew-upm/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Upgrade your Homebrew packages. Skip patch updates for the ones on your list.

```sh
brew upm                         # refresh metadata, then upgrade
brew upm add docker-desktop wget  # skip these packages' patch updates
brew upm list
brew upm remove wget
brew upm recover                # inspect pins after a forced interruption
brew upm --dry-run               # preview; no metadata or package changes
```

For example, add Docker Desktop and let `upm` defer a patch download:

```sh
brew upm add docker-desktop
brew upm
```

Illustrative version policy (not literal command output):

```text
4.93.0 → 4.93.1  skip
4.93.0 → 4.94.0  upgrade
```

Unlisted formulae and casks upgrade normally. Listed packages upgrade when their
major or minor version increases: `4.93.0 → 4.94.0` qualifies;
`4.93.0 → 4.93.1` does not. A qualifying upgrade installs Homebrew's latest
version, including its patches.

## Why

Some desktop apps are 500–700 MB and publish updates frequently, sometimes
daily. If every release is treated as an update, `brew upgrade` can repeatedly
download a large app just to apply a patch. Homebrew's built-in `brew pin` avoids
those downloads by skipping the package entirely, but then it also skips minor
and major updates. `brew upm` lets you defer patch releases for selected apps
while continuing to update everything else. Those apps still receive all
patches—including security fixes—when a major or minor update becomes available.

## Install

Requires macOS and Homebrew 5.1.12 or newer. `upm` is a native Ruby Homebrew
external command; it uses Homebrew's Ruby runtime and has no separate language
or package dependencies.

Add the tap, trust just this command, then add the packages you want the policy
to cover:

```sh
brew tap azizoid/upm && brew trust --command azizoid/upm/upm
brew upm add docker-desktop
brew upm --dry-run
```

Homebrew automatically updates the tap when you run `brew update`. The trust
command authorizes only `upm` from this tap. Review the command source before
trusting it; command trust authorizes execution but is not an official Homebrew
audit. To uninstall the command, run
`brew untap azizoid/upm`. Your package list stays in your configuration
directory.

## Your list

The list lives outside the repository at `~/.config/brew-upm/packages.txt`.
`HOMEBREW_XDG_CONFIG_HOME` changes the config root; `HOMEBREW_UPM_CONFIG`
overrides the file. Homebrew preserves these `HOMEBREW_*` variables when it
starts the command.
Fresh installations start with an empty list. `packages.example.txt` shows the
format, with optional comments and one `formula:name` or `cask:name` per line.

`add` accepts installed Homebrew names and stores their package type. If a name
matches both types, use `brew upm add cask:name` or `formula:name`. If the
package exists in Homebrew but is not installed, UPM tells you how to install
it before adding it. If Homebrew cannot find it, check the name with
`brew search NAME` or add the tap that provides it.
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

If the process is forcibly killed or the machine loses power while temporary
pins are active, the tool keeps a recovery journal and blocks further operations
until you run `brew upm recover`. Because Homebrew does not record which process
created a pin, recovery will not unpin packages automatically: it lists any
remaining pins and gives you the exact `brew unpin` commands. Review them, run
only the commands you want, then run `brew upm recover` again to clear the journal.
The tool serializes its own operations across config files; avoid running other
Homebrew commands that change pins or upgrades at the same time. Plain
`brew upgrade` ignores this tool's list.

## Development

```sh
ruby -Ilib test/test_upm.rb
```

Tests mock Homebrew: they never install, upgrade, pin, or unpin real packages.
See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines.

## License

[MIT](LICENSE) © 2026 azizoid.
