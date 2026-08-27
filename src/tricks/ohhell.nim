## Module `oh-hell` -- 4 seats, individual, predict your tricks EXACTLY.

import types, cards, rules

proc ohHellDeckProc(): seq[int] {.nimcall.} = fullDeck()

proc dealScheduleOf*(cfg: GameConfig): seq[int] =
  if cfg.dealSchedule.len > 0: cfg.dealSchedule else: @DefaultDealSchedule

proc ohHellCards(cfg: GameConfig, hand: int): int {.nimcall.} =
  let schedule = dealScheduleOf(cfg)
  if schedule.len == 0: 1
  elif hand < schedule.len: schedule[hand]
  else: schedule[schedule.len - 1]

proc ohHellPackets(cfg: GameConfig, hand: int): seq[int] {.nimcall.} = @[]

proc ohHellSetup(sim: var Sim, rest: var seq[int]) {.nimcall.} =
  if rest.len < 1:
    raise newException(TricksError, "oh-hell needs a turn-up card")
  sim.turnup = rest[0]
  sim.trump = suitOf(sim.turnup)
  sim.phase = phBid
  sim.bidStep = 0
  sim.actorPos = (sim.dealer + 1) and 3

proc ohHellTrump(sim: Sim): int {.nimcall.} = sim.trump

proc ohHellRestricted(sim: Sim, card: int, leading: bool): bool {.nimcall.} =
  false

proc ohHellBreaks(sim: Sim, card: int, leading, followed: bool): bool
    {.nimcall.} = false

proc ohHellTrickPoints(sim: Sim, cards: seq[int]): int {.nimcall.} = 0

proc ohHellSwingCap(cfg: GameConfig, hand: int): float {.nimcall.} =
  0.75 * (10.0 + ohHellCards(cfg, hand).float)

proc ohHellWorstCase(cfg: GameConfig, hand: int): int {.nimcall.} =
  4 + 4 * ohHellCards(cfg, hand)

proc hookedBid*(sim: Sim): int =
  ## "Screw the dealer": the dealer may not bid the value that would make
  ## the four bids sum to exactly the number of tricks. -1 when the hook
  ## forbids nothing (the balanced value is out of range).
  if sim.bidStep != Seats - 1:
    return -1
  var placed = 0
  for slot in 0 ..< Seats:
    if sim.bids[slot] >= 0:
      placed += sim.bids[slot]
  let balanced = sim.tricksThisHand - placed
  if balanced < 0 or balanced > sim.tricksThisHand:
    return -1
  balanced

proc ohHellLegal(sim: Sim): seq[Move] {.nimcall.} =
  if sim.phase != phBid:
    return
  let banned = hookedBid(sim)
  for value in 0 .. sim.tricksThisHand:
    if value != banned:
      result.add(bidMove("bid", value, -1))

proc ohHellTell(sim: Sim, ev: GameEvent): string {.nimcall.} =
  case ev.kind
  of evBid:
    if ev.value == 0:
      return "Bidding nothing: will duck every trick."
    if ev.value == sim.tricksThisHand:
      return "Claiming every trick."
    if sim.bidStep == Seats - 1:
      var placed = 0
      for slot in 0 ..< Seats:
        if sim.bids[slot] >= 0:
          placed += sim.bids[slot]
      let k = placed + ev.value - sim.tricksThisHand
      return "Hooked off the balanced number -- the table is " &
        (if k > 0: "over" else: "under") & " by " & $abs(k) & "."
    ""
  of evPlay:
    if ev.trickPos != 0:
      return ""
    if sim.trump >= 0 and suitOf(ev.card) == sim.trump and
        sim.currentTrick() == 0:
      return "Cashing the bid immediately."
    ""
  else: ""

proc ohHellApply(sim: var Sim, move: Move, notes: string, scripted: bool)
    {.nimcall.} =
  if sim.phase != phBid:
    raise newException(TricksError, "oh-hell: no module decision is due")
  let slot = sim.actorSlot
  if move.value < 0 or move.value > sim.tricksThisHand:
    raise newException(TricksError,
      "an oh-hell bid is 0.." & $sim.tricksThisHand)
  let banned = hookedBid(sim)
  if banned >= 0 and move.value == banned:
    raise newException(TricksError,
      "the hook forbids the dealer bidding " & $banned)
  if notes.len > 0:
    sim.notes[slot] = cleanNotes(notes)
  var ev = blankEvent(evBid)
  ev.hand = sim.hand
  ev.slot = slot
  ev.action = "bid"
  ev.value = move.value
  ev.suit = -1
  ev.scripted = scripted
  ev.text = sim.notes[slot]
  ev.tell = ohHellTell(sim, ev)
  sim.tell = ev.tell
  sim.addEvent(ev)
  sim.bids[slot] = move.value
  sim.bidActions[slot] = "bid"
  sim.bidsTotal[slot] += move.value
  inc sim.bidStep
  sim.actorPos = (sim.actorPos + 1) and 3
  if sim.bidStep >= Seats:
    sim.beginPlay((sim.dealer + 1) and 3)

proc ohHellScore(sim: var Sim): array[Seats, float] {.nimcall.} =
  var s: array[Seats, float]
  var total = 0.0
  for slot in 0 ..< Seats:
    if sim.tricksWon[slot] == sim.bids[slot]:
      s[slot] = 10.0 + sim.bids[slot].float
      inc sim.bidsMade[slot]
    else:
      s[slot] = 0.0
    total += s[slot]
  let mean = total / Seats.float
  for slot in 0 ..< Seats:
    sim.points[slot] += s[slot]
    result[slot] = s[slot] - mean

proc ohHellVerdict(sim: Sim): string {.nimcall.} =
  var made = 0
  for slot in 0 ..< Seats:
    if sim.tricksWon[slot] == sim.bids[slot]:
      inc made
  $made & " of 4 made the bid"

proc ohHellRules(): string {.nimcall.} =
  """1. Oh Hell, four seats, every cog for itself.
2. Each hand deals a different number of cards from a fresh 52-card shuffle -
   the deal schedule runs 1, 2, 3, 4, 5, 6, 5, 4, 3, 2, 1 - and the next card is
   turned face up: ITS SUIT IS TRUMP for that hand. The turn-up is out of play.
3. Bidding, clockwise from the left of the dealer: each seat bids exactly how
   many tricks it will take, from 0 up to the number of cards dealt, seeing
   every earlier bid.
4. THE HOOK is on: the dealer may not bid the value that would make the four
   bids add up to exactly the number of tricks. Somebody always misses.
5. The seat left of the dealer leads trick 0. There is no lead restriction.
6. Follow the led suit if you can; otherwise play anything. The highest trump
   wins, else the highest card of the led suit. Ranks are 2 < ... < K < A.
7. Scoring: a seat that takes EXACTLY its bid scores 10 plus its bid. Any other
   number of tricks scores ZERO - one over is as bad as three under.
8. So a bid is a contract in both directions: steer to it exactly, and duck
   tricks you do not need as hard as you chase the ones you do."""

proc ohHellModule*(): RuleModule =
  RuleModule(
    id: "oh-hell",
    displayName: "Oh Hell",
    partnership: false,
    audited: true,
    deck: ohHellDeckProc,
    cardsPerHand: ohHellCards,
    dealPackets: ohHellPackets,
    setupHand: ohHellSetup,
    legalMoves: ohHellLegal,
    applyMove: ohHellApply,
    trumpOf: ohHellTrump,
    restricted: ohHellRestricted,
    breaks: ohHellBreaks,
    trickPoints: ohHellTrickPoints,
    scoreHand: ohHellScore,
    swingCap: ohHellSwingCap,
    tell: ohHellTell,
    verdict: ohHellVerdict,
    rulesText: ohHellRules,
    worstCaseDecisions: ohHellWorstCase
  )
