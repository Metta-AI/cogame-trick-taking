## Module `euchre` -- 4 seats, partnerships (positions 0&2 vs 1&3).
## The first module to certify.

import types, cards, rules

proc euchreDeckProc(): seq[int] {.nimcall.} = euchreDeck()

proc euchreCards(cfg: GameConfig, hand: int): int {.nimcall.} = 5

proc euchrePackets(cfg: GameConfig, hand: int): seq[int] {.nimcall.} =
  ## 3-2 / 2-3 alternating, clockwise from the left of the dealer.
  @[3, 2, 3, 2, 2, 3, 2, 3]

proc euchreSetup(sim: var Sim, rest: var seq[int]) {.nimcall.} =
  if rest.len < 4:
    raise newException(TricksError, "euchre needs a four-card kitty")
  sim.kitty = rest[0 ..< 4]
  sim.upcard = sim.kitty[0]
  sim.upcardLive = true
  sim.trump = -1
  sim.phase = phBid
  sim.bidRound = 1
  sim.bidStep = 0
  sim.actorPos = (sim.dealer + 1) and 3

proc euchreTrump(sim: Sim): int {.nimcall.} = sim.trump

proc euchreRestricted(sim: Sim, card: int, leading: bool): bool {.nimcall.} =
  false

proc euchreBreaks(sim: Sim, card: int, leading, followed: bool): bool
    {.nimcall.} = false

proc euchreTrickPoints(sim: Sim, cards: seq[int]): int {.nimcall.} = 0

proc euchreSwingCap(cfg: GameConfig, hand: int): float {.nimcall.} = 4.0

proc euchreWorstCase(cfg: GameConfig, hand: int): int {.nimcall.} = 29

proc euchreLegal(sim: Sim): seq[Move] {.nimcall.} =
  case sim.phase
  of phBid:
    if sim.bidRound == 1:
      result.add(bidMove("pass"))
      result.add(bidMove("order", 0, suitOf(sim.upcard)))
      result.add(bidMove("alone", 0, suitOf(sim.upcard)))
    else:
      let banned = suitOf(sim.upcard)
      ## Stick the dealer: the fourth seat in round 2 must name a suit.
      if not (sim.bidStep == 3):
        result.add(bidMove("pass"))
      for suit in 0 ..< 4:
        if suit != banned:
          result.add(bidMove("name", 0, suit))
          result.add(bidMove("alone", 0, suit))
  of phDiscard:
    for card in sim.deal[sim.actorSlot]:
      result.add(discardMove(card))
  else:
    discard

proc euchreTell(sim: Sim, ev: GameEvent): string {.nimcall.} =
  let dealer = sim.dealerSlot
  let dealerPartner = sim.slotAt((sim.dealer + 2) and 3)
  case ev.kind
  of evBid:
    if ev.action == "order" or ev.action == "alone":
      if ev.slot == dealerPartner:
        return "Giving the dealer the up-card: side strength, wants that " &
          "trump in partner's hand."
      if ev.slot != dealer:
        return "Taking the up-card away: likely the right bower, or two " &
          "trumps and an ace."
      if ev.action == "alone":
        return "Alone: right bower plus at least two more trumps. " &
          "Partner, stay out."
      return ""
    if ev.action == "pass" and ev.value == 1:
      return "No ordering hand in " & suitName(suitOf(sim.upcard)) & "."
    if ev.action == "name":
      if sim.stuck and ev.slot == dealer:
        return "Forced by stick-the-dealer -- read nothing into this suit."
      return "Strength is in " & suitName(ev.suit) & ", not " &
        suitName(suitOf(sim.upcard)) & "."
    ""
  of evPlay:
    if ev.trickPos != 0:
      return ""
    let card = ev.card
    let led = euchreEffectiveSuit(card, sim.trump)
    if led == sim.trump:
      let makerTeam = (if sim.maker >= 0: sim.teamOf(sim.maker) else: -1)
      if makerTeam >= 0 and sim.teamOf(ev.slot) == makerTeam:
        return "Drawing trumps to protect the march."
      return "Drawing the maker's trumps early."
    if rankOf(card) == RankAce:
      return "Cashing a certain winner; probably void in " &
        suitName(led) & " next trick."
    if rankOf(card) == 7 or rankOf(card) == RankTen:
      return "Probing: weak in " & suitName(led) & " and hoping partner is not."
    ""
  else: ""

proc finishEuchreBidding(sim: var Sim) =
  ## Trump is settled and any discard is done: seat the alone partner out
  ## and lead from the left of the dealer.
  if sim.alone and sim.maker >= 0:
    sim.sittingOut = sim.slotAt((sim.posOf[sim.maker] + 2) and 3)
  var lead = (sim.dealer + 1) and 3
  for _ in 0 ..< Seats:
    if sim.sittingOut < 0 or sim.slotAt(lead) != sim.sittingOut:
      break
    lead = (lead + 1) and 3
  sim.beginPlay(lead)

proc euchreApply(sim: var Sim, move: Move, notes: string, scripted: bool)
    {.nimcall.} =
  let slot = sim.actorSlot
  if notes.len > 0:
    sim.notes[slot] = cleanNotes(notes)
  case sim.phase
  of phBid:
    var ev = blankEvent(evBid)
    ev.hand = sim.hand
    ev.slot = slot
    ev.action = move.action
    ev.value = sim.bidRound
    ev.suit = (if move.action == "pass": -1 else: move.suit)
    ev.scripted = scripted
    ev.text = sim.notes[slot]
    ev.tell = euchreTell(sim, ev)
    sim.tell = ev.tell
    sim.bidActions[slot] = move.action
    sim.addEvent(ev)
    if move.action == "pass":
      inc sim.bidStep
      sim.actorPos = (sim.actorPos + 1) and 3
      if sim.bidStep >= Seats:
        if sim.bidRound == 1:
          sim.bidRound = 2
          sim.bidStep = 0
          sim.upcardLive = false
          sim.actorPos = (sim.dealer + 1) and 3
        else:
          raise newException(TricksError,
            "stick the dealer: the dealer may not pass in round 2")
      elif sim.bidRound == 2 and sim.bidStep == 3:
        sim.stuck = true
      return
    ## order / name / alone: trump is made.
    sim.trump = move.suit
    sim.maker = slot
    sim.alone = move.action == "alone"
    var trumpEvent = blankEvent(evTrump)
    trumpEvent.hand = sim.hand
    trumpEvent.slot = slot
    trumpEvent.suit = sim.trump
    trumpEvent.alone = sim.alone
    trumpEvent.text = (if sim.stuck and slot == sim.dealerSlot:
      "stuck dealer" else: "")
    sim.addEvent(trumpEvent)
    if sim.bidRound == 1:
      ## The dealer picks the up-card up and discards one face down.
      let dealer = sim.dealerSlot
      sim.deal[dealer] = sortedHand(sim.deal[dealer] & @[sim.upcard])
      sim.upcardLive = false
      sim.phase = phDiscard
      sim.actorPos = sim.dealer
    else:
      finishEuchreBidding(sim)
  of phDiscard:
    let index = sim.deal[slot].find(move.card)
    if index < 0:
      raise newException(TricksError,
        "the dealer does not hold " & cardCode(move.card))
    sim.deal[slot].delete(index)
    sim.discarded = move.card
    var ev = blankEvent(evDiscard)
    ev.hand = sim.hand
    ev.slot = slot
    ev.card = move.card
    ev.scripted = scripted
    ev.text = sim.notes[slot]
    sim.addEvent(ev)
    finishEuchreBidding(sim)
  else:
    raise newException(TricksError, "euchre: no module decision is due")

proc euchreScore(sim: var Sim): array[Seats, float] {.nimcall.} =
  let makerTeam = sim.teamOf(sim.maker)
  let mk = teamTricks(sim, makerTeam)
  var makerPts = 0.0
  var defPts = 0.0
  if mk >= 3:
    if mk == 5:
      makerPts = (if sim.alone: 4.0 else: 2.0)
    else:
      makerPts = 1.0
  else:
    defPts = 2.0
  for slot in 0 ..< Seats:
    let mine = (if sim.teamOf(slot) == makerTeam: makerPts else: defPts)
    let theirs = (if sim.teamOf(slot) == makerTeam: defPts else: makerPts)
    sim.points[slot] += mine
    result[slot] = mine - theirs
    if sim.teamOf(slot) == makerTeam:
      if mk == 5: inc sim.marches[slot]
    else:
      if mk <= 2: inc sim.euchres[slot]

proc euchreVerdict(sim: Sim): string {.nimcall.} =
  let makerTeam = sim.teamOf(sim.maker)
  let mk = teamTricks(sim, makerTeam)
  if mk <= 2: "euchred"
  elif mk == 5: (if sim.alone: "lone march" else: "march")
  else: "makers make it"

proc euchreRules(): string {.nimcall.} =
  """1. Euchre, four seats, partnerships: table positions 0 and 2 against 1 and 3.
2. The deck is 24 cards - 9, 10, J, Q, K, A of every suit. Five cards each; the
   four left over are the kitty and its top card is turned face up (the up-card).
3. Bidding round 1, clockwise from the left of the dealer: pass, order (make the
   up-card's suit trump), or alone (make it trump and play without your partner).
   The first non-pass ends round 1 and that seat is the maker; the dealer then
   picks the up-card up and discards one card face down.
4. Bidding round 2 happens only if all four pass. The up-card is turned down and
   each seat may pass, or name/alone any suit EXCEPT the up-card's. Stick the
   dealer is ON: if the first three pass, the dealer MUST name a suit.
5. The jack of trump is the right bower, the highest trump. The jack of the other
   suit of the same colour is the left bower, the second-highest trump, and it is
   a TRUMP, not a card of its printed suit - for following, leading and winning.
6. Trump ranks 9 < 10 < Q < K < A < left bower < right bower. Other suits rank
   2 < ... < 10 < J < Q < K < A.
7. The seat left of the dealer leads trick 0. Follow the led suit if you can;
   otherwise play anything. Highest trump wins, else highest card of the led suit.
8. If the maker went alone, the maker's partner sits out the whole hand.
9. Scoring: makers take 3 or 4 tricks = 1 point; all 5 = 2 points (4 if alone);
   makers take 2 or fewer (euchred) = 2 points to the defenders."""

proc euchreModule*(): RuleModule =
  RuleModule(
    id: "euchre",
    displayName: "Euchre",
    partnership: true,
    audited: false,
    deck: euchreDeckProc,
    cardsPerHand: euchreCards,
    dealPackets: euchrePackets,
    setupHand: euchreSetup,
    legalMoves: euchreLegal,
    applyMove: euchreApply,
    trumpOf: euchreTrump,
    restricted: euchreRestricted,
    breaks: euchreBreaks,
    trickPoints: euchreTrickPoints,
    scoreHand: euchreScore,
    swingCap: euchreSwingCap,
    tell: euchreTell,
    verdict: euchreVerdict,
    rulesText: euchreRules,
    worstCaseDecisions: euchreWorstCase
  )
