-- agent-resume.lua: bring Claude Code or pi back into its tab after Rex restarts.
--
-- Run:   rex do ~/.config/rex/agent-resume.lua --all   (init.lua starts it)
-- Test:  rex do ~/.config/rex/agent-resume.lua --all dry=true --for 5s
--
-- While an agent runs in a pane, it reports program status to Rex. On each
-- report this script looks up the session ID (see FIND below)
-- and saves block -> {session, cwd} to agent-sessions.json.
--
-- When the script starts on a new server instance (a Rex update or restart),
-- it types the resume command into every saved pane whose foreground is a
-- plain shell again. Panes running anything else are left alone. dry=true
-- prints the commands instead and ignores the instance check.

local T = "com.superlogical.terminal"
local HOME = os.getenv("HOME")
local FILE = HOME .. "/.config/rex/agent-sessions.json"
local SHELLS = { zsh = true, bash = true, fish = true, sh = true }
local DRY = rex.args.dry == true or rex.args.dry == "true"
local RESUME = {
  ["claude-code"] = "claude --resume ",
  pi = "pi --session ",
}

-- First message after a resume. The old process died with the server, and
-- with it any background work the agent had started.
local RESUME_PROMPT = "Rex restarted and this session was resumed in its tab. "
  .. "If a turn was cut off, finish it. Background tasks, subagents and monitors "
  .. "you started before the restart are gone, so restart the ones still needed. "
  .. "If nothing was running, reply in one line and stop."

local function load()
  local f = io.open(FILE)
  if not f then return { blocks = {} } end
  local ok, data = pcall(rex.json.decode, f:read("*a"))
  f:close()
  if ok and type(data) == "table" then
    data.blocks = data.blocks or {}
    return data
  end
  return { blocks = {} }
end

local state = load()
local status = rex.call("server.status") or {}
local instance = status.instance_id

local function save()
  state.instance_id = instance
  local tmp = FILE .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(rex.json.encode(state))
  f:close()
  os.rename(tmp, FILE)
end

local function sh_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

-- Restore on a new server instance. Right after a restart the panes' shells
-- may not be running yet (foreground is `login` or missing), so each pane is
-- retried every second for up to a minute until its shell shows up.
pcall(function() io.stdout:setvbuf("line") end) -- log lines reach the file right away
local function log(...) print(os.date("%H:%M:%S"), ...) end

local restoring = DRY or (state.instance_id and state.instance_id ~= instance)
if restoring then
  local pending = {}
  for block_id, a in pairs(state.blocks) do pending[block_id] = a end
  local attached = {}

  -- Returns true when the pane is settled: resumed, gone, or busy with something else.
  local function try(block_id, a, last)
    -- Top-level code hears no session until it attaches, even with --all.
    if not attached[a.session_id] then
      attached[a.session_id] = rex.session.attach{ session_id = a.session_id } ~= nil
    end
    local p = attached[a.session_id]
      and rex.block.call(T, "process", { session_id = a.session_id, block_id = block_id })
    local fg = p and p.foreground
    local name = fg and (fg.name or ""):gsub("^%-", "")
    if fg and SHELLS[name] then
      local flags = (a.flags and a.flags ~= "") and (" " .. a.flags) or ""
      local cmd = "cd -- " .. sh_quote(a.cwd) .. " && "
        .. RESUME[a.app or "claude-code"] .. a.session .. flags
        .. " " .. sh_quote(RESUME_PROMPT) .. "\r"
      if DRY then
        print(block_id, cmd)
      else
        rex.block.call(T, "write", { session_id = a.session_id, block_id = block_id, data = cmd })
        log(block_id, "resumed", a.app or "claude-code", a.session)
      end
      return true
    end
    if not last and (not fg or name == "login") then return false end -- still starting
    if not p then
      state.blocks[block_id] = nil
      log(block_id, "pane gone, dropped")
    else
      log(block_id, "skipped, foreground is", name or "unknown")
    end
    return true
  end

  local tries = 0
  local timer
  timer = rex.every(1, function()
    tries = tries + 1
    for block_id, a in pairs(pending) do
      if try(block_id, a, tries >= 60) then pending[block_id] = nil end
    end
    if next(pending) == nil then
      timer:cancel()
      if not DRY then save() end
    end
  end)
end
if not DRY then save() end

-- Per harness: find the session a status record belongs to -> id, cwd.
local FIND = {}

-- Claude keeps ~/.claude/sessions/<pid>.json with the session ID. Permission
-- flags come from the process arguments so a resumed agent keeps its mode.
FIND["claude-code"] = function(rec)
  local pid = rec.owner.pid
  local f = io.open(HOME .. "/.claude/sessions/" .. pid .. ".json")
  if not f then return end
  local ok, s = pcall(rex.json.decode, f:read("*a"))
  f:close()
  if not (ok and s and s.sessionId) then return end
  local r = rex.exec{ "ps", "-o", "args=", "-p", tostring(pid) }
  local args = r and r.ok and r.stdout or ""
  local flags = {}
  local mode = args:match("%-%-permission%-mode[%s=](%S+)")
  if mode then flags[#flags + 1] = "--permission-mode " .. mode end
  if args:find("%-%-dangerously%-skip%-permissions") then
    flags[#flags + 1] = "--dangerously-skip-permissions"
  end
  return s.sessionId, s.cwd, table.concat(flags, " ")
end

-- Pi has no per-process file. Take the newest session in the pane's folder:
-- ~/.pi/agent/sessions/--Users-me-repo--/<timestamp>_<id>.jsonl
-- Two pi agents in one folder can be mixed up.
FIND["pi"] = function(rec, ctx)
  local p = rex.block.call(T, "process", { session_id = ctx.session_id, block_id = ctx.block_id })
  local cwd = p and p.foreground and p.foreground.cwd
  if not cwd then return end
  local dir = HOME .. "/.pi/agent/sessions/--" .. cwd:sub(2):gsub("/", "-") .. "--"
  local r = rex.exec{ "ls", "-t", dir }
  local newest = r and r.ok and r.stdout:match("[^\n]+")
  local id = newest and newest:match("_([%w%-]+)%.jsonl$")
  if id then return id, cwd end
end

-- Record which agent session each pane runs.
local function record(ctx, app, pid)
  local id, cwd, flags = FIND[app]({ owner = { pid = pid } }, ctx)
  if not id then return end
  local cur = state.blocks[ctx.block_id]
  if cur and cur.session == id and cur.flags == flags then return end
  state.blocks[ctx.block_id] =
    { app = app, session = id, cwd = cwd, flags = flags, session_id = ctx.session_id }
  if not DRY then save() end
end

rex.on("terminal.program_status_changed", function(ctx, ev)
  local rec = ev.record
  if rec and FIND[rec.app] and rec.owner and rec.owner.pid then
    record(ctx, rec.app, rec.owner.pid)
  end
end)

-- Startup scan: save agents already running, including idle ones that won't
-- report a status change before the next restart. Skipped while restoring,
-- since the panes are bare shells then.
if not restoring then
  local list = rex.call("session.list")
  for _, s in ipairs(list and list.sessions or {}) do
    rex.session.attach{ session_id = s.session_id }
    local bl = rex.session.list_blocks{ session_id = s.session_id }
    for _, b in ipairs(bl and bl.blocks or {}) do
      local ctx = { session_id = s.session_id, block_id = b.block_id }
      local p = rex.block.call(T, "process", ctx)
      local fg = p and p.foreground
      if fg and fg.pid then
        local fh = io.open(HOME .. "/.claude/sessions/" .. fg.pid .. ".json")
        if fh then
          fh:close()
          record(ctx, "claude-code", fg.pid)
        elseif fg.argv0 == "pi" then
          record(ctx, "pi", fg.pid)
        end
      end
    end
  end
end

rex.on("block_closed", function(ctx)
  if state.blocks[ctx.block_id] then
    state.blocks[ctx.block_id] = nil
    if not DRY then save() end
  end
end)
