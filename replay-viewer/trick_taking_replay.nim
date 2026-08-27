## Trick-taking static replay viewer, wasm side.
##
## JS hands the raw replay bytes to tt_load_replay; this module parses them
## with the SAME sim code the game server runs, re-derives the per-event
## table states, and exposes the enriched payload (identical shape to the
## game's /replay websocket message) for the shared renderer.js to draw.

import
  std/json,
  tricks/sim

var
  payload: string
  lastError: string

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc ttLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "tt_load_replay", cdecl.} =
  try:
    lastError = ""
    let replay = parseJson(bytesFromPointer(data, int(length)))
    let config = configFromReplay(replay)
    var events: seq[GameEvent]
    for node in replay["events"]:
      events.add(eventFromJson(node))
    payload = $ %*{
      "type": "replay",
      "protocol": replay{"protocol"}.getStr("tricks.replay.v1"),
      "names": replay["names"],
      "policyNames": replay{"policyNames"},
      "config": replay["config"],
      "events": replay["events"],
      "results": replay{"results"},
      "states": replayStates(config, events)
    }
    return 1
  except CatchableError as error:
    lastError = error.msg
    return 0

proc ttPayloadPointer(): ptr uint8 {.exportc: "tt_payload_ptr", cdecl.} =
  if payload.len == 0:
    nil
  else:
    cast[ptr uint8](payload[0].addr)

proc ttPayloadLength(): cint {.exportc: "tt_payload_len", cdecl.} =
  cint(payload.len)

proc ttErrorPointer(): ptr uint8 {.exportc: "tt_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc ttErrorLength(): cint {.exportc: "tt_error_len", cdecl.} =
  cint(lastError.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main would run module-global destructors on return,
  ## freeing `payload` and friends while JS keeps calling into the module.
  ## Exiting with a live runtime skips the destructor epilogue so globals
  ## stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
