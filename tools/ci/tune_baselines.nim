## tools/ci/tune_baselines.nim -- the grid harness behind the scripted
## baselines' bidding thresholds.
##
## The play side of `follow`/`tracker` is rule-derived, but the BIDS carry
## free parameters: euchre's order-it-up and go-alone strengths, the shade
## spades bids under its winner count, and the suit length at which oh-hell
## stops counting an off-suit ace. Numbers like that are guesses until
## something plays them against each other.
##
## This harness seats a CANDIDATE configuration at table positions 0 and 2
## and the SHIPPED one at 1 and 3 -- the partnership split in euchre and
## spades, and an even split in oh-hell -- and plays a fixed, seeded set of
## all-scripted matches per grid point. The reported score is the mean of
## the candidate seats' normalised scores, where 0.5 is break-even by
## construction (`sim.scoresOf`), so a configuration is better than the
## shipped one only above 0.5.
##
## It is deterministic: same grid, same seeds, same numbers on every run.
## `docs/tuning.md` is its output, and `tests/test_tuning.nim` pins the
## shipped constants to the row this harness chose.
##
## It is also a gate: it exits non-zero if any grid point beats the shipped
## configuration by more than `--tolerance` (the run-to-run noise band,
## measured at +/-0.002 over two independent seed sets), so a hand-edited
## threshold that the grid does not support fails CI.
##
##   nim r -d:release --path:src tools/ci/tune_baselines.nim [--matches N]
##                     [--seed N] [--tolerance F] [--json PATH]
import std/[json, os, strformat, strutils]
import tricks/[llm, sim]

const
  Modules* = ["euchre", "spades", "oh-hell"]
  ## Small enough to run inside a CI step, large enough that the ranking is
  ## not a coin flip: 96 matches x 8 hands is ~750 scored hands per point.
  DefaultMatches = 96

proc handsFor(module: string): int =
  case module
  of "euchre": 8
  of "oh-hell": 11
  else: 4

proc matchConfig(module: string, seed: int): GameConfig =
  result = defaultGameConfig()
  result.module = module
  result.hands = handsFor(module)
  result.seed = seed
  result.turnDelayMs = 0
  result.sampled = true
  if module == "oh-hell":
    result.dealSchedule = @DefaultDealSchedule
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc playMatch*(module, baseline: string, seed: int,
    candidate, shipped: BaselineParams,
    candidateEven: bool): tuple[score: float, win: bool] =
  ## One all-scripted match. The candidate configuration bids for one pair
  ## of table positions and the shipped one for the other; everything else
  ## about the two sides is identical.
  var sim = initSim(matchConfig(module, seed))
  while not sim.done:
    let call = sim.currentCall()
    case call.kind
    of ckDeal: sim.beginHand()
    of ckNone: break
    else:
      let even = (sim.actorPos and 1) == 0
      let params = if even == candidateEven: candidate else: shipped
      sim.applyMove(scriptedMove(sim, baseline, params), "", true)
  let scores = sim.scoresOf()
  let wins = sim.winsOf()
  let a = sim.slotAt(if candidateEven: 0 else: 1)
  let b = sim.slotAt(if candidateEven: 2 else: 3)
  result.score = (scores[a] + scores[b]) / 2.0
  result.win = wins[a] or wins[b]

proc sweepPoint*(module, baseline: string, matches, seedBase: int,
    candidate, shipped: BaselineParams): tuple[score, winRate: float] =
  ## Every deal is played twice, once with the candidate on each pair of
  ## positions, and the two are averaged. Without that, a seeded deal that
  ## happens to favour positions 0/2 shows up as a parameter effect: the
  ## self-play control row would not read 0.5000, and it must, since both
  ## sides of it are the same configuration.
  var total = 0.0
  var wins = 0
  for run in 0 ..< matches:
    ## Fixed seeds: the same deals for every grid point, so the points are
    ## compared on the same cards and not on their luck.
    let seed = 1000 * run + seedBase
    for candidateEven in [true, false]:
      let (score, win) = playMatch(module, baseline, seed, candidate,
        shipped, candidateEven)
      total += score
      if win: inc wins
  (total / (2 * matches).float, wins.float / (2 * matches).float)

proc gridFor*(module: string, shipped: BaselineParams): seq[BaselineParams] =
  ## Each grid brackets the shipped value on both sides.
  case module
  of "euchre":
    for orderAt in [8, 10, 12, 14]:
      for aloneAt in [14, 16, 18, 20]:
        var point = shipped
        point.orderAt = orderAt
        point.aloneAt = aloneAt
        result.add(point)
  of "spades":
    for shade in [0, 1, 2]:
      var point = shipped
      point.spadesShade = shade
      result.add(point)
  of "oh-hell":
    for drop in [0, 1, 2, 3]:
      var point = shipped
      point.ohHellDrop = drop
      result.add(point)
  else: discard

proc label*(module: string, point: BaselineParams): string =
  case module
  of "euchre": &"orderAt={point.orderAt} aloneAt={point.aloneAt}"
  of "spades": &"spadesShade={point.spadesShade}"
  of "oh-hell": &"ohHellDrop={point.ohHellDrop}"
  else: "-"

proc main() =
  var matches = DefaultMatches
  var seedBase = 17
  var tolerance = 0.005
  var jsonPath = ""
  var index = 1
  while index <= paramCount():
    case paramStr(index)
    of "--matches":
      inc index
      matches = parseInt(paramStr(index))
    of "--tolerance":
      inc index
      tolerance = parseFloat(paramStr(index))
    of "--seed":
      inc index
      seedBase = parseInt(paramStr(index))
    of "--json":
      inc index
      jsonPath = paramStr(index)
    else:
      quit("unknown argument: " & paramStr(index), 2)
    inc index

  var report = newJArray()
  var beaten: seq[string]
  echo &"grid sweep: {matches} seeded deals per point (seeds " &
    &"{seedBase}, {1000 + seedBase}, ...), each played twice with the " &
    "candidate on either pair of positions"
  for baseline in Baselines:
    let shipped = baselineParams(baseline)
    for module in Modules:
      echo ""
      echo &"### {module} / {baseline}"
      echo "| parameters | mean score | win rate | vs shipped |"
      echo "|---|---|---|---|"
      var best = -1.0
      var bestLabel = ""
      for point in gridFor(module, shipped):
        let (score, winRate) = sweepPoint(module, baseline, matches, seedBase,
          point, shipped)
        let isShipped = point == shipped
        let mark = if isShipped: " **(shipped)**" else: ""
        echo &"| {label(module, point)}{mark} | {score:.4f} | " &
          &"{winRate:.3f} | {score - 0.5:+.4f} |"
        report.add(%*{
          "module": module, "baseline": baseline,
          "parameters": label(module, point), "shipped": isShipped,
          "meanScore": score, "winRate": winRate})
        if score > best:
          best = score
          bestLabel = label(module, point)
        ## The shipped row is 0.5000 by construction: it is the same
        ## configuration on both sides of the table.
        if not isShipped and score - 0.5 > tolerance:
          beaten.add(&"{module}/{baseline}: {label(module, point)} scores " &
            &"{score:.4f} against the shipped {label(module, shipped)}")
      echo &"best: {bestLabel} at {best:.4f} " &
        &"(shipped: {label(module, shipped)})"
  if beaten.len > 0:
    echo ""
    for line in beaten:
      echo "::error::" & line
    echo &"::error::the shipped baseline parameters are no longer the grid " &
      &"maximum (tolerance {tolerance:.4f}). Re-tune them and update " &
      "docs/tuning.md."
  if jsonPath.len > 0:
    createDir(parentDir(jsonPath))
    writeFile(jsonPath, pretty(%*{"matches": matches, "seed": seedBase,
      "points": report}))
    echo &"wrote {jsonPath}"
  if beaten.len > 0:
    quit(1)

when isMainModule:
  main()
