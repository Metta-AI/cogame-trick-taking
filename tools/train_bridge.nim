## Persistent numeric bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:trick-taking-train-bridge tools/train_bridge.nim

import std/[algorithm, json, os]
import tricks/[cards, llm, sim]

const
  OperatorPrompt = "Choose legal moves to maximize your score over the complete match."
  Variants = ["euchre", "spades", "hearts", "oh-hell"]
  ActionCount = 286 # 13 choose 3: every possible Hearts pass.

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc payload(move: Move, phase: Phase, module: string): JsonNode =
  result = %*{"notes": ""}
  case phase
  of phPlay, phDiscard:
    result["card"] = %cardCode(move.card)
  of phPass:
    result["cards"] = newJArray()
    for card in move.cards:
      result["cards"].add(%cardCode(card))
  of phBid:
    if module == "euchre":
      result["action"] = %move.action
      if move.suit >= 0:
        result["suit"] = %suitName(move.suit)
    else:
      result["bid"] = %move.value
  else:
    doAssert false, "no decision due"

proc choices(sim: Sim): seq[Move] =
  if sim.phase == phPass:
    let hand = sim.deal[sim.actorSlot]
    for a in 0 ..< hand.len:
      for b in a + 1 ..< hand.len:
        for c in b + 1 ..< hand.len:
          result.add(passMove(@[hand[a], hand[b], hand[c]]))
  else:
    result = sim.legalMoves()
  doAssert result.len > 0 and result.len <= ActionCount

proc actions(sim: Sim): JsonNode =
  result = newJArray()
  for move in sim.choices():
    result.add(payload(move, sim.phase, sim.module))
  while result.len < ActionCount:
    result.add(newJNull())

proc decision(sim: Sim, id: int): JsonNode =
  let seat = sim.actorSlot
  var legal = newJArray()
  for move in sim.choices():
    legal.add(payload(move, sim.phase, sim.module))
  var seats = newJArray()
  for slot in 0 ..< Seats:
    seats.add(%*{"seat": slot, "position": sim.posOf[slot],
      "points": sim.points[slot], "net": sim.net[slot],
      "bid": sim.bids[slot], "tricks": sim.tricksWon[slot],
      "penalty": sim.penalty[slot]})
  var table = newJArray()
  for play in sim.table:
    table.add(%*{"seat": play.slot, "card": cardCode(play.card)})
  var hand = newJArray()
  for card in sim.deal[seat]:
    hand.add(%cardCode(card))
  %*{
    "kind": "decision", "game": "trick-taking", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": sim.hand,
    "semantic_view": {"module": sim.module, "hand": sim.hand,
      "hands": sim.config.hands, "phase": $sim.phase, "seats": seats,
      "own_cards": hand, "table": table, "trump": sim.trump,
      "upcard": sim.upcard, "turnup": sim.turnup,
      "dealer": sim.dealerSlot, "leader": sim.leaderSlot,
      "trick": sim.trick, "broken": sim.broken,
      "pass_direction": sim.passDir, "legal_actions": legal},
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(sim, seat)},
      {"role": "user", "content": userPrompt(sim, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "enum": legal},
    "typed_question": newJNull()
  }

proc encoding(sim: Sim, id: int): JsonNode =
  let seat = sim.actorSlot
  var values = newJArray()
  for name in Variants:
    values.add(%(if sim.module == name: 1 else: 0))
  for phase in Phase:
    values.add(%(if sim.phase == phase: 1 else: 0))
  for value in [seat, sim.hand, sim.config.hands, sim.dealerSlot,
      sim.leaderSlot, sim.trick, sim.tricksThisHand, sim.bidRound,
      sim.bidStep, sim.trump + 1, sim.upcard + 1, sim.turnup + 1,
      sim.maker + 1, sim.sittingOut + 1, sim.ledSuit + 1,
      sim.table.len, sim.handsScored]:
    values.add(%value)
  for flag in [sim.broken, sim.alone, sim.upcardLive]:
    values.add(%(if flag: 1 else: 0))
  for slot in 0 ..< Seats:
    for value in [sim.posOf[slot], sim.bids[slot], sim.tricksWon[slot],
        sim.penalty[slot], sim.tricksTotal[slot], sim.bidsTotal[slot],
        sim.bags[slot]]:
      values.add(%value)
    for value in [sim.points[slot], sim.net[slot]]:
      values.add(%value)
  for card in 0 ..< 52:
    values.add(%(if card in sim.deal[seat]: 1 else: 0))
    values.add(%(if sim.played[card]: 1 else: 0))
  for offset in 0 ..< Seats:
    if offset < sim.table.len:
      values.add(%(sim.table[offset].slot + 1))
      values.add(%(sim.table[offset].card + 1))
    else:
      values.add(%0)
      values.add(%0)
  let moves = sim.choices()
  for index in 0 ..< ActionCount:
    if index < moves.len:
      let move = moves[index]
      for value in [ord(move.kind), move.value, move.suit + 1,
          move.card + 1, move.cards.len]:
        values.add(%value)
      for cardIndex in 0 ..< 3:
        values.add(%(if cardIndex < move.cards.len:
          move.cards[cardIndex] + 1 else: 0))
      for action in ["pass", "order", "alone", "name", "bid"]:
        values.add(%(if move.action == action: 1 else: 0))
    else:
      for field in 0 ..< 13:
        values.add(%0)
  %*{"decision_id": id, "values": values, "actions": sim.actions()}

proc nextDecision(sim: var Sim) =
  while not sim.done and sim.currentCall().kind == ckDeal:
    sim.beginHand()

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: trick-taking-train-bridge MANIFEST [variant]", 1)
  let variant = if args.len == 2: args[1] else: Variants[0]
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      runtimeConfig["tokens"] = newJArray()
      for seat in 0 ..< Seats:
        runtimeConfig["tokens"].add(%("t" & $seat))
      runtimeConfig["turnDelayMs"] = %0
      config.update($runtimeConfig)
      game = initSim(sampleEpisode(config))
      game.nextDecision()
      id = 0
      response = game.decision(id)
    of "encode":
      doAssert not game.done
      response = game.encoding(id)
    of "teacher":
      doAssert not game.done
      let teacher = scriptedMove(game, "tracker")
      var teacherCards = teacher.cards
      teacherCards.sort()
      var chosen: JsonNode
      for move in game.choices():
        var candidateCards = move.cards
        candidateCards.sort()
        if move.kind == teacher.kind and move.action == teacher.action and
            move.value == teacher.value and move.suit == teacher.suit and
            move.card == teacher.card and candidateCards == teacherCards:
          chosen = payload(move, game.phase, game.module)
          break
      doAssert not chosen.isNil, "tracker has no legal candidate"
      response = %*{"response": $chosen}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let chosen = parseJson(request["response"].getStr())
      doAssert chosen in game.actions(), "action is not in the legal catalog"
      let move = parseDecision(game, chosen).move
      game.applyMove(move)
      game.nextDecision()
      inc id
      var observation: JsonNode
      if game.done:
        var scores = newJObject()
        let result = game.scoresOf()
        for slot in 0 ..< Seats:
          scores[$slot] = %result[slot]
        observation = %*{"kind": "terminal", "scores": scores}
      else:
        observation = game.decision(id)
      response = %*{"kind": "accepted", "action": chosen,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
