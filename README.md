# ghostty
Example plugin for fizzy adding a ghostty terminal to the bottom panel

## `terminal.run`

Other plugins run a program in a terminal the person types into through the internal command
`terminal.run` (the chat's terminal sign-in, `claude /login`, is one). Its arguments, as ZON:
`.{ .title, .argv, .env = .{ .{ .name, .value } }, .cwd, .done, .tag }`. The program runs in a
pane of its own in the bottom panel, in `cwd` (empty: the project folder), over fizzy's
environment with the login shell's `PATH` plus `env`. When it exits, `terminal.run` calls the
command `done` with `.{ .tag, .code }`; the pane stays, showing the exit code, until the person
closes it. A caller checks `host.hasCommand("terminal.run")` before offering anything that needs
it. The contract is `src/launch.zig`.
