-- The one line appended to the private copy's main.lua requires this file. It wires the game-facing file into the
-- two decision files, which load in a sandbox with no way to reach the game except what they are handed.
local world = require "bot/world"

local SAFE = { "table", "string", "ipairs", "pairs", "next", "type", "tostring", "tonumber", "select", "assert", "error",
  "pcall", "unpack", "setmetatable", "getmetatable" }

-- math.random is the game's own random stream, so the decision files get math without it.
local function sandbox(path)
  local env = {}
  for _, name in ipairs(SAFE) do env[name] = _G[name] end
  env.math = {}
  for name, f in pairs(math) do
    if name ~= "random" and name ~= "randomseed" then env.math[name] = f end
  end
  setmetatable(env, {
    __index = function(_, k) error(path .. " read the global " .. tostring(k), 2) end,
    __newindex = function(_, k) error(path .. " set the global " .. tostring(k), 2) end,
  })
  local chunk = assert(love.filesystem.load(path))
  setfenv(chunk, env)
  return chunk()
end

local solver = sandbox("bot/solver.lua")
local run = sandbox("bot/run.lua")

io.stdout:setvbuf("line")

local function clean(text) return (tostring(text):gsub("[\r\n]+", " / ")) end
local function send(...)
  local parts = { ... }
  for i, part in ipairs(parts) do parts[i] = clean(part) end
  io.stdout:write("@@", table.concat(parts, "|"), "\n")
end

-- Reading stdin blocks, so it has its own thread. The end of stdin means Balabro has gone, however it went.
local inbox = love.thread.getChannel("balabro_inbox")
love.thread.newThread([[
  require "love.thread"
  local inbox = love.thread.getChannel("balabro_inbox")
  while true do
    local line = io.read("*l")
    inbox:push(line or "EOF")
    if not line then return end
  end
]]):start()

local function split(line)
  local parts = {}
  for part in (line .. "|"):gmatch("(.-)|") do parts[#parts + 1] = part end
  return parts
end

local function ask(id, kind, picks, path, brief)
  send("decide", id, kind, picks, path, brief)
  while true do
    local line = inbox:pop()
    if line == "EOF" then os.exit(0) end
    if line then
      local parts = split(line)
      if parts[1] == "plan" and tonumber(parts[2]) == id then
        table.remove(parts, 1); table.remove(parts, 1)
        return parts
      end
    else
      coroutine.yield()
    end
  end
end

local function fail(kind, detail)
  send("broken", kind, detail)
  io.stdout:flush()
  os.exit(3)
end

-- The game's own error screen would hang with nobody to read it.
love.errhand = function(message) fail("crashed", tostring(message) .. " " .. debug.traceback()) end

function love.load()
  G.SETTINGS.WINDOW.screenmode = "Windowed"
  G:start_up()
  love.window.updateMode(960, 540, { fullscreen = false, resizable = true })
  love.resize(960, 540)
  world.prepare_profile()
end

local co = coroutine.create(function()
  run.main({
    world = world, solver = solver, ask = ask, send = send, now = love.timer.getTime,
    goal = os.getenv("BALABRO_BOT_GOAL") or "win",
    deck = os.getenv("BALABRO_BOT_DECK") or "b_red",
    stake = tonumber(os.getenv("BALABRO_BOT_STAKE") or "1"),
  })
  send("exit")
  love.event.quit(0)
end)

local game_update = love.update
function love.update(dt)
  game_update(dt)
  if inbox:peek() == "EOF" then os.exit(0) end
  if coroutine.status(co) == "suspended" then
    local ok, err = coroutine.resume(co)
    if not ok then
      local kind, detail = tostring(err):match("broken:(%w+):(.*)")
      if kind then fail(kind, detail) else fail("crashed", tostring(err) .. " " .. debug.traceback(co)) end
    end
  end
end

if os.getenv("BALABRO_BOT_VERIFY") then
  co = coroutine.create(function()
    local verify = require "bot/verify"
    verify.main(world, solver, send)
    love.event.quit(0)
  end)
end
