## Trick-taking game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared stage renderer
##   GET /client/chrome.css          - shared chrome
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (tricks.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","protocol":"tricks.player.v1",...}
##                   {"type":"state",...} after every event batch, REDACTED:
##                   every other slot's cards and notes, the kitty, the
##                   euchre discard, the tell and the policy names are gone
##                   {"type":"final","done":true,...}
##   player -> game: {"type":"prompt","prompt":str,"scripted":bool,
##                    "baseline":"follow"|"tracker"}
##                   (prompt max 4000 characters, truncated on RUNE
##                   boundaries; scripted:true plays the named baseline)

import
  std/[json, locks, os, sets, strutils, tables, times],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  ShutdownGraceSeconds = 20
    ## The certifier pings /global AFTER the player pods start, so a short
    ## episode must keep answering for a bounded grace (lantern 0.1.3-0.1.4).

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[bool]
    baselines: seq[string]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous aliases; the policy names ride alongside for
  ## the SPECTATOR views only.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.frameStateJson()
  result["type"] = %"state"
  result["game"] = %"trick-taking"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  ## Hidden information: every other slot's cards and notes, the kitty, the
  ## euchre discard, the tell annotations and the policy names are removed.
  result = gs.sim.frameStateJson()
  result["type"] = %"state"
  result["slot"] = %slot
  result.delete("tell")
  result.delete("kitty")
  result.delete("discard")
  for seat in result["seats"]:
    if seat["slot"].getInt() != slot:
      seat["hand"] = newJArray()
      seat["notes"] = %""
  result["started"] = %gs.started
  result["done"] = %gs.sim.done

proc broadcastLocked(gs: GameState) =
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  ## The replay bytes come straight from the sim, so the server and the
  ## wasm viewer can never disagree about the format.
  var payload = gs.sim.replayJson()
  payload["results"] = results
  $payload

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Players get their final frame BEFORE the artifacts are written: the
    ## hosted worker tears player pods down as soon as results.json exists.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "win": results["win"],
      "names": aliasNames,
      "points": results["points"],
      "net": results["net"],
      "handsScored": results["handsScored"],
      "reason": results["reason"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "trick-taking: writing results and replay"
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  writeArtifact(runtimeConfig.replayUri, replayData,
    "application/octet-stream", "COGAME_SAVE_REPLAY_METHOD")
  ## /healthz and /global keep answering - and keep answering a WebSocket
  ## Ping with a Pong - for a bounded grace after the artifacts land.
  echo "trick-taking: artifacts written; serving for a ",
    ShutdownGraceSeconds, "s shutdown grace"
  sleep(ShutdownGraceSeconds * 1000)
  echo "trick-taking: episode complete, shutting down"
  quit(0)

proc decisionText(sim: Sim, call: Call, decision: Decision): string =
  if call.slot < 0:
    return ""
  let who = sim.names[call.slot]
  case decision.move.kind
  of mkPlay: who & " plays " & cardCode(decision.move.card)
  of mkDiscard: who & " discards"
  of mkPass: who & " passes three"
  of mkBid:
    if decision.move.action == "bid": who & " bids " & $decision.move.value
    else: who & " " & decision.move.action &
      (if decision.move.suit >= 0: " " & suitName(decision.move.suit) else: "")
  else: who & " waits"

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let connectDeadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "trick-taking: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The hosted dispatcher hands the timeout only to its own worker
    ## sidecar, NOT to the game container, so when the env is silent assume
    ## the configured platform default rather than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let softDeadline = gameStart + timeoutSeconds * SoftDeadlineFraction
    let hardDeadline = gameStart + timeoutSeconds * HardDeadlineFraction
    echo "trick-taking: episode timeout ", timeoutSeconds.int, "s (",
      (if hostedTimeout.len > 0: "from env" else: "assumed"),
      "); soft guard at ", (timeoutSeconds * SoftDeadlineFraction).int,
      "s, hard guard at ", (timeoutSeconds * HardDeadlineFraction).int, "s"

    var modelCalls = 0
    var stopReason = ""
    var lastDecisionAt = 0.0

    while true:
      var call: Call
      var simCopy: Sim
      var seatPrompt: string
      var seatScripted = false
      var baseline = "follow"
      var settled = false
      var paceTrick = false

      withLock stateLock:
        if state.sim.done:
          settled = true
        else:
          call = state.sim.currentCall()
          let now = epochTime()
          let pastSoft = now > softDeadline
          let pastHard = now > hardDeadline
          let budgetOut = modelCalls >= EpisodeDecisionBudget
          if budgetOut and stopReason.len == 0:
            stopReason = "budget"
          if pastSoft and stopReason.len == 0:
            stopReason = "deadline"
          if call.kind == ckNone:
            settled = true
          elif call.kind == ckDeal:
            if stopReason.len > 0:
              echo "trick-taking: settling after ", state.sim.handsScored,
                "/", config.hands, " hands (", stopReason, ")"
              state.sim.endEarly(stopReason)
              state.broadcastLocked()
              settled = true
            else:
              state.sim.beginHand()
              echo "trick-taking: hand ", state.sim.hand + 1, " of ",
                config.hands, " at ", (epochTime() - gameStart).int, "s"
              state.broadcastLocked()
          elif pastHard:
            ## The hand in progress is abandoned: not scored, excluded from
            ## H and from NORM. A recorded event, so the replay re-derives.
            echo "trick-taking: hard deadline; voiding hand ",
              state.sim.hand + 1
            state.sim.voidHand()
            state.broadcastLocked()
            settled = true
          else:
            let forced = state.sim.forcedMove()
            if forced >= 0:
              ## Exactly one legal option: no model call is spent.
              state.sim.applyMove(playMove(forced), "", true)
              inc state.sim.decisions[call.slot]
              paceTrick = state.sim.trickComplete
              state.broadcastLocked()
            else:
              simCopy = state.sim
              seatPrompt = state.prompts[call.slot]
              seatScripted = state.scripted[call.slot] or stopReason.len > 0
              baseline = state.baselines[call.slot]

      if settled:
        break
      if simCopy.names.len == 0:
        ## The iteration dealt a hand or played a forced card; loop again.
        if paceTrick and config.turnDelayMs > 0:
          sleep(config.turnDelayMs)
        continue

      ## With no credentials at all the decision is scripted by construction:
      ## no request is issued, so no spacing is owed and nothing is a
      ## fallback. That is what keeps offline certification and the docker
      ## smoke finishing in a second rather than in ten minutes.
      let modelPath = not seatScripted and not client.disabled
      if modelPath:
        ## Decision-start to decision-start spacing floor.
        let spacing = (DecisionSpacingMs + client.extraSpacingMs).float / 1000.0
        let wait = lastDecisionAt + spacing - epochTime()
        if wait > 0:
          sleep(int(wait * 1000))
        lastDecisionAt = epochTime()
        inc modelCalls

      ## The slow part (Claude) runs outside the lock on a snapshot; only
      ## this thread mutates the sim, so the snapshot cannot go stale.
      let decision = client.decide(simCopy, seatPrompt, seatScripted, baseline)

      withLock stateLock:
        inc state.sim.decisions[call.slot]
        if decision.scripted and modelPath:
          inc state.sim.fallbacks[call.slot]
        if decision.forced:
          inc state.sim.forcedMoves[call.slot]
        echo "trick-taking: hand ", state.sim.hand + 1, " ",
          decisionText(state.sim, call, decision), " at ",
          (epochTime() - gameStart).int, "s"
        try:
          state.sim.applyMove(decision.move, decision.notes,
            decision.scripted or seatScripted)
        except TricksError as error:
          echo "trick-taking: move rejected (", error.msg,
            "); using the scripted fallback"
          inc state.sim.fallbacks[call.slot]
          let fallback = baselineDecision(state.sim, baseline, error.msg)
          if fallback.forced:
            inc state.sim.forcedMoves[call.slot]
          state.sim.applyMove(fallback.move, "", true)
        paceTrick = state.sim.trickComplete
        state.broadcastLocked()

      ## Pace after each COMPLETED trick, not after each card.
      if paceTrick and config.turnDelayMs > 0:
        sleep(config.turnDelayMs)

    if config.turnDelayMs > 0:
      sleep(config.turnDelayMs)
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8")

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "chrome.css", "text/css; charset=utf-8")

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "trick-taking: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      let partner = state.sim.partnerSlot(slot)
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "tricks.player.v1",
        "slot": slot,
        "name": state.sim.names[slot],
        "module": state.sim.module,
        "displayName": state.sim.displayName,
        "hands": state.config.hands,
        "pos": state.sim.posOf[slot],
        "partner": (if partner >= 0: %state.sim.names[partner]
                    else: newJNull())
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the certifier pings /global to check the game is
      ## alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          ## Rune-safe: a byte slice here is how a replay renders in a
          ## browser and still fails a strict UTF-8 parser.
          let prompt = truncateRunes(payload{"prompt"}.getStr(), MaxPromptLen)
          let scripted = payload{"scripted"}.getBool(false)
          var baseline = payload{"baseline"}.getStr("follow").strip()
          if baseline notin Baselines:
            baseline = "follow"
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = scripted
            state.baselines[slot] = baseline
          echo "trick-taking: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if scripted: ", scripted " & baseline else: ""), ")"
      except CatchableError as error:
        echo "trick-taking: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("tricks.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": replayStates(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "trick-taking: replay mode on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(TricksError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[bool](config.players.len)
  state.baselines = newSeq[string](config.players.len)
  for slot in 0 ..< config.players.len:
    state.baselines[slot] = "follow"
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "trick-taking: serving on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
