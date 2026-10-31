-- The only bot file that may name the game. A change in the game means a change here and nowhere else.
-- Everything it hands out is a plain table with no card objects in it, holding only what a player can see.
local world = {}

local GAME_SPEED = 32
local STUCK_AFTER = 45

local CONTRACT = {
  funcs = { "select_blind", "skip_blind", "play_cards_from_highlighted", "discard_cards_from_highlighted", "cash_out",
    "buy_from_shop", "reroll_shop", "toggle_shop", "use_card", "skip_booster", "start_run", "evaluate_play",
    "exit_overlay_menu", "can_buy", "can_reroll", "check_for_buy_space", "get_poker_hand_info" },
  globals = { "pseudoseed", "save_run", "STR_PACK", "copy_card", "delay", "update_hand_text", "card_eval_status_text",
    "juice_card", "highlight_card", "play_sound", "ease_dollars", "check_for_unlock", "check_and_set_high_score",
    "inc_career_stat", "set_hand_usage", "attention_text", "play_area_status_text", "juice_card_until", "Back", "CardArea", "get_blind_amount", "STR_UNPACK" },
}

local function broken(kind, detail) error("broken:" .. kind .. ":" .. detail, 0) end

function world.check()
  for _, name in ipairs(CONTRACT.funcs) do
    if type(G.FUNCS[name]) ~= "function" then broken("gameChanged", "G.FUNCS." .. name .. " is missing") end
  end
  for _, name in ipairs(CONTRACT.globals) do
    if _G[name] == nil then broken("gameChanged", name .. " is missing") end
  end
end

function world.version() return G.VERSION or "unknown" end

function world.prepare_profile()
  G.SETTINGS.tutorial_complete = true
  G.SETTINGS.GAMESPEED = GAME_SPEED
  G.SETTINGS.SOUND.volume = 0
  G.SETTINGS.SOUND.music_volume = 0
  G.SETTINGS.SOUND.game_sounds_volume = 0
  G.PROFILES[G.SETTINGS.profile].all_unlocked = true
  for _, group in ipairs({ G.P_CENTERS, G.P_BLINDS, G.P_TAGS }) do
    for _, item in pairs(group) do
      if not item.demo and not item.wip then
        item.alerted, item.discovered, item.unlocked = true, true, true
      end
    end
  end
end

local function wait_for(what, predicate, timeout)
  local deadline = love.timer.getTime() + (timeout or STUCK_AFTER)
  while not predicate() do
    if love.timer.getTime() > deadline then
      broken("stuck", what .. " state=" .. tostring(G.STATE) .. " complete=" .. tostring(G.STATE_COMPLETE)
        .. " locked=" .. tostring(G.CONTROLLER.locked) .. " queue=" .. #G.E_MANAGER.queues.base)
    end
    coroutine.yield()
  end
end

-- Acting before the queue drains crashes the game, because later events expect the UI they built to still be there.
local quiet_frames = 0
local function settled()
  if not G.STATE_COMPLETE or G.CONTROLLER.locked then quiet_frames = 0; return false end
  for _, event in ipairs(G.E_MANAGER.queues.base) do
    if event.blocking ~= false then quiet_frames = 0; return false end
  end
  quiet_frames = quiet_frames + 1
  return quiet_frames >= 3
end

local function cash_out_ready()
  if not G.round_eval then return false end
  for _, box in ipairs(G.I.UIBOX) do
    if box:get_UIE_by_ID("cash_out_button") then return true end
  end
  return false
end

local PACK_STATES = { "TAROT_PACK", "PLANET_PACK", "SPECTRAL_PACK", "STANDARD_PACK", "BUFFOON_PACK" }
local function in_pack()
  for _, name in ipairs(PACK_STATES) do
    if G.STATE == G.STATES[name] then return true end
  end
  return false
end

function world.start(setup)
  world.check()
  wait_for("the main menu", function() return G.STAGE == G.STAGES.MAIN_MENU and G.MAIN_MENU_UI end, 60)
  G.GAME.viewed_back = Back(G.P_CENTERS[setup.deck])
  G.FUNCS.start_run(nil, { stake = setup.stake })
  world.real_evaluate = G.FUNCS.evaluate_play
  G.FUNCS.evaluate_play = function(e)
    world.real_evaluate(e)
    world.last_score = hand_chips * mult
  end
end

-- Returns "blind", "hand", "cash_out", "shop", "pack", "win_screen" or "game_over".
function world.next_moment()
  local found
  wait_for("the next decision", function()
    if G.STATE == G.STATES.GAME_OVER then found = "game_over"; return true end
    if G.SETTINGS.paused and G.OVERLAY_MENU then
      if G.GAME.won and not world.saw_win then found = "win_screen"; return true end
      G.FUNCS.exit_overlay_menu()
      return false
    end
    if not settled() then return false end
    if G.STATE == G.STATES.BLIND_SELECT and G.blind_select and G.blind_prompt_box then found = "blind"
    elseif G.STATE == G.STATES.SELECTING_HAND and #G.hand.cards > 0 and G.buttons then found = "hand"
    elseif G.STATE == G.STATES.ROUND_EVAL and cash_out_ready() then found = "cash_out"
    elseif G.STATE == G.STATES.SHOP and G.shop and G.shop_jokers then found = "shop"
    elseif in_pack() and G.pack_cards and #G.pack_cards.cards > 0 then found = "pack"
    end
    return found ~= nil
  end)
  return found
end

local function key_of(c)
  return table.concat({ c.base.value, c.base.suit, c.config.center.key, c.edition and (c.edition.type or "e") or "",
    c.seal or "", c.ability.perma_bonus or 0, c.debuff and "d" or "" }, "/")
end

local SUIT_SYMBOLS = { Spades = "♠", Hearts = "♥", Clubs = "♣", Diamonds = "♦" }
local RANK_LABELS = { Ace = "A", King = "K", Queen = "Q", Jack = "J" }

local function view_of(c, id)
  local stone = c.ability.effect == "Stone Card"
  local suit = SUIT_SYMBOLS[c.base.suit] or ""
  return { id = id, key = key_of(c), label = stone and "Stone card" or (RANK_LABELS[c.base.value] or c.base.value) .. suit,
    rank = stone and nil or c:get_id(), suit = c.base.suit, stone = stone,
    wild = c.ability.effect == "Wild Card", debuffed = c.debuff == true, value = c.base.nominal }
end

local by_id, standing = {}, nil
local function plain(t) return type(t) == "table" and getmetatable(t) == nil end
local function copy(t, seen)
  seen = seen or {}
  if seen[t] then return seen[t] end
  local out = {}
  seen[t] = out
  for k, v in pairs(t) do out[k] = plain(v) and copy(v, seen) or v end
  return out
end
local function restore(target, saved, seen)
  seen = seen or {}
  if seen[saved] then return end
  seen[saved] = true
  for k in pairs(target) do if saved[k] == nil then target[k] = nil end end
  for k, v in pairs(saved) do
    if plain(v) then
      if not plain(target[k]) then target[k] = {} end
      restore(target[k], v, seen)
    else
      target[k] = v
    end
  end
end

local CARD_FIELDS = { "debuff", "destroyed", "shattered", "lucky_trigger", "getting_sliced", "vampired", "sell_cost" }
local function save_card(c)
  local saved = { card = c, ability = c.ability, ability_copy = copy(c.ability), center = c.config.center, base = copy(c.base) }
  for _, field in ipairs(CARD_FIELDS) do saved[field] = c[field] end
  return saved
end
local function restore_card(saved)
  local c = saved.card
  c.ability = saved.ability
  restore(saved.ability, saved.ability_copy)
  c.config.center = saved.center
  restore(c.base, saved.base)
  for _, field in ipairs(CARD_FIELDS) do c[field] = saved[field] end
end

local function take_standing(offered)
  local s = { offered = offered, game = copy(G.GAME), blind = copy(G.GAME.blind), cards = {}, hand = G.hand.cards, play = G.play.cards,
    jokers = G.jokers.cards, playing_count = #G.playing_cards, deck_limit = G.deck.config.card_limit,
    chips = hand_chips, mult = mult, deck_order = {} }
  for i, c in ipairs(G.deck.cards) do s.deck_order[i] = c end
  for _, area in ipairs({ G.playing_cards, G.jokers.cards, G.consumeables.cards, offered }) do
    for _, c in ipairs(area) do s.cards[#s.cards + 1] = save_card(c) end
  end
  return s
end

function world.see()
  by_id = {}
  local next_id = 0
  local function register(c) next_id = next_id + 1; by_id[next_id] = c; return next_id end

  local view = { hand = {}, jokers = {}, consumables = {}, unseen = {} }
  local hidden = {}
  world.hidden = {}
  for _, c in ipairs(G.hand.cards) do
    local id = register(c)
    if c.facing == "back" then
      view.hand[#view.hand + 1] = { id = id, label = "face-down card", face_down = true, forced = c.ability.forced_selection == true }
      hidden[#hidden + 1] = c
      world.hidden[id] = true
    else
      local card = view_of(c, id)
      card.forced = c.ability.forced_selection == true
      view.hand[#view.hand + 1] = card
    end
  end
  for _, c in ipairs(G.jokers.cards) do
    view.jokers[#view.jokers + 1] = { id = register(c), face_down = c.facing == "back" }
  end
  for _, c in ipairs(G.consumeables.cards) do
    local aims = c.ability.consumeable and c.ability.consumeable.max_highlighted ~= nil
    view.consumables[#view.consumables + 1] = { id = register(c), needs_hand = aims }
  end

  -- Jokers on offer, so their effect can be rehearsed before buying, as a player would work it out.
  view.offers = {}
  local offered = {}
  local row, offer_area = "card", G.shop_jokers
  if in_pack() then row, offer_area = "pick", G.pack_cards end
  for position, c in ipairs(offer_area and offer_area.cards or {}) do
    if c.ability.set == "Joker" then
      offered[#offered + 1] = c
      view.offers[#view.offers + 1] = { id = register(c), row = row, position = position, name = c.ability.name }
    end
  end
  for position, joker in ipairs(view.jokers) do joker.position, joker.name = position, by_id[joker.id].ability.name end

  -- Sorted by what the cards are, so the order of this list says nothing about the order of the deck.
  local unseen = {}
  for _, c in ipairs(G.deck.cards) do unseen[#unseen + 1] = c end
  for _, c in ipairs(hidden) do unseen[#unseen + 1] = c end
  table.sort(unseen, function(a, b) return key_of(a) < key_of(b) end)
  for _, c in ipairs(unseen) do
    view.unseen[#view.unseen + 1] = view_of(c, register(c))
  end

  view.hand_size = G.hand.config.card_limit
  view.need = G.GAME.blind.chips - G.GAME.chips
  view.hands_left = G.GAME.current_round.hands_left
  view.discards_left = G.GAME.current_round.discards_left
  view.four_fingers = next(find_joker("Four Fingers")) ~= nil
  view.levels = {}
  for name, hand in pairs(G.GAME.hands) do view.levels[name] = { chips = hand.chips, mult = hand.mult } end

  standing = take_standing(offered)
  return view
end

-- Between rounds the counters still hold what the last round left, which would skew Banner, Acrobat and the like.
function world.as_fresh_round(rehearsals)
  local real, round = standing, G.GAME.current_round
  round.discards_left = math.max(0, G.GAME.round_resets.discards + G.GAME.round_bonus.discards)
  round.hands_left = math.max(1, G.GAME.round_resets.hands + G.GAME.round_bonus.next_hands)
  round.hands_played, round.discards_used = 0, 0
  standing = take_standing(real.offered)
  local result = rehearsals()
  restore(G.GAME, real.game)
  standing = real
  return result
end

local NOOP = function() end
-- DNA copies a card during the rehearsal and then sets fields on the copy and calls its methods.
local inert = setmetatable({}, { __index = function(t) return t end, __call = function(t) return t end, __newindex = NOOP })
local SILENCED = { "delay", "highlight_card", "update_hand_text", "card_eval_status_text", "juice_card", "play_sound",
  "play_area_status_text", "check_for_unlock", "check_and_set_high_score", "inc_career_stat", "set_hand_usage",
  "attention_text", "ease_dollars", "juice_card_until", "ease_chips" }

-- xorshift, so no rehearsal touches the game's random stream.
local function fake_stream(roll)
  local x = bit.bxor(math.floor(roll * 2147483647) + 1, 0x5bd1e995)
  return function()
    x = bit.bxor(x, bit.lshift(x, 13)); x = bit.bxor(x, bit.rshift(x, 17)); x = bit.bxor(x, bit.lshift(x, 5))
    return (bit.band(x, 0x7fffffff) + 0.5) / 2147483648
  end
end

-- The game's own evaluate_play with real cards and real jokers, nothing visible, and everything put back.
-- A face-down id is refused, played or held, because its score would reveal it. Callers put a sampled unseen id there.
function world.rehearse(play_ids, held_ids, roll, order_ids)
  local play, held = {}, {}
  for i, id in ipairs(play_ids) do
    if world.hidden[id] then error("rehearsed a face-down card", 2) end
    play[i] = by_id[id]
  end
  for i, id in ipairs(held_ids) do
    if world.hidden[id] then error("rehearsed a face-down card", 2) end
    held[i] = by_id[id]
  end

  local saved_x = {}
  for i, c in ipairs(play) do saved_x[i] = c.T.x; c.T.x = i end
  local saved = {}
  for _, name in ipairs(SILENCED) do saved[name] = _G[name]; _G[name] = NOOP end
  local add_event, real_copy, real_emplace, real_seed = G.E_MANAGER.add_event, _G.copy_card, CardArea.emplace, _G.pseudoseed
  G.E_MANAGER.add_event = NOOP
  CardArea.emplace = NOOP
  _G.copy_card = function() return inert end
  local chancy, stream = false, fake_stream(roll or 0.5)
  _G.pseudoseed = function() chancy = true; return stream() end

  G.play.cards, G.hand.cards = play, held
  if order_ids then
    local order = {}
    for i, id in ipairs(order_ids) do order[i] = by_id[id] end
    G.jokers.cards = order
  end
  G.GAME.current_round.hands_left = G.GAME.current_round.hands_left - 1

  local ok, err = pcall(world.real_evaluate)
  local score, name = ok and hand_chips * mult or 0, G.GAME.last_hand_played
  local chips, final_mult = hand_chips, mult

  G.E_MANAGER.add_event, CardArea.emplace, _G.copy_card, _G.pseudoseed = add_event, real_emplace, real_copy, real_seed
  for _, n in ipairs(SILENCED) do _G[n] = saved[n] end
  G.play.cards, G.hand.cards, G.jokers.cards = standing.play, standing.hand, standing.jokers
  restore(G.GAME, standing.game)
  restore(G.GAME.blind, standing.blind)
  for _, card in ipairs(standing.cards) do restore_card(card) end
  for i = #G.playing_cards, standing.playing_count + 1, -1 do G.playing_cards[i] = nil end
  G.deck.config.card_limit = standing.deck_limit
  hand_chips, mult = standing.chips, standing.mult
  for i, c in ipairs(play) do c.T.x = saved_x[i] end

  if not ok then broken("rehearsal", tostring(err)) end
  -- The game's own check `chips >= target` is false for nan, so nan can't clear a blind.
  if score ~= score then score = 0 end
  return score, name, chancy, chips, final_mult
end

-- After a batch of rehearsals everything must be as it was, or this is no longer a fair run.
function world.audit()
  local function same(a, b, path)
    for k, v in pairs(a) do
      if plain(v) then
        if not plain(b[k]) then return path .. "." .. tostring(k) end
        local diff = same(v, b[k], path .. "." .. tostring(k))
        if diff then return diff end
      elseif b[k] ~= v and not (v ~= v and b[k] ~= b[k]) then
        return path .. "." .. tostring(k)
      end
    end
  end
  local diff = same(standing.game.pseudorandom, G.GAME.pseudorandom, "pseudorandom")
    or (standing.game.dollars ~= G.GAME.dollars and "dollars")
    or (standing.game.chips ~= G.GAME.chips and "chips")
    or (standing.blind.chips ~= G.GAME.blind.chips and "blind")
    or (standing.playing_count ~= #G.playing_cards and "playing cards")
  if not diff then
    for i, c in ipairs(standing.deck_order) do
      if G.deck.cards[i] ~= c then diff = "deck order"; break end
    end
  end
  if diff then broken("rehearsalLeak", diff) end
end

-- What a button's enabled check needs: an element with a config.
local function element(card, id) return { config = { ref_table = card, id = id }, UIBox = { states = {} } } end

local function highlight(cards)
  G.hand:unhighlight_all()
  for _, c in ipairs(cards) do
    if not c.highlighted then G.hand:add_to_highlighted(c, true) end
  end
end

local function settle() wait_for("the game to settle", settled) end

local function apply_order(ids)
  local slots, order = {}, {}
  for i, c in ipairs(G.jokers.cards) do slots[i] = c.T.x end
  table.sort(slots)
  for i, id in ipairs(ids) do
    order[i] = by_id[id]
    order[i].T.x = slots[i]
  end
  G.jokers.cards = order
  G.jokers:set_ranks()
end

function world.play(ids, order_ids)
  if order_ids then apply_order(order_ids) end
  local cards = {}
  for i, id in ipairs(ids) do cards[i] = by_id[id] end
  highlight(cards)
  world.last_score = nil
  G.FUNCS.play_cards_from_highlighted(nil)
  wait_for("the hand to score", function() return world.last_score ~= nil end)
  return world.last_score, G.GAME.last_hand_played
end

function world.discard(ids)
  local cards = {}
  for i, id in ipairs(ids) do cards[i] = by_id[id] end
  highlight(cards)
  G.FUNCS.discard_cards_from_highlighted(nil)
  wait_for("the discard to start", function() return G.STATE ~= G.STATES.SELECTING_HAND end, 10)
end

function world.select_blind()
  local key = G.GAME.round_resets.blind_choices[G.GAME.blind_on_deck]
  G.FUNCS.select_blind(element(G.P_BLINDS[key]))
  wait_for("the blind to start", function() return G.STATE ~= G.STATES.BLIND_SELECT end, 10)
end

function world.blind_is_boss() return G.GAME.blind_on_deck == "Boss" end

function world.skip_blind()
  G.FUNCS.skip_blind({ UIBox = G.blind_select_opts[string.lower(G.GAME.blind_on_deck)], config = {} })
  settle()
end

function world.cash_out() G.FUNCS.cash_out({ config = {} }) end

function world.continue_endless()
  world.saw_win = true
  G.FUNCS.exit_overlay_menu()
end

function world.leave_shop()
  G.FUNCS.toggle_shop(nil)
  wait_for("the shop to close", function() return G.STATE ~= G.STATES.SHOP end, 10)
end

function world.skip_pack()
  G.FUNCS.skip_booster({ config = {} })
  wait_for("the pack to close", function() return not in_pack() end)
end

-- Only a private copy may do this: it replaces the run in progress with the one in the save.
function world.load_save(path)
  local file = assert(io.open(path, "rb"))
  local data = file:read("*a")
  file:close()
  G.FUNCS.start_run(nil, { savetext = STR_UNPACK(love.data.decompress("string", "deflate", data)) })
end

-- The game's clock is capped per frame, so a slow idle loop costs nothing once frames speed up again.
function world.set_idle(idle) G.FPS_CAP = idle and 4 or 500 end

function world.targets()
  local base = get_blind_amount(G.GAME.round_resets.ante) * G.GAME.starting_params.ante_scaling
  local boss = G.P_BLINDS[G.GAME.round_resets.blind_choices.Boss]
  return { small = base, big = base * 1.5, boss = base * (boss and boss.mult or 2),
    next_small = get_blind_amount(G.GAME.round_resets.ante + 1) * G.GAME.starting_params.ante_scaling }
end

function world.dollars() return G.GAME.dollars end
function world.best_hand() return G.GAME.round_scores.hand and G.GAME.round_scores.hand.amt or 0 end
function world.ante() return G.GAME.round_resets.ante end
function world.round() return G.GAME.round end
-- The game leaves pack_choices at 1 after the last pick, so it only counts while a pack is open.
function world.picks_left() return in_pack() and G.GAME.pack_choices or 0 end

local ROWS = {
  card = function() return G.shop_jokers end, voucher = function() return G.shop_vouchers end,
  pack = function() return G.shop_booster end, joker = function() return G.jokers end,
  consumable = function() return G.consumeables end, hand = function() return G.hand end,
  pick = function() return G.pack_cards end,
}

-- Positions refer to the state Claude was shown, so they turn into cards before the first move runs.
function world.resolve(row, position)
  local area = ROWS[row] and ROWS[row]()
  return area and area.cards[position]
end

local MOVES = {
  buy = function(card)
    local e = element(card, "buy")
    G.FUNCS.can_buy(e)
    if not e.config.button then return "not enough money" end
    if not G.FUNCS.check_for_buy_space(card) then return "no free slot" end
    G.FUNCS.buy_from_shop(e)
  end,
  buy_use = function(card)
    local e = element(card, "buy_and_use")
    G.FUNCS.can_buy(e)
    if not e.config.button then return "not enough money" end
    G.FUNCS.buy_from_shop(e)
  end,
  redeem = function(card)
    local e = element(card)
    G.FUNCS.can_buy(e)
    if not e.config.button then return "not enough money" end
    G.FUNCS.use_card(element(card))
  end,
  sell = function(card)
    if not card:can_sell_card() then return "this card can't be sold" end
    card:sell_card()
  end,
  use = function(card, on_hand)
    highlight(on_hand or {})
    if not card:can_use_consumeable() then return "it can't be used on those cards" end
    G.FUNCS.use_card(element(card))
  end,
  take = function(card, on_hand)
    highlight(on_hand or {})
    if card.ability.consumeable and not card:can_use_consumeable() then return "it can't be used on those cards" end
    if card.ability.set == "Joker" and not (card.edition and card.edition.negative)
      and #G.jokers.cards >= G.jokers.config.card_limit then return "no free joker slot" end
    G.FUNCS.use_card(element(card))
  end,
  reroll = function()
    local e = { config = {} }
    G.FUNCS.can_reroll(e)
    if not e.config.button then return "not enough money" end
    G.FUNCS.reroll_shop(nil)
  end,
}

-- Calls what the button calls, after asking what the button asks. Returns a reason if the game refuses.
function world.move(name, card, on_hand)
  local refusal = MOVES[name](card, on_hand)
  if refusal then return refusal end
  settle()
end

-- The game's own save table, written where Balabro can read it. RunSnapshot can't hold the draw order, so it stops there.
function world.write_decision(id)
  save_run()
  local name = "decision-" .. id .. ".jkr"
  assert(love.filesystem.write(name, STR_PACK(G.culled_table)))
  return love.filesystem.getSaveDirectory() .. "/" .. name
end

return world
