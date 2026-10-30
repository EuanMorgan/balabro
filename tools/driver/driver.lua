-- Plays a short scripted run in an unpacked copy of Balatro and copies save.jkr after
-- every write, so tests and the overlay can use real saves instead of hand-made ones.
local OUT = os.getenv("BALABRO_DRIVER_OUT") or "/tmp/balabro-driver-out"
local SEED = os.getenv("BALABRO_DRIVER_SEED") or "BALABRO1"
local STEP_PAUSE = tonumber(os.getenv("BALABRO_DRIVER_PAUSE") or "0")

local function log(...)
  io.write("[driver] ", table.concat({ ... }, " "), "\n")
  io.flush()
end

local function write_file(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

-- Steam would quit the game when the Steam client isn't the launcher.
function love.load()
  G:start_up()
  love.mouse.setVisible(true)
end

local last_save, saves = nil, 0
local function save_path() return G.SETTINGS.profile .. "/save.jkr" end

local function capture_save(label)
  local data = love.filesystem.read(save_path())
  if data and data ~= last_save then
    last_save = data
    saves = saves + 1
    local name = string.format("%02d-%s.jkr", saves, label)
    write_file(OUT .. "/" .. name, data)
    log("saved", name, "state=" .. tostring(G.STATE))
    return true
  end
  return false
end

local function screenshot(label)
  love.graphics.captureScreenshot(function(img)
    write_file(OUT .. "/" .. label .. ".png", img:encode("png"):getString())
    log("screenshot", label .. ".png")
  end)
end

local function wait(seconds)
  local t = love.timer.getTime() + seconds
  while love.timer.getTime() < t do coroutine.yield() end
end

local function wait_until(what, pred, timeout)
  local deadline = love.timer.getTime() + (timeout or 30)
  while not pred() do
    if love.timer.getTime() > deadline then
      error(string.format("timed out waiting for %s (state=%s complete=%s locked=%s queue=%d)", what,
        tostring(G.STATE), tostring(G.STATE_COMPLETE), tostring(G.CONTROLLER.locked), #G.E_MANAGER.queues.base))
    end
    coroutine.yield()
  end
end

local function idle()
  return G.STATE_COMPLETE and not G.CONTROLLER.locked
end

local ready = {
  BLIND_SELECT = function() return G.blind_select and G.blind_prompt_box end,
  SELECTING_HAND = function() return #G.hand.cards > 0 and G.buttons end,
  ROUND_EVAL = function() return G.round_eval end,
  SHOP = function() return G.shop and G.shop_jokers end,
}

local function wait_for_save(label, timeout)
  local deadline = love.timer.getTime() + (timeout or 15)
  while not capture_save(label) do
    if love.timer.getTime() > deadline then error("no save written for " .. label) end
    coroutine.yield()
  end
  wait(STEP_PAUSE)
end

local function wait_state(name, timeout)
  wait_until("state " .. name, function()
    return G.STATE == G.STATES[name] and idle() and ready[name]()
  end, timeout)
  wait(0.5)
end

local function highlight(cards)
  G.hand:unhighlight_all()
  for _, c in ipairs(cards) do G.hand:add_to_highlighted(c, true) end
end

local function first_n(area, n)
  local out = {}
  for i = 1, math.min(n, #area.cards) do out[#out + 1] = area.cards[i] end
  return out
end

local function select_blind()
  wait_state("BLIND_SELECT")
  wait_for_save("blind-select")
  local key = G.GAME.round_resets.blind_choices[G.GAME.blind_on_deck]
  G.FUNCS.select_blind({ config = { ref_table = G.P_BLINDS[key] } })
  wait_state("SELECTING_HAND")
  wait_for_save("hand")
end

local function discard(n, label)
  highlight(first_n(G.hand, n))
  G.FUNCS.discard_cards_from_highlighted(nil)
  wait_until("discard to finish", function() return G.STATE ~= G.STATES.SELECTING_HAND end, 5)
  wait_state("SELECTING_HAND")
  wait_for_save(label)
end

local function win_round()
  -- Lower the target so a 5 card High Card wins; the saves before this keep the real target.
  G.GAME.blind.chips = 1
  highlight(first_n(G.hand, 5))
  G.FUNCS.play_cards_from_highlighted(nil)
  wait_state("ROUND_EVAL", 60)
  wait_for_save("round-eval")
  G.FUNCS.cash_out({ config = {} })
  wait_state("SHOP")
  wait_for_save("shop")
end

local function shop_round()
  G.GAME.dollars = 100
  G.FUNCS.reroll_shop(nil)
  wait_until("reroll", function() return not G.CONTROLLER.locks.shop_reroll and idle() end)
  wait_for_save("shop-reroll")

  local joker = G.shop_jokers.cards[1]
  if joker then
    G.FUNCS.buy_from_shop({ config = { ref_table = joker, id = "buy" } })
    wait_until("joker bought", function() return #G.jokers.cards > 0 and idle() end, 10)
    wait(1)
  end

  local pack = G.shop_booster.cards[1]
  if pack then
    G.FUNCS.use_card({ config = { ref_table = pack } })
    wait_for_save("pack-opening")
    wait_until("pack cards", function() return G.pack_cards and #G.pack_cards.cards > 0 and idle() end)
    wait(1.5)
    screenshot(string.format("%02d-pack-open", saves))
    wait(0.5)
    G.FUNCS.skip_booster({ config = {} })
    wait_state("SHOP")
    wait_for_save("pack-closed")
  end

  G.FUNCS.toggle_shop(nil)
end

local function script()
  wait_until("main menu", function() return G.STAGE == G.STAGES.MAIN_MENU and G.MAIN_MENU_UI end, 60)
  G.SETTINGS.tutorial_complete = true
  G.SETTINGS.GAMESPEED = 4
  log("starting run seed=" .. SEED)
  G.FUNCS.start_run(nil, { stake = 1, seed = SEED })

  select_blind()
  discard(5, "hand-after-discard")
  win_round()
  shop_round()

  select_blind()
  win_round()

  log("done", saves .. " saves")
  love.event.quit(0)
end

local co = coroutine.create(script)
local game_update = love.update
function love.update(dt)
  game_update(dt)
  if coroutine.status(co) == "suspended" then
    local ok, err = coroutine.resume(co)
    if not ok then
      log("FAILED", err, debug.traceback(co))
      love.event.quit(1)
    end
  end
end
