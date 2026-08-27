## Generates `tools/ci/fixtures/hearts_moon.replay` -- the committed worst-
## case replay the wasm-viewer job plays in a real browser.
##
## The certification fixture is a scripted Euchre episode, and a scripted
## baseline emits NO notes at all, so without this fixture nothing in CI
## ever draws the LLM-text chrome (cogchemists, 2026-08-24). This one
## carries a shot moon, a full-cap 400-rune `notes` on every seat, a
## full-cap 120-rune `tell`, and a non-null audit.
##
## `tests/test_sim.nim` regenerates it with this same proc and diffs it
## against the committed bytes, so the fixture can never drift from the
## format.
##
##   nim r --path:src tools/ci/gen_fixture.nim

import
  std/[json, os, unicode],
  tricks/sim

const
  ## Deliberately multi-byte, so the 400-rune cap exercises rune-boundary
  ## truncation and the replay still parses under a strict UTF-8 decoder.
  NotesSeed = "\u2660\u2665\u2666\u2663 count: queen still out, " &
    "west void in \u2666 since trick 1, two high hearts left \u2014 "
  TellSeed = "Flushing out the queen \u2014 a lead nobody at this table " &
    "can read as anything else, and the only thing this cog is allowed " &
    "to say about its hand at all. "

proc longNotes(): string =
  while result.runeLen <= 600:
    result.add(NotesSeed)

proc longTell(): string =
  while result.runeLen <= 300:
    result.add(TellSeed)

proc moonTargets(): array[Seats, seq[int]] =
  ## Slot 0 holds the top three of every suit plus the jack of spades, so it
  ## wins every trick after the forced two-of-clubs lead and takes all 26
  ## penalty points. The other three hands are the deterministic remainder.
  var mine: seq[int]
  for suit in 0 ..< 4:
    for rank in [RankAce, RankKing, RankQueen]:
      mine.add(makeCard(rank, suit))
  mine.add(makeCard(RankJack, SuitSpades))
  result[0] = sortedHand(mine)
  var rest: seq[int]
  for card in fullDeck():
    if card notin mine:
      rest.add(card)
  rest = sortedHand(rest)
  ## Deal the remainder so every seat keeps at least one club (nothing
  ## penalty-bearing can fall on trick 0) and slot 1 holds the two of clubs.
  var clubs, others: seq[int]
  for card in rest:
    if suitOf(card) == SuitClubs: clubs.add(card) else: others.add(card)
  for slot in 1 ..< Seats:
    result[slot] = @[]
  ## Clubs round-robin so every seat keeps at least one and the lowest club
  ## (the forced opening lead) lands on slot 1; the rest fills each hand to
  ## thirteen in order.
  for index, card in clubs:
    result[1 + (index mod 3)].add(card)
  var cursor = 0
  for slot in 1 ..< Seats:
    while result[slot].len < 13:
      result[slot].add(others[cursor])
      inc cursor
  for slot in 0 ..< Seats:
    result[slot] = sortedHand(result[slot])

proc passBlocks(sim: Sim, targets: array[Seats, seq[int]]):
    array[Seats, seq[int]] =
  ## Hand 0 passes LEFT. If the seat at position p passes block B[p] to the
  ## seat at position p+1, and B[p] is three cards of position p+1's target
  ## hand, then dealing (target[p] minus B[p-1]) plus B[p] to position p and
  ## playing those passes lands every seat on exactly its target hand.
  for pos in 0 ..< Seats:
    let nextSlot = sim.slotAt((pos + 1) and 3)
    result[pos] = targets[nextSlot][0 ..< 3]

proc stackedDeal(sim: Sim, targets: array[Seats, seq[int]],
    blocks: array[Seats, seq[int]]): seq[seq[int]] =
  result = newSeq[seq[int]](Seats)
  for pos in 0 ..< Seats:
    let slot = sim.slotAt(pos)
    let incoming = blocks[(pos + 3) and 3]
    var cards: seq[int]
    for card in targets[slot]:
      if card notin incoming:
        cards.add(card)
    for card in blocks[pos]:
      cards.add(card)
    result[slot] = sortedHand(cards)

proc highestLegal(sim: Sim): int =
  let legal = legalCards(sim)
  result = legal[0]
  for card in legal:
    if rankOf(card) > rankOf(result) or
        (rankOf(card) == rankOf(result) and suitOf(card) > suitOf(result)):
      result = card

proc lowestLegalCard(sim: Sim): int =
  let legal = legalCards(sim)
  result = legal[0]
  for card in legal:
    if suitOf(card) < suitOf(result) or
        (suitOf(card) == suitOf(result) and rankOf(card) < rankOf(result)):
      result = card

proc simplePass(sim: Sim): seq[int] =
  ## Hand 1 passes the three highest cards; deterministic, and legal by
  ## construction.
  var hand = sortedHand(sim.deal[sim.actorSlot])
  for _ in 0 ..< 3:
    var pick = hand[0]
    for card in hand:
      if rankOf(card) > rankOf(pick) or
          (rankOf(card) == rankOf(pick) and suitOf(card) > suitOf(pick)):
        pick = card
    result.add(pick)
    hand.delete(hand.find(pick))

proc heartsMoonReplay*(): string =
  var config = defaultGameConfig()
  config.module = "hearts"
  config.hands = 2
  config.seed = 20260826
  config.turnDelayMs = 0
  config.sampled = true
  config.players = @[
    PlayerConfig(name: "trick-taking-signaller"),
    PlayerConfig(name: "trick-taking-counter"),
    PlayerConfig(name: "trick-taking-follow"),
    PlayerConfig(name: "trick-taking-tracker")
  ]
  for slot in 0 ..< Seats:
    config.tokens.add("token-" & $slot)
  var sim = initSim(config)
  let notes = longNotes()
  let targets = moonTargets()
  let blocks = passBlocks(sim, targets)
  sim.beginHand(stackedDeal(sim, targets, blocks))
  while not sim.done:
    let call = sim.currentCall()
    case call.kind
    of ckDeal:
      sim.beginHand()
    of ckNone:
      break
    of ckPass:
      if sim.hand == 0:
        sim.applyMove(passMove(blocks[sim.actorPos]), notes, false)
      else:
        sim.applyMove(passMove(simplePass(sim)), notes, false)
    of ckPlay:
      let card =
        if sim.actorSlot == 0 and sim.hand == 0: highestLegal(sim)
        else: lowestLegalCard(sim)
      sim.applyMove(playMove(card), notes, false)
    else:
      raise newException(TricksError, "hearts has no bidding phase")
  if sim.moons[0] != 1:
    raise newException(TricksError,
      "the stacked hand no longer shoots the moon: penalties " &
        $sim.penalty[0])
  var payload = sim.replayJson()
  ## One lead carries a tell at the FULL 120-rune cap, so the viewer's
  ## ribbon is exercised at its worst case. The engine's own tells are
  ## short by construction; this is the fixture's whole point.
  let padded = truncateRunes(longTell(), MaxTellLen)
  for event in payload["events"]:
    if event{"kind"}.getStr() == "play" and event{"trickPos"}.getInt(-1) == 0:
      event["tell"] = %padded
      break
  $payload

when isMainModule:
  let target =
    if paramCount() >= 1: paramStr(1)
    else: "tools/ci/fixtures/hearts_moon.replay"
  createDir(parentDir(target))
  writeFile(target, heartsMoonReplay())
  echo "wrote ", target, " (", getFileSize(target), " bytes)"
