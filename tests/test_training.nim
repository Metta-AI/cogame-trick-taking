## Teacher and prompt cannot observe opponents' hidden hands.
import std/[algorithm, json, sequtils, strutils]
import bitworld/decision_trajectory
import tricks/[llm, sim, training]

when isMainModule:
  let manifest = parseFile("coworld_manifest_template.json")
  var labels = 0
  for entry in manifest["variants"]:
    for seed in 1 .. 3:
      var config = defaultGameConfig()
      let raw = copy(entry["game_config"])
      raw["tokens"] = newJArray()
      for seat in 0 ..< raw["players"].len: raw["tokens"].add(%("t" & $seat))
      raw["seed"] = %seed
      config.update($raw)
      config = sampleEpisode(config)
      var sim = initSim(config)
      let trajectory = newDecisionTrajectory("test", "test", "test", "test", "test")
      while not sim.done:
        if sim.currentCall().kind == ckDeal:
          sim.beginHand()
          continue
        let seat = sim.actorSlot
        let teacher = baselineDecision(sim, "tracker")
        let privatePrompt = userPrompt(sim, "maximize score")
        for permutation in 0 ..< 6:
          var hidden = sim
          var pool: seq[int]
          for other in 0 ..< sim.config.players.len:
            if other != seat:
              for card in sim.deal[other]: pool.add(card)
          if pool.len > 0: pool.rotateLeft(permutation mod pool.len)
          var cursor = 0
          for other in 0 ..< sim.config.players.len:
            if other == seat: continue
            hidden.deal[other] = @[]
            for index in 0 ..< sim.deal[other].len:
              hidden.deal[other].add(pool[cursor])
              inc cursor
          hidden.kitty = reversed(sim.kitty)
          doAssert userPrompt(hidden, "maximize score") == privatePrompt
          doAssert systemPrompt(hidden, seat) == systemPrompt(sim, seat)
          doAssert scriptedMove(hidden, "tracker") == teacher.move
        let before = sim
        let completion = sim.decisionAction(teacher)
        let parsed = parseDecision(sim, extractJsonObject($completion))
        sim.applyMove(parsed.move, parsed.notes, true)
        trajectory.recordAppliedDecision(before, sim, seat, teacher, "maximize score", true)
        inc labels
      trajectory.finishTrajectory(sim)
      for line in trajectory.eventsJsonl().splitLines():
        if line.len == 0: continue
        let event = parseJson(line)
        if event["event_type"].getStr() == "decision":
          doAssert event["attempts"][0]["parsed_action"] == event["executed_action"]
      echo entry["id"].getStr(), " seed=", seed, " complete"
  doAssert labels > 0
  echo "hidden-state invariant labels=", labels
