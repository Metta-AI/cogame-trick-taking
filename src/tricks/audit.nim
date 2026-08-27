## Soft-play audit -- a PURE function of the recorded event log.
##
## `results.audit` is non-null for `hearts` and `oh-hell` and null for the
## partnership modules: in a partnership game letting your partner win IS
## the correct play, and there is nothing to audit.
##
## Every `play` event records the acting seat's legal set, so this needs no
## re-derivation and cannot drift from the engine. The server and the wasm
## replay viewer call this same proc on the same bytes.
##
## v1 REPORTS AND NEVER ACCUSES. There are no flags, no thresholds and no
## penalties: the matrices, the per-seat field rate and a `power` block are
## the whole output, so a four-hand episode's numbers read as the weak
## evidence they are.

import std/[algorithm, json], types, cards

proc auditFromEvents*(config: GameConfig, events: seq[GameEvent]): JsonNode =
  let euchre = config.module == "euchre"
  let isHearts = config.module == "hearts"
  var chance: array[Seats, array[Seats, int]]
  var declines: array[Seats, array[Seats, int]]
  var discards: array[Seats, array[Seats, int]]
  var gifts: array[Seats, array[Seats, int]]
  var hands = 0
  var trump = -1
  var led = -1
  var bestIndex = 0
  var slots: seq[int]
  var played: seq[int]
  var followed: seq[bool]

  for event in events:
    case event.kind
    of evHand:
      inc hands
      trump =
        if config.module == "spades": SuitSpades
        elif event.turnup >= 0: suitOf(event.turnup)
        else: -1
      slots = @[]
      played = @[]
      followed = @[]
      bestIndex = 0
      led = -1
    of evTrump:
      trump = event.suit
    of evPlay:
      let suit = effectiveSuit(event.card, trump, euchre)
      if event.trickPos == 0:
        slots = @[event.slot]
        played = @[event.card]
        followed = @[true]
        led = suit
        bestIndex = 0
      else:
        let bestSlot = slots[bestIndex]
        let bestCard = played[bestIndex]
        if bestSlot != event.slot:
          var couldBeat = false
          for candidate in event.legal:
            if beats(candidate, bestCard, led, trump, euchre):
              couldBeat = true
              break
          if couldBeat:
            inc chance[event.slot][bestSlot]
            if not beats(event.card, bestCard, led, trump, euchre):
              inc declines[event.slot][bestSlot]
        slots.add(event.slot)
        played.add(event.card)
        followed.add(suit == led)
        if beats(event.card, bestCard, led, trump, euchre):
          bestIndex = played.high
    of evTrick:
      if isHearts:
        for index in 0 ..< slots.len:
          let actor = slots[index]
          if actor == event.slot or followed[index]:
            continue
          inc discards[actor][event.slot]
          gifts[actor][event.slot] += heartsPenalty(played[index])
    else:
      discard

  proc matrix(source: array[Seats, array[Seats, int]]): JsonNode =
    result = newJArray()
    for a in 0 ..< Seats:
      var row = newJArray()
      for b in 0 ..< Seats:
        row.add(%source[a][b])
      result.add(row)

  proc rates(num, den: array[Seats, array[Seats, int]]): JsonNode =
    result = newJArray()
    for a in 0 ..< Seats:
      var row = newJArray()
      for b in 0 ..< Seats:
        row.add(%(num[a][b].float / max(den[a][b], 1).float))
      result.add(row)

  var field = newJArray()
  for a in 0 ..< Seats:
    var num = 0
    var den = 0
    for b in 0 ..< Seats:
      if b == a: continue
      num += declines[a][b]
      den += chance[a][b]
    field.add(%(num.float / max(den, 1).float))

  var cells: seq[int]
  for a in 0 ..< Seats:
    for b in 0 ..< Seats:
      if a != b:
        cells.add(chance[a][b])
  cells.sort()
  let chanceMin = (if cells.len > 0: cells[0] else: 0)
  let chanceMedian = (if cells.len > 0: cells[cells.len div 2] else: 0)

  result = %*{
    "chance": matrix(chance),
    "yield": matrix(declines),
    "yieldRate": rates(declines, chance),
    "field": field,
    "power": {
      "hands": hands,
      "chanceMin": chanceMin,
      "chanceMedian": chanceMedian
    }
  }
  if isHearts:
    result["discards"] = matrix(discards)
    result["gift"] = matrix(gifts)
    result["giftRate"] = rates(gifts, discards)
  else:
    result["discards"] = newJNull()
    result["gift"] = newJNull()
    result["giftRate"] = newJNull()
