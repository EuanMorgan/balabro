-- Checks only the real game can show. Not shipped: it rigs jokers and blind targets to reach more cases.
-- Run with: BALABRO_BOT_VERIFY=1 tools/bot/drive.py. Run it after any Balatro update.
local verify = {}

local ENHANCEMENTS = { "m_bonus", "m_mult", "m_wild", "m_glass", "m_steel", "m_stone", "m_gold", "m_lucky" }
local SEALS = { "Red", "Blue", "Gold", "Purple" }
local HANDS = tonumber(os.getenv("BALABRO_BOT_VERIFY_HANDS") or "50")

local function deal_jokers()
  for i = #G.jokers.cards, 1, -1 do
    local joker = G.jokers.cards[i]
    joker:remove_from_deck()
    joker:remove()
  end
  G.hand.config.card_limit = 8
  for _ = 1, 5 do
    local center = G.P_CENTER_POOLS.Joker[math.random(#G.P_CENTER_POOLS.Joker)]
    local joker = create_card("Joker", G.jokers, nil, nil, nil, nil, center.key)
    joker:add_to_deck()
    G.jokers:emplace(joker)
  end
  for _, card in ipairs(G.hand.cards) do
    if math.random() < 0.4 then card:set_ability(G.P_CENTERS[ENHANCEMENTS[math.random(#ENHANCEMENTS)]], nil, true) end
    if math.random() < 0.2 then card:set_seal(SEALS[math.random(#SEALS)], true, true) end
    G.GAME.blind:debuff_card(card)
  end
end

local function describe(decision)
  local jokers = decision.order and table.concat(decision.order, ",") or ""
  return decision.action .. ":" .. table.concat(decision.ids, ",") .. ":" .. jokers
end

-- Everything a player can't see is changed. The solver's answer must not change by a byte.
local function blindfold(world, solver)
  local fixed = { world = world, now = function() return 0 end, seed = 12345 }
  local before = describe(solver.decide(world.see(), fixed))
  for i = #G.deck.cards, 2, -1 do
    local j = math.random(i)
    G.deck.cards[i], G.deck.cards[j] = G.deck.cards[j], G.deck.cards[i]
  end
  for key, value in pairs(G.GAME.pseudorandom) do
    if type(value) == "number" and key ~= "hashed_seed" then G.GAME.pseudorandom[key] = (value * 7.3) % 1 end
  end
  local after = describe(solver.decide(world.see(), fixed))
  return before == after, before, after
end

-- Rehearsing a Green Joker on offer must not grow it, and Banner must count a new round's discards, not the last round's.
local function appraisal_is_clean(world, solver)
  local function add(area, key)
    local joker = create_card("Joker", area, nil, nil, nil, nil, key)
    area:emplace(joker)
    return joker
  end
  local green = add(G.shop_jokers, "j_green_joker")
  add(G.jokers, "j_banner")
  add(G.jokers, "j_joker")
  G.GAME.current_round.discards_left = 0
  local appraisal = solver.appraise(world.see(), { world = world, now = love.timer.getTime, seed = 777 })
  world.audit()
  local banner_counted = false
  for _, joker in ipairs(appraisal.owned) do
    if joker.name == "Banner" and joker.typical < appraisal.typical then banner_counted = true end
  end
  return green.ability.mult == 0 and banner_counted and G.GAME.current_round.discards_left == 0,
    "green mult " .. green.ability.mult .. ", banner counted " .. tostring(banner_counted)
end

local function wait_frames(n) for _ = 1, n do coroutine.yield() end end

function verify.main(world, solver, send)
  world.start({ deck = "b_red", stake = 1 })
  math.randomseed(os.time())
  local hands, matched, compared, blind_ok, blind_runs = 0, 0, 0, 0, 0
  local appraisal_ok, appraisal_detail
  while hands < HANDS do
    local moment = world.next_moment()
    if moment == "game_over" then error("the verify run lost, which rigged targets shouldn't allow")
    elseif moment == "win_screen" then world.continue_endless()
    elseif moment == "cash_out" then world.cash_out()
    elseif moment == "blind" then world.select_blind()
    elseif moment == "shop" then
      if appraisal_ok == nil then appraisal_ok, appraisal_detail = appraisal_is_clean(world, solver) end
      world.leave_shop()
    elseif moment == "pack" then world.skip_pack()
    elseif moment == "hand" then
      deal_jokers()
      wait_frames(30)

      G.GAME.blind.chips = 1e30
      local same, before, after = blindfold(world, solver)
      blind_runs = blind_runs + 1
      if same then blind_ok = blind_ok + 1 else send("blindfold-failed", before, after) end
      world.see()
      world.audit()

      G.GAME.blind.chips = 1
      local fixed = { world = world, now = love.timer.getTime, seed = 777 }
      local decision = solver.decide(world.see(), fixed)
      world.audit()
      if decision.action ~= "play" then error("a target of 1 should always play, but it chose " .. decision.action) end
      local names = {}
      for _, joker in ipairs(G.jokers.cards) do names[#names + 1] = joker.ability.name end
      local actual, name = world.play(decision.ids, decision.order)
      hands = hands + 1
      if decision.predicted then
        compared = compared + 1
        if math.abs(actual - decision.predicted) <= math.abs(actual) * 1e-9 then
          matched = matched + 1
        else
          send("score-miss", name, decision.predicted, actual, G.GAME.blind.name, table.concat(names, ","))
        end
      end
    end
  end
  send("verified", "scores " .. matched .. "/" .. compared, "blindfold " .. blind_ok .. "/" .. blind_runs, "appraisal " .. tostring(appraisal_detail))
  send("ended", (matched == compared and blind_ok == blind_runs and appraisal_ok) and "pass" or "fail", 0, 0, 0)
end

return verify
