## Module `hearts` -- 4 seats, individual, avoid tricks. No trump.

import types, cards, rules

proc heartsDeckProc(): seq[int] {.nimcall.} = fullDeck()

proc heartsCards(cfg: GameConfig, hand: int): int {.nimcall.} = 13

proc heartsPackets(cfg: GameConfig, hand: int): seq[int] {.nimcall.} = @[]

proc passTarget*(pos, hand: int): int =
  ## Direction by hand index: 0 left, 1 right, 2 across, 3 hold.
  case hand mod 4
  of 0: (pos + 1) and 3
  of 1: (pos + 3) and 3
  of 2: (pos + 2) and 3
  else: pos

proc passDirName*(hand: int): string =
  case hand mod 4
  of 0: "left"
  of 1: "right"
  of 2: "across"
  else: "hold"

proc startHeartsPlay(sim: var Sim) =
  ## The holder of the two of clubs leads it to trick 0.
  var leader = 0
  for slot in 0 ..< Seats:
    if TwoOfClubs in sim.deal[slot]:
      leader = sim.posOf[slot]
  sim.beginPlay(leader)

proc heartsSetup(sim: var Sim, rest: var seq[int]) {.nimcall.} =
  sim.trump = -1
  sim.broken = false
  sim.passDir = passDirName(sim.hand)
  if sim.passDir == "hold":
    startHeartsPlay(sim)
  else:
    sim.phase = phPass
    sim.bidStep = 0
    sim.actorPos = 0

proc heartsTrump(sim: Sim): int {.nimcall.} = -1

proc heartsRestricted(sim: Sim, card: int, leading: bool): bool {.nimcall.} =
  let trick = sim.currentTrick()
  if trick == 0:
    ## The two of clubs is led to trick 0, and no heart and not the queen of
    ## spades may be played on it at all.
    if leading:
      return card != TwoOfClubs
    return heartsPenalty(card) > 0
  leading and suitOf(card) == SuitHearts and not sim.broken

proc heartsBreaks(sim: Sim, card: int, leading, followed: bool): bool
    {.nimcall.} =
  heartsPenalty(card) > 0 and (leading or not followed)

proc heartsTrickPoints(sim: Sim, cards: seq[int]): int {.nimcall.} =
  for card in cards:
    result += heartsPenalty(card)

proc heartsSwingCap(cfg: GameConfig, hand: int): float {.nimcall.} = 19.5

proc heartsWorstCase(cfg: GameConfig, hand: int): int {.nimcall.} = 56

proc heartsLegal(sim: Sim): seq[Move] {.nimcall.} =
  ## The pass pool: every held card is passable, and exactly three distinct
  ## ones make a move. `applyMove` validates the triple.
  if sim.phase == phPass:
    for card in sim.deal[sim.actorSlot]:
      result.add(passMove(@[card]))

proc heartsTell(sim: Sim, ev: GameEvent): string {.nimcall.} =
  if ev.kind != evPlay or ev.trickPos != 0:
    return ""
  let card = ev.card
  let suit = suitOf(card)
  if not sim.broken and (suit == SuitClubs or suit == SuitDiamonds) and
      rankOf(card) < RankJack:
    return "Flushing out the queen."
  if suit == SuitSpades and rankOf(card) < RankQueen:
    return "Hunting the queen."
  if suit == SuitHearts and sim.broken:
    return "Hearts are running."
  if sim.penalty[ev.slot] >= 20:
    return "This looks like a moon attempt."
  ""

proc heartsApply(sim: var Sim, move: Move, notes: string, scripted: bool)
    {.nimcall.} =
  if sim.phase != phPass:
    raise newException(TricksError, "hearts: no module decision is due")
  let slot = sim.actorSlot
  if move.cards.len != 3:
    raise newException(TricksError, "a hearts pass is exactly three cards")
  for index, card in move.cards:
    if card notin sim.deal[slot]:
      raise newException(TricksError,
        "you do not hold " & cardCode(card))
    for other in 0 ..< index:
      if move.cards[other] == card:
        raise newException(TricksError, "a hearts pass is three DISTINCT cards")
  if notes.len > 0:
    sim.notes[slot] = cleanNotes(notes)
  sim.passSel[slot] = move.cards
  var ev = blankEvent(evPass)
  ev.hand = sim.hand
  ev.slot = slot
  ev.cards = move.cards
  ev.other = sim.slotAt(passTarget(sim.posOf[slot], sim.hand))
  ev.scripted = scripted
  ev.text = sim.notes[slot]
  sim.addEvent(ev)
  inc sim.bidStep
  if sim.bidStep < Seats:
    sim.actorPos = sim.bidStep
    return
  ## Only after all four have chosen are the received cards delivered.
  var taken: array[Seats, seq[int]]
  for pos in 0 ..< Seats:
    let giver = sim.slotAt(pos)
    let receiver = sim.slotAt(passTarget(pos, sim.hand))
    taken[receiver] = taken[receiver] & sim.passSel[giver]
  for pos in 0 ..< Seats:
    let giver = sim.slotAt(pos)
    for card in sim.passSel[giver]:
      let index = sim.deal[giver].find(card)
      if index >= 0:
        sim.deal[giver].delete(index)
  for slotIndex in 0 ..< Seats:
    sim.deal[slotIndex] = sortedHand(sim.deal[slotIndex] & taken[slotIndex])
  sim.actorPos = 0
  startHeartsPlay(sim)

proc heartsScore(sim: var Sim): array[Seats, float] {.nimcall.} =
  var p: array[Seats, int]
  var moon = -1
  for slot in 0 ..< Seats:
    p[slot] = sim.penalty[slot]
    if p[slot] == 26:
      moon = slot
  if moon >= 0:
    for slot in 0 ..< Seats:
      p[slot] = (if slot == moon: 0 else: 26)
    inc sim.moons[moon]
  var total = 0
  for slot in 0 ..< Seats:
    total += p[slot]
  let mean = total.float / Seats.float
  for slot in 0 ..< Seats:
    sim.points[slot] += p[slot].float
    sim.penalties[slot] += p[slot]
    result[slot] = mean - p[slot].float

proc heartsVerdict(sim: Sim): string {.nimcall.} =
  for slot in 0 ..< Seats:
    if sim.penalty[slot] == 26:
      return "shot the moon"
  "points split"

proc heartsRules(): string {.nimcall.} =
  """1. Hearts, four seats, every cog for itself. There is NO TRUMP.
2. A full 52-card deck, thirteen cards each.
3. The pass: hand 1 passes three cards to the left, hand 2 to the right,
   hand 3 across, hand 4 nobody passes, and so on. You choose three cards from
   your thirteen; nothing is revealed until all four seats have chosen, and you
   never learn what anyone else passed.
4. The holder of the two of clubs leads it to trick 0.
5. On trick 0 no heart and not the queen of spades may be played, unless a seat
   holds nothing else. A HEART MAY NOT BE LED until hearts are broken - a heart
   or the queen of spades has been discarded - unless the leader holds only
   hearts.
6. Follow the led suit if you can; otherwise play anything. The highest card of
   the led suit takes the trick. Ranks are 2 < ... < 10 < J < Q < K < A.
7. Every heart in a trick you take costs you 1 penalty point and the queen of
   spades costs 13. The hand always carries exactly 26 points.
8. SHOOTING THE MOON: a seat that takes all 26 scores 0 and every other seat
   scores 26 instead.
9. Fewer penalty points is better. Duck early, count the queen, and watch who
   is void in what."""

proc heartsModule*(): RuleModule =
  RuleModule(
    id: "hearts",
    displayName: "Hearts",
    partnership: false,
    audited: true,
    deck: heartsDeckProc,
    cardsPerHand: heartsCards,
    dealPackets: heartsPackets,
    setupHand: heartsSetup,
    legalMoves: heartsLegal,
    applyMove: heartsApply,
    trumpOf: heartsTrump,
    restricted: heartsRestricted,
    breaks: heartsBreaks,
    trickPoints: heartsTrickPoints,
    scoreHand: heartsScore,
    swingCap: heartsSwingCap,
    tell: heartsTell,
    verdict: heartsVerdict,
    rulesText: heartsRules,
    worstCaseDecisions: heartsWorstCase
  )
