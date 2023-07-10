# digitd

A simple daemon for responding with user-supplied information to
[`finger`](https://wikipedia.org/wiki/Finger_(protocol)) requests. Does not run any external
programs but rather reads only specific files from `$HOME/.local/share/digitd/` and responds with
their contents.

## Usage

### Starting the daemon on port 79 (default `fingerd` port)

```bash
$ task build && sudo ./digitd.bin 79
```

## Building/development

If you want debug output or to debug the app, use `task build_debug` instead of `task build`.
The debug level will be set to `Debug` with the former which will make it easier to see what is
happening in the application.

If you want to jump straight into `lldb` after building, use `task debug`. The port for this will
be 1079 instead and this is meant mostly for usage with, for example,
[netcat](https://wikipedia.org/wiki/Netcat), i.e. diagnosis of potential issues and stepping
through what is going on in response to specific requests.

## User information

When a query comes in there are three files that are read for different pieces of information.

### `.local/share/digitd/info`

This file could contain basic information about the user, perhaps where they work and with what.

### `.local/share/digitd/project`

This could contain information about the projects that a user is working on in perhaps a less
fast-moving sense.

### `.local/share/digitd/plan`

This file is meant to contain a user's plan for a shorter timeframe and perhaps more specifically
what they will be doing in terms of their projects or maybe even just life in general. It could
be treated as a journal of sorts.

A good example of this in the context of someone journaling about their work and company is
[John Carmack's plan files at Id Software](https://github.com/ESWAT/john-carmack-plan-archive).
