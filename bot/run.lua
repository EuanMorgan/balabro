-- One run from start to finish. Loaded in a sandbox: it reaches the game only through `world`, and Claude only through `ask`.
local run = {}

local function plan_lines(plan)
  local why, moves, ending = nil, {}, nil
  for _, line in ipairs(plan) do
    local head = line:match("^(%a+):")
    if head == "why" then why = line:sub(5)
    elseif head == "end" then ending = line:sub(5)
    elseif line ~= "" then moves[#moves + 1] = line end
  end
  return why, moves, ending or "next play"
end

local function words(line)
  local out = {}
  for word in line:gmatch("%S+") do out[#out + 1] = word end
  return out
end

-- `use consumable 1 on hand 2 5` -> the consumable and hand cards 2 and 5.
local function targets(parts, from, world)
  local cards = {}
  for i = from, #parts do cards[#cards + 1] = world.resolve("hand", tonumber(parts[i])) end
  return cards
end

-- Each line becomes a card and a move before any move runs, so an earlier buy can't renumber a later one.
local function carry_out(moves, id, ctx)
  local world, resolved = ctx.world, {}
  for _, line in ipairs(moves) do
    local parts = words(line)
    local verb, row, position = parts[1], parts[2], tonumber(parts[3])
    local name = verb
    if verb == "buy" and row == "voucher" then name = "redeem"
    elseif verb == "buyuse" then name = "buy_use" end
    local card = world.resolve(row or "", position or 0)
    local on_hand = parts[4] == "on" and targets(parts, 6, world) or nil
    resolved[#resolved + 1] = { line = line, name = name, card = card, on_hand = on_hand }
  end
  for _, step in ipairs(resolved) do
    if not step.card then
      ctx.send("refused", id, step.line, "nothing is at that position")
    else
      local refusal = world.move(step.name, step.card, step.on_hand)
      if refusal then ctx.send("refused", id, step.line, refusal) end
    end
  end
end

local function status(ctx, doing)
  local world = ctx.world
  ctx.send("status", world.ante(), world.round(), world.dollars(), world.best_hand(), doing)
end

local function question(ctx, kind)
  ctx.next_question = ctx.next_question + 1
  local id = ctx.next_question
  local plan = ctx.ask(id, kind, ctx.world.picks_left(), ctx.world.write_decision(id))
  local why, moves, ending = plan_lines(plan)
  if why then status(ctx, why) end
  carry_out(moves, id, ctx)
  return ending
end

local function hand_moment(ctx, state)
  local world, view = ctx.world, ctx.world.see()
  if not state.asked_this_round then
    state.asked_this_round = true
    for _, consumable in ipairs(view.consumables) do
      if consumable.needs_hand then
        question(ctx, "hand")
        return
      end
    end
  end
  local decision = ctx.solver.decide(view, { world = world, now = ctx.now, seed = (math.floor(ctx.now() * 1000) % 2147483646) + 1 })
  world.audit()
  status(ctx, decision.doing)
  if decision.action == "discard" then
    world.discard(decision.ids)
  else
    local actual, name = world.play(decision.ids, decision.order)
    ctx.send("played", name, decision.predicted and string.format("%.17g", decision.predicted) or "-", string.format("%.17g", actual))
    if actual >= 1.8e308 then return "naneinf" end
  end
end

-- A refused reroll or pack just leaves the shop as it is, so Claude is asked again with the refusal in its state.
local function shop_moment(ctx, state)
  local ending = question(ctx, "shop")
  if ending == "reroll" then
    local refusal = ctx.world.move("reroll")
    if refusal then ctx.send("refused", ctx.next_question, "reroll", refusal) end
  elseif ending:match("^open ") then
    local card = ctx.world.resolve("pack", tonumber(ending:match("%d+")) or 0)
    local refusal = "nothing is at that position"
    if card then refusal = ctx.world.move("redeem", card) end
    if refusal then ctx.send("refused", ctx.next_question, ending, refusal) end
  else
    state.next_blind = ending:match("skip") and "skip" or "play"
    ctx.world.leave_shop()
  end
end

local function pack_moment(ctx, state)
  local world = ctx.world
  local ending = question(ctx, "pack")
  if ending:match("skip") then state.next_blind = "skip" end
  if world.picks_left() > 0 then world.skip_pack() end
end

local function blind_moment(ctx, state)
  local world = ctx.world
  state.asked_this_round = false
  if world.blind_is_boss() then
    world.select_blind()
    return
  end
  local choice = state.next_blind
  state.next_blind = nil
  if not choice then
    local ending = question(ctx, "blind")
    choice = ending:match("skip") and "skip" or "play"
  end
  if choice == "skip" then world.skip_blind() else world.select_blind() end
end

function run.main(ctx)
  local world, state = ctx.world, {}
  ctx.next_question = 0
  world.start({ deck = ctx.deck, stake = ctx.stake })
  ctx.send("ready", world.version())
  while true do
    local moment = world.next_moment()
    if moment == "game_over" then
      ctx.send("ended", "lost", world.ante(), world.round(), world.best_hand())
      return
    elseif moment == "win_screen" then
      if ctx.goal == "win" then
        ctx.send("ended", "won", world.ante(), world.round(), world.best_hand())
        return
      end
      world.continue_endless()
    elseif moment == "cash_out" then
      world.cash_out()
    elseif moment == "blind" then
      blind_moment(ctx, state)
    elseif moment == "hand" then
      if hand_moment(ctx, state) == "naneinf" then
        ctx.send("ended", "naneinf", world.ante(), world.round(), world.best_hand())
        return
      end
    elseif moment == "shop" then
      shop_moment(ctx, state)
    elseif moment == "pack" then
      pack_moment(ctx, state)
    end
  end
end

return run
