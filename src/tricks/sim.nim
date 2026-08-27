## The trick-taking engine. Pure Nim, no IO, no networking -- the game
## server, the tests and the wasm replay viewer all drive this same module.
##
## The engine deals, enforces follow-suit, decides who takes the trick,
## scores the hand through the active rule module and rotates the deal.
## Everything random is drawn from the seed, and the DEAL is recorded in the
## `hand` event, so a replay re-derives the episode from the event log alone
## -- including a wall-clock stop, which is a recorded, load-bearing event
## applied by the same proc on record and on playback.

import
  std/[json, random, strutils],
  types, cards, rules, audit, euchre, spades, hearts, ohhell

export types, cards, rules, audit, euchre, spades, hearts, ohhell

type
  CallKind* = enum
    ckDeal = "deal"     ## the next hand needs dealing (no model call)
    ckBid = "bid"
    ckPass = "pass"
    ckDiscard = "discard"
    ckPlay = "play"
    ckNone = "none"

  Call* = tuple[kind: CallKind, slot: int]

let Registry = [euchreModule(), spadesModule(), heartsModule(), ohHellModule()]

proc moduleIds*(): seq[string] =
  for m in Registry:
    result.add(m.id)

proc hasModule*(id: string): bool =
  for m in Registry:
    if m.id == id:
      return true
  false

proc moduleFor*(id: string): RuleModule =
  ## The registry. A fifth game is one new file and one line here.
  for m in Registry:
    if m.id == id:
      return m
  raise newException(TricksError, "unknown rule module: " & id)

proc ruleModule*(sim: Sim): RuleModule = moduleFor(sim.module)

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog alias, drawn deterministically from the seed.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(truncateRunes(pool[index], MaxAliasLen))
    else:
      result.add("Cog " & $(index + 1))

proc seatOrderOf*(seed: int): array[Seats, int] =
  ## Table position -> policy slot. Re-drawn every episode, so a policy has
  ## a different partner from episode to episode and can never arrange to be
  ## partnered with itself.
  var rng = initRand(int64(seed) * 15486047 + 977)
  var pool = @[0, 1, 2, 3]
  rng.shuffle(pool)
  for pos in 0 ..< Seats:
    result[pos] = pool[pos]

proc worstCaseDecisionsPerHand*(config: GameConfig, hand: int): int =
  moduleFor(config.module).worstCaseDecisions(config, hand)

proc worstCaseDecisions*(config: GameConfig): int =
  for hand in 0 ..< config.hands:
    result += worstCaseDecisionsPerHand(config, hand)

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the hand count into one episode's decision budget. Idempotent: a
  ## config that already carries the cap (a replay being re-read) is
  ## untouched, so a replay is never re-fitted.
  result = config
  if result.sampled:
    return
  if not hasModule(result.module):
    result.module = "euchre"
  if result.module == "oh-hell":
    var schedule =
      if result.dealSchedule.len > 0: result.dealSchedule
      else: @DefaultDealSchedule
    if result.hands > 0 and result.hands < schedule.len:
      schedule.setLen(result.hands)
    proc total(s: seq[int]): int =
      for cards in s:
        result += 4 + 4 * cards
    while schedule.len > MinHands and total(schedule) > EpisodeDecisionBudget:
      schedule.setLen(schedule.len - 1)
    result.dealSchedule = schedule
    result.hands = schedule.len
  else:
    let per = max(1, moduleFor(result.module).worstCaseDecisions(result, 0))
    result.hands = max(MinHands,
      min(result.hands, EpisodeDecisionBudget div per))
  result.sampled = true

proc validate*(config: GameConfig) =
  if config.players.len != Seats:
    raise newException(TricksError,
      "trick-taking needs exactly " & $Seats & " players")
  if not hasModule(config.module):
    raise newException(TricksError, "unknown rule module: " & config.module)
  if config.hands < MinHands:
    raise newException(TricksError, "hands must be at least " & $MinHands)
  if config.module == "oh-hell":
    var schedule = config.dealSchedule
    if schedule.len == 0:
      schedule = @DefaultDealSchedule
      if config.hands <= schedule.len:
        schedule.setLen(config.hands)
    if schedule.len != config.hands:
      raise newException(TricksError,
        "oh-hell needs one dealSchedule entry per hand")
    for cards in schedule:
      if cards < 1 or cards > 6:
        raise newException(TricksError,
          "oh-hell deals 1..6 cards per hand, got " & $cards)

proc initSim*(config: GameConfig): Sim =
  validate(config)
  let m = moduleFor(config.module)
  var cfg = config
  if cfg.module == "oh-hell" and cfg.dealSchedule.len == 0:
    cfg.dealSchedule = @DefaultDealSchedule
    cfg.dealSchedule.setLen(cfg.hands)
  else:
    discard
  result = Sim(
    config: cfg,
    module: m.id,
    displayName: m.displayName,
    partnership: m.partnership,
    names: tableNames(cfg.players, cfg.seed)
  )
  result.seatOrder = seatOrderOf(cfg.seed)
  for pos in 0 ..< Seats:
    result.posOf[result.seatOrder[pos]] = pos
  result.hand = -1
  result.dealer = -1
  result.phase = phDeal
  result.upcard = -1
  result.turnup = -1
  result.discarded = -1
  result.trump = -1
  result.maker = -1
  result.sittingOut = -1
  result.trickWinner = -1
  result.ledSuit = -1
  result.trick = -1
  for slot in 0 ..< Seats:
    result.bids[slot] = -1
  var event = blankEvent(evStart)
  event.text = m.id
  result.addEvent(event)

# ---- The hand ---------------------------------------------------------------

proc resetHand(sim: var Sim) =
  for slot in 0 ..< Seats:
    sim.deal[slot] = @[]
    sim.dealt[slot] = @[]
    sim.passSel[slot] = @[]
    sim.tricksWon[slot] = 0
    sim.penalty[slot] = 0
    sim.bids[slot] = -1
    sim.bidActions[slot] = ""
    for suit in 0 ..< 4:
      sim.voids[slot][suit] = false
  for card in 0 ..< 52:
    sim.played[card] = false
  sim.kitty = @[]
  sim.upcard = -1
  sim.upcardLive = false
  sim.turnup = -1
  sim.discarded = -1
  sim.trump = -1
  sim.maker = -1
  sim.alone = false
  sim.sittingOut = -1
  sim.broken = false
  sim.passDir = ""
  sim.stuck = false
  sim.bidStep = 0
  sim.bidRound = 1
  sim.table = @[]
  sim.ledSuit = -1
  sim.trick = 0
  sim.trickComplete = false
  sim.trickWinner = -1
  sim.handDone = false
  sim.tell = ""

proc recordHandEvent(sim: var Sim) =
  var event = blankEvent(evHand)
  event.hand = sim.hand
  event.dealer = sim.dealer
  for slot in 0 ..< Seats:
    event.deals.add(sim.dealt[slot])
  event.kitty = sim.kitty
  event.upcard = sim.upcard
  event.turnup = sim.turnup
  event.count = sim.tricksThisHand
  event.passDir = sim.passDir
  sim.addEvent(event)

proc beginHand*(sim: var Sim, stacked: seq[seq[int]] = @[]) =
  ## Deals the next hand. `stacked` pins the deal (fixtures and tests only);
  ## otherwise the deck is shuffled from the seed and the hand index.
  if sim.done:
    raise newException(TricksError, "the episode is over")
  if sim.phase != phDeal:
    raise newException(TricksError, "a hand is already in progress")
  let m = sim.ruleModule
  sim.resetHand()
  sim.hand = sim.handsPlayed
  sim.dealer = sim.hand mod Seats
  sim.tricksThisHand = m.cardsPerHand(sim.config, sim.hand)
  var rng = initRand(int64(sim.config.seed) * 104729 +
    int64(sim.hand) * 7919 + 13)
  var deck = m.deck()
  rng.shuffle(deck)
  var rest: seq[int]
  if stacked.len == Seats:
    var taken: array[52, bool]
    for slot in 0 ..< Seats:
      sim.deal[slot] = stacked[slot]
      for card in stacked[slot]:
        taken[card] = true
    for card in deck:
      if not taken[card]:
        rest.add(card)
  else:
    var index = 0
    let packets = m.dealPackets(sim.config, sim.hand)
    if packets.len > 0:
      var pos = (sim.dealer + 1) and 3
      for packet in packets:
        let slot = sim.slotAt(pos)
        for _ in 0 ..< packet:
          sim.deal[slot].add(deck[index])
          inc index
        pos = (pos + 1) and 3
    else:
      for _ in 0 ..< sim.tricksThisHand:
        var pos = (sim.dealer + 1) and 3
        for _ in 0 ..< Seats:
          sim.deal[sim.slotAt(pos)].add(deck[index])
          inc index
          pos = (pos + 1) and 3
    rest = deck[index .. ^1]
  for slot in 0 ..< Seats:
    sim.deal[slot] = sortedHand(sim.deal[slot])
    sim.dealt[slot] = sim.deal[slot]
  m.setupHand(sim, rest)
  sim.recordHandEvent()

proc beginHandFrom*(sim: var Sim, event: GameEvent) =
  ## Replay: the deal comes from the recorded `hand` event, not from the
  ## seed, because the audit and the all-hands-visible replay both need the
  ## literal deal.
  if sim.done:
    raise newException(TricksError, "the episode is over")
  let m = sim.ruleModule
  sim.resetHand()
  sim.hand = event.hand
  sim.dealer = event.dealer
  sim.tricksThisHand = event.count
  if event.deals.len != Seats:
    raise newException(TricksError, "the hand event carries no deal")
  for slot in 0 ..< Seats:
    sim.deal[slot] = sortedHand(event.deals[slot])
    sim.dealt[slot] = sim.deal[slot]
  var rest =
    if event.kitty.len > 0: event.kitty
    elif event.turnup >= 0: @[event.turnup]
    else: newSeq[int]()
  m.setupHand(sim, rest)
  if sim.upcard != event.upcard or sim.turnup != event.turnup:
    raise newException(TricksError,
      "hand " & $event.hand & " does not match the recorded deal")
  sim.recordHandEvent()

# ---- Legality ---------------------------------------------------------------

proc leadingNow*(sim: Sim): bool =
  sim.table.len == 0 or sim.trickComplete

proc legalCards*(sim: Sim): seq[int] =
  ## The acting seat's playable cards. If the seat holds at least one card
  ## of the LED suit, its legal set is exactly those cards; otherwise it is
  ## the whole remaining hand. Two module overlays sit on top and only two:
  ## euchre's left bower (a trump, not a card of its printed suit) and the
  ## lead restrictions. The set is never empty, and it is computed by the
  ## same predicate `applyPlay` validates with.
  let m = sim.ruleModule
  let slot = sim.actorSlot
  let hand = sim.deal[slot]
  let leading = sim.leadingNow()
  var base: seq[int]
  if leading:
    base = hand
  else:
    let trump = m.trumpOf(sim)
    for card in hand:
      if effectiveSuit(card, trump, m.isEuchre) == sim.ledSuit:
        base.add(card)
    if base.len == 0:
      base = hand
  var allowed: seq[int]
  for card in base:
    if not m.restricted(sim, card, leading):
      allowed.add(card)
  result = (if allowed.len > 0: allowed else: base)

proc legalMoves*(sim: Sim): seq[Move] =
  if sim.done or sim.phase in {phDeal, phDone}:
    return
  if sim.phase == phPlay:
    for card in legalCards(sim):
      result.add(playMove(card))
  else:
    result = sim.ruleModule.legalMoves(sim)

proc currentCall*(sim: Sim): Call =
  if sim.done:
    return (ckNone, -1)
  case sim.phase
  of phDeal: (ckDeal, -1)
  of phBid: (ckBid, sim.actorSlot)
  of phPass: (ckPass, sim.actorSlot)
  of phDiscard: (ckDiscard, sim.actorSlot)
  of phPlay: (ckPlay, sim.actorSlot)
  of phDone: (ckNone, -1)

# ---- Scoring and settling ---------------------------------------------------

proc scoresOf*(sim: Sim): array[Seats, float] =
  ## scores[i] = 0.5 + net[i] / (2 * NORM). Higher is better; a seat that
  ## breaks even scores exactly 0.5; the sum is exactly 2.0.
  if sim.handsScored == 0 or sim.norm <= 0.0:
    for slot in 0 ..< Seats:
      result[slot] = 0.5
    return
  for slot in 0 ..< Seats:
    result[slot] = 0.5 + sim.net[slot] / (2.0 * sim.norm)

proc winsOf*(sim: Sim): array[Seats, bool] =
  var best = sim.net[0]
  for slot in 1 ..< Seats:
    if sim.net[slot] > best:
      best = sim.net[slot]
  for slot in 0 ..< Seats:
    result[slot] = abs(sim.net[slot] - best) < 1e-9

proc settle*(sim: var Sim, reason: string) =
  if sim.done:
    return
  sim.done = true
  sim.reason = reason
  sim.phase = phDone
  let m = sim.ruleModule
  if m.audited:
    var event = blankEvent(evAudit)
    event.hand = sim.hand
    event.data = auditFromEvents(sim.config, sim.events)
    sim.addEvent(event)
  var event = blankEvent(evEnd)
  event.hand = sim.handsPlayed
  event.text = reason
  event.data = %*{
    "handsScored": sim.handsScored,
    "hands": sim.config.hands,
    "seed": sim.config.seed,
    "norm": sim.norm
  }
  sim.addEvent(event)

proc finishHand(sim: var Sim) =
  let m = sim.ruleModule
  let before = sim.points
  let net = m.scoreHand(sim)
  var event = blankEvent(evHandEnd)
  event.hand = sim.hand
  var teamPoints: array[Teams, float]
  for slot in 0 ..< Seats:
    let delta = sim.points[slot] - before[slot]
    event.points.add(delta)
    event.tricks.add(sim.tricksWon[slot])
    event.net.add(net[slot])
    if sim.partnership:
      teamPoints[sim.teamOf(slot)] = delta
  if sim.partnership:
    for team in 0 ..< Teams:
      event.teamPoints.add(teamPoints[team])
  event.text = m.verdict(sim)
  for slot in 0 ..< Seats:
    sim.net[slot] += net[slot]
  let cap = m.swingCap(sim.config, sim.hand)
  sim.norm += cap
  sim.swingCaps.add(cap)
  inc sim.handsScored
  inc sim.handsPlayed
  sim.addEvent(event)
  sim.handDone = true
  sim.phase = phDeal
  if sim.handsPlayed >= sim.config.hands:
    sim.settle("complete")

proc voidHand*(sim: var Sim) =
  ## The hard deadline abandoned the hand in progress: it is NOT scored and
  ## is excluded from H and from NORM. The stop is a recorded event, so the
  ## replay re-derives bit-identically.
  if sim.done:
    return
  var event = blankEvent(evHandVoid)
  event.hand = sim.hand
  sim.addEvent(event)
  inc sim.handsPlayed
  sim.handDone = true
  sim.phase = phDeal
  sim.settle("deadline")

proc endEarly*(sim: var Sim, reason = "deadline") =
  ## Stop between hands. The hosted platform keeps nothing from an episode
  ## that outlives its timeout, so a short honest episode always wins.
  if sim.done:
    return
  sim.settle(reason)

# ---- Play -------------------------------------------------------------------

proc resolveTrick(sim: var Sim) =
  let m = sim.ruleModule
  let trump = m.trumpOf(sim)
  var best = 0
  for index in 1 ..< sim.table.len:
    if beats(sim.table[index].card, sim.table[best].card, sim.ledSuit,
        trump, m.isEuchre):
      best = index
  let winner = sim.table[best].slot
  inc sim.tricksWon[winner]
  inc sim.tricksTotal[winner]
  var cards: seq[int]
  for entry in sim.table:
    cards.add(entry.card)
  let points = m.trickPoints(sim, cards)
  sim.penalty[winner] += points
  sim.trickWinner = winner
  sim.trickComplete = true
  var event = blankEvent(evTrick)
  event.hand = sim.hand
  event.trick = sim.trick
  event.slot = winner
  event.cards = cards
  event.value = points
  sim.addEvent(event)
  sim.leaderPos = sim.posOf[winner]
  sim.actorPos = sim.leaderPos
  var done = 0
  for slot in 0 ..< Seats:
    done += sim.tricksWon[slot]
  if done >= sim.tricksThisHand:
    finishHand(sim)

proc applyPlay*(sim: var Sim, card: int, notes = "", scripted = false) =
  if sim.phase != phPlay:
    raise newException(TricksError, "no card is due")
  let m = sim.ruleModule
  let legal = legalCards(sim)
  if card notin legal:
    raise newException(TricksError, cardCode(card) & " is not legal here")
  let slot = sim.actorSlot
  let leading = sim.leadingNow()
  if sim.trickComplete:
    sim.table = @[]
    sim.trickComplete = false
    inc sim.trick
    sim.ledSuit = -1
  let trump = m.trumpOf(sim)
  let suit = effectiveSuit(card, trump, m.isEuchre)
  let trickPos = sim.table.len
  var followed = true
  if leading:
    sim.ledSuit = suit
  else:
    followed = suit == sim.ledSuit
    if not followed and sim.ledSuit >= 0:
      ## Public information: a seat that failed to follow can never hold
      ## that suit again this hand.
      sim.voids[slot][sim.ledSuit] = true
  let index = sim.deal[slot].find(card)
  if index < 0:
    raise newException(TricksError, "seat does not hold " & cardCode(card))
  sim.deal[slot].delete(index)
  sim.played[card] = true
  if notes.len > 0:
    sim.notes[slot] = cleanNotes(notes)
  var event = blankEvent(evPlay)
  event.hand = sim.hand
  event.slot = slot
  event.card = card
  event.trick = sim.trick
  event.trickPos = trickPos
  event.legal = legal
  event.scripted = scripted
  event.text = sim.notes[slot]
  if trickPos == 0:
    event.tell = truncateRunes(m.tell(sim, event), MaxTellLen)
    sim.tell = event.tell
  sim.table.add(TablePlay(slot: slot, card: card))
  sim.addEvent(event)
  if not sim.broken and m.breaks(sim, card, leading, followed):
    sim.broken = true
    var broke = blankEvent(evBroken)
    broke.hand = sim.hand
    broke.suit = (if sim.module == "spades": SuitSpades else: SuitHearts)
    sim.addEvent(broke)
  if sim.table.len >= sim.seatsInPlay():
    resolveTrick(sim)
  else:
    sim.actorPos = sim.nextPos(sim.actorPos)

proc moveAllowed(sim: Sim, move: Move): bool =
  let legal = sim.ruleModule.legalMoves(sim)
  case sim.phase
  of phBid:
    for candidate in legal:
      if candidate.action == move.action and candidate.value == move.value and
          candidate.suit == move.suit:
        return true
    false
  of phDiscard:
    for candidate in legal:
      if candidate.card == move.card:
        return true
    false
  else: true

proc applyMove*(sim: var Sim, move: Move, notes = "", scripted = false) =
  ## The one applier. Raises `TricksError` on anything illegal; the game
  ## server falls back to the scripted baseline on a rejection.
  if sim.done:
    raise newException(TricksError, "the episode is over")
  case sim.phase
  of phPlay:
    if move.kind != mkPlay:
      raise newException(TricksError, "a card is due")
    applyPlay(sim, move.card, notes, scripted)
  of phBid, phPass, phDiscard:
    if not moveAllowed(sim, move):
      raise newException(TricksError, "that is not a legal option here")
    sim.ruleModule.applyMove(sim, move, notes, scripted)
  else:
    raise newException(TricksError, "no decision is due")

proc forcedMove*(sim: Sim): int =
  ## A phase with exactly one legal option costs no model call: hearts'
  ## opening two of clubs, and the last card of a hand.
  if sim.phase != phPlay:
    return -1
  let legal = legalCards(sim)
  if legal.len == 1: legal[0] else: -1

proc lowestLegal*(sim: Sim): Move =
  ## The forced move of last resort: lowest card by (suit, rank), lowest
  ## legal bid, `pass`. `legalMoves` is never empty, so the hand always
  ## advances.
  let legal = legalMoves(sim)
  if legal.len == 0:
    raise newException(TricksError, "no legal option")
  if sim.phase == phPlay:
    var best = legal[0]
    for candidate in legal:
      if suitOf(candidate.card) < suitOf(best.card) or
          (suitOf(candidate.card) == suitOf(best.card) and
           rankOf(candidate.card) < rankOf(best.card)):
        best = candidate
    return best
  if sim.phase == phPass:
    var cards: seq[int]
    for candidate in sortedHand(sim.deal[sim.actorSlot]):
      if cards.len < 3:
        cards.add(candidate)
    return passMove(cards)
  if sim.phase == phDiscard:
    var best = legal[0]
    for candidate in legal:
      if suitOf(candidate.card) < suitOf(best.card) or
          (suitOf(candidate.card) == suitOf(best.card) and
           rankOf(candidate.card) < rankOf(best.card)):
        best = candidate
    return best
  for candidate in legal:
    if candidate.action == "pass":
      return candidate
  var best = legal[0]
  for candidate in legal:
    if candidate.value < best.value:
      best = candidate
  best

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  let scores = sim.scoresOf()
  let wins = sim.winsOf()
  var names = newJArray()
  var scoreNode = newJArray()
  var winNode = newJArray()
  var netNode = newJArray()
  var pointsNode = newJArray()
  var tricksNode = newJArray()
  var bidsNode = newJArray()
  var bidsMadeNode = newJArray()
  var penaltiesNode = newJArray()
  var moonsNode = newJArray()
  var marchesNode = newJArray()
  var euchresNode = newJArray()
  var nilsMadeNode = newJArray()
  var nilsFailedNode = newJArray()
  var bagsNode = newJArray()
  var decisionsNode = newJArray()
  var fallbacksNode = newJArray()
  var forcedNode = newJArray()
  var orderNode = newJArray()
  for slot in 0 ..< Seats:
    ## Results are platform-facing: the league attributes by POLICY name,
    ## not by the anonymous alias the seat played under.
    names.add(%sim.config.players[slot].name)
    scoreNode.add(%scores[slot])
    winNode.add(%wins[slot])
    netNode.add(%sim.net[slot])
    pointsNode.add(%sim.points[slot])
    tricksNode.add(%sim.tricksTotal[slot])
    bidsNode.add(%sim.bidsTotal[slot])
    bidsMadeNode.add(%sim.bidsMade[slot])
    penaltiesNode.add(%sim.penalties[slot])
    moonsNode.add(%sim.moons[slot])
    marchesNode.add(%sim.marches[slot])
    euchresNode.add(%sim.euchres[slot])
    nilsMadeNode.add(%sim.nilsMade[slot])
    nilsFailedNode.add(%sim.nilsFailed[slot])
    bagsNode.add(%sim.bags[slot])
    decisionsNode.add(%sim.decisions[slot])
    fallbacksNode.add(%sim.fallbacks[slot])
    forcedNode.add(%sim.forcedMoves[slot])
  for pos in 0 ..< Seats:
    orderNode.add(%sim.seatOrder[pos])
  var teamPoints: JsonNode = newJNull()
  if sim.partnership:
    var totals: array[Teams, float]
    for slot in 0 ..< Seats:
      totals[sim.teamOf(slot)] = sim.points[slot]
    teamPoints = newJArray()
    for team in 0 ..< Teams:
      teamPoints.add(%totals[team])
  var auditNode: JsonNode = newJNull()
  if sim.ruleModule.audited:
    auditNode = auditFromEvents(sim.config, sim.events)
  %*{
    "names": names,
    "scores": scoreNode,
    "win": winNode,
    "net": netNode,
    "points": pointsNode,
    "teamPoints": teamPoints,
    "tricks": tricksNode,
    "bids": bidsNode,
    "bidsMade": bidsMadeNode,
    "penalties": penaltiesNode,
    "moons": moonsNode,
    "marches": marchesNode,
    "euchres": euchresNode,
    "nilsMade": nilsMadeNode,
    "nilsFailed": nilsFailedNode,
    "bags": bagsNode,
    "decisions": decisionsNode,
    "fallbacks": fallbacksNode,
    "forcedMoves": forcedNode,
    "audit": auditNode,
    "module": sim.module,
    "seats": Seats,
    "seatOrder": orderNode,
    "handsPlayed": sim.handsPlayed,
    "handsScored": sim.handsScored,
    "hands": sim.config.hands,
    "norm": sim.norm,
    "seed": sim.config.seed,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc frameStateJson*(sim: Sim): JsonNode =
  ## The one shape the renderer reads, for all three views.
  let scores = sim.scoresOf()
  var seats = newJArray()
  let acting = (not sim.done) and
    sim.phase in {phBid, phPass, phDiscard, phPlay}
  for slot in 0 ..< Seats:
    var hand = newJArray()
    for card in sim.deal[slot]:
      hand.add(%card)
    var voids = newJArray()
    for suit in 0 ..< 4:
      voids.add(%sim.voids[slot][suit])
    seats.add(%*{
      "slot": slot,
      "pos": sim.posOf[slot],
      "name": sim.names[slot],
      "team": (if sim.partnership: sim.teamOf(slot) else: -1),
      "hand": hand,
      "bid": sim.bids[slot],
      "made": sim.tricksWon[slot],
      "tricks": sim.tricksWon[slot],
      "points": sim.points[slot],
      "net": sim.net[slot],
      "score": scores[slot],
      "penalty": sim.penalty[slot],
      "void": voids,
      "notes": sim.notes[slot],
      "acting": acting and sim.actorSlot == slot,
      "sittingOut": sim.sittingOut == slot,
      "dealer": sim.dealer >= 0 and sim.dealerSlot == slot
    })
  var table = newJArray()
  for entry in sim.table:
    table.add(%*{"slot": entry.slot, "card": entry.card})
  var teams: JsonNode = newJNull()
  if sim.partnership:
    teams = newJArray()
    for team in 0 ..< Teams:
      var points = 0.0
      var bid = 0
      var tricks = 0
      for slot in 0 ..< Seats:
        if sim.teamOf(slot) == team:
          points = sim.points[slot]
          if sim.bids[slot] > 0:
            bid += sim.bids[slot]
          tricks += sim.tricksWon[slot]
      teams.add(%*{"points": points, "bid": bid, "tricks": tricks})
  var order = newJArray()
  for pos in 0 ..< Seats:
    order.add(%sim.seatOrder[pos])
  var kitty = newJArray()
  for card in sim.kitty:
    kitty.add(%card)
  %*{
    "module": sim.module,
    "displayName": sim.displayName,
    "hand": sim.hand,
    "hands": sim.config.hands,
    "dealer": (if sim.dealer >= 0: sim.dealerSlot else: -1),
    "seatOrder": order,
    "trump": sim.trump,
    "trumpName": (if sim.trump >= 0: suitName(sim.trump) else: ""),
    "upcard": sim.upcard,
    "turnup": sim.turnup,
    "kitty": kitty,
    "discard": sim.discarded,
    "maker": sim.maker,
    "alone": sim.alone,
    "broken": sim.broken,
    "passDir": sim.passDir,
    "phase": $sim.phase,
    "actor": (if acting: sim.actorSlot else: -1),
    "leader": (if sim.phase == phPlay: sim.leaderSlot else: -1),
    "trick": sim.trick,
    "tricks": sim.tricksThisHand,
    "table": table,
    "seats": seats,
    "teams": teams,
    "tell": sim.tell,
    "handDone": sim.handDone,
    "gameDone": sim.done,
    "reason": sim.reason
  }

proc tableStateJson*(sim: Sim): JsonNode =
  frameStateJson(sim)

# ---- Event JSON -------------------------------------------------------------

proc intArray(values: seq[int]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%value)

proc floatArray(values: seq[float]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%value)

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.hand >= 0: result["hand"] = %event.hand
  if event.slot >= 0: result["slot"] = %event.slot
  if event.other >= 0: result["other"] = %event.other
  if event.card >= 0: result["card"] = %event.card
  if event.cards.len > 0: result["cards"] = intArray(event.cards)
  if event.deals.len > 0:
    var deals = newJArray()
    for cards in event.deals:
      deals.add(intArray(cards))
    result["hands"] = deals
  if event.kitty.len > 0: result["kitty"] = intArray(event.kitty)
  if event.upcard >= 0: result["upcard"] = %event.upcard
  if event.turnup >= 0: result["turnup"] = %event.turnup
  if event.dealer >= 0: result["dealer"] = %event.dealer
  if event.kind == evHand: result["count"] = %event.count
  if event.passDir.len > 0: result["passDir"] = %event.passDir
  if event.action.len > 0: result["action"] = %event.action
  if event.kind in {evBid, evTrick}: result["value"] = %event.value
  if event.suit >= 0: result["suit"] = %event.suit
  if event.kind in {evTrump}: result["alone"] = %event.alone
  if event.kind in {evBid, evPlay, evDiscard, evPass}:
    result["scripted"] = %event.scripted
  if event.kind == evPlay:
    result["trick"] = %event.trick
    result["trickPos"] = %event.trickPos
    result["legal"] = intArray(event.legal)
  if event.kind == evTrick: result["trick"] = %event.trick
  if event.points.len > 0: result["points"] = floatArray(event.points)
  if event.teamPoints.len > 0:
    result["teamPoints"] = floatArray(event.teamPoints)
  if event.tricks.len > 0: result["tricks"] = intArray(event.tricks)
  if event.net.len > 0: result["net"] = floatArray(event.net)
  if event.tell.len > 0: result["tell"] = %event.tell
  if event.text.len > 0: result["text"] = %event.text
  if not event.data.isNil: result["data"] = event.data

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    hand: node{"hand"}.getInt(-1),
    slot: node{"slot"}.getInt(-1),
    other: node{"other"}.getInt(-1),
    card: node{"card"}.getInt(-1),
    upcard: node{"upcard"}.getInt(-1),
    turnup: node{"turnup"}.getInt(-1),
    dealer: node{"dealer"}.getInt(-1),
    count: node{"count"}.getInt(0),
    passDir: node{"passDir"}.getStr(""),
    action: node{"action"}.getStr(""),
    value: node{"value"}.getInt(0),
    suit: node{"suit"}.getInt(-1),
    alone: node{"alone"}.getBool(false),
    scripted: node{"scripted"}.getBool(false),
    trick: node{"trick"}.getInt(-1),
    trickPos: node{"trickPos"}.getInt(-1),
    tell: node{"tell"}.getStr(""),
    text: node{"text"}.getStr("")
  )
  if node.hasKey("cards"):
    for entry in node["cards"]: result.cards.add(entry.getInt())
  if node.hasKey("hands"):
    for row in node["hands"]:
      var cards: seq[int]
      for entry in row: cards.add(entry.getInt())
      result.deals.add(cards)
  if node.hasKey("kitty"):
    for entry in node["kitty"]: result.kitty.add(entry.getInt())
  if node.hasKey("legal"):
    for entry in node["legal"]: result.legal.add(entry.getInt())
  if node.hasKey("points"):
    for entry in node["points"]: result.points.add(entry.getFloat())
  if node.hasKey("teamPoints"):
    for entry in node["teamPoints"]: result.teamPoints.add(entry.getFloat())
  if node.hasKey("tricks"):
    for entry in node["tricks"]: result.tricks.add(entry.getInt())
  if node.hasKey("net"):
    for entry in node["net"]: result.net.add(entry.getFloat())
  if node.hasKey("data"):
    result.data = node["data"]

# ---- Replay -----------------------------------------------------------------

proc replayRun(config: GameConfig, events: seq[GameEvent],
    frames: var seq[Sim], collect: bool): Sim =
  ## Re-derives the episode by replaying bid / pass / discard / play through
  ## the same rules the server ran. The deal comes from the recorded `hand`
  ## event (never from the seed), and a wall-clock stop is applied by the
  ## same proc on record and on playback, so a `deadline` replay re-derives
  ## bit-identically to a `complete` one.
  var sim = initSim(config)
  sim.events = @[]
  proc snapshot(source: Sim): Sim =
    ## Frames carry no event log of their own: the timeline is the states.
    result = source
    result.events = @[]
  if collect:
    frames.add(snapshot(sim))
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evHand:
      sim.beginHandFrom(event)
    of evPass:
      sim.applyMove(passMove(event.cards), event.text, event.scripted)
    of evBid:
      var move = bidMove(event.action, event.value, event.suit)
      if sim.module == "euchre":
        ## Euchre records the bidding ROUND in `value`; the move carries no
        ## number of its own.
        move = bidMove(event.action, 0,
          (if event.action == "pass": -1
           elif event.action == "order": suitOf(sim.upcard)
           else: event.suit))
      sim.applyMove(move, event.text, event.scripted)
    of evDiscard:
      sim.applyMove(discardMove(event.card), event.text, event.scripted)
    of evPlay:
      sim.applyMove(playMove(event.card), event.text, event.scripted)
      ## The recorded annotation wins: a fixture may carry a padded tell.
      if event.trickPos == 0:
        sim.tell = event.tell
    of evHandVoid:
      sim.voidHand()
    of evEnd:
      if not sim.done:
        sim.settle(event.text)
    of evTrump, evTrick, evBroken, evHandEnd, evAudit:
      ## Produced by the applier itself; nothing to re-apply.
      discard
    if collect:
      frames.add(snapshot(sim))
  sim

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## `frames[i]` is the table after `events[0 ..< i]`.
  discard replayRun(config, events, result, true)

proc replayEpisode*(config: GameConfig, events: seq[GameEvent]): Sim =
  ## The final re-derived state, event log included -- the record then
  ## re-derive check.
  var frames: seq[Sim]
  replayRun(config, events, frames, false)

proc replayStates*(config: GameConfig, events: seq[GameEvent]): JsonNode =
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.frameStateJson())

proc replayConfigJson*(sim: Sim): JsonNode =
  var order = newJArray()
  for pos in 0 ..< Seats:
    order.add(%sim.seatOrder[pos])
  var schedule = newJArray()
  for cards in sim.config.dealSchedule:
    schedule.add(%cards)
  var caps = newJArray()
  for cap in sim.swingCaps:
    caps.add(%cap)
  %*{
    "module": sim.module,
    "displayName": sim.displayName,
    "seats": Seats,
    "hands": sim.config.hands,
    "dealSchedule": schedule,
    "seatOrder": order,
    "partnership": sim.partnership,
    "swingCaps": caps,
    "norm": sim.norm,
    "seed": sim.config.seed,
    "sampled": true,
    "gameVersion": GameVersion
  }

proc replayJson*(sim: Sim): JsonNode =
  ## The replay bytes are self-sufficient: names, policy names, config, the
  ## seed, every dealt card, the whole event log and the results. Nothing
  ## else is ever fetched.
  var names = newJArray()
  for name in sim.names:
    names.add(%name)
  var policyNames = newJArray()
  for player in sim.config.players:
    policyNames.add(%player.name)
  var events = newJArray()
  for event in sim.events:
    events.add(event.eventToJson())
  %*{
    "protocol": "tricks.replay.v" & $GameVersion,
    "names": names,
    "policyNames": policyNames,
    "config": sim.replayConfigJson(),
    "events": events,
    "results": sim.resultsJson()
  }

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  let config = payload["config"]
  result.module = config{"module"}.getStr("euchre")
  result.hands = config{"hands"}.getInt(2)
  result.seed = config{"seed"}.getInt(0)
  result.dealSchedule = @[]
  if config.hasKey("dealSchedule"):
    for entry in config["dealSchedule"]:
      result.dealSchedule.add(entry.getInt())
  ## The replay carries the episode's fitted cap; never re-fit it.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))
