## The pluggable rule module.
##
## One trick-taking engine (`sim.nim`) deals, enforces follow-suit, decides
## who takes the trick and rotates the deal; a `RuleModule` supplies the
## deck, the bidding, the trump rule, the hand scoring and the "what your
## partner just told you" annotation.
##
## Adding a fifth game is one new file, one registry line in `sim.nim`, and
## one manifest variant.
##
## Two notes on the shape, both deliberate:
##   * `legalMoves` / `applyMove` here cover the module's own phases (bidding,
##     the hearts pass, the euchre discard). Card PLAY is engine-wide and
##     lives in `sim.nim`, which consults `trumpOf` and `restricted`; that is
##     what keeps "the legal set is computed by the same predicate applyPlay
##     validates with" true across every module.
##   * `restricted` subsumes the note's `leadRestricted` and hearts' trick-0
##     rule (no heart and not the queen of spades on the first trick unless
##     the seat holds nothing else), which is a restriction on a FOLLOW as
##     well as on a lead -- hence the `leading` flag.

import types

type
  RuleModule* = object
    id*: string
    displayName*: string
    partnership*: bool          ## true => positions 0&2 vs 1&3
    audited*: bool              ## individual modules only
    deck*: proc(): seq[int] {.nimcall.}
    cardsPerHand*: proc(cfg: GameConfig, hand: int): int {.nimcall.}
    dealPackets*: proc(cfg: GameConfig, hand: int): seq[int] {.nimcall.}
      ## Cards per position per pass, clockwise from the left of the dealer.
      ## Empty means "one at a time"; euchre uses 3,2,3,2 then 2,3,2,3.
    setupHand*: proc(sim: var Sim, rest: var seq[int]) {.nimcall.}
      ## Kitty / up-card / turn-up off the top of `rest`, then the first phase.
    legalMoves*: proc(sim: Sim): seq[Move] {.nimcall.}
    applyMove*: proc(sim: var Sim, move: Move, notes: string,
      scripted: bool) {.nimcall.}
    trumpOf*: proc(sim: Sim): int {.nimcall.}
    restricted*: proc(sim: Sim, card: int, leading: bool): bool {.nimcall.}
    breaks*: proc(sim: Sim, card: int, leading, followed: bool): bool
      {.nimcall.}
      ## Did this card break the suit that may not be led yet?
    trickPoints*: proc(sim: Sim, cards: seq[int]): int {.nimcall.}
      ## Penalty points the completed trick carries (hearts only).
    scoreHand*: proc(sim: var Sim): array[Seats, float] {.nimcall.}
    swingCap*: proc(cfg: GameConfig, hand: int): float {.nimcall.}
    tell*: proc(sim: Sim, ev: GameEvent): string {.nimcall.}
    verdict*: proc(sim: Sim): string {.nimcall.}
      ## One phrase for the hand just scored: "march", "euchred", "nil made".
    rulesText*: proc(): string {.nimcall.}
    worstCaseDecisions*: proc(cfg: GameConfig, hand: int): int {.nimcall.}

proc isEuchre*(m: RuleModule): bool = m.id == "euchre"

proc teamTricks*(sim: Sim, team: int): int =
  for slot in 0 ..< Seats:
    if sim.teamOf(slot) == team:
      result += sim.tricksWon[slot]

proc bidMove*(action: string, value = 0, suit = -1): Move =
  Move(kind: mkBid, action: action, value: value, suit: suit)

proc playMove*(card: int): Move =
  Move(kind: mkPlay, action: "play", card: card, suit: -1)

proc discardMove*(card: int): Move =
  Move(kind: mkDiscard, action: "discard", card: card, suit: -1)

proc passMove*(cards: seq[int]): Move =
  Move(kind: mkPass, action: "pass", cards: cards, suit: -1)
