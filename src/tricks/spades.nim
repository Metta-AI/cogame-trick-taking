## Module `spades` -- 4 seats, partnerships (positions 0&2 vs 1&3).
## Trump is always spades; every seat bids a number of tricks and a bid of
## zero is nil.

import std/strutils, types, cards, rules

proc spadesDeckProc(): seq[int] {.nimcall.} = fullDeck()

proc spadesCards(cfg: GameConfig, hand: int): int {.nimcall.} = 13

proc spadesPackets(cfg: GameConfig, hand: int): seq[int] {.nimcall.} = @[]

proc spadesSetup(sim: var Sim, rest: var seq[int]) {.nimcall.} =
  sim.trump = SuitSpades
  sim.broken = false
  sim.phase = phBid
  sim.bidStep = 0
  sim.actorPos = (sim.dealer + 1) and 3

proc spadesTrump(sim: Sim): int {.nimcall.} = SuitSpades

proc spadesRestricted(sim: Sim, card: int, leading: bool): bool {.nimcall.} =
  ## A spade may not be LED until spades are broken.
  leading and suitOf(card) == SuitSpades and not sim.broken

proc spadesBreaks(sim: Sim, card: int, leading, followed: bool): bool
    {.nimcall.} =
  suitOf(card) == SuitSpades and (leading or not followed)

proc spadesTrickPoints(sim: Sim, cards: seq[int]): int {.nimcall.} = 0

proc spadesSwingCap(cfg: GameConfig, hand: int): float {.nimcall.} = 460.0

proc spadesWorstCase(cfg: GameConfig, hand: int): int {.nimcall.} = 56

proc spadesLegal(sim: Sim): seq[Move] {.nimcall.} =
  if sim.phase == phBid:
    for value in 0 .. 13:
      result.add(bidMove("bid", value, -1))

proc spadesTell(sim: Sim, ev: GameEvent): string {.nimcall.} =
  case ev.kind
  of evBid:
    if ev.value == 0:
      return "Nil: not one card that can win a trick. Partner, cover."
    if ev.value >= 5:
      return $ev.value & " near-certain winners -- long spades."
    if ev.value <= 2:
      return "A weak hand; the contract is partner's."
    ""
  of evPlay:
    if ev.trickPos != 0:
      return ""
    let partner = sim.partnerSlot(ev.slot)
    if suitOf(ev.card) == SuitSpades and sim.broken and partner >= 0 and
        sim.bids[partner] == 0:
      return "Pulling trumps to protect the nil."
    if rankOf(ev.card) == RankAce:
      return "Banking the contract early."
    ""
  else: ""

proc spadesApply(sim: var Sim, move: Move, notes: string, scripted: bool)
    {.nimcall.} =
  if sim.phase != phBid:
    raise newException(TricksError, "spades: no module decision is due")
  let slot = sim.actorSlot
  if move.value < 0 or move.value > 13:
    raise newException(TricksError, "a spades bid is 0..13")
  if notes.len > 0:
    sim.notes[slot] = cleanNotes(notes)
  sim.bids[slot] = move.value
  sim.bidActions[slot] = "bid"
  sim.bidsTotal[slot] += move.value
  var ev = blankEvent(evBid)
  ev.hand = sim.hand
  ev.slot = slot
  ev.action = "bid"
  ev.value = move.value
  ev.suit = -1
  ev.scripted = scripted
  ev.text = sim.notes[slot]
  ev.tell = spadesTell(sim, ev)
  sim.tell = ev.tell
  sim.addEvent(ev)
  inc sim.bidStep
  sim.actorPos = (sim.actorPos + 1) and 3
  if sim.bidStep >= Seats:
    sim.beginPlay((sim.dealer + 1) and 3)

proc spadesScore(sim: var Sim): array[Seats, float] {.nimcall.} =
  var teamScore: array[Teams, float]
  for team in 0 ..< Teams:
    var contract = 0
    var nonNilTricks = 0
    var failedNilTricks = 0
    var nilBonus = 0
    for slot in 0 ..< Seats:
      if sim.teamOf(slot) != team:
        continue
      if sim.bids[slot] == 0:
        if sim.tricksWon[slot] == 0:
          nilBonus += 100
          inc sim.nilsMade[slot]
        else:
          nilBonus -= 100
          inc sim.nilsFailed[slot]
          failedNilTricks += sim.tricksWon[slot]
      else:
        contract += sim.bids[slot]
        nonNilTricks += sim.tricksWon[slot]
    ## A team cannot contract for more tricks than exist: two partners may
    ## each bid up to 13, but the CONTRACT is capped at 13. That cap is what
    ## makes |teamScore| <= 230 provable (max 130 + 100 for a made
    ## 13-contract alongside a successful nil, min -130 - 100), and therefore
    ## what keeps every score inside [0, 1] with no clamping.
    contract = min(contract, 13)
    var base = 0
    var bags = 0
    if nonNilTricks >= contract:
      bags = max(0, nonNilTricks + failedNilTricks - contract)
      base = 10 * contract + bags
    else:
      base = -10 * contract
    teamScore[team] = float(base + nilBonus)
    for slot in 0 ..< Seats:
      if sim.teamOf(slot) == team:
        sim.bags[slot] += bags
  for slot in 0 ..< Seats:
    let mine = teamScore[sim.teamOf(slot)]
    let theirs = teamScore[1 - sim.teamOf(slot)]
    sim.points[slot] += mine
    result[slot] = mine - theirs
    if sim.bids[slot] >= 0 and sim.tricksWon[slot] >= sim.bids[slot] and
        sim.bids[slot] > 0:
      inc sim.bidsMade[slot]
    elif sim.bids[slot] == 0 and sim.tricksWon[slot] == 0:
      inc sim.bidsMade[slot]

proc spadesVerdict(sim: Sim): string {.nimcall.} =
  var parts: seq[string]
  for slot in 0 ..< Seats:
    if sim.bids[slot] == 0:
      parts.add(if sim.tricksWon[slot] == 0: "nil made" else: "nil failed")
  for team in 0 ..< Teams:
    var contract = 0
    var tricks = 0
    for slot in 0 ..< Seats:
      if sim.teamOf(slot) == team and sim.bids[slot] > 0:
        contract += sim.bids[slot]
        tricks += sim.tricksWon[slot]
    if contract > 0:
      parts.add("team " & $team & (if tricks >= contract: " makes " else: " is set on ") & $contract)
  parts.join(", ")

proc spadesRules(): string {.nimcall.} =
  """1. Spades, four seats, partnerships: table positions 0 and 2 against 1 and 3.
2. A full 52-card deck, thirteen cards each. TRUMP IS ALWAYS SPADES.
3. Bidding, clockwise from the left of the dealer: each seat bids a whole number
   of tricks from 0 to 13, seeing every earlier bid. A bid of 0 is NIL.
4. The team contract is the sum of the two partners' non-nil bids, capped at
   13 - a team cannot contract for more tricks than exist.
5. The seat left of the dealer leads trick 0. A SPADE MAY NOT BE LED until
   spades are broken - a spade has been played by a seat void in the led suit -
   unless the leader holds nothing but spades.
6. Follow the led suit if you can; otherwise play anything. The highest spade
   wins the trick, else the highest card of the led suit.
7. Ranks are 2 < 3 < ... < 10 < J < Q < K < A.
8. Scoring per team: if the non-nil members take at least the contract C, the
   team scores 10 x C plus one point per overtrick (a bag); if they fall short,
   the team scores minus 10 x C.
9. A nil member scores +100 if it wins NO trick and -100 otherwise. A failed
   nil's tricks count as bags but never towards the contract.
10. There is no bag rollover penalty in this version."""

proc spadesModule*(): RuleModule =
  RuleModule(
    id: "spades",
    displayName: "Spades",
    partnership: true,
    audited: false,
    deck: spadesDeckProc,
    cardsPerHand: spadesCards,
    dealPackets: spadesPackets,
    setupHand: spadesSetup,
    legalMoves: spadesLegal,
    applyMove: spadesApply,
    trumpOf: spadesTrump,
    restricted: spadesRestricted,
    breaks: spadesBreaks,
    trickPoints: spadesTrickPoints,
    scoreHand: spadesScore,
    swingCap: spadesSwingCap,
    tell: spadesTell,
    verdict: spadesVerdict,
    rulesText: spadesRules,
    worstCaseDecisions: spadesWorstCase
  )
