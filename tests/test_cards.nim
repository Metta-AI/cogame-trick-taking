## Card encoding, rendering and comparison.

import std/[strutils, unittest]
import tricks/[cards, types]

suite "encoding":
  test "cardCode / parseCard round-trip over all 52 cards":
    for card in 0 ..< 52:
      check parseCard(cardCode(card)) == card
      check parseCard(cardCode(card).toLowerAscii()) == card

  test "ten always renders 10, never T":
    for suit in 0 ..< 4:
      let card = makeCard(RankTen, suit)
      check cardCode(card) == "10" & SuitLetters[suit]
      check "T" notin cardCode(card)
      check cardGlyph(card).startsWith("10")

  test "TH, 10h, H10 and 'ten of hearts' all parse to the same card":
    let want = makeCard(RankTen, SuitHearts)
    for text in ["TH", "th", "10h", "10H", "H10", "HT",
        "ten of hearts", "Ten Of Hearts", "10 of Hearts"]:
      check parseCard(text) == want

  test "face and word forms parse":
    check parseCard("AS") == makeCard(RankAce, SuitSpades)
    check parseCard("ace of spades") == makeCard(RankAce, SuitSpades)
    check parseCard("QD") == makeCard(RankQueen, SuitDiamonds)
    check parseCard("KH") == makeCard(RankKing, SuitHearts)
    check parseCard("2C") == makeCard(0, SuitClubs)
    check parseCard("JS") == makeCard(RankJack, SuitSpades)
    check parseCard("9\u2666") == makeCard(7, SuitDiamonds)

  test "a code outside the deck raises":
    for text in ["", "??", "1C", "ZZ", "purple", "0"]:
      expect TricksError:
        discard parseCard(text)

  test "the euchre deck is the 24-card subset rank >= 7":
    let deck = euchreDeck()
    check deck.len == 24
    for card in deck:
      check rankOf(card) >= 7
    check fullDeck().len == 52

suite "comparison":
  test "beats orders every suit 2 < ... < 10 < J < Q < K < A":
    for suit in 0 ..< 4:
      for low in 0 ..< 12:
        let a = makeCard(low + 1, suit)
        let b = makeCard(low, suit)
        check beats(a, b, suit, -1, false)
        check not beats(b, a, suit, -1, false)

  test "a trump beats any non-trump, and a non-trump off the led suit never wins":
    let trump = SuitSpades
    let led = SuitHearts
    let lowTrump = makeCard(0, trump)
    let highLed = makeCard(RankAce, led)
    check beats(lowTrump, highLed, led, trump, false)
    check not beats(highLed, lowTrump, led, trump, false)
    let offSuit = makeCard(RankAce, SuitDiamonds)
    check not beats(offSuit, makeCard(0, led), led, trump, false)
    check not beats(offSuit, makeCard(0, led), led, -1, false)

suite "euchre bowers":
  const trump = SuitHearts   ## left bower is the jack of diamonds
  let right = rightBowerOf(trump)
  let left = leftBowerOf(trump)

  test "the left bower's effective suit is trump, not its printed suit":
    check suitOf(left) == SuitDiamonds
    check euchreEffectiveSuit(left, trump) == trump
    check euchreEffectiveSuit(right, trump) == trump
    ## And it is NOT a diamond for following: a seat holding only the left
    ## bower is void in diamonds.
    check euchreEffectiveSuit(left, trump) != SuitDiamonds

  test "right beats left, left beats the ace of trump":
    check beats(right, left, trump, trump, true)
    check not beats(left, right, trump, trump, true)
    let aceTrump = makeCard(RankAce, trump)
    check beats(left, aceTrump, trump, trump, true)
    check not beats(aceTrump, left, trump, trump, true)

  test "the 9 of trump beats the ace of a side suit":
    let nine = makeCard(7, trump)
    let sideAce = makeCard(RankAce, SuitSpades)
    check beats(nine, sideAce, SuitSpades, trump, true)
    check not beats(sideAce, nine, SuitSpades, trump, true)

  test "euchre trump ranking is 9 < 10 < Q < K < A < left < right":
    let order = [makeCard(7, trump), makeCard(RankTen, trump),
      makeCard(RankQueen, trump), makeCard(RankKing, trump),
      makeCard(RankAce, trump), left, right]
    for index in 1 ..< order.len:
      check euchreTrumpRank(order[index], trump) >
        euchreTrumpRank(order[index - 1], trump)
      check beats(order[index], order[index - 1], trump, trump, true)

suite "hands":
  test "sortedHand orders by suit then rank":
    let hand = sortedHand(@[makeCard(RankAce, SuitSpades),
      makeCard(0, SuitClubs), makeCard(RankKing, SuitClubs)])
    check hand == @[makeCard(0, SuitClubs), makeCard(RankKing, SuitClubs),
      makeCard(RankAce, SuitSpades)]
    check handCodes(hand) == "2C KC AS"

  test "hearts penalties are one a heart and thirteen for the queen":
    check heartsPenalty(QueenOfSpades) == 13
    check heartsPenalty(makeCard(0, SuitHearts)) == 1
    check heartsPenalty(makeCard(RankAce, SuitClubs)) == 0
    var total = 0
    for card in fullDeck():
      total += heartsPenalty(card)
    check total == 26
