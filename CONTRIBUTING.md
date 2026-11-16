# Contributing

Bug reports, ideas and pull requests are welcome, in English or Italian. I maintain LiquidMouse in my spare time,
so replies can take a few days.

## Reporting a problem

Use the bug report template: Mac model, macOS version, the LiquidMouse version shown at the bottom of its settings,
the app where it happens and the steps to make it happen again. The system log often helps:

```sh
/usr/bin/log stream --level info --predicate 'subsystem == "io.github.beniaminonardone.LiquidMouse"'
```

## Pull requests

- For anything beyond a small fix, open an issue first, so we can agree on the approach.
- How the cursor looks and moves is a deliberate design: propose a visual change on its own, with a recording.
- One change per pull request, with how you tested it. Run `Scripts/test.sh` first, without touching the mouse
  or keyboard while it runs.
- No external dependencies, and undocumented macOS calls only in `WindowServer.swift`.
- You are responsible for every line you submit, whatever tools helped you write it.

Contributions are released under the project's license, the [GNU GPL version 3](LICENSE).
