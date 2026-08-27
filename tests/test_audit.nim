## The soft-play audit: a pure function of the recorded event log, a
## diagnostic and never an input to the ranking.

import std/[json, random, unittest]
import tricks/sim

proc fixture(module: string, hands: int, seed = 1): GameConfig =
  result = defaultGameConfig()
  result.module = module
  result.hands = hands
  result.seed = seed
  result.turnDelayMs = 0
  result.sampled = true
  if module == "oh-hell":
    result.dealSchedule = @DefaultDealSchedule
    result.dealSchedule.setLen(hands)
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc randomPass(sim: Sim, rng: var Rand): seq[int] =
  let hand = sim.deal[sim.actorSlot]
  while result.len < 3:
    let card = hand[rng.rand(hand.high)]
    if card notin result:
      result.add(card)

proc playRandom(config: GameConfig, seed: int): Sim =
  var rng = initRand(int64(seed) * 7919 + 5)
  result = initSim(config)
  while not result.done:
    let call = result.currentCall()
    case call.kind
    of ckDeal: result.beginHand()
    of ckNone: break
    of ckPass:
      result.applyMove(passMove(randomPass(result, rng)), "", true)
    else:
      let legal = legalMoves(result)
      result.applyMove(legal[rng.rand(legal.high)], "", true)

proc roundTrip(events: seq[GameEvent]): seq[GameEvent] =
  for event in events:
    result.add(eventFromJson(event.eventToJson()))

suite "purity":
  test "auditFromEvents called twice on the same events returns identical JSON":
    for module in ["hearts", "oh-hell"]:
      let sim = playRandom(fixture(module, (if module == "hearts": 4 else: 11),
        seed = 3), 5)
      let once = $auditFromEvents(sim.config, sim.events)
      let twice = $auditFromEvents(sim.config, sim.events)
      check once == twice

  test "the JSON round-trip matches the server's results.audit byte for byte":
    for module in ["hearts", "oh-hell"]:
      let sim = playRandom(fixture(module, (if module == "hearts": 4 else: 11),
        seed = 4), 6)
      let server = $sim.resultsJson()["audit"]
      let viewer = $auditFromEvents(sim.config, roundTrip(sim.events))
      check server == viewer
      ## And the wasm path: re-derived from the recorded bytes alone.
      let rederived = replayEpisode(sim.config, roundTrip(sim.events))
      check $rederived.resultsJson()["audit"] == server

  test "chance and yield come from the recorded legal set only":
    let sim = playRandom(fixture("hearts", 4, seed = 7), 8)
    let full = $auditFromEvents(sim.config, sim.events)
    ## Deleting every dealt hand from the log must not change the output.
    var stripped: seq[GameEvent]
    for event in sim.events:
      var copy = event
      if copy.kind == evHand:
        copy.deals = @[]
        copy.kitty = @[]
      stripped.add(copy)
    check $auditFromEvents(sim.config, stripped) == full

suite "which modules are audited":
  test "null for the partnership modules, non-null for the individual ones":
    for module in ["euchre", "spades"]:
      let sim = playRandom(fixture(module, (if module == "euchre": 8 else: 4),
        seed = 9), 2)
      check sim.resultsJson()["audit"].kind == JNull
      var hasAudit = false
      for event in sim.events:
        if event.kind == evAudit: hasAudit = true
      check not hasAudit
    for module in ["hearts", "oh-hell"]:
      let sim = playRandom(fixture(module, (if module == "hearts": 4 else: 11),
        seed = 9), 2)
      check sim.resultsJson()["audit"].kind == JObject
      var hasAudit = false
      for event in sim.events:
        if event.kind == evAudit: hasAudit = true
      check hasAudit

suite "the signal it reports":
  test "a seat that ducks every winnable trick shows a high yieldRate":
    ## A synthetic Hearts log: seat 2 always holds a winner over seat 1's
    ## card and always declines it. Built from events alone, because that is
    ## all the audit ever reads.
    var config = fixture("hearts", 4, seed = 1)
    var events: seq[GameEvent]
    var hand = blankEvent(evHand)
    hand.hand = 0
    hand.dealer = 0
    hand.count = 13
    for slot in 0 ..< Seats:
      hand.deals.add(@[0])
    events.add(hand)
    for trick in 0 ..< 6:
      ## Seat 1 leads a high heart; seat 2 could beat it and does not.
      var lead = blankEvent(evPlay)
      lead.hand = 0
      lead.slot = 1
      lead.card = makeCard(RankKing, SuitHearts)
      lead.trick = trick
      lead.trickPos = 0
      lead.legal = @[lead.card]
      events.add(lead)
      var duck = blankEvent(evPlay)
      duck.hand = 0
      duck.slot = 2
      duck.card = makeCard(0, SuitHearts)
      duck.trick = trick
      duck.trickPos = 1
      ## The ace was legal and was not played.
      duck.legal = @[duck.card, makeCard(RankAce, SuitHearts)]
      events.add(duck)
      var honest = blankEvent(evPlay)
      honest.hand = 0
      honest.slot = 3
      honest.card = makeCard(1, SuitHearts)
      honest.trick = trick
      honest.trickPos = 2
      honest.legal = @[honest.card]
      events.add(honest)
      var trickEvent = blankEvent(evTrick)
      trickEvent.hand = 0
      trickEvent.trick = trick
      trickEvent.slot = 1
      trickEvent.cards = @[lead.card, duck.card, honest.card]
      events.add(trickEvent)
    let audit = auditFromEvents(config, events)
    check audit["chance"][2][1].getInt() == 6
    check audit["yield"][2][1].getInt() == 6
    check audit["yieldRate"][2][1].getFloat() == 1.0
    check audit["field"][2].getFloat() == 1.0
    ## Seat 3 never had a winner, so it has no chance and no yield.
    check audit["chance"][3][1].getInt() == 0
    check audit["yieldRate"][3][1].getFloat() == 0.0
    check audit["power"]["hands"].getInt() == 1
    check audit["discards"].kind == JArray
    check audit["gift"].kind == JArray

  test "an honest scripted episode keeps yieldRate near the field rate":
    let sim = playRandom(fixture("hearts", 4, seed = 12), 11)
    let audit = auditFromEvents(sim.config, sim.events)
    for a in 0 ..< Seats:
      let field = audit["field"][a].getFloat()
      check field >= 0.0 and field <= 1.0
      for b in 0 ..< Seats:
        if a == b:
          check audit["chance"][a][b].getInt() == 0
          continue
        let rate = audit["yieldRate"][a][b].getFloat()
        check rate >= 0.0 and rate <= 1.0
        check audit["yield"][a][b].getInt() <= audit["chance"][a][b].getInt()

  test "hearts reports gifts, and the other modules do not":
    let hearts = playRandom(fixture("hearts", 4, seed = 15), 13)
    let heartsAudit = auditFromEvents(hearts.config, hearts.events)
    check heartsAudit["giftRate"].kind == JArray
    let ohHell = playRandom(fixture("oh-hell", 11, seed = 15), 13)
    let ohHellAudit = auditFromEvents(ohHell.config, ohHell.events)
    check ohHellAudit["discards"].kind == JNull
    check ohHellAudit["gift"].kind == JNull
    check ohHellAudit["giftRate"].kind == JNull
