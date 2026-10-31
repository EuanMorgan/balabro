-- Facts a careful player would work out for themselves, written for Claude. Loaded in a sandbox.
local brief = {}

local function number(n)
  if n >= 1e11 then return string.format("%.3e", n) end
  local text = string.format("%.0f", n)
  local grouped = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (grouped:gsub("^,", ""))
end

local function decimal(n)
  return (string.format("%.2f", n):gsub("%.?0+$", ""))
end

local function seed(now) return (math.floor(now() * 1000) % 2147483646) + 1 end

function brief.score_check(world, solver, now, kind)
  local t = world.targets()
  local lines = { string.format("Score check: this ante's blinds need %s, %s and %s for the Boss. Next ante's Small Blind needs %s. Your best hand this run is %s.",
    number(t.small), number(t.big), number(t.boss), number(t.next_small), number(world.best_hand())) }
  local view = world.see()
  if (kind == "shop" or kind == "pack") and #view.hand == 0 then
    local a = solver.appraise(view, { world = world, now = now, seed = seed(now) })
    world.audit()
    lines[#lines + 1] = string.format("From a fresh hand your jokers typically score %s (worst %s, best %s of 7 hands).", number(a.typical), number(a.low), number(a.high))
    local changes = {}
    for _, offer in ipairs(a.offers) do
      changes[#changes + 1] = string.format("adding %s (%s %d) makes it %s", offer.name, offer.row, offer.position, number(offer.typical))
    end
    for _, joker in ipairs(a.owned) do
      changes[#changes + 1] = string.format("without %s (joker %d) it would be %s", joker.name, joker.position, number(joker.typical))
    end
    if #changes > 0 then lines[#lines + 1] = "On those same hands: " .. table.concat(changes, "; ") .. "." end
  end
  return table.concat(lines, " ")
end

local function labels(cards)
  local out = {}
  for i, c in ipairs(cards) do out[i] = c.label end
  return table.concat(out, " ")
end

function brief.exact_scores(world, solver, now)
  local view = world.see()
  local report = solver.report(view, { world = world, now = now, seed = seed(now) })
  world.audit()
  local lines = { string.format("EXACT SCORES: You need %s with %d hands left, so about %s a hand.", number(view.need), view.hands_left, number(report.pace)) }
  for _, play in ipairs(report.plays) do
    local chance = play.chancy and string.format(" (%s to %s by chance)", number(play.low), number(play.high)) or ""
    lines[#lines + 1] = string.format("%s, %s: %s x %s %s %s%s.", play.name, labels(play.cards), number(play.chips), decimal(play.mult),
      play.chancy and "≈" or "=", number(play.score), chance)
  end
  if report.order then
    local names, by_id = {}, {}
    for _, joker in ipairs(view.jokers) do by_id[joker.id] = joker.name end
    for i, id in ipairs(report.order) do names[i] = by_id[id] end
    lines[#lines + 1] = string.format("Ordering the jokers %s lifts the best play to %s.", table.concat(names, ", "), number(report.order_score))
  end
  if report.discard then
    lines[#lines + 1] = string.format("Best discard: %s, which reaches %s on the next hand %.0f%% of the time.", labels(report.discard), number(report.pace), report.reach * 100)
  end
  return table.concat(lines, " ")
end

return brief
