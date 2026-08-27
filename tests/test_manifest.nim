## The manifest template is a contract with the platform, and repo CI is the
## only place it is checked before an upload rejects it.

import std/[json, os, sets, strutils, unittest]
import tricks/sim

proc manifestPath(): string =
  for candidate in ["coworld_manifest_template.json",
      "../coworld_manifest_template.json"]:
    if fileExists(candidate):
      return candidate
  raise newException(IOError, "coworld_manifest_template.json not found")

let manifest = parseJson(readFile(manifestPath()))
let game = manifest["game"]

proc configFrom(node: JsonNode): GameConfig =
  ## Exactly what the game does at start-up: defaults, then the runtime
  ## JSON on top, then the budget fit.
  result = defaultGameConfig()
  var copy = node.copy()
  copy.delete("num_agents")
  result.update($copy)
  result.tokens = @[]
  for index in 0 ..< result.players.len:
    result.tokens.add("token-" & $index)
  result = sampleEpisode(result)

suite "top level":
  test "schema, tags, no top-level version, episode timeout":
    check manifest.hasKey("$schema")
    check manifest["tags"].len >= 3
    check not manifest.hasKey("version")
    check manifest["episode_timeout_minutes"].getInt() == 20

  test "game.description is present and game.tags is absent":
    check game.hasKey("description")
    check game["description"].getStr().len > 200
    check not game.hasKey("tags")
    check not game.hasKey("display_name")
    check game["owner"].getStr() == "daveey@gmail.com"
    check game["name"].getStr() == "trick-taking"

  test "the replay viewer is a STATIC bundle, nested under game":
    check not manifest.hasKey("replay_viewer")
    check game["replay_viewer"]["bundle"].getStr() == "static-replay-viewer"

  test "the game runnable carries the secret URI in the game.name namespace":
    let runnable = game["runnable"]
    check runnable["type"].getStr() == "game"
    check runnable["image"].getStr() == "{{TRICK_TAKING_IMAGE}}"
    check runnable["run"][0].getStr() == "/bin/trick-taking"
    check runnable["env"]["ANTHROPIC_API_KEY_URI"].getStr() ==
      "secret://coworld/" & game["name"].getStr() & "/anthropic_api_key"

suite "schemas":
  test "every array property in config_schema declares minItems and maxItems":
    let properties = game["config_schema"]["properties"]
    var arrays = 0
    for name, spec in properties:
      if spec{"type"}.getStr() != "array":
        continue
      inc arrays
      check spec.hasKey("minItems")
      check spec.hasKey("maxItems")
    check arrays >= 3
    check properties["tokens"]["minItems"].getInt() == Seats
    check properties["tokens"]["maxItems"].getInt() == Seats
    check properties["players"]["minItems"].getInt() == Seats
    check properties["players"]["maxItems"].getInt() == Seats

  test "results_schema declares the reason enum and nothing else is legal":
    let results = game["results_schema"]["properties"]
    var reasons: seq[string]
    for value in results["reason"]["enum"]:
      reasons.add(value.getStr())
    check reasons == @["complete", "deadline", "budget"]
    for key in ["names", "scores", "win", "net", "points", "teamPoints",
        "tricks", "bids", "bidsMade", "penalties", "moons", "marches",
        "euchres", "nilsMade", "nilsFailed", "bags", "decisions",
        "fallbacks", "forcedMoves", "audit", "module", "seats", "seatOrder",
        "handsPlayed", "handsScored", "hands", "norm", "seed", "reason"]:
      check results.hasKey(key)

  test "results_schema covers exactly what the game writes":
    var config = defaultGameConfig()
    config.module = "hearts"
    config.hands = 2
    config.sampled = true
    for index in 0 ..< Seats:
      config.players.add(PlayerConfig(name: "P" & $index))
      config.tokens.add("t" & $index)
    let produced = initSim(config).resultsJson()
    let declared = game["results_schema"]["properties"]
    for key, _ in produced:
      check declared.hasKey(key)

suite "protocols and docs":
  test "player and global are both {type, value} objects":
    for name in ["player", "global"]:
      let node = game["protocols"][name]
      check node.kind == JObject
      check node["type"].getStr() == "text"
      check node["value"].getStr().len > 200

  test "docs carry a readme object and the three named pages":
    check game["docs"]["readme"]["type"].getStr() == "text"
    check game["docs"]["readme"]["value"].getStr().len > 200
    var ids: seq[string]
    for page in game["docs"]["pages"]:
      ids.add(page["id"].getStr())
      check page["title"].getStr().len > 0
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 200
    check ids == @["rules.md", "modules.md", "scoring.md"]

suite "players":
  test "three declared runnables, each with limits.cpu 1":
    var ids: seq[string]
    for player in manifest["player"]:
      ids.add(player["id"].getStr())
      check player["type"].getStr() == "player"
      check player["run"][0].getStr() == "/bin/trick-taking-player"
      check player["image"].getStr() == "{{TRICK_TAKING_IMAGE}}"
      check player["resources"]["limits"]["cpu"].getStr() == "1"
      check player["description"].getStr().len > 40
    check ids == @["trick-taking-player", "trick-taking-follow",
      "trick-taking-tracker"]

  test "every declared player is seated in the certification fixture":
    var seated = initHashSet[string]()
    for entry in manifest["certification"]["players"]:
      seated.incl(entry["player_id"].getStr())
    for player in manifest["player"]:
      check player["id"].getStr() in seated

  test "the scripted baselines name a baseline the game knows":
    for player in manifest["player"]:
      if player.hasKey("env") and player["env"].hasKey("PLAYER_SCRIPTED"):
        check player["env"]["PLAYER_SCRIPTED"].getStr() in
          ["follow", "tracker"]

suite "variants and the certification fixture":
  test "num_agents is 4 in EVERY variant and equals the players length":
    check manifest["variants"].len == 4
    var ids: seq[string]
    for variant in manifest["variants"]:
      ids.add(variant["id"].getStr())
      check variant["description"].getStr().len > 40
      check variant["name"].getStr().len > 0
      let config = variant["game_config"]
      check config.hasKey("num_agents")
      check config["num_agents"].getInt() == Seats
      check config["players"].len == Seats
      check config["episodeTimeoutSeconds"].getInt() == 1200
      check config["player_connect_timeout_seconds"].getInt() == 180
    check ids == @["euchre", "spades", "hearts", "oh-hell"]

  test "no runner-managed tokens appear in any game_config":
    for variant in manifest["variants"]:
      check not variant["game_config"].hasKey("tokens")
    check not manifest["certification"]["game_config"].hasKey("tokens")

  test "EVERY variant's game_config constructs a valid Sim":
    for variant in manifest["variants"]:
      let config = configFrom(variant["game_config"])
      check config.module == variant["id"].getStr()
      var sim = initSim(config)
      check sim.names.len == Seats
      ## And it plays: deal the first hand and run it out on the baseline.
      sim.beginHand()
      check sim.dealt[0].len ==
        moduleFor(config.module).cardsPerHand(config, 0)
      check worstCaseDecisions(config) <= EpisodeDecisionBudget

  test "the certification fixture is a three-hand euchre episode at four seats":
    let cert = manifest["certification"]
    let config = cert["game_config"]
    check config["module"].getStr() == "euchre"
    check config["num_agents"].getInt() == Seats
    check config["seed"].getInt() == 7
    check config["hands"].getInt() == 3
    check config["turnDelayMs"].getInt() == 0
    check config["players"].len == Seats
    check cert["players"].len == Seats
    let parsed = configFrom(config)
    check parsed.hands == 3
    var sim = initSim(parsed)
    check sim.module == "euchre"

suite "the policy set CI ships":
  test "two prompt champions, two scripted fillers, champion #2 owned":
    let policies = parseJson(readFile(
      if fileExists("tools/ci/policies.json"): "tools/ci/policies.json"
      else: "../tools/ci/policies.json"))
    check policies.len == 4
    var prompts = 0
    var scripted = 0
    var owned = 0
    var names = initHashSet[string]()
    for policy in policies:
      names.incl(policy["name"].getStr())
      check policy["run"].getStr() == "/bin/trick-taking-player"
      check policy["name"].getStr().startsWith("trick-taking-")
      if policy["env"].hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 200
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        inc scripted
        check policy["env"]["PLAYER_SCRIPTED"].getStr() in
          ["follow", "tracker"]
      if policy.hasKey("player"):
        inc owned
        check policy["player"].getStr() ==
          "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
        check policy["env"].hasKey("PLAYER_PROMPT")
    check prompts == 2
    check scripted == 2
    check owned == 1
    check names.len == 4
