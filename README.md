# rex-scripts

Lua scripts for [Rex](https://www.superlogical.com/rex), the terminal.

## agent-resume.lua

When the Rex server updates or restarts, your tabs stay open but the coding
agents in them exit, leaving each pane at a bare shell. `claude --continue`
only brings back the newest session in a folder, so tabs that shared a folder
lose track of which session was theirs.

This script remembers which agent session each pane was running. After a
restart it types the resume command back into each pane, so every tab gets
its own session again. It works with [Claude Code](https://claude.com/claude-code)
and [pi](https://github.com/badlogic/pi-mono).

Tested on macOS with Rex 0.1.0-preview.22.

### What it does

1. While an agent runs, it reports its status to Rex. On each report the
   script looks up the agent's session ID and saves the pane, session and
   folder to `~/.config/rex/agent-sessions.json`. On startup it also scans
   every pane, so idle agents are saved too.
2. When the script starts on a new server instance, it waits for each saved
   pane's shell to come back (up to a minute), then types one of these:
   ```
   cd -- '<folder>' && claude --resume <id> --permission-mode <mode> '<prompt>'
   cd -- '<folder>' && pi --session <id> '<prompt>'
   ```
   Panes running anything other than a plain shell are left alone.
3. The prompt tells the agent it was resumed after a restart. It finishes a
   turn that was cut off and restarts any background tasks, subagents or
   monitors it still needs. If nothing was running, it replies in one line.

Claude Code keeps `~/.claude/sessions/<pid>.json`, so its session ID is
exact. Its `--permission-mode` and `--dangerously-skip-permissions` flags
are read from the process and kept. Pi has no file per process, so the
script takes the newest session in the pane's folder. Two pi agents in the
same folder can get each other's session.

### Install

Copy the script:

```sh
mkdir -p ~/.config/rex/logs
cp agent-resume.lua ~/.config/rex/
```

Add this to `~/.config/rex/init.lua`. It starts the script whenever the
config loads, including after a server restart, unless it's already running:

```lua
do
  local dir = os.getenv("HOME") .. "/.config/rex"
  -- The server's PATH has no rex, so use the app bundle path.
  -- Versions/Current follows updates.
  local rex_bin = os.getenv("HOME") .. "/Library/Application Support/com.superlogical.rex"
    .. "/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  local r = rex.exec{ "pgrep", "-f", "rex do " .. dir .. "/agent-resume.lua" }
  if not (r and r.ok) then
    rex.exec.start(
      { "/bin/sh", "-c", 'exec "$0" do "$1" --all >>"$2" 2>&1',
        rex_bin, dir .. "/agent-resume.lua", dir .. "/logs/agent-resume.lua.log" },
      { detach = true })
  end
end
```

Then reload:

```sh
rex config reload
```

### Check it

See what it would type, without typing anything:

```sh
rex do ~/.config/rex/agent-resume.lua --all dry=true --for 5s
```

Only panes at a plain shell show up, so with every agent running this prints
nothing. After a real restart, `~/.config/rex/logs/agent-resume.lua.log` has
one line per pane, `resumed` or `skipped`.

To load a new version of the script, stop it and reload the config:

```sh
pkill -f '[a]gent-resume.lua'
rex config reload
```

### Limits

- An agent's in-flight turn and anything typed but not sent are lost. The
  prompt asks the agent to pick the turn back up from its transcript.
- Background tasks, subagents and monitors die with the old process. The
  agent can only restart the ones it can see in its own transcript.
- Rex is in preview, and the Lua API may change.

## License

MIT
