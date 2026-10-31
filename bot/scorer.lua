-- Works out exact scores for the coach from the player's saves, in the private copy of the game. Loaded in a sandbox.
-- The save holds the draw order, so all this file ever reads is `world.see()`, the same view the bot plays from.
local scorer = {}

function scorer.main(ctx)
  local world = ctx.world
  world.start({ deck = "b_red", stake = 1 })
  world.next_moment()
  ctx.send("ready", world.version())
  world.set_idle(true)
  while true do
    local id, path, meta = ctx.next_request()
    world.set_idle(false)
    world.match_unlocks(meta)
    world.load_save(path)
    local moment = world.next_moment()
    local pack_file = moment == "pack" and world.write_decision("pack") or ""
    local facts = ""
    if moment == "hand" then
      facts = ctx.brief.exact_scores(world, ctx.solver, ctx.now)
    elseif moment == "shop" or moment == "pack" then
      facts = ctx.brief.score_check(world, ctx.solver, ctx.now, moment)
    end
    ctx.send("scored", id, pack_file, facts)
    world.set_idle(true)
  end
end

return scorer
