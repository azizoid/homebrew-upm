# Contributing

Issues and pull requests are welcome. For a bug report, include your macOS and
Homebrew versions, the command you ran, and the relevant output.
Remove personal information from logs before posting them.

Keep the command compatible with Homebrew's supported Ruby runtime. Add
regression tests for behavior changes and use mocked Homebrew commands so tests
cannot modify installed packages or pins.

Run the test suite before submitting a pull request:

```sh
brew ruby test/test_upm.rb
```

Your personal package list belongs in your configuration directory, outside
this repository. Update the README when changing command behavior.
