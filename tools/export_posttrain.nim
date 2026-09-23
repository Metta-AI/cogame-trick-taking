## Export complete trick-taking matches as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import tricks/[cards, llm, sim]

const OperatorPrompt = "Choose legal moves to maximize your score over the complete match."
const Variants = ["euchre", "spades", "hearts", "oh-hell"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: Variants[0]
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    runtimeConfig["turnDelayMs"] = %0
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var sim = initSim(config)
    var rows: seq[string]
    while not sim.done:
      let call = sim.currentCall()
      case call.kind
      of ckDeal:
        sim.beginHand()
      of ckNone:
        break
      else:
        let seat = sim.actorSlot
        let teacher = scriptedMove(sim, "tracker")
        var completion = %*{"notes": ""}
        case sim.phase
        of phPlay, phDiscard:
          completion["card"] = %cardCode(teacher.card)
        of phPass:
          completion["cards"] = newJArray()
          for card in teacher.cards:
            completion["cards"].add(%cardCode(card))
        of phBid:
          if sim.module == "euchre":
            completion["action"] = %teacher.action
            if teacher.suit >= 0:
              completion["suit"] = %suitName(teacher.suit)
          else:
            completion["bid"] = %teacher.value
        else:
          doAssert false, "no decision due"
        let parsed = parseDecision(sim, completion)
        doAssert parsed.move == teacher
        rows.add($(%*{
          "episode_id": "trick-taking-" & variant & "-" & $seed,
          "seed": "trick-taking-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(sim, seat)},
            {"role": "user", "content": userPrompt(sim, OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "trick-taking",
          "action_schema_revision": "tricks-move-v1"
        }))
        sim.applyMove(parsed.move, parsed.notes, true)
    doAssert sim.reason == "complete" and rows.len > 0
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "hands_scored": sim.handsScored})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "trick-taking",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-tracker",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
