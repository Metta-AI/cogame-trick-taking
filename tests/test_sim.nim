## The engine and the four rule modules.

import std/[json, os, random, sets, strutils, unicode, unittest]
import tricks/sim
import ../tools/ci/gen_fixture

proc fixture(module: string, hands: int, seed = 1): GameConfig =
  result = defaultGameConfig()
  result.module = module
  result.hands = hands
  result.seed = seed
  result.turnDelayMs = 0
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  if module == "oh-hell":
    result.dealSchedule = @DefaultDealSchedule
    result.dealSchedule.setLen(hands)
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc defaultHands(module: string): int =
  case module
  of "euchre": 8
  of "oh-hell": 11
  else: 4

const Modules = ["euchre", "spades", "hearts", "oh-hell"]

proc randomPass(sim: Sim, rng: var Rand): seq[int] =
  let hand = sim.deal[sim.actorSlot]
  while result.len < 3:
    let card = hand[rng.rand(hand.high)]
    if card notin result:
      result.add(card)

proc playRandom(config: GameConfig, seed: int, checkLegality = false): Sim =
  ## One whole episode of uniformly random LEGAL moves.
  var rng = initRand(int64(seed) * 7919 + 5)
  result = initSim(config)
  while not result.done:
    let call = result.currentCall()
    case call.kind
    of ckDeal:
      result.beginHand()
    of ckNone:
      break
    of ckPass:
      result.applyMove(passMove(randomPass(result, rng)), "", true)
    else:
      let legal = legalMoves(result)
      doAssert legal.len > 0, "legalMoves is never empty"
      if checkLegality and result.phase == phPlay:
        let slot = result.actorSlot
        let cards = legalCards(result)
        for card in cards:
          doAssert card in result.deal[slot],
            "a legal card the seat does not hold"
      result.applyMove(legal[rng.rand(legal.high)], "", true)

proc playRecording(config: GameConfig, seed: int,
    live: var seq[(int, string)]): Sim =
  ## One whole episode, recording the LIVE per-tick state the server
  ## broadcasts after every applied move (`server.nim` calls
  ## `frameStateJson` there and then discards it), paired with the number of
  ## events the log carried at that instant. That pairing is what lets a
  ## test compare frame by frame: `replayMatch(config, events)[n]` is the
  ## table after the first `n` events, so it must equal the live state at
  ## the tick where the log reached `n`.
  var rng = initRand(int64(seed) * 7919 + 5)
  result = initSim(config)
  live.add((result.events.len, $result.frameStateJson()))
  while not result.done:
    let call = result.currentCall()
    case call.kind
    of ckDeal:
      result.beginHand()
    of ckNone:
      break
    of ckPass:
      result.applyMove(passMove(randomPass(result, rng)), "", true)
    else:
      let legal = legalMoves(result)
      result.applyMove(legal[rng.rand(legal.high)], "", true)
    live.add((result.events.len, $result.frameStateJson()))

proc eventsJson(events: seq[GameEvent]): string =
  var node = newJArray()
  for event in events:
    node.add(event.eventToJson())
  $node

proc roundTrip(events: seq[GameEvent]): seq[GameEvent] =
  for event in events:
    result.add(eventFromJson(event.eventToJson()))

# ---------------------------------------------------------------------------

suite "deal":
  test "every module deals its card count with no card twice and none lost":
    for module in Modules:
      let config = fixture(module, defaultHands(module), seed = 11)
      var sim = initSim(config)
      let m = moduleFor(module)
      let deckSize = m.deck().len
      check deckSize == (if module == "euchre": 24 else: 52)
      for hand in 0 ..< config.hands:
        sim.beginHand()
        check sim.dealer == hand mod Seats
        let per = m.cardsPerHand(config, hand)
        var seen = initHashSet[int]()
        for slot in 0 ..< Seats:
          check sim.dealt[slot].len == per
          for card in sim.dealt[slot]:
            check card notin seen
            seen.incl(card)
        if sim.upcard >= 0:
          check sim.upcard notin seen
        if sim.turnup >= 0:
          check sim.turnup notin seen
        check seen.len == per * Seats
        ## Finish the hand so the next one can be dealt.
        while not sim.done and sim.phase != phDeal:
          if sim.phase == phPass:
            var rng = initRand(int64(hand) * 31 + 7)
            sim.applyMove(passMove(randomPass(sim, rng)), "", true)
          else:
            sim.applyMove(legalMoves(sim)[0], "", true)

suite "follow-suit legality":
  test "500 random legal matches per module never break the follow rule":
    for module in Modules:
      let config = fixture(module, defaultHands(module), seed = 3)
      for run in 0 ..< 500:
        var rng = initRand(int64(run) * 104729 + 17)
        var sim = initSim(config)
        while not sim.done:
          let call = sim.currentCall()
          case call.kind
          of ckDeal: sim.beginHand()
          of ckNone: break
          of ckPass:
            sim.applyMove(passMove(randomPass(sim, rng)), "", true)
          of ckPlay:
            let m = sim.ruleModule
            let slot = sim.actorSlot
            let cards = legalCards(sim)
            doAssert cards.len > 0
            for card in cards:
              doAssert card in sim.deal[slot]
            if not sim.leadingNow():
              var follow: seq[int]
              for card in sim.deal[slot]:
                if effectiveSuit(card, m.trumpOf(sim), m.isEuchre) ==
                    sim.ledSuit:
                  follow.add(card)
              if follow.len > 0:
                doAssert cards.len == follow.len,
                  "holding the led suit means the legal set IS the led suit"
                for card in follow:
                  doAssert card in cards
            sim.applyMove(playMove(cards[rng.rand(cards.high)]), "", true)
          else:
            let legal = legalMoves(sim)
            sim.applyMove(legal[rng.rand(legal.high)], "", true)
        check sim.done
      check true

  test "applyMove raises on every card outside legalMoves":
    for module in Modules:
      let config = fixture(module, defaultHands(module), seed = 5)
      var sim = initSim(config)
      sim.beginHand()
      var rng = initRand(99)
      while sim.phase != phPlay and not sim.done:
        if sim.phase == phPass:
          sim.applyMove(passMove(randomPass(sim, rng)), "", true)
        else:
          sim.applyMove(legalMoves(sim)[0], "", true)
      let legal = legalCards(sim)
      var rejected = 0
      for card in 0 ..< 52:
        if card in legal:
          continue
        var probe = sim
        try:
          probe.applyMove(playMove(card), "", true)
          check false
        except TricksError:
          inc rejected
      check rejected > 0

suite "lead restrictions":
  test "a spade cannot be led before the break unless the hand is all spades":
    let config = fixture("spades", 4, seed = 21)
    var sim = initSim(config)
    var rng = initRand(4)
    var checked = 0
    while not sim.done:
      let call = sim.currentCall()
      case call.kind
      of ckDeal: sim.beginHand()
      of ckNone: break
      of ckPlay:
        let cards = legalCards(sim)
        if sim.leadingNow() and not sim.broken:
          var nonSpades = 0
          for card in sim.deal[sim.actorSlot]:
            if suitOf(card) != SuitSpades: inc nonSpades
          if nonSpades > 0:
            for card in cards:
              check suitOf(card) != SuitSpades
            inc checked
        sim.applyMove(playMove(cards[rng.rand(cards.high)]), "", true)
      else:
        let legal = legalMoves(sim)
        sim.applyMove(legal[rng.rand(legal.high)], "", true)
    check checked > 0

  test "hearts: no heart and no queen of spades on trick 0, and the two of clubs leads":
    let config = fixture("hearts", 4, seed = 33)
    var sim = initSim(config)
    var rng = initRand(6)
    var leads = 0
    var trick0 = 0
    while not sim.done:
      let call = sim.currentCall()
      case call.kind
      of ckDeal: sim.beginHand()
      of ckNone: break
      of ckPass:
        sim.applyMove(passMove(randomPass(sim, rng)), "", true)
      of ckPlay:
        let cards = legalCards(sim)
        if sim.currentTrick() == 0:
          if sim.leadingNow():
            check cards == @[TwoOfClubs]
            inc leads
          else:
            var forced = true
            for card in sim.deal[sim.actorSlot]:
              if heartsPenalty(card) == 0: forced = false
            if not forced:
              for card in cards:
                check heartsPenalty(card) == 0
              inc trick0
        elif sim.leadingNow() and not sim.broken:
          var nonHearts = 0
          for card in sim.deal[sim.actorSlot]:
            if suitOf(card) != SuitHearts: inc nonHearts
          if nonHearts > 0:
            for card in cards:
              check suitOf(card) != SuitHearts
        sim.applyMove(playMove(cards[rng.rand(cards.high)]), "", true)
      else:
        sim.applyMove(legalMoves(sim)[0], "", true)
    check leads == 4
    check trick0 > 0

suite "euchre rules":
  proc euchreHand(makerTeamTricks: int, alone: bool): array[Seats, float] =
    ## Drives the module's own scoreHand over a synthetic trick record.
    let config = fixture("euchre", 8, seed = 2)
    var sim = initSim(config)
    sim.beginHand()
    sim.trump = 0
    sim.maker = sim.slotAt(0)
    sim.alone = alone
    let makerTeam = sim.teamOf(sim.maker)
    for slot in 0 ..< Seats:
      sim.tricksWon[slot] = 0
    var given = 0
    for slot in 0 ..< Seats:
      if sim.teamOf(slot) == makerTeam and given < makerTeamTricks:
        let take = min(makerTeamTricks - given, 5)
        sim.tricksWon[slot] = take
        given += take
    var others = 5 - makerTeamTricks
    for slot in 0 ..< Seats:
      if sim.teamOf(slot) != makerTeam and others > 0:
        sim.tricksWon[slot] = others
        others = 0
    moduleFor("euchre").scoreHand(sim)

  test "all four scoring outcomes produce the documented points":
    for tricks in 3 .. 4:
      let net = euchreHand(tricks, false)
      check abs(net[0]) == 1.0
    check abs(euchreHand(5, false)[0]) == 2.0
    check abs(euchreHand(5, true)[0]) == 4.0
    for tricks in 0 .. 2:
      let net = euchreHand(tricks, false)
      check abs(net[0]) == 2.0
    for tricks in 0 .. 5:
      for alone in [false, true]:
        let net = euchreHand(tricks, alone)
        var total = 0.0
        for slot in 0 ..< Seats:
          total += net[slot]
          check abs(net[slot]) <= moduleFor("euchre").swingCap(
            fixture("euchre", 8), 0)
        check abs(total) < 1e-9

  test "the ordered-up card leaves the kitty when it joins the dealer's hand":
    ## A card that is in the dealer's hand AND still in the kitty is drawn
    ## twice by any spectator view that shows both -- the kitty backs and
    ## the up-card face sit side by side in the corner of the felt.
    let config = fixture("euchre", 8, seed = 55)
    var sim = initSim(config)
    sim.beginHand()
    let upcard = sim.upcard
    check sim.kitty.len == 4
    check sim.kitty[0] == upcard
    sim.applyMove(bidMove("order", 0, suitOf(upcard)), "", true)
    check sim.phase == phDiscard
    let dealer = sim.dealerSlot
    check upcard in sim.deal[dealer]
    check upcard notin sim.kitty
    check sim.kitty.len == 3
    check not sim.upcardLive
    ## `upcard` keeps the value: it is the record of which card was turned
    ## up, and the prompts, the tells and the `hand` event all read it.
    check sim.upcard == upcard
    ## Every one of the 24 cards is in exactly one place.
    var seen = initHashSet[int]()
    for slot in 0 ..< Seats:
      for card in sim.deal[slot]:
        check card notin seen
        seen.incl(card)
    for card in sim.kitty:
      check card notin seen
      seen.incl(card)
    check seen.len == 24

  test "a turned-down up-card stays in the kitty":
    ## Round 2 means nobody ordered it up: the card was turned down, not
    ## picked up, so it is still on the table.
    let config = fixture("euchre", 8, seed = 41)
    var sim = initSim(config)
    sim.beginHand()
    let upcard = sim.upcard
    for _ in 0 ..< Seats:
      sim.applyMove(bidMove("pass", 0, -1), "", true)
    check sim.bidRound == 2
    check not sim.upcardLive
    check upcard in sim.kitty
    check sim.kitty.len == 4

  test "stick the dealer forces a named suit and never a re-deal":
    let config = fixture("euchre", 8, seed = 41)
    var sim = initSim(config)
    sim.beginHand()
    ## Everyone passes in round 1.
    for _ in 0 ..< Seats:
      sim.applyMove(bidMove("pass", 0, -1), "", true)
    check sim.bidRound == 2
    ## Then the first three pass in round 2.
    for _ in 0 ..< 3:
      sim.applyMove(bidMove("pass", 0, -1), "", true)
    check sim.stuck
    check sim.actorPos == sim.dealer
    let legal = legalMoves(sim)
    check legal.len > 0
    for move in legal:
      check move.action != "pass"
      check move.suit != suitOf(sim.upcard)
    sim.applyMove(legal[0], "", true)
    check sim.trump >= 0
    check sim.phase == phPlay

  test "the alone partner plays no card and is skipped in turn order":
    let config = fixture("euchre", 8, seed = 77)
    var sim = initSim(config)
    sim.beginHand()
    sim.applyMove(bidMove("alone", 0, suitOf(sim.upcard)), "", true)
    check sim.phase == phDiscard
    let dealer = sim.dealerSlot
    check sim.deal[dealer].len == 6
    sim.applyMove(discardMove(sim.deal[dealer][0]), "", true)
    check sim.deal[dealer].len == 5
    check sim.phase == phPlay
    check sim.sittingOut >= 0
    check sim.seatsInPlay == 3
    let sittingOut = sim.sittingOut
    var rng = initRand(3)
    while sim.phase == phPlay and not sim.done:
      check sim.actorSlot != sittingOut
      let cards = legalCards(sim)
      sim.applyMove(playMove(cards[rng.rand(cards.high)]), "", true)
    check sim.deal[sittingOut].len == 5

suite "spades rules":
  proc spadesScoreFor(bids, tricks: array[Seats, int]): array[Seats, float] =
    let config = fixture("spades", 4, seed = 8)
    var sim = initSim(config)
    sim.beginHand()
    for slot in 0 ..< Seats:
      sim.bids[slot] = bids[slot]
      sim.tricksWon[slot] = tricks[slot]
    moduleFor("spades").scoreHand(sim)

  test "made contracts, set contracts, nils, and the proven 230 bound":
    var rng = initRand(1234)
    for _ in 0 ..< 10_000:
      var bids: array[Seats, int]
      var tricks: array[Seats, int]
      var left = 13
      for slot in 0 ..< Seats:
        bids[slot] = rng.rand(13)
        tricks[slot] = (if slot == Seats - 1: left else: rng.rand(left))
        left -= tricks[slot]
      let net = spadesScoreFor(bids, tricks)
      var total = 0.0
      for slot in 0 ..< Seats:
        total += net[slot]
        ## net = teamScore(mine) - teamScore(theirs) and |teamScore| <= 230.
        check abs(net[slot]) <= 460.0
      check abs(total) < 1e-9

  test "a made contract is 10*C + bags and a set contract is -10*C":
    var bids: array[Seats, int]
    var tricks: array[Seats, int]
    ## Team 0 = positions 0 and 2. Build in position space via a fresh sim.
    let config = fixture("spades", 4, seed = 8)
    var sim = initSim(config)
    let a = sim.slotAt(0)
    let b = sim.slotAt(2)
    let c = sim.slotAt(1)
    let d = sim.slotAt(3)
    bids[a] = 3; bids[b] = 2; bids[c] = 4; bids[d] = 4
    tricks[a] = 4; tricks[b] = 2; tricks[c] = 4; tricks[d] = 3
    var net = spadesScoreFor(bids, tricks)
    ## Team 0 contract 5, took 6 -> 50 + 1 = 51. Team 1 contract 8, took 7 -> -80.
    check abs(net[a] - (51.0 - -80.0)) < 1e-9
    check abs(net[c] - (-80.0 - 51.0)) < 1e-9
    ## A made nil is +100 and a failed nil -100 with its tricks as bags.
    bids[a] = 0; bids[b] = 3; bids[c] = 5; bids[d] = 5
    tricks[a] = 0; tricks[b] = 3; tricks[c] = 5; tricks[d] = 5
    net = spadesScoreFor(bids, tricks)
    check abs(net[a] - (130.0 - 100.0)) < 1e-9
    bids[a] = 0
    tricks[a] = 1; tricks[b] = 3; tricks[c] = 5; tricks[d] = 4
    net = spadesScoreFor(bids, tricks)
    ## Team 0: contract 3, non-nil tricks 3 -> made, bags = 3 + 1 - 3 = 1,
    ## base 31, nil failed -100 => -69. Team 1: contract 10, took 9 -> -100.
    check abs(net[a] - (-69.0 - -100.0)) < 1e-9

suite "hearts rules":
  test "pass directions cycle left, right, across, hold":
    let config = fixture("hearts", 4, seed = 12)
    var sim = initSim(config)
    var seen: seq[string]
    var rng = initRand(2)
    while not sim.done:
      let call = sim.currentCall()
      case call.kind
      of ckDeal:
        sim.beginHand()
        seen.add(sim.passDir)
      of ckNone: break
      of ckPass:
        let cards = randomPass(sim, rng)
        check cards.len == 3
        var distinct2 = initHashSet[int]()
        for card in cards:
          check card in sim.deal[sim.actorSlot]
          distinct2.incl(card)
        check distinct2.len == 3
        sim.applyMove(passMove(cards), "", true)
      of ckPlay:
        let cards = legalCards(sim)
        sim.applyMove(playMove(cards[rng.rand(cards.high)]), "", true)
      else:
        sim.applyMove(legalMoves(sim)[0], "", true)
    check seen == @["left", "right", "across", "hold"]

  test "total penalty is always 26 and a moon flips the table":
    let config = fixture("hearts", 4, seed = 55)
    var sim = playRandom(config, 4)
    for event in sim.events:
      if event.kind == evHandEnd:
        var total = 0.0
        for value in event.points:
          total += value
        check abs(total - 26.0) < 1e-9 or abs(total - 78.0) < 1e-9
    ## A synthetic moon: one seat takes all 26.
    var probe = initSim(config)
    probe.beginHand()
    for slot in 0 ..< Seats:
      probe.penalty[slot] = 0
    probe.penalty[1] = 26
    let net = moduleFor("hearts").scoreHand(probe)
    check probe.moons[1] == 1
    check abs(net[1] - 19.5) < 1e-9
    for slot in 0 ..< Seats:
      if slot != 1:
        check abs(net[slot] - -6.5) < 1e-9

suite "oh-hell rules":
  test "the hook forbids exactly the balanced bid and only for the dealer":
    let config = fixture("oh-hell", 11, seed = 66)
    var sim = initSim(config)
    var rng = initRand(9)
    var hooks = 0
    while not sim.done:
      let call = sim.currentCall()
      case call.kind
      of ckDeal: sim.beginHand()
      of ckNone: break
      of ckBid:
        let legal = legalMoves(sim)
        if sim.bidStep == Seats - 1:
          check sim.actorPos == sim.dealer
          var placed = 0
          for slot in 0 ..< Seats:
            if sim.bids[slot] >= 0: placed += sim.bids[slot]
          let balanced = sim.tricksThisHand - placed
          if balanced >= 0 and balanced <= sim.tricksThisHand:
            check legal.len == sim.tricksThisHand
            for move in legal:
              check move.value != balanced
            inc hooks
        else:
          check legal.len == sim.tricksThisHand + 1
        sim.applyMove(legal[rng.rand(legal.high)], "", true)
      of ckPlay:
        let cards = legalCards(sim)
        check sim.turnup notin cards
        sim.applyMove(playMove(cards[rng.rand(cards.high)]), "", true)
      else:
        sim.applyMove(legalMoves(sim)[0], "", true)
    check hooks > 0

  test "exact scores 10 + bid, anything else scores zero":
    let config = fixture("oh-hell", 11, seed = 67)
    var sim = initSim(config)
    sim.beginHand()
    for slot in 0 ..< Seats:
      sim.bids[slot] = 0
      sim.tricksWon[slot] = 0
    sim.bids[0] = 1
    sim.tricksWon[0] = 1
    let net = moduleFor("oh-hell").scoreHand(sim)
    ## s = [11, 10, 10, 10], mean 10.25.
    check abs(net[0] - 0.75) < 1e-9
    check abs(net[1] - -0.25) < 1e-9
    sim.bids[0] = 1
    sim.tricksWon[0] = 0
    for slot in 1 ..< Seats:
      sim.bids[slot] = 1
      sim.tricksWon[slot] = 1
    let missed = moduleFor("oh-hell").scoreHand(sim)
    ## Only seat 0 missed; s = [0, 11, 11, 11].
    check abs(missed[0] - -8.25) < 1e-9

suite "scoring":
  test "net sums to zero, scores sum to 2.0 and land in [0,1], no clamp":
    for module in Modules:
      let config = fixture(module, defaultHands(module), seed = 100)
      let cap = moduleFor(module)
      for run in 0 ..< 2000:
        let sim = playRandom(config, run + 1)
        var netTotal = 0.0
        var scoreTotal = 0.0
        let scores = sim.scoresOf()
        for slot in 0 ..< Seats:
          netTotal += sim.net[slot]
          scoreTotal += scores[slot]
          doAssert scores[slot] >= 0.0 and scores[slot] <= 1.0,
            module & ": score outside [0,1]: " & $scores[slot]
          if abs(sim.net[slot]) < 1e-9:
            doAssert abs(scores[slot] - 0.5) < 1e-9,
              "breaking even must score exactly 0.5"
        doAssert abs(netTotal) < 1e-6, module & ": net does not sum to zero"
        doAssert abs(scoreTotal - 2.0) < 1e-6,
          module & ": scores do not sum to 2.0"
        ## Per hand, too, and no realised net_h exceeds the swing cap.
        for event in sim.events:
          if event.kind != evHandEnd:
            continue
          var handTotal = 0.0
          for value in event.net:
            handTotal += value
            doAssert abs(value) <= cap.swingCap(config, event.hand) + 1e-9,
              module & ": a realised net_h exceeded the swing cap"
          doAssert abs(handTotal) < 1e-6,
            module & ": a hand's net does not sum to zero"
      check true

  test "no scored hand means every seat scores 0.5":
    let config = fixture("euchre", 8, seed = 4)
    let sim = initSim(config)
    let scores = sim.scoresOf()
    for slot in 0 ..< Seats:
      check scores[slot] == 0.5

suite "record then re-derive":
  proc rederives(sim: Sim) =
    let events = roundTrip(sim.events)
    let again = replayEpisode(sim.config, events)
    check eventsJson(again.events) == eventsJson(sim.events)
    check $again.resultsJson() == $sim.resultsJson()
    check $replayStates(sim.config, events) ==
      $replayStates(sim.config, sim.events)
    let frames = replayMatch(sim.config, events)
    check frames.len == events.len + 1
    check $frames[^1].frameStateJson() == $sim.frameStateJson()

  test "every intermediate live frame equals the re-derived frame at that tick":
    ## The final frame agreeing is not the claim: the viewer plays the WHOLE
    ## timeline, so every intermediate frame has to be the one the table
    ## actually stood in. This records the live state after every applied
    ## move -- the same `frameStateJson` the live server broadcasts and
    ## throws away -- and checks it against the re-derived frame at the tick
    ## where the event log reached the same length. A drift in any one hand
    ## boundary, trick resolution or score update shows up here and nowhere
    ## in the final-frame check.
    for module in Modules:
      var live: seq[(int, string)]
      let sim = playRecording(
        fixture(module, defaultHands(module), seed = 94), 11, live)
      check sim.reason == "complete"
      let frames = replayMatch(sim.config, roundTrip(sim.events))
      check frames.len == sim.events.len + 1
      ## Every module plays at least a hand's worth of ticks, so an empty
      ## recording cannot pass this vacuously.
      check live.len > 30
      var compared = 0
      for (count, state) in live:
        check count < frames.len
        if count < frames.len:
          check $frames[count].frameStateJson() == state
          inc compared
      check compared == live.len

  test "an episode that ended complete re-derives byte-identically":
    for module in Modules:
      let sim = playRandom(fixture(module, defaultHands(module), seed = 91), 7)
      check sim.reason == "complete"
      rederives(sim)

  test "an episode that ended at the hard deadline re-derives byte-identically":
    for module in Modules:
      let config = fixture(module, defaultHands(module), seed = 92)
      var sim = initSim(config)
      var rng = initRand(13)
      sim.beginHand()
      for _ in 0 ..< 6:
        if sim.done or sim.phase == phDeal: break
        if sim.phase == phPass:
          sim.applyMove(passMove(randomPass(sim, rng)), "", true)
        else:
          let legal = legalMoves(sim)
          sim.applyMove(legal[rng.rand(legal.high)], "", true)
      sim.voidHand()
      check sim.reason == "deadline"
      check sim.handsScored == 0
      check sim.norm == 0.0
      var voided = false
      for event in sim.events:
        if event.kind == evHandVoid: voided = true
      check voided
      rederives(sim)

  test "an episode that ended on the decision budget re-derives byte-identically":
    for module in Modules:
      let config = fixture(module, defaultHands(module), seed = 93)
      var sim = initSim(config)
      var rng = initRand(23)
      sim.beginHand()
      while not sim.done and sim.phase != phDeal:
        if sim.phase == phPass:
          sim.applyMove(passMove(randomPass(sim, rng)), "", true)
        else:
          let legal = legalMoves(sim)
          sim.applyMove(legal[rng.rand(legal.high)], "", true)
      sim.endEarly("budget")
      check sim.reason == "budget"
      check sim.handsScored == 1
      rederives(sim)

suite "event JSON":
  test "every kind in the vocabulary round-trips":
    var seen = initHashSet[EventKind]()
    var episodes: seq[Sim]
    episodes.add(playRandom(fixture("euchre", 8, seed = 71), 3))
    episodes.add(playRandom(fixture("hearts", 4, seed = 72), 3))
    episodes.add(playRandom(fixture("spades", 4, seed = 73), 3))
    episodes.add(playRandom(fixture("oh-hell", 11, seed = 74), 3))
    block:
      var sim = initSim(fixture("hearts", 4, seed = 75))
      sim.beginHand()
      sim.voidHand()
      episodes.add(sim)
    for sim in episodes:
      for event in sim.events:
        seen.incl(event.kind)
        let node = event.eventToJson()
        check $eventFromJson(node).eventToJson() == $node
    for kind in EventKind:
      check kind in seen

suite "budget fit":
  test "sampleEpisode is idempotent and never returns fewer than MinHands":
    for module in Modules:
      var config = fixture(module, defaultHands(module))
      config.sampled = false
      config.hands = 999
      if module == "oh-hell":
        config.dealSchedule = @[]
      let once = sampleEpisode(config)
      let twice = sampleEpisode(once)
      check once.hands == twice.hands
      check once.dealSchedule == twice.dealSchedule
      check once.hands >= MinHands
      check worstCaseDecisions(once) <= EpisodeDecisionBudget

  test "oh-hell trims its deal schedule from the TAIL":
    var config = fixture("oh-hell", 11)
    config.sampled = false
    config.dealSchedule = @[1, 2, 3, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6]
    config.hands = config.dealSchedule.len
    let fitted = sampleEpisode(config)
    check fitted.dealSchedule.len == fitted.hands
    check fitted.dealSchedule.len < 16
    check fitted.dealSchedule[0 ..< 6] == @[1, 2, 3, 4, 5, 6]
    check worstCaseDecisions(fitted) <= EpisodeDecisionBudget

  test "every shipped variant fits the budget and the soft guard":
    ## The counts are the design note's own table (§Decisions 3), so a
    ## module whose worst case drifts from the arithmetic the note published
    ## fails here rather than silently eating budget headroom.
    const Shipped = [("euchre", 8, 232), ("spades", 4, 224),
      ("hearts", 4, 220), ("oh-hell", 11, 188)]
    for (module, hands, expected) in Shipped:
      let config = fixture(module, hands)
      let decisions = worstCaseDecisions(config)
      check decisions == expected
      check decisions <= EpisodeDecisionBudget
      ## 2.6 s budgeted per decision against the 0.55 * 1200 s soft guard.
      check decisions.float * 2.6 <= 660.0
      ## And sampling does not shrink a shipped variant.
      var unsampled = config
      unsampled.sampled = false
      check sampleEpisode(unsampled).hands == hands

  test "hearts spends no pass decision on a hold hand":
    ## Pass directions cycle left, right, across, HOLD. The hold hand
    ## passes nothing, so it costs 52 plays and no pass decision.
    let m = moduleFor("hearts")
    let config = fixture("hearts", 4)
    for hand in 0 ..< 4:
      let expected = if passDirName(hand) == "hold": 52 else: 56
      check m.worstCaseDecisions(config, hand) == expected
    check passDirName(3) == "hold"

suite "rune truncation":
  test "truncateRunes never splits a multi-byte rune":
    let emoji = "\u2660\u2665\u2666\u2663".repeat(400)
    for limit in [1, 8, 120, 400, 4000]:
      let cut = truncateRunes(emoji, limit)
      check cut.runeLen <= limit
      check cut.validateUtf8() == -1
    check truncateRunes("short", 400) == "short"
    check truncateRunes("", 400) == ""
    check truncateRunes("abc", 0) == ""

  test "a replay carrying a full-cap notes parses under a strict decoder":
    let config = fixture("hearts", 4, seed = 88)
    var sim = initSim(config)
    var rng = initRand(17)
    let hostile = "\u{1F0A1}\u{1F0B1}\u{1F0C1}\u{1F0D1}".repeat(400)
    while not sim.done:
      let call = sim.currentCall()
      case call.kind
      of ckDeal: sim.beginHand()
      of ckNone: break
      of ckPass:
        sim.applyMove(passMove(randomPass(sim, rng)), hostile, false)
      else:
        let legal = legalMoves(sim)
        sim.applyMove(legal[rng.rand(legal.high)], hostile, false)
    for slot in 0 ..< Seats:
      check sim.notes[slot].runeLen <= MaxNotesLen
    let bytes = $sim.replayJson()
    check bytes.validateUtf8() == -1
    let reparsed = parseJson(bytes)
    check reparsed["events"].len == sim.events.len

suite "the committed hearts_moon fixture":
  test "regenerates byte-identically":
    let generated = heartsMoonReplay()
    let path = "tools/ci/fixtures/hearts_moon.replay"
    if not fileExists(path):
      ## Bootstrap: CI uploads the generated bytes as an artifact so they can
      ## be committed. Once the file exists this test DIFFS it and fails on
      ## any drift.
      createDir(parentDir(path))
      writeFile(path, generated)
      echo "NOTE: created ", path, " (", generated.len,
        " bytes) -- commit it; from now on it is diffed."
    else:
      let committed = readFile(path)
      if committed != generated:
        writeFile("hearts_moon.regenerated.replay", generated)
        echo "committed fixture is ", committed.len,
          " bytes, regenerated is ", generated.len, " bytes"
      check committed == generated

  test "carries a shot moon, full-cap text and a non-null audit":
    let payload = parseJson(heartsMoonReplay())
    check payload["protocol"].getStr() == "tricks.replay.v1"
    check payload["results"]["moons"][0].getInt() == 1
    check payload["results"]["audit"].kind == JObject
    var fullNotes = 0
    var fullTell = 0
    var seatsWithNotes = initHashSet[int]()
    for event in payload["events"]:
      let text = event{"text"}.getStr()
      if text.runeLen == MaxNotesLen:
        inc fullNotes
        seatsWithNotes.incl(event{"slot"}.getInt(-1))
      if event{"tell"}.getStr().runeLen == MaxTellLen:
        inc fullTell
    check fullNotes > 0
    check seatsWithNotes.len == Seats
    check fullTell == 1
    check ($payload).validateUtf8() == -1
