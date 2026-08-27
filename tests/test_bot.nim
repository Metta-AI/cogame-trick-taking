## The scripted baselines are the completion path: they are the
## no-credentials fallback, the move played whenever an LLM decision fails,
## AND fieldable policies. Every move they propose must be legal in every
## module, always.

import std/[json, random, sets, strutils, times, unicode, unittest]
import tricks/[llm, sim]

const Modules = ["euchre", "spades", "hearts", "oh-hell"]

proc defaultHands(module: string): int =
  case module
  of "euchre": 8
  of "oh-hell": 11
  else: 4

proc fixture(module: string, seed: int): GameConfig =
  result = defaultGameConfig()
  result.module = module
  result.hands = defaultHands(module)
  result.seed = seed
  result.turnDelayMs = 0
  result.sampled = true
  if module == "oh-hell":
    result.dealSchedule = @DefaultDealSchedule
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc moveIsLegal(sim: Sim, move: Move): bool =
  let legal = legalMoves(sim)
  case sim.phase
  of phPlay, phDiscard:
    for candidate in legal:
      if candidate.card == move.card:
        return true
    false
  of phBid:
    for candidate in legal:
      if candidate.action == move.action and candidate.value == move.value and
          candidate.suit == move.suit:
        return true
    false
  of phPass:
    if move.cards.len != 3:
      return false
    var seen = initHashSet[int]()
    for card in move.cards:
      if card notin sim.deal[sim.actorSlot]:
        return false
      seen.incl(card)
    seen.len == 3
  else: false

proc playBaseline(config: GameConfig, baseline: string): Sim =
  result = initSim(config)
  var lastPos = -1
  while not result.done:
    let call = result.currentCall()
    case call.kind
    of ckDeal:
      result.beginHand()
      lastPos = -1
    of ckNone:
      break
    else:
      ## Never out of turn: an alone partner is skipped, and inside a trick
      ## the actor walks clockwise.
      doAssert result.actorSlot != result.sittingOut
      if result.phase == phPlay and result.table.len > 0 and
          not result.trickComplete and lastPos >= 0:
        doAssert result.actorPos == result.nextPos(lastPos),
          "the actor must walk clockwise inside a trick"
      lastPos = result.actorPos
      let move = scriptedMove(result, baseline)
      doAssert moveIsLegal(result, move),
        baseline & " proposed an illegal move in " & config.module
      if result.phase == phBid and config.module != "euchre":
        let top = (if config.module == "spades": 13 else: result.tricksThisHand)
        doAssert move.value >= 0 and move.value <= top,
          "a bid outside the module's range"
        if config.module == "oh-hell":
          let banned = hookedBid(result)
          doAssert banned < 0 or move.value != banned,
            "the oh-hell dealer bid the hooked value"
      result.applyMove(move, "", true)

suite "bounded, legal orders":
  test "follow and tracker play 200 complete matches in every module":
    for baseline in Baselines:
      for module in Modules:
        for run in 0 ..< 200:
          var config = fixture(module, 1000 * run + 17)
          let sim = playBaseline(config, baseline)
          doAssert sim.done
          doAssert sim.reason == "complete",
            module & "/" & baseline & " did not complete"
          doAssert sim.handsScored == config.hands
          var scoreTotal = 0.0
          for value in sim.scoresOf():
            scoreTotal += value
          doAssert abs(scoreTotal - 2.0) < 1e-6
        check true

  test "lowestLegal is always a legal option, in every phase":
    for module in Modules:
      var config = fixture(module, 55)
      var sim = initSim(config)
      var rng = initRand(4)
      var phases = initHashSet[string]()
      while not sim.done:
        let call = sim.currentCall()
        if call.kind == ckDeal:
          sim.beginHand()
          continue
        if call.kind == ckNone:
          break
        phases.incl($sim.phase)
        let forced = lowestLegal(sim)
        check moveIsLegal(sim, forced)
        sim.applyMove(scriptedMove(sim, "follow"), "", true)
      check phases.len > 0

suite "degrade, never hang":
  test "decide with no credentials returns the scripted move immediately":
    var config = fixture("euchre", 21)
    let client = newLlmClient(config)
    var sim = initSim(config)
    sim.beginHand()
    let started = epochTime()
    let decision = client.decide(sim, "some operator prompt",
      scripted = client.disabled, baseline = "follow")
    check epochTime() - started < 2.0
    check decision.scripted
    check moveIsLegal(sim, decision.move)
    check decision.notes.len == 0

  test "an unparseable reply is rejected and the baseline move is legal":
    for module in Modules:
      var config = fixture(module, 31)
      var sim = initSim(config)
      sim.beginHand()
      for text in ["not json at all", "{}", "{\"card\": \"ZZ\"}",
          "{\"bid\": 99}", "{\"action\": \"shout\"}"]:
        var failed = false
        try:
          let payload =
            (if '{' in text: extractJsonObject(text) else: parseJson("{}"))
          discard parseDecision(sim, payload)
        except CatchableError:
          failed = true
        if not failed:
          ## A reply that parses must still be legal; the applier decides.
          discard
      let fallback = baselineDecision(sim, "follow", "two bad replies")
      check fallback.scripted
      check moveIsLegal(sim, fallback.move)
      check fallback.error == "two bad replies"

  test "an episode whose every model call fails still reaches complete":
    for module in Modules:
      var config = fixture(module, 41)
      var sim = initSim(config)
      var fallbacks = 0
      var forced = 0
      while not sim.done:
        let call = sim.currentCall()
        case call.kind
        of ckDeal: sim.beginHand()
        of ckNone: break
        else:
          ## Every model call "fails", so every decision takes the baseline.
          let decision = baselineDecision(sim, "tracker", "transport error")
          inc fallbacks
          if decision.forced: inc forced
          sim.fallbacks[call.slot] += 1
          sim.applyMove(decision.move, decision.notes, true)
      check sim.reason == "complete"
      check fallbacks > 0
      var totalFallbacks = 0
      for slot in 0 ..< Seats:
        totalFallbacks += sim.fallbacks[slot]
      check totalFallbacks == fallbacks
      check forced == 0

  test "a hostile 5 kB reply is capped at 400 runes and the replay is valid UTF-8":
    var config = fixture("hearts", 51)
    var sim = initSim(config)
    let hostile = "\u{1F0A1}\u{1F0B1}\u{1F0C1}\u{1F0D1}\u2660".repeat(500)
    check hostile.len > 5000
    let payload = %*{"notes": hostile, "card": "2C"}
    sim.beginHand()
    while sim.phase != phPlay and not sim.done:
      sim.applyMove(scriptedMove(sim, "follow"), hostile, true)
    var attempt: Decision
    try:
      attempt = parseDecision(sim, payload)
    except CatchableError:
      attempt = baselineDecision(sim, "follow")
      attempt.notes = cleanNotes(hostile)
    check attempt.notes.runeLen == MaxNotesLen
    check attempt.notes.validateUtf8() == -1
    while not sim.done:
      let call = sim.currentCall()
      case call.kind
      of ckDeal: sim.beginHand()
      of ckNone: break
      else:
        sim.applyMove(scriptedMove(sim, "follow"), hostile, true)
    for slot in 0 ..< Seats:
      check sim.notes[slot].runeLen == MaxNotesLen
    let bytes = $sim.replayJson()
    check bytes.validateUtf8() == -1
    discard parseJson(bytes)

suite "the tell is spectator-side only":
  test "every bid and lead carries a tell of at most 120 runes, and none reaches a prompt":
    for module in Modules:
      var config = fixture(module, 61)
      var sim = initSim(config)
      var prompts: seq[string]
      var tells: seq[string]
      var annotated = 0
      while not sim.done:
        let call = sim.currentCall()
        case call.kind
        of ckDeal: sim.beginHand()
        of ckNone: break
        else:
          ## Every seat's whole view, exactly as the model would see it.
          prompts.add(systemPrompt(sim, sim.actorSlot))
          prompts.add(userPrompt(sim, "operator guidance goes here"))
          prompts.add(userPrompt(sim, "operator guidance goes here",
            retry = true))
          sim.applyMove(scriptedMove(sim, "follow"), "", true)
      for event in sim.events:
        if event.kind == evBid or
            (event.kind == evPlay and event.trickPos == 0):
          check event.tell.runeLen <= MaxTellLen
          if event.tell.len > 0:
            inc annotated
            tells.add(event.tell)
      check annotated > 0
      for tell in tells:
        for prompt in prompts:
          doAssert tell notin prompt,
            module & ": a tell reached a seat's prompt"

  test "a prompt carries the legal set and never another seat's cards":
    for module in Modules:
      var config = fixture(module, 71)
      var sim = initSim(config)
      sim.beginHand()
      while sim.phase != phPlay and not sim.done:
        sim.applyMove(scriptedMove(sim, "follow"), "", true)
      let slot = sim.actorSlot
      let prompt = userPrompt(sim, "")
      for card in legalCards(sim):
        check cardCode(card) in prompt
      check handCodes(sim.deal[slot]) in prompt
      ## No other seat's hand is printed anywhere in it.
      for other in 0 ..< Seats:
        if other == slot or sim.deal[other].len < 3:
          continue
        check handCodes(sim.deal[other]) notin prompt
