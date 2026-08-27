## Card encoding, rendering and comparison for every rule module.
##
## `card in 0..51`, `rank = card div 4` (0 = deuce ... 8 = ten, 9 = J,
## 10 = Q, 11 = K, 12 = A), `suit = card mod 4`
## (0 = clubs, 1 = diamonds, 2 = hearts, 3 = spades).
##
## Rank ten is written `10`, NEVER `T`, in prompts and on the canvas.
## `T` is accepted on input because models write it.

import std/[strutils], types

const
  SuitLetters* = ["C", "D", "H", "S"]
  SuitNames* = ["clubs", "diamonds", "hearts", "spades"]
  SuitGlyphs* = ["\u2663", "\u2666", "\u2665", "\u2660"]
  RankCodes* = ["2", "3", "4", "5", "6", "7", "8", "9", "10",
    "J", "Q", "K", "A"]
  RankNames* = ["two", "three", "four", "five", "six", "seven", "eight",
    "nine", "ten", "jack", "queen", "king", "ace"]
  RankTen* = 8
  RankJack* = 9
  RankQueen* = 10
  RankKing* = 11
  RankAce* = 12
  SuitClubs* = 0
  SuitDiamonds* = 1
  SuitHearts* = 2
  SuitSpades* = 3
  QueenOfSpades* = RankQueen * 4 + SuitSpades
  TwoOfClubs* = 0 * 4 + SuitClubs
  ## Word forms, longest-first where one could contain another.
  RankWords = [
    ("ACE", RankAce), ("KING", RankKing), ("QUEEN", RankQueen),
    ("JACK", RankJack), ("TEN", RankTen), ("NINE", 7), ("EIGHT", 6),
    ("SEVEN", 5), ("SIX", 4), ("FIVE", 3), ("FOUR", 2), ("THREE", 1),
    ("TWO", 0), ("DEUCE", 0)
  ]
  SuitWords = [
    ("CLUB", SuitClubs), ("DIAMOND", SuitDiamonds), ("HEART", SuitHearts),
    ("SPADE", SuitSpades)
  ]

proc suitOf*(card: int): int = card mod 4
proc rankOf*(card: int): int = card div 4
proc makeCard*(rank, suit: int): int = rank * 4 + suit

proc cardCode*(card: int): string =
  ## Prompt form: `2C`, `9D`, `10H`, `JS`, `AS`. Ten is `10`.
  if card < 0 or card > 51:
    raise newException(TricksError, "bad card: " & $card)
  RankCodes[rankOf(card)] & SuitLetters[suitOf(card)]

proc cardGlyph*(card: int): string =
  ## Viewer form: `10`+heart, `J`+spade.
  if card < 0 or card > 51:
    return "??"
  RankCodes[rankOf(card)] & SuitGlyphs[suitOf(card)]

proc cardName*(card: int): string =
  RankNames[rankOf(card)] & " of " & SuitNames[suitOf(card)]

proc fullDeck*(): seq[int] =
  for card in 0 ..< 52:
    result.add(card)

proc euchreDeck*(): seq[int] =
  ## 9, 10, J, Q, K, A of every suit: the 24-card subset `rank >= 7`.
  for card in 0 ..< 52:
    if rankOf(card) >= 7:
      result.add(card)

proc sameColourOther*(suit: int): int =
  ## Clubs <-> spades, diamonds <-> hearts.
  case suit
  of SuitClubs: SuitSpades
  of SuitSpades: SuitClubs
  of SuitDiamonds: SuitHearts
  else: SuitDiamonds

proc rightBowerOf*(trump: int): int = makeCard(RankJack, trump)
proc leftBowerOf*(trump: int): int = makeCard(RankJack, sameColourOther(trump))

proc euchreEffectiveSuit*(card, trump: int): int =
  ## The left bower is a TRUMP and is NOT a card of its printed suit --
  ## for leading, for following and for winning.
  if trump >= 0 and card == leftBowerOf(trump): trump
  else: suitOf(card)

proc effectiveSuit*(card, trump: int, euchre: bool): int =
  if euchre: euchreEffectiveSuit(card, trump) else: suitOf(card)

proc euchreTrumpRank*(card, trump: int): int =
  ## 9 < 10 < Q < K < A < left bower < right bower.
  if card == rightBowerOf(trump): 100
  elif card == leftBowerOf(trump): 99
  else: rankOf(card)

proc beats*(a, b, led, trump: int, euchre: bool): bool =
  ## Does `a` beat the current best `b`, with `led` led and `trump` trump
  ## (-1 = no trump)? Rank order is 2 < ... < 10 < J < Q < K < A, except
  ## that euchre's trump suit ranks 9 < 10 < Q < K < A < left < right.
  let ea = effectiveSuit(a, trump, euchre)
  let eb = effectiveSuit(b, trump, euchre)
  if trump >= 0:
    if ea == trump and eb != trump:
      return true
    if ea != trump and eb == trump:
      return false
    if ea == trump and eb == trump:
      return (if euchre: euchreTrumpRank(a, trump) > euchreTrumpRank(b, trump)
              else: rankOf(a) > rankOf(b))
  if ea != led:
    return false
  if eb != led:
    return true
  rankOf(a) > rankOf(b)

proc heartsPenalty*(card: int): int =
  if card == QueenOfSpades: 13
  elif suitOf(card) == SuitHearts: 1
  else: 0

proc suitLetter*(suit: int): string =
  if suit < 0 or suit > 3: "-" else: SuitLetters[suit]

proc suitName*(suit: int): string =
  if suit < 0 or suit > 3: "none" else: SuitNames[suit]

proc suitGlyph*(suit: int): string =
  if suit < 0 or suit > 3: "-" else: SuitGlyphs[suit]

proc parseSuit*(text: string): int =
  ## `C`|`D`|`H`|`S`, or the word, any case. -1 when nothing matches.
  var s = ""
  for ch in text.toUpperAscii():
    if ch in {'A' .. 'Z'}:
      s.add(ch)
  if s.len == 0:
    ## The glyphs, which arrive as multi-byte runes.
    for index, glyph in SuitGlyphs:
      if glyph in text:
        return index
    return -1
  for (word, value) in SuitWords:
    if word in s:
      return value
  for index, letter in SuitLetters:
    if s == letter:
      return index
  -1

proc normaliseCode(text: string): string =
  ## Upper-cased, glyphs folded to letters, everything else dropped.
  var swapped = text
  for index, glyph in SuitGlyphs:
    swapped = swapped.replace(glyph, SuitLetters[index])
  for ch in swapped.toUpperAscii():
    if ch in {'A' .. 'Z', '0' .. '9'}:
      result.add(ch)

proc parseCard*(text: string): int =
  ## Tolerant card-code parsing: `10H`, `TH`, `HT`, `H10`, `ten of hearts`
  ## and `10 of Hearts` all resolve to the same card. Raises on anything
  ## that is not a card.
  var s = normaliseCode(text)
  if s.len == 0:
    raise newException(TricksError, "not a card: " & text)
  var rank = -1
  var suit = -1
  for (word, value) in RankWords:
    if word in s:
      rank = value
      s = s.replace(word, "")
      break
  if rank < 0 and "10" in s:
    rank = RankTen
    s = s.replace("10", "")
  for (word, value) in SuitWords:
    if word in s:
      suit = value
      s = s.replace(word, "")
      break
  if suit < 0:
    for index, ch in s:
      let found = SuitLetters.find($ch)
      if found >= 0:
        suit = found
        s = s[0 ..< index] & s[index + 1 .. ^1]
        break
  if rank < 0:
    for ch in s:
      case ch
      of '2' .. '9': rank = ord(ch) - ord('2')
      of 'T': rank = RankTen
      of 'J': rank = RankJack
      of 'Q': rank = RankQueen
      of 'K': rank = RankKing
      of 'A': rank = RankAce
      else: continue
      break
  if rank < 0 or suit < 0:
    raise newException(TricksError, "not a card: " & text)
  makeCard(rank, suit)

proc sortedHand*(cards: seq[int]): seq[int] =
  ## By suit, then rank -- the order a hand is printed in a prompt and
  ## fanned on the canvas.
  result = cards
  for i in 1 ..< result.len:
    let value = result[i]
    var j = i - 1
    while j >= 0 and (suitOf(result[j]) > suitOf(value) or
        (suitOf(result[j]) == suitOf(value) and rankOf(result[j]) > rankOf(value))):
      result[j + 1] = result[j]
      dec j
    result[j + 1] = value

proc handCodes*(cards: seq[int]): string =
  var parts: seq[string]
  for card in sortedHand(cards):
    parts.add(cardCode(card))
  parts.join(" ")

proc codeList*(cards: seq[int]): string =
  var parts: seq[string]
  for card in cards:
    parts.add(cardCode(card))
  parts.join(", ")
