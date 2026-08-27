## Claude-backed decisions for the trick table, plus the two scripted
## baselines.
##
## A policy is just a prompt: the game server composes the acting seat's
## view (its own hand, the public record of the hand, the standings, its
## private notes and the PRECOMPUTED LEGAL SET) plus that seat's prompt and
## asks Claude for one JSON object.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately, so offline certification always completes.
##
## Degrade, never hang: one retry, then the seat's scripted baseline move,
## then the lowest legal option. There is no path in which the engine waits
## on anything.

import
  std/[json, os, random, strutils, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## Decision-start to decision-start floor: 240 sequential decisions at
  ## 2.2 s hold the episode at <= 27 requests/minute, inside the Bedrock
  ## sidecar's ~30 rpm per-episode cap.
  DecisionSpacingMs* = 2200
  ThrottleExtraMs* = 500
  ## Ceiling on the 429 backoff. The spacing floor is a wait like any other,
  ## so it has to be bounded by something the deadline can accommodate:
  ## uncapped, a long throttle storm grows it without limit and the last
  ## decision of an episode sleeps past the settle.
  MaxExtraSpacingMs* = 3000
  Baselines* = ["follow", "tracker"]

type
  Decision* = object
    move*: Move
    notes*: string
    scripted*: bool     ## decided by the baseline rather than the model
    forced*: bool       ## the baseline move was rejected; lowest legal used
    error*: string      ## recorded on a fallback, rune-truncated

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool
    extraSpacingMs*: int   ## raised by a 429 for the rest of the episode
    rand: Rand

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "trick-taking llm: failed to fetch ANTHROPIC_API_KEY_URI: ",
      error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## `us.anthropic.claude-sonnet-4-6` is deliberately NOT in this list: it
  ## times out on every sidecar call (raid, 2026-08-23), and one throttle
  ## cascades into scripted fallbacks.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "trick-taking llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds,
    rand: initRand(config.seed xor 0x5EED)
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "trick-taking llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "trick-taking llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "trick-taking llm: no LLM credentials; using scripted fallback"

proc noteThrottled*(client: LlmClient) =
  ## A 429 raises the decision spacing for the rest of the episode, up to
  ## MaxExtraSpacingMs.
  client.extraSpacingMs =
    min(client.extraSpacingMs + ThrottleExtraMs, MaxExtraSpacingMs)

proc worstCaseCallSeconds*(client: LlmClient): float =
  ## The longest a single `decide` can take on the model path: one attempt,
  ## one retry, each bounded by the transport timeout. The caller uses it to
  ## refuse a call that would not return before the hard deadline.
  (2 * client.timeoutSeconds).float

# ---- Scripted baselines -----------------------------------------------------
#
# `follow` is the default and the move played whenever an LLM decision
# fails. `tracker` is identical except for its overrides, each computed
# from public information. Both select ONLY from legalMoves.
#
# The bidding thresholds below are the ones the grid sweep in
# `tools/ci/tune_baselines.nim` selected; `docs/tuning.md` records the swept
# grid and the head-to-head result that chose them, and
# `tests/test_tuning.nim` pins the chosen values to that record. They are
# parameters of the bid, not of the play, so a sweep can vary them per seat
# without touching anything else.

type
  BaselineParams* = object
    orderAt*: int      ## euchre: order the up-card at this hand strength
    aloneAt*: int      ## euchre: go alone at this hand strength
    spadesShade*: int  ## spades: bid this many under the winner count
    ohHellDrop*: int   ## oh-hell: an off-suit ace in a suit this short is
                       ## not counted as a winner (0 disables the rule)

proc baselineParams*(baseline: string): BaselineParams =
  ## The tuned configuration. Changing a number here without re-running
  ## tools/ci/tune_baselines.nim fails tests/test_tuning.nim.
  if baseline == "tracker":
    BaselineParams(orderAt: 10, aloneAt: 16, spadesShade: 0, ohHellDrop: 2)
  else:
    BaselineParams(orderAt: 10, aloneAt: 16, spadesShade: 0, ohHellDrop: 0)

proc handSuitCount(hand: seq[int], suit, trump: int, euchre: bool): int =
  for card in hand:
    if effectiveSuit(card, trump, euchre) == suit:
      inc result

proc euchreStrength*(hand: seq[int], suit: int): int =
  ## right bower 5, left bower 4, A 4, K 3, Q 2, 10 or 9 of trump 1, each
  ## off-suit ace 2, each non-trump suit the hand is void in +1.
  let right = rightBowerOf(suit)
  let left = leftBowerOf(suit)
  for card in hand:
    if card == right: result += 5
    elif card == left: result += 4
    elif suitOf(card) == suit:
      case rankOf(card)
      of RankAce: result += 4
      of RankKing: result += 3
      of RankQueen: result += 2
      of RankTen, 7: result += 1
      else: discard
    elif rankOf(card) == RankAce:
      result += 2
  for other in 0 ..< 4:
    if other == suit: continue
    if handSuitCount(hand, other, suit, true) == 0:
      inc result

proc lowestOf(cards: seq[int]): int =
  result = cards[0]
  for card in cards:
    if suitOf(card) < suitOf(result) or
        (suitOf(card) == suitOf(result) and rankOf(card) < rankOf(result)):
      result = card

proc highestOf(cards: seq[int]): int =
  result = cards[0]
  for card in cards:
    if rankOf(card) > rankOf(result) or
        (rankOf(card) == rankOf(result) and suitOf(card) > suitOf(result)):
      result = card

proc currentBest(sim: Sim): int =
  ## The card currently winning the trick, or -1 when the seat is leading.
  if sim.leadingNow() or sim.table.len == 0:
    return -1
  let m = sim.ruleModule
  let trump = m.trumpOf(sim)
  var best = sim.table[0].card
  for entry in sim.table:
    if beats(entry.card, best, sim.ledSuit, trump, m.isEuchre):
      best = entry.card
  best

proc currentBestSlot(sim: Sim): int =
  if sim.leadingNow() or sim.table.len == 0:
    return -1
  let m = sim.ruleModule
  let trump = m.trumpOf(sim)
  var best = 0
  for index in 1 ..< sim.table.len:
    if beats(sim.table[index].card, sim.table[best].card, sim.ledSuit,
        trump, m.isEuchre):
      best = index
  sim.table[best].slot

proc beatsBest(sim: Sim, card, best: int): bool =
  if best < 0:
    return true
  let m = sim.ruleModule
  beats(card, best, sim.ledSuit, m.trumpOf(sim), m.isEuchre)

proc cheapestWinner(sim: Sim, cards: seq[int]): int =
  ## The cheapest card that wins: a card of the led suit before a ruff, and
  ## the lowest rank inside each category.
  let m = sim.ruleModule
  let trump = m.trumpOf(sim)
  proc isTrump(card: int): bool =
    trump >= 0 and effectiveSuit(card, trump, m.isEuchre) == trump
  proc power(card: int): int =
    if m.isEuchre and isTrump(card): euchreTrumpRank(card, trump)
    else: rankOf(card)
  result = cards[0]
  for card in cards:
    if (not isTrump(card) and isTrump(result)) or
        (isTrump(card) == isTrump(result) and power(card) < power(result)):
      result = card

proc shortestSuitCards(hand: seq[int], skip, trump: int, euchre: bool): seq[int] =
  var bestSuit = -1
  var bestCount = 99
  for suit in 0 ..< 4:
    if suit == skip: continue
    let count = handSuitCount(hand, suit, trump, euchre)
    if count > 0 and count < bestCount:
      bestCount = count
      bestSuit = suit
  if bestSuit < 0:
    return hand
  for card in hand:
    if effectiveSuit(card, trump, euchre) == bestSuit:
      result.add(card)

proc pickFrom(legal: seq[int], wanted: int): int =
  ## Wherever a rule points at a card that is not legal, the lowest legal
  ## card is taken instead.
  if wanted >= 0 and wanted in legal:
    return wanted
  lowestOf(legal)

proc isHighestOutstanding(sim: Sim, hand: seq[int], card: int): bool =
  let suit = suitOf(card)
  for rank in rankOf(card) + 1 .. RankAce:
    if sim.module == "euchre" and rank < 7:
      continue
    let higher = makeCard(rank, suit)
    if not sim.played[higher] and higher notin hand:
      return false
  true

proc onMakingSide(sim: Sim, slot: int): bool =
  case sim.module
  of "euchre": sim.maker >= 0 and sim.teamOf(slot) == sim.teamOf(sim.maker)
  of "spades": sim.bids[slot] >= 3
  of "oh-hell": sim.bids[slot] > sim.tricksWon[slot]
  else: false

proc leadChoice(sim: Sim, legal: seq[int], tracker: bool): int =
  let m = sim.ruleModule
  let slot = sim.actorSlot
  let trump = m.trumpOf(sim)
  let euchre = m.isEuchre
  let hand = sim.deal[slot]
  var pool = legal
  if tracker and sim.partnership:
    ## Never lead a suit in which BOTH opponents are known void while the
    ## partner is not.
    let partner = sim.partnerSlot(slot)
    var kept: seq[int]
    for card in pool:
      let suit = effectiveSuit(card, trump, euchre)
      var opponentsVoid = 0
      for other in 0 ..< Seats:
        if other == slot or other == partner: continue
        if sim.voids[other][suit]: inc opponentsVoid
      let partnerVoid = partner >= 0 and sim.voids[partner][suit]
      if opponentsVoid >= 2 and not partnerVoid:
        continue
      kept.add(card)
    if kept.len > 0:
      pool = kept
  if tracker:
    ## Certain winners: lead the highest outstanding card of any suit.
    var winners: seq[int]
    for card in pool:
      if sim.isHighestOutstanding(hand, card):
        winners.add(card)
    if winners.len > 0:
      return highestOf(winners)
  if sim.module == "hearts":
    var safe: seq[int]
    for card in pool:
      if suitOf(card) != SuitHearts and card != QueenOfSpades:
        safe.add(card)
    if tracker and safe.len > 0:
      ## Prefer a suit some other seat is already known void in.
      var flushing: seq[int]
      for card in safe:
        for other in 0 ..< Seats:
          if other != slot and sim.voids[other][suitOf(card)]:
            flushing.add(card)
            break
      if flushing.len > 0:
        return lowestOf(flushing)
    if safe.len > 0:
      return lowestOf(shortestSuitCards(safe, SuitHearts, -1, false))
    return lowestOf(pool)
  if trump >= 0 and onMakingSide(sim, slot) and
      handSuitCount(hand, trump, trump, euchre) >= 3:
    var trumps: seq[int]
    for card in pool:
      if effectiveSuit(card, trump, euchre) == trump:
        trumps.add(card)
    if trumps.len > 0:
      if euchre:
        var best = trumps[0]
        for card in trumps:
          if euchreTrumpRank(card, trump) > euchreTrumpRank(best, trump):
            best = card
        return best
      return highestOf(trumps)
  var aces: seq[int]
  for card in pool:
    if rankOf(card) == RankAce and effectiveSuit(card, trump, euchre) != trump:
      aces.add(card)
  if aces.len > 0:
    return highestOf(aces)
  let short = shortestSuitCards(pool, trump, trump, euchre)
  if short.len > 0:
    return lowestOf(short)
  lowestOf(pool)

proc followChoice(sim: Sim, legal: seq[int], tracker: bool): int =
  let slot = sim.actorSlot
  let m = sim.ruleModule
  let best = sim.currentBest()
  case sim.module
  of "hearts":
    let followedSuit = sim.ledSuit >= 0 and
      handSuitCount(sim.deal[slot], sim.ledSuit, -1, false) > 0
    if not followedSuit:
      if QueenOfSpades in legal:
        return QueenOfSpades
      var hearts: seq[int]
      for card in legal:
        if suitOf(card) == SuitHearts:
          hearts.add(card)
      if hearts.len > 0:
        return highestOf(hearts)
      return highestOf(shortestSuitCards(legal, -1, -1, false))
    var safe: seq[int]
    for card in legal:
      if not sim.beatsBest(card, best):
        safe.add(card)
    if safe.len > 0:
      return highestOf(safe)
    return highestOf(legal)
  of "oh-hell":
    let needs = sim.tricksWon[slot] < sim.bids[slot]
    if needs:
      var winners: seq[int]
      for card in legal:
        if sim.beatsBest(card, best):
          winners.add(card)
      if winners.len > 0:
        return sim.cheapestWinner(winners)
      return lowestOf(legal)
    var safe: seq[int]
    for card in legal:
      if not sim.beatsBest(card, best):
        safe.add(card)
    if safe.len > 0:
      return highestOf(safe)
    return lowestOf(legal)
  else:
    let partner = sim.partnerSlot(slot)
    let holder = sim.currentBestSlot()
    if tracker and sim.module == "spades":
      ## Bag avoidance: once the team has met its contract, play low unless
      ## a nil still needs covering.
      var contract = 0
      var tricks = 0
      var nilAlive = false
      for other in 0 ..< Seats:
        if sim.teamOf(other) != sim.teamOf(slot): continue
        if sim.bids[other] == 0:
          if sim.tricksWon[other] == 0: nilAlive = true
        else:
          contract += sim.bids[other]
          tricks += sim.tricksWon[other]
      if contract > 0 and tricks >= contract and not nilAlive:
        return lowestOf(legal)
    if partner >= 0 and holder == partner:
      return lowestOf(legal)
    var winners: seq[int]
    for card in legal:
      if sim.beatsBest(card, best):
        winners.add(card)
    if winners.len > 0:
      return sim.cheapestWinner(winners)
    lowestOf(legal)

proc scriptedEuchreBid(sim: Sim, legal: seq[Move], params: BaselineParams): Move =
  let slot = sim.actorSlot
  let orderAt = params.orderAt
  let aloneAt = params.aloneAt
  let upSuit = suitOf(sim.upcard)
  proc allowed(action: string, suit: int): bool =
    for move in legal:
      if move.action == action and move.suit == suit:
        return true
    false
  if sim.bidRound == 1:
    var hand = sim.deal[slot]
    var strength = 0
    if slot == sim.dealerSlot:
      hand.add(sim.upcard)
      strength = euchreStrength(hand, upSuit)
    else:
      strength = euchreStrength(hand, upSuit)
      if slot == sim.slotAt((sim.dealer + 2) and 3):
        strength += 2
      else:
        strength -= 2
    if strength >= aloneAt and allowed("alone", upSuit):
      return bidMove("alone", 0, upSuit)
    if strength >= orderAt and allowed("order", upSuit):
      return bidMove("order", 0, upSuit)
    if allowed("pass", -1):
      return bidMove("pass", 0, -1)
    return legal[0]
  var bestSuit = -1
  var bestScore = -1
  for suit in 0 ..< 4:
    if suit == upSuit: continue
    let score = euchreStrength(sim.deal[slot], suit)
    if score > bestScore:
      bestScore = score
      bestSuit = suit
  let stuck = not allowed("pass", -1)
  if bestSuit >= 0 and (stuck or bestScore >= orderAt):
    if bestScore >= aloneAt and allowed("alone", bestSuit):
      return bidMove("alone", 0, bestSuit)
    if allowed("name", bestSuit):
      return bidMove("name", 0, bestSuit)
  if allowed("pass", -1):
    return bidMove("pass", 0, -1)
  legal[0]

proc scriptedSpadesBid(sim: Sim, legal: seq[Move], params: BaselineParams): Move =
  let hand = sim.deal[sim.actorSlot]
  var aces = 0
  var kings = 0
  var spades = 0
  var topSpade = false
  for card in hand:
    if rankOf(card) == RankAce: inc aces
    if suitOf(card) == SuitSpades:
      inc spades
      if rankOf(card) > 7: topSpade = true
  for card in hand:
    if rankOf(card) == RankKing and
        handSuitCount(hand, suitOf(card), SuitSpades, false) >= 2:
      inc kings
  var winners = aces + kings + max(0, spades - 3)
  if spades >= 3 and makeCard(RankQueen, SuitSpades) in hand:
    inc winners
  let canNil = winners == 0 and not topSpade and spades <= 3
  if canNil:
    return bidMove("bid", 0, -1)
  bidMove("bid", max(0, min(13, winners - params.spadesShade)), -1)

proc scriptedOhHellBid(sim: Sim, legal: seq[Move], params: BaselineParams): Move =
  let hand = sim.deal[sim.actorSlot]
  let trump = sim.trump
  var winners = 0
  for card in hand:
    if suitOf(card) == trump and rankOf(card) >= RankQueen:
      inc winners
    elif rankOf(card) == RankAce and suitOf(card) != trump:
      if params.ohHellDrop > 0 and
          handSuitCount(hand, suitOf(card), trump, false) <= params.ohHellDrop:
        discard
      else:
        inc winners
  var wanted = max(0, min(sim.tricksThisHand, winners))
  proc legalBid(value: int): bool =
    for move in legal:
      if move.value == value:
        return true
    false
  if legalBid(wanted):
    return bidMove("bid", wanted, -1)
  ## The hook forbids it: move to the nearest legal value, downward first.
  for delta in 1 .. sim.tricksThisHand + 1:
    if legalBid(wanted - delta):
      return bidMove("bid", wanted - delta, -1)
    if legalBid(wanted + delta):
      return bidMove("bid", wanted + delta, -1)
  legal[0]

proc scriptedHeartsPass(sim: Sim): Move =
  let hand = sim.deal[sim.actorSlot]
  let spades = handSuitCount(hand, SuitSpades, -1, false)
  var chosen: seq[int]
  proc take(card: int) =
    if chosen.len < 3 and card in hand and card notin chosen:
      chosen.add(card)
  if spades < 4:
    take(QueenOfSpades)
    take(makeCard(RankAce, SuitSpades))
    take(makeCard(RankKing, SuitSpades))
  var hearts: seq[int]
  for card in hand:
    if suitOf(card) == SuitHearts and card notin chosen:
      hearts.add(card)
  while chosen.len < 3 and hearts.len > 0:
    let pick = highestOf(hearts)
    take(pick)
    hearts.delete(hearts.find(pick))
  if chosen.len < 3:
    var rest: seq[int]
    for card in hand:
      if card notin chosen:
        rest.add(card)
    var pool = shortestSuitCards(rest, SuitHearts, -1, false)
    while chosen.len < 3 and pool.len > 0:
      let pick = highestOf(pool)
      take(pick)
      pool.delete(pool.find(pick))
    while chosen.len < 3:
      for card in hand:
        if card notin chosen:
          chosen.add(card)
          break
  passMove(chosen)

proc scriptedEuchreDiscard(sim: Sim, legal: seq[Move]): Move =
  let hand = sim.deal[sim.actorSlot]
  let trump = sim.trump
  var bestSuit = -1
  var bestCount = 99
  for suit in 0 ..< 4:
    if suit == trump: continue
    let count = handSuitCount(hand, suit, trump, true)
    if count > 0 and count < bestCount:
      bestCount = count
      bestSuit = suit
  var pool: seq[int]
  for card in hand:
    if bestSuit >= 0 and euchreEffectiveSuit(card, trump) == bestSuit:
      pool.add(card)
  if pool.len == 0:
    pool = hand
  discardMove(lowestOf(pool))

proc scriptedMove*(sim: Sim, baseline: string,
    params: BaselineParams): Move =
  ## Always legal, in every module and every phase. `params` is the tuned
  ## bidding configuration; the shipped one is `baselineParams(baseline)`.
  let tracker = baseline == "tracker"
  let legal = legalMoves(sim)
  if legal.len == 0:
    raise newException(TricksError, "no legal option")
  case sim.phase
  of phPlay:
    var cards: seq[int]
    for move in legal:
      cards.add(move.card)
    let wanted =
      if sim.leadingNow(): leadChoice(sim, cards, tracker)
      else: followChoice(sim, cards, tracker)
    playMove(pickFrom(cards, wanted))
  of phDiscard:
    scriptedEuchreDiscard(sim, legal)
  of phPass:
    scriptedHeartsPass(sim)
  of phBid:
    case sim.module
    of "euchre": scriptedEuchreBid(sim, legal, params)
    of "spades": scriptedSpadesBid(sim, legal, params)
    of "oh-hell": scriptedOhHellBid(sim, legal, params)
    else: legal[0]
  else:
    raise newException(TricksError, "no decision is due")

proc scriptedMove*(sim: Sim, baseline: string): Move =
  ## The shipped configuration.
  scriptedMove(sim, baseline, baselineParams(baseline))

# ---- Prompt building --------------------------------------------------------

proc standingsText(sim: Sim): string =
  var lines: seq[string]
  for pos in 0 ..< Seats:
    let slot = sim.slotAt(pos)
    var line = "  " & sim.names[slot] & " (seat " & $pos & "): " &
      formatFloat(sim.points[slot], ffDecimal, 1) & " points"
    if sim.bids[slot] >= 0:
      line.add(", bid " & $sim.bids[slot] & " made " & $sim.tricksWon[slot])
    else:
      line.add(", " & $sim.tricksWon[slot] & " tricks this hand")
    if sim.module == "hearts":
      line.add(", " & $sim.penalty[slot] & " penalty this hand")
    lines.add(line)
  lines.join("\n")

proc seatingText(sim: Sim, slot: int): string =
  var order: seq[string]
  for pos in 0 ..< Seats:
    order.add(sim.names[sim.slotAt(pos)])
  result = "Seating clockwise: " & order.join(" -> ") & " -> " &
    order[0] & ".\n"
  result.add("You are " & sim.names[slot] & " at table position " &
    $sim.posOf[slot] & ". The dealer is " & sim.names[sim.dealerSlot] & ".\n")
  if sim.partnership:
    let partner = sim.partnerSlot(slot)
    result.add("Your partner is " & sim.names[partner] & ". ")
    if sim.sittingOut == partner:
      result.add("Your partner is SITTING OUT this hand (alone).\n")
    elif sim.sittingOut == slot:
      result.add("You are SITTING OUT this hand.\n")
    else:
      result.add("\n")

proc handRecordText(sim: Sim, slot: int): string =
  var bidLines: seq[string]
  var trickLines: seq[string]
  var current: seq[string]
  var pending: seq[string]
  for event in sim.events:
    if event.hand != sim.hand:
      continue
    case event.kind
    of evBid:
      var line = "  " & sim.names[event.slot] & ": "
      case event.action
      of "bid": line.add("bids " & $event.value)
      of "pass": line.add("passes")
      of "order": line.add("orders it up (" & suitName(event.suit) & ")")
      of "name": line.add("names " & suitName(event.suit))
      of "alone": line.add("goes ALONE in " & suitName(event.suit))
      else: line.add(event.action)
      bidLines.add(line)
    of evPlay:
      let text = sim.names[event.slot] & " " & cardCode(event.card)
      if event.trick < sim.currentTrick():
        pending.add(text)
      else:
        current.add(text)
    of evTrick:
      trickLines.add("  trick " & $(event.trick + 1) & ": " &
        pending.join(", ") & " -- " & sim.names[event.slot] & " takes it" &
        (if event.value > 0: " (" & $event.value & " penalty)" else: ""))
      pending = @[]
    else:
      discard
  result = "BIDDING THIS HAND:\n" &
    (if bidLines.len > 0: bidLines.join("\n") else: "  (none)") & "\n\n"
  result.add("COMPLETED TRICKS THIS HAND:\n" &
    (if trickLines.len > 0: trickLines.join("\n") else: "  (none yet)") &
    "\n\n")
  result.add("THE CURRENT TRICK: " &
    (if current.len > 0: current.join(", ") else: "(you are on lead)") &
    "\n\n")
  var voidLines: seq[string]
  for other in 0 ..< Seats:
    var suits: seq[string]
    for suit in 0 ..< 4:
      if sim.voids[other][suit]:
        suits.add(suitName(suit))
    if suits.len > 0:
      voidLines.add("  " & sim.names[other] & " is void in " &
        suits.join(", "))
  result.add("KNOWN VOIDS (from failures to follow -- public):\n" &
    (if voidLines.len > 0: voidLines.join("\n") else: "  (none seen)") & "\n\n")

proc trumpText(sim: Sim): string =
  case sim.module
  of "euchre":
    if sim.trump >= 0:
      result = "TRUMP: " & suitName(sim.trump) & " (right bower " &
        cardCode(rightBowerOf(sim.trump)) & ", left bower " &
        cardCode(leftBowerOf(sim.trump)) & " -- the left bower is a TRUMP, " &
        "not a card of its printed suit)."
      if sim.alone and sim.maker >= 0:
        result.add(" " & sim.names[sim.maker] & " is playing ALONE.")
    else:
      result = "The up-card is " & cardCode(sim.upcard) & " (" &
        suitName(suitOf(sim.upcard)) & "). Trump is not settled yet."
  of "spades":
    result = "TRUMP: spades. Spades are " &
      (if sim.broken: "BROKEN (a spade may be led)."
       else: "NOT broken (a spade may not be led yet).")
  of "hearts":
    result = "There is NO TRUMP. Hearts are " &
      (if sim.broken: "BROKEN (a heart may be led)."
       else: "NOT broken (a heart may not be led yet).") &
      " The pass this hand is: " & sim.passDir & "."
  else:
    result = "TRUMP: " & suitName(sim.trump) & " (turn-up " &
      cardCode(sim.turnup) & ", out of play)."

proc legalCardText(sim: Sim): string =
  var parts: seq[string]
  var index = 1
  for card in legalCards(sim):
    parts.add($index & ") " & cardCode(card))
    inc index
  parts.join("  ")

proc optionInstruction(sim: Sim): string =
  case sim.phase
  of phPlay:
    "YOUR LEGAL CARDS (pick exactly one): " & legalCardText(sim) &
      "\n\nReply with ONLY {\"card\": \"10H\", \"notes\": \"...\"} -- one " &
      "card code from the legal list above (write ten as 10, never T); " &
      "notes at most " & $MaxNotesLen & " characters."
  of phDiscard:
    "You picked up the up-card and must now discard ONE card face down. " &
      "Your hand: " & handCodes(sim.deal[sim.actorSlot]) &
      "\n\nReply with ONLY {\"card\": \"9C\", \"notes\": \"...\"}."
  of phPass:
    "Choose EXACTLY 3 distinct cards from your hand to pass " & sim.passDir &
      ".\n\nReply with ONLY {\"cards\": [\"QS\", \"2H\", \"AD\"], " &
      "\"notes\": \"...\"}."
  of phBid:
    if sim.module == "euchre":
      if sim.bidRound == 1:
        "The up-card is " & cardCode(sim.upcard) & ". You may: " &
          "\"pass\"; \"order\" (make " & suitName(suitOf(sim.upcard)) &
          " trump); or \"alone\" (make it trump and play without your " &
          "partner).\n\nReply with ONLY {\"action\": \"order\", " &
          "\"notes\": \"...\"}."
      else:
        var suits: seq[string]
        for move in legalMoves(sim):
          if move.action == "name":
            suits.add(suitName(move.suit))
        (if sim.stuck:
            "Everyone has passed and STICK THE DEALER is on: you are the " &
              "dealer and you MUST name a suit. "
           else: "") &
          "You may " & (if sim.stuck: "" else: "\"pass\", or ") &
          "\"name\" a suit, or go \"alone\" in a suit. Legal suits: " &
          suits.join(", ") & ".\n\nReply with ONLY {\"action\": \"name\", " &
          "\"suit\": \"hearts\", \"notes\": \"...\"}."
    elif sim.module == "spades":
      "Bid a whole number of tricks from 0 to 13 (0 is NIL).\n\n" &
        "Reply with ONLY {\"bid\": 4, \"notes\": \"...\"}."
    else:
      var allowed: seq[string]
      for move in legalMoves(sim):
        allowed.add($move.value)
      "Bid exactly how many of the " & $sim.tricksThisHand &
        " tricks you will take. Legal bids: " & allowed.join(", ") &
        " (the hook forbids the dealer the balanced number).\n\n" &
        "Reply with ONLY {\"bid\": 2, \"notes\": \"...\"}."
  else:
    ""

proc systemPrompt*(sim: Sim, slot: int): string =
  let m = sim.ruleModule
  "You are " & sim.names[slot] & ", a cog at a four-seat card table " &
    "playing " & m.displayName & ".\n\n" & m.rulesText() & """

- You never see another cog's cards. Everything you know about them, you
  inferred from what they bid and what they played.
- THERE IS NO TALKING AT THIS TABLE. No chat, no signals, no side deals. In
  the partnership games the ONLY thing you can tell your partner is which
  card you play and what you bid - so bid and lead as if your partner is
  reading you, because they are.
- Your notes are private to you and are handed back to you before every
  decision. Keep your card count, the voids you have spotted, and your read
  on each cog in them.
- Pick exactly one option from the legal list you are given. An illegal
  answer is replaced by a house baseline move, which is never what you want.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis,
no explanation, no markdown fences, no text before or after the object. Your
reply must begin with the character { and end with }."""

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always pick a legal option):\n" &
    truncateRunes(prompt, MaxPromptLen) & "\n\n"

proc userPrompt*(sim: Sim, prompt: string, retry = false): string =
  let slot = sim.actorSlot
  result.add("HAND " & $(sim.hand + 1) & " of " & $sim.config.hands &
    ", trick " & $(sim.currentTrick() + 1) & " of " & $sim.tricksThisHand &
    ".\n\n")
  result.add("STANDINGS (module points, higher is better" &
    (if sim.module == "hearts": " -- fewer penalty points is better)" else: ")") &
    ":\n" & standingsText(sim) & "\n\n")
  result.add(seatingText(sim, slot) & "\n")
  result.add(handRecordText(sim, slot))
  result.add("YOUR HAND: " & handCodes(sim.deal[slot]) & "\n\n")
  result.add(trumpText(sim) & "\n\n")
  result.add("YOUR NOTES:\n" &
    (if sim.notes[slot].len > 0: sim.notes[slot] else: "(none yet)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add(optionInstruction(sim))
  if retry:
    result.add("\nYour previous reply was invalid. Respond with ONLY the " &
      "requested JSON object, choosing one option from the legal list.")
    if sim.phase == phPlay:
      result.add("\nLegal cards: " & legalCardText(sim))

# ---- Reply parsing ----------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## The first {...} object, tolerating fences and trailing prose.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(TricksError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc indexOrCard(sim: Sim, text: string, legal: seq[int]): int =
  ## A bare integer 1..k is a 1-based index into the printed legal list.
  let trimmed = text.strip()
  if trimmed.len > 0 and trimmed.len <= 2 and
      trimmed.allCharsInSet({'0' .. '9'}):
    let index = parseInt(trimmed)
    if index >= 1 and index <= legal.len:
      return legal[index - 1]
  parseCard(truncateRunes(trimmed, 24))

proc parseDecision*(sim: Sim, payload: JsonNode): Decision =
  result.notes = cleanNotes(payload{"notes"}.getStr())
  case sim.phase
  of phPlay, phDiscard:
    let legal = legalCards(sim)
    let node = payload{"card"}
    if node.isNil:
      raise newException(TricksError, "no card in the reply")
    var card = -1
    if node.kind == JInt:
      let index = node.getInt()
      if index >= 1 and index <= legal.len:
        card = legal[index - 1]
      else:
        raise newException(TricksError, "card index out of range")
    else:
      card = indexOrCard(sim, node.getStr(), legal)
    result.move =
      (if sim.phase == phPlay: playMove(card) else: discardMove(card))
  of phPass:
    let node = payload{"cards"}
    if node.isNil or node.kind != JArray:
      raise newException(TricksError, "no cards array in the reply")
    if node.len != 3:
      raise newException(TricksError, "a hearts pass is exactly three cards")
    var cards: seq[int]
    for entry in node:
      cards.add(parseCard(truncateRunes(entry.getStr(), 24)))
    result.move = passMove(cards)
  of phBid:
    if sim.module == "euchre":
      var action = truncateRunes(
        payload{"action"}.getStr().strip(), MaxAliasLen).toLowerAscii()
      if action.len == 0 and payload.hasKey("bid"):
        action = "pass"
      var suit = -1
      if payload.hasKey("suit"):
        suit = parseSuit(truncateRunes(payload{"suit"}.getStr(), 8))
      case action
      of "pass": result.move = bidMove("pass", 0, -1)
      of "order", "order it up", "orderup":
        result.move = bidMove("order", 0, suitOf(sim.upcard))
      of "alone", "go alone", "loner":
        result.move = bidMove("alone", 0,
          (if sim.bidRound == 1: suitOf(sim.upcard) else: suit))
      of "name", "call", "make":
        result.move = bidMove("name", 0, suit)
      else:
        raise newException(TricksError, "unknown euchre action: " & action)
    else:
      let node = payload{"bid"}
      if node.isNil:
        raise newException(TricksError, "no bid in the reply")
      var value = -1
      if node.kind == JInt:
        value = node.getInt()
      elif node.kind == JString:
        try:
          value = parseInt(node.getStr().strip())
        except ValueError:
          raise newException(TricksError, "bid is not a number")
      else:
        raise newException(TricksError, "bid is not a number")
      let top = (if sim.module == "spades": 13 else: sim.tricksThisHand)
      if value < 0 or value > top:
        raise newException(TricksError, "bid out of range: " & $value)
      result.move = bidMove("bid", value, -1)
  else:
    raise newException(TricksError, "no decision is due")

# ---- Transport --------------------------------------------------------------

proc completeText(client: LlmClient, system, user: string): string =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  var url: string
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Haiku 4.5 rejects the whole request with a 400 when an effort
    ## setting is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    url = AnthropicUrl
  let response = client.curl.post(url, headers, $body, client.timeoutSeconds)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(TricksError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(TricksError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    client.noteThrottled()
    discard client.tryNextBedrockModel("throttled")
    raise newException(TricksError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(TricksError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(TricksError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(TricksError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc baselineDecision*(sim: Sim, baseline: string, why = ""): Decision =
  ## The seat's scripted baseline move; if the engine somehow rejects it,
  ## the lowest legal option is forced.
  result.scripted = true
  result.error = truncateRunes(why, MaxErrorLen)
  try:
    let move = scriptedMove(sim, baseline)
    var probe = sim
    probe.applyMove(move, "", true)
    result.move = move
  except CatchableError:
    result.forced = true
    result.move = lowestLegal(sim)

proc decide*(
  client: LlmClient,
  sim: Sim,
  prompt: string,
  scripted: bool,
  baseline: string
): Decision =
  ## One decision for one seat. Never raises: any failure falls back to the
  ## scripted baseline, and a rejected baseline falls back to the lowest
  ## legal option, so the episode always advances.
  if scripted or client.disabled:
    return baselineDecision(sim, baseline)
  let slot = sim.actorSlot
  let system = systemPrompt(sim, slot)
  var lastError = ""
  for attempt in 0 .. 1:
    let user = userPrompt(sim, prompt, retry = attempt > 0)
    try:
      let payload = extractJsonObject(client.completeText(system, user))
      var decision = parseDecision(sim, payload)
      ## Reject an illegal reply here so the retry carries the hint.
      var probe = sim
      probe.applyMove(decision.move, decision.notes, false)
      decision.scripted = false
      return decision
    except CatchableError as error:
      lastError = error.msg
      echo "trick-taking llm: slot ", slot, " attempt ", attempt,
        " failed: ", error.msg
      if client.disabled:
        break
      if "429" in error.msg:
        ## No retry on a throttle: take the scripted move immediately.
        break
  echo "trick-taking llm: slot ", slot, " falling back to a scripted decision"
  baselineDecision(sim, baseline, lastError)
