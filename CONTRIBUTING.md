# Contributing

Issues and pull requests are welcome. For a bug report, include your macOS,
Homebrew, and Python versions, the command you ran, and the relevant output.
Remove personal information from logs before posting them.

Keep changes compatible with Python 3.9 and the standard library. Add regression
tests for behavior changes and use mocked Homebrew commands so tests cannot
modify installed packages or pins.

Run the test suite before submitting a pull request:

```sh
python3 -m unittest -v
```

Your personal package list belongs in your configuration directory, outside
this repository. Update the README when changing command behavior.
