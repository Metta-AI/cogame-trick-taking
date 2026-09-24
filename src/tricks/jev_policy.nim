## Rank game-provided legal actions from a seat-private trick-taking view.

import std/[algorithm, json, os, strutils]
import curly

proc chooseAction*(observation: JsonNode): JsonNode =
  var criteria = newJObject()
  for action in observation["legalActions"]:
    criteria[$action["id"].getInt()] = action["description"]

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Trick Taking Jev policy has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $observation["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You are playing a trick-taking game. Maximize your own " &
      "final score. This seat-private observation is all you may use:\n" &
      $observation,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Rank the legal actions for your score. In a Hearts " &
        "pass, the three highest ranked cards are passed together.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len or
      answer["confidence"].getFloat() < 0 or
      answer["confidence"].getFloat() > 1:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var total = 0.0
  var ranked: seq[tuple[id: int, probability: float]]
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    ranked.add((parseInt(choice), value))
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  ranked.sort(proc(a, b: tuple[id: int, probability: float]): int =
    let byProbability = cmp(b.probability, a.probability)
    if byProbability != 0: byProbability else: cmp(a.id, b.id))
  let count = if observation["phase"].getStr() == "pass": 3 else: 1
  if ranked.len < count:
    raise newException(ValueError, "Jev choice set is too short")
  var choices = newJArray()
  for index in 0 ..< count:
    choices.add(%ranked[index].id)
  echo "Trick Taking Jev player: choices ", choices,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
  result = %*{"choices": choices}
