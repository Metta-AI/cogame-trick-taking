## Shared types for the trick-taking engine: the episode config, the event
## vocabulary, the `Sim` state object, and the one rune-safe truncation
## helper every recorded string goes through.
##
## Nothing here knows about a specific rule module. The module records live
## in `rules.nim`; the engine that drives them lives in `sim.nim`.

import std/[json, unicode]

const
  Seats* = 4
    ## Every shipped variant seats exactly four cogs.
  Teams* = 2
  GameVersion* = 1
  ## Caps. Every string that can reach the replay is truncated on RUNE
  ## boundaries with `truncateRunes`; a byte-boundary cut is how a replay
  ## renders in a browser and still fails a strict UTF-8 parser.
  MaxNotesLen* = 400
  MaxPromptLen* = 4000
  MaxAliasLen* = 16
  MaxTellLen* = 120
  MaxErrorLen* = 200
  ## An episode's whole model-call allowance. Trick-taking is sequential:
  ## exactly one seat is on decision, so the budget is per decision.
  EpisodeDecisionBudget* = 240
  MinHands* = 2
  ## Wall-clock guards, as fractions of the episode timeout.
  SoftDeadlineFraction* = 0.55
  HardDeadlineFraction* = 0.56
  ## Anonymous table aliases. No policy name ever enters a prompt.
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]
  DefaultDealSchedule* = [1, 2, 3, 4, 5, 6, 5, 4, 3, 2, 1]

type
  TricksError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    module*: string           ## "euchre" | "spades" | "hearts" | "oh-hell"
    hands*: int
    dealSchedule*: seq[int]   ## oh-hell only
    episodeTimeoutSeconds*: int
    sampled*: bool            ## true once the budget cap has been applied
    turnDelayMs*: int         ## slept after each COMPLETED trick
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  EventKind* = enum
    evStart = "start"
    evHand = "hand"
    evPass = "pass"
    evBid = "bid"
    evTrump = "trump"
    evDiscard = "discard"
    evPlay = "play"
    evTrick = "trick"
    evBroken = "broken"
    evHandEnd = "handEnd"
    evHandVoid = "handVoid"
    evAudit = "audit"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    hand*: int              ## -1 before the first hand
    slot*: int              ## -1 for table events
    other*: int             ## pass: the receiving slot
    card*: int              ## play / discard; -1 otherwise
    cards*: seq[int]        ## pass: the three; trick: cards in play order
    deals*: seq[seq[int]]   ## hand: every slot's dealt cards
    kitty*: seq[int]
    upcard*: int
    turnup*: int
    dealer*: int            ## hand: the dealer's table POSITION
    count*: int             ## hand: tricks this hand
    passDir*: string
    action*: string         ## pass|order|alone|name|bid
    value*: int             ## integer bid; trick: penalty points taken
    suit*: int              ## -1 when none
    alone*: bool
    scripted*: bool
    trick*: int
    trickPos*: int
    legal*: seq[int]        ## play: the acting seat's legal set
    points*: seq[float]     ## handEnd: module-native points per slot
    teamPoints*: seq[float] ## handEnd: per team, empty in individual modules
    tricks*: seq[int]
    net*: seq[float]
    tell*: string
    text*: string
    data*: JsonNode

  Phase* = enum
    phDeal = "deal"         ## between hands: the next hand needs dealing
    phBid = "bid"           ## any bidding / trump-making decision
    phPass = "pass"         ## hearts: choosing three cards
    phDiscard = "discard"   ## euchre: the dealer's discard
    phPlay = "play"
    phDone = "done"

  MoveKind* = enum
    mkNone = "none"
    mkBid = "bid"
    mkPass = "pass"
    mkDiscard = "discard"
    mkPlay = "play"

  Move* = object
    kind*: MoveKind
    action*: string   ## bid: pass|order|alone|name|bid
    value*: int       ## bid: the integer bid
    suit*: int        ## bid: named suit, -1 when none
    card*: int        ## play / discard
    cards*: seq[int]  ## hearts pass: exactly three

  TablePlay* = object
    slot*: int
    card*: int

  Sim* = object
    config*: GameConfig
    module*: string
    displayName*: string
    partnership*: bool
    names*: seq[string]              ## anonymous alias per SLOT
    seatOrder*: array[Seats, int]    ## table position -> policy slot
    posOf*: array[Seats, int]        ## policy slot -> table position

    hand*: int                       ## hand in progress; -1 before the first
    dealer*: int                     ## table position
    deal*: array[Seats, seq[int]]    ## remaining cards, by slot
    dealt*: array[Seats, seq[int]]   ## cards as dealt, by slot
    kitty*: seq[int]
    upcard*: int
    upcardLive*: bool                ## euchre: still face up (round 1)
    turnup*: int
    discarded*: int
    trump*: int                      ## -1 = no trump
    maker*: int                      ## slot, -1 = none
    alone*: bool
    sittingOut*: int                 ## slot, -1 = none
    broken*: bool
    passDir*: string
    passSel*: array[Seats, seq[int]]

    phase*: Phase
    bidStep*: int
    bidRound*: int
    stuck*: bool                     ## euchre: the dealer was stuck
    bids*: array[Seats, int]         ## -1 = no bid this hand
    bidActions*: array[Seats, string]
    actorPos*: int
    leaderPos*: int
    trick*: int
    tricksThisHand*: int
    trickComplete*: bool
    trickWinner*: int                ## slot of the last trick's winner
    table*: seq[TablePlay]
    ledSuit*: int
    tricksWon*: array[Seats, int]    ## this hand
    penalty*: array[Seats, int]      ## hearts: this hand
    voids*: array[Seats, array[4, bool]]
    played*: array[52, bool]         ## cards played this hand

    points*: array[Seats, float]     ## cumulative, module-native
    net*: array[Seats, float]        ## cumulative, zero-sum
    tricksTotal*: array[Seats, int]
    bidsTotal*: array[Seats, int]
    bidsMade*: array[Seats, int]
    penalties*: array[Seats, int]
    moons*: array[Seats, int]
    marches*: array[Seats, int]
    euchres*: array[Seats, int]
    nilsMade*: array[Seats, int]
    nilsFailed*: array[Seats, int]
    bags*: array[Seats, int]
    decisions*: array[Seats, int]
    fallbacks*: array[Seats, int]
    forcedMoves*: array[Seats, int]

    notes*: array[Seats, string]
    tell*: string                    ## the latest annotation, spectator-side
    handsPlayed*: int
    handsScored*: int
    norm*: float
    swingCaps*: seq[float]
    done*: bool
    handDone*: bool
    reason*: string                  ## complete | deadline | budget
    events*: seq[GameEvent]

# ---- Rune-safe truncation ---------------------------------------------------

proc truncateRunes*(text: string, limit: int): string =
  ## The one place a recorded string is shortened. Cuts on a RUNE boundary
  ## and marks the cut, so the replay always parses under a strict UTF-8
  ## decoder.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit - 1) & "\u2026"

proc cleanNotes*(text: string): string =
  truncateRunes(text.strip(), MaxNotesLen)

# ---- Config -----------------------------------------------------------------

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    module: "euchre",
    hands: 8,
    dealSchedule: @[],
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 250,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 20
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(TricksError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("module"):
    config.module = node["module"].getStr()
  if node.hasKey("hands"):
    config.hands = node["hands"].getInt()
  if node.hasKey("dealSchedule"):
    config.dealSchedule = @[]
    for entry in node["dealSchedule"]:
      config.dealSchedule.add(entry.getInt())
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.hands < MinHands:
    raise newException(TricksError, "hands must be at least " & $MinHands)

# ---- Small state helpers ----------------------------------------------------

proc slotAt*(sim: Sim, pos: int): int =
  sim.seatOrder[pos and 3]

proc actorSlot*(sim: Sim): int =
  sim.slotAt(sim.actorPos)

proc leaderSlot*(sim: Sim): int =
  sim.slotAt(sim.leaderPos)

proc dealerSlot*(sim: Sim): int =
  sim.slotAt(sim.dealer)

proc teamOfPos*(pos: int): int =
  pos and 1

proc teamOf*(sim: Sim, slot: int): int =
  sim.posOf[slot] and 1

proc partnerSlot*(sim: Sim, slot: int): int =
  ## The slot sitting opposite, or -1 in an individual module.
  if not sim.partnership:
    -1
  else:
    sim.slotAt((sim.posOf[slot] + 2) and 3)

proc nextPos*(sim: Sim, pos: int): int =
  ## The next position clockwise that is actually playing.
  var p = (pos + 1) and 3
  for _ in 0 ..< Seats:
    if sim.sittingOut < 0 or sim.slotAt(p) != sim.sittingOut:
      return p
    p = (p + 1) and 3
  p

proc currentTrick*(sim: Sim): int =
  ## The trick the NEXT card belongs to. `sim.trick` still names the trick
  ## whose four cards are on the table until the next play sweeps them.
  sim.trick + (if sim.trickComplete: 1 else: 0)

proc seatsInPlay*(sim: Sim): int =
  if sim.sittingOut >= 0: Seats - 1 else: Seats

proc blankEvent*(kind: EventKind): GameEvent =
  GameEvent(kind: kind, hand: -1, slot: -1, other: -1, card: -1,
    upcard: -1, turnup: -1, dealer: -1, count: 0, value: 0, suit: -1,
    trick: -1, trickPos: -1)

proc addEvent*(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc beginPlay*(sim: var Sim, leaderPos: int) =
  ## Opens trick 0 of the hand from `leaderPos`.
  sim.phase = phPlay
  sim.trick = 0
  sim.leaderPos = leaderPos
  sim.actorPos = leaderPos
  sim.table = @[]
  sim.ledSuit = -1
  sim.trickComplete = false
