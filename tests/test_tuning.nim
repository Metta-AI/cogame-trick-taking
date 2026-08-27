## The scripted baselines' bidding thresholds are a tuned configuration, not
## a guess: `tools/ci/tune_baselines.nim` sweeps a grid around each of them
## and `docs/tuning.md` records the sweep that chose the shipped values.
## This suite pins the two together, so a hand-edited threshold either comes
## with a re-run of the sweep or fails here.

import std/[strformat, unittest]
import tricks/llm
import ../tools/ci/tune_baselines

const
  ## docs/tuning.md, "Chosen configuration". Change these only together
  ## with that table and the constants in src/tricks/llm.nim.
  ChosenFollow = BaselineParams(orderAt: 10, aloneAt: 16, spadesShade: 0,
    ohHellDrop: 0)
  ChosenTracker = BaselineParams(orderAt: 10, aloneAt: 16, spadesShade: 0,
    ohHellDrop: 2)
  ## The sweep's own gate, at the sample size a test can afford. The
  ## run-to-run noise band over two independent seed sets at 96 matches is
  ## +/-0.002 and the largest spurious gain seen at 24 matches is +0.0044;
  ## a parameter that really is better than the shipped one wins by 0.01
  ## to 0.10 (docs/tuning.md).
  TestMatches = 24
  Tolerance = 0.008

suite "the baselines' bidding parameters are the grid's choice":
  test "the shipped constants are the configuration docs/tuning.md records":
    check baselineParams("follow") == ChosenFollow
    check baselineParams("tracker") == ChosenTracker

  test "self-play is exactly break-even, so the sweep measures parameters":
    ## Both sides of the control row are the same configuration and every
    ## deal is played from both pairs of positions, so any deviation from
    ## 0.5 would be seating luck leaking into the comparison.
    for module in Modules:
      for baseline in Baselines:
        let shipped = baselineParams(baseline)
        let (score, _) = sweepPoint(module, baseline, TestMatches, 17,
          shipped, shipped)
        check abs(score - 0.5) < 1e-9

  test "no grid point beats the shipped configuration":
    for baseline in Baselines:
      let shipped = baselineParams(baseline)
      for module in Modules:
        for point in gridFor(module, shipped):
          if point == shipped: continue
          let (score, _) = sweepPoint(module, baseline, TestMatches, 17,
            point, shipped)
          check score - 0.5 <= Tolerance
          if score - 0.5 > Tolerance:
            echo &"{module}/{baseline}: {label(module, point)} scores " &
              &"{score:.4f}; re-run tools/ci/tune_baselines.nim"

  test "the far corners of each grid lose, and lose clearly":
    ## The shape the sweep found: ordering up late costs euchre, and
    ## bidding under the winner count costs spades.
    let tracker = baselineParams("tracker")
    var timid = tracker
    timid.orderAt = 14
    timid.aloneAt = 20
    let (euchre, _) = sweepPoint("euchre", "tracker", TestMatches, 17, timid,
      tracker)
    check euchre < 0.49
    var shaded = tracker
    shaded.spadesShade = 2
    let (spades, _) = sweepPoint("spades", "tracker", TestMatches, 17,
      shaded, tracker)
    check spades < 0.46

  test "every grid point still plays legal, complete matches":
    ## A sweep is only evidence if every point it scored finished the
    ## episode by the rules.
    for baseline in Baselines:
      let shipped = baselineParams(baseline)
      for module in Modules:
        for point in gridFor(module, shipped):
          let (score, _) = playMatch(module, baseline, 4242, point, shipped,
            true)
          check score >= 0.0 and score <= 1.0
