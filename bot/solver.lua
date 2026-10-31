-- Decides plays and discards. Loaded in a sandbox, so it knows the game only through `view` and the functions it's
-- handed, which means it can't cheat. A sampled draw shuffles a copy of `view.unseen`, never the deck.
--
-- One rehearsal costs about 0.25 ms. All 218 discards x 218 plays x many draws is far too many, so discards narrow in
-- stages and stop at the deadline with the best answer so far.
local solver = {}

local DISCARD_BUDGET = 1.0
local PLAY_BUDGET = 3.0
local FILTER_DRAWS, WIDE_KEEP, WIDE_DRAWS, NARROW_KEEP, NARROW_DRAWS, PLAYS_PER_DRAW = 6, 16, 6, 4, 12, 20

local function new_rng(seed)
  local state = seed
  return function()
    -- Numerical Recipes' linear congruential step: plain doubles, so it needs no bit library in the sandbox.
    state = (state * 16807) % 2147483647
    return state / 2147483647
  end
end

local function shuffled(list, rng)
  local out = {}
  for i, v in ipairs(list) do out[i] = v end
  for i = #out, 2, -1 do
    local j = math.floor(rng() * i) + 1
    out[i], out[j] = out[j], out[i]
  end
  return out
end

-- The best poker hand's base value, ignoring jokers. Only used to choose what is worth rehearsing.
local function quick_value(cards, view)
  local ranks, suits, wilds = {}, {}, 0
  local max_same, second_same = 0, 0
  for _, c in ipairs(cards) do
    if not c.stone and not c.face_down and c.rank then
      ranks[c.rank] = (ranks[c.rank] or 0) + 1
      if c.wild then wilds = wilds + 1 else suits[c.suit] = (suits[c.suit] or 0) + 1 end
    end
  end
  for _, n in pairs(ranks) do
    if n > max_same then max_same, second_same = n, max_same
    elseif n > second_same then second_same = n end
  end
  local need = view.four_fingers and 4 or 5
  local flush = false
  for _, n in pairs(suits) do if n + wilds >= need then flush = true end end
  if wilds >= need then flush = true end
  local run, straight = 0, false
  for r = 1, 14 do
    local present = ranks[r] or (r == 1 and ranks[14])
    run = present and run + 1 or 0
    if run >= need then straight = true end
  end

  local name = "High Card"
  if max_same >= 5 then name = "Five of a Kind"
  elseif straight and flush then name = "Straight Flush"
  elseif max_same == 4 then name = "Four of a Kind"
  elseif max_same == 3 and second_same >= 2 then name = "Full House"
  elseif flush then name = "Flush"
  elseif straight then name = "Straight"
  elseif max_same == 3 then name = "Three of a Kind"
  elseif max_same == 2 and second_same == 2 then name = "Two Pair"
  elseif max_same == 2 then name = "Pair"
  end
  local level = view.levels[name]
  local chips = level.chips
  for _, c in ipairs(cards) do chips = chips + (c.value or 0) end
  return chips * level.mult
end

local function ids_of(cards)
  local out = {}
  for i, c in ipairs(cards) do out[i] = c.id end
  return out
end

local function each_play(hand, visit)
  local n, forced_mask = #hand, 0
  for i, c in ipairs(hand) do if c.forced then forced_mask = forced_mask + 2 ^ (i - 1) end end
  for mask = 1, 2 ^ n - 1 do
    local play, held, m = {}, {}, mask
    local count, forced_seen = 0, 0
    for i = 1, n do
      if m % 2 == 1 then
        count = count + 1
        play[count] = hand[i]
        if hand[i].forced then forced_seen = forced_seen + 2 ^ (i - 1) end
      else
        held[#held + 1] = hand[i]
      end
      m = math.floor(m / 2)
    end
    if count <= 5 and forced_seen == forced_mask then visit(play, held, mask) end
  end
end

-- `stand_in` holds a sampled unseen card for each face-down card, so rehearsals work without knowing what it is.
local function rehearse(ctx, play, held, order, stand_in)
  local function ids(cards)
    local out = {}
    for i, c in ipairs(cards) do out[i] = c.face_down and stand_in[c.id] or c.id end
    return out
  end
  return ctx.world.rehearse(ids(play), ids(held), ctx.rng(), order)
end

local function best_play(hand, ctx, order, stand_in, deadline)
  local results, chancy_seen, memo = {}, false, {}
  local use_memo = #hand > 8
  each_play(hand, function(play, held)
    if ctx.now() > deadline and results[1] then return end
    local memo_key
    if use_memo then
      local keys = {}
      for i, c in ipairs(play) do keys[i] = c.key or c.id end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for i, k in ipairs(keys) do keys[i] = tostring(k) end
      memo_key = table.concat(keys, ",")
      if memo[memo_key] then return end
    end
    local score, name, chancy = rehearse(ctx, play, held, order, stand_in)
    chancy_seen = chancy_seen or chancy
    results[#results + 1] = { play = play, held = held, score = score, name = name, chancy = chancy }
    if memo_key then memo[memo_key] = true end
  end)
  table.sort(results, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return #a.play > #b.play
  end)
  if chancy_seen then
    for i = 1, math.min(5, #results) do
      local total = results[i].score
      for _ = 2, 5 do total = total + rehearse(ctx, results[i].play, results[i].held, order, stand_in) end
      results[i].score = total / 5
    end
    local top = {}
    for i = 1, math.min(5, #results) do top[i] = results[i] end
    table.sort(top, function(a, b) return a.score > b.score end)
    return top[1]
  end
  return results[1]
end

-- Adjacent swaps, because +Mult before XMult and Blueprint's neighbour are what mostly matter.
local function better_order(best, view, ctx, stand_in)
  if #view.jokers < 2 then return nil end
  for _, j in ipairs(view.jokers) do if j.face_down then return nil end end
  local order, improved, top = ids_of(view.jokers), false, nil
  top = rehearse(ctx, best.play, best.held, order, stand_in)
  for _ = 1, 2 do
    for i = 1, #order - 1 do
      order[i], order[i + 1] = order[i + 1], order[i]
      local score = rehearse(ctx, best.play, best.held, order, stand_in)
      if score > top * 1.001 then top, improved = score, true
      else order[i], order[i + 1] = order[i + 1], order[i] end
    end
  end
  return improved and order or nil
end

local function draw_hand(kept, view, rng)
  local deck = shuffled(view.unseen, rng)
  local hand = {}
  for i, c in ipairs(kept) do hand[i] = c end
  for i = 1, math.min(view.hand_size - #kept, #deck) do hand[#hand + 1] = deck[i] end
  return hand
end

local function plays_worth_rehearsing(hand, view, limit)
  local options = {}
  each_play(hand, function(play, held)
    options[#options + 1] = { play = play, held = held, value = quick_value(play, view) }
  end)
  table.sort(options, function(a, b) return a.value > b.value end)
  for i = #options, limit + 1, -1 do options[i] = nil end
  return options
end

local function score_keep(kept, view, ctx, stand_in, pace, draws, deadline)
  local hits, total_log, tried = 0, 0, 0
  for _ = 1, draws do
    if ctx.now() > deadline then break end
    local hand = draw_hand(kept, view, ctx.rng)
    local top = 0
    for _, option in ipairs(plays_worth_rehearsing(hand, view, PLAYS_PER_DRAW)) do
      local score = rehearse(ctx, option.play, option.held, nil, stand_in)
      if score > top then top = score end
    end
    tried = tried + 1
    if top >= pace then hits = hits + 1 end
    total_log = total_log + math.log10(top + 1)
  end
  if tried == 0 then return 0, 0 end
  return hits / tried, total_log / tried
end

local function better(a_reach, a_log, b_reach, b_log)
  if a_reach ~= b_reach then return a_reach > b_reach end
  return a_log > b_log
end

local function best_discard(view, ctx, stand_in, pace, deadline)
  local keeps = {}
  each_play(view.hand, function(play, held)
    local value = 0
    for _ = 1, FILTER_DRAWS do value = value + quick_value(draw_hand(held, view, ctx.rng), view) end
    keeps[#keeps + 1] = { discard = play, kept = held, value = value }
  end)
  table.sort(keeps, function(a, b) return a.value > b.value end)

  for i = 1, #keeps do
    if i > WIDE_KEEP then keeps[i] = nil else
      keeps[i].reach, keeps[i].log = score_keep(keeps[i].kept, view, ctx, stand_in, pace, WIDE_DRAWS, deadline)
    end
  end
  table.sort(keeps, function(a, b) return better(a.reach, a.log, b.reach, b.log) end)
  for i = 1, math.min(NARROW_KEEP, #keeps) do
    local reach, log = score_keep(keeps[i].kept, view, ctx, stand_in, pace, NARROW_DRAWS, deadline)
    keeps[i].reach, keeps[i].log = (keeps[i].reach * WIDE_DRAWS + reach * NARROW_DRAWS) / (WIDE_DRAWS + NARROW_DRAWS),
      (keeps[i].log * WIDE_DRAWS + log * NARROW_DRAWS) / (WIDE_DRAWS + NARROW_DRAWS)
  end
  for i = #keeps, NARROW_KEEP + 1, -1 do keeps[i] = nil end
  table.sort(keeps, function(a, b) return better(a.reach, a.log, b.reach, b.log) end)
  return keeps[1]
end

local APPRAISAL_DRAWS, APPRAISAL_PLAYS = 7, 30

-- What the jokers score from a fresh hand, and what each change would do, on the same hands so the differences are real.
-- Only meaningful with no hand on the table, as in a shop.
function solver.appraise(view, ctx)
  ctx.rng = new_rng(ctx.seed)
  local hands = {}
  for i = 1, APPRAISAL_DRAWS do
    hands[i] = plays_worth_rehearsing(draw_hand({}, view, ctx.rng), view, APPRAISAL_PLAYS)
  end
  local function scores(order)
    local tops = {}
    for i, options in ipairs(hands) do
      local top = 0
      for _, option in ipairs(options) do
        local score = rehearse(ctx, option.play, option.held, order, {})
        if score > top then top = score end
      end
      tops[i] = top
    end
    table.sort(tops)
    return tops
  end
  return ctx.world.as_fresh_round(function()
    local owned = ids_of(view.jokers)
    local now = scores(owned)
    local result = { low = now[1], typical = now[math.ceil(#now / 2)], high = now[#now], offers = {}, owned = {} }
    for _, offer in ipairs(view.offers) do
      local order = ids_of(view.jokers)
      order[#order + 1] = offer.id
      local with = scores(order)
      result.offers[#result.offers + 1] = { row = offer.row, position = offer.position, name = offer.name, typical = with[math.ceil(#with / 2)] }
    end
    if #view.jokers > 1 then
      for i, joker in ipairs(view.jokers) do
        local order = {}
        for j, id in ipairs(owned) do if j ~= i then order[#order + 1] = id end end
        local without = scores(order)
        result.owned[#result.owned + 1] = { position = joker.position, name = joker.name, typical = without[math.ceil(#without / 2)] }
      end
    end
    return result
  end)
end

-- Returns { action = "play" | "discard", ids, order, doing, predicted }.
-- ctx = { world, now, seed }. The seed comes from the caller's clock, never from the game's random stream.
function solver.decide(view, ctx)
  ctx.rng = new_rng(ctx.seed)
  local stand_in, deck = {}, shuffled(view.unseen, ctx.rng)
  local used = 0
  for _, c in ipairs(view.hand) do
    if c.face_down then used = used + 1; stand_in[c.id] = deck[used] and deck[used].id end
  end

  local start = ctx.now()
  local best = best_play(view.hand, ctx, nil, stand_in, start + PLAY_BUDGET)
  local order = better_order(best, view, ctx, stand_in)
  if order then best = best_play(view.hand, ctx, order, stand_in, start + PLAY_BUDGET) end

  local function play_best()
    return { action = "play", ids = ids_of(best.play), order = order, predicted = (not best.chancy and not next(stand_in)) and best.score or nil,
      doing = "Playing " .. best.name .. " for about " .. string.format("%.0f", best.score) .. " of " .. string.format("%.0f", view.need) }
  end

  local pace = view.need / math.max(view.hands_left, 1)
  if best.score >= view.need or view.discards_left <= 0 or best.score >= pace then return play_best() end

  local pick = best_discard(view, ctx, stand_in, pace, ctx.now() + DISCARD_BUDGET)
  if pick and better(pick.reach, pick.log, 0, math.log10(best.score + 1)) then
    return { action = "discard", ids = ids_of(pick.discard),
      doing = string.format("Discarding %d cards, %.0f%% to reach %.0f", #pick.discard, pick.reach * 100, pace) }
  end
  return play_best()
end

return solver
