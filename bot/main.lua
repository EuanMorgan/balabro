-- The one line appended to the private copy's main.lua requires this file. It wires the game-facing file into the
-- two decision files, which load in a sandbox with no way to reach the game except what they are handed.
local world = require "bot/world"

local SCORING = os.getenv("BALABRO_BOT_MODE") == "scorer"
-- A scorer can run beside a "play for me" run, so it keeps its own save folder.
if SCORING then love.filesystem.setIdentity("balabro-scorer") end

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
local brief = sandbox("bot/brief.lua")
local scorer = sandbox("bot/scorer.lua")

-- On Windows "line" acts as full buffering, so nothing would reach Balabro until the game quit.
io.stdout:setvbuf("no")

local function clean(text) return (tostring(text):gsub("[\r\n]+", " / ")) end
local function send(...)
  local parts = { ... }
  for i, part in ipairs(parts) do parts[i] = clean(part) end
  io.stdout:write("@@" .. table.concat(parts, "|") .. "\n")
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

-- The newest request wins, because the player has already moved on from the older ones.
local function next_request()
  while true do
    local newest
    while inbox:getCount() > 0 do
      newest = inbox:pop()
      if newest == "EOF" then os.exit(0) end
    end
    if newest then
      local parts = split(newest)
      if parts[1] == "score" then return tonumber(parts[2]), parts[3], parts[4] end
    end
    coroutine.yield()
  end
end

local function fail(kind, detail)
  send("broken", kind, detail)
  os.exit(3)
end

-- The game's own error screen would hang with nobody to read it.
love.errhand = function(message) fail("crashed", tostring(message) .. " " .. debug.traceback()) end

function love.load()
  G.SETTINGS.WINDOW.screenmode = "Windowed"
  world.lower_graphics()
  G:start_up()
  love.window.updateMode(960, 540, { fullscreen = false, resizable = true })
  love.resize(960, 540)
  world.prepare_profile()
  if SCORING then
    love.window.minimize()
    love.draw = function() end
  end
end

local co = coroutine.create(function()
  run.main({
    world = world, solver = solver, brief = brief, ask = ask, send = send, now = love.timer.getTime,
    goal = os.getenv("BALABRO_BOT_GOAL") or "win",
    deck = os.getenv("BALABRO_BOT_DECK") or "b_red",
    stake = tonumber(os.getenv("BALABRO_BOT_STAKE") or "1"),
    -- Only for comparing two versions of the bot on the same runs. Neither the solver nor Claude is told it.
    seed = os.getenv("BALABRO_BOT_SEED"),
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

if SCORING then
  co = coroutine.create(function()
    scorer.main({ world = world, solver = solver, brief = brief, send = send, next_request = next_request, now = love.timer.getTime })
  end)
end

if os.getenv("BALABRO_BOT_VERIFY") then
  co = coroutine.create(function()
    local verify = require "bot/verify"
    verify.main(world, solver, send)
    love.event.quit(0)
  end)
end
