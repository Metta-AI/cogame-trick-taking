## Trick-taking player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default trick-taking personality), then idles until the final frame. All
## of the actual decision making happens inside the game server, which sends
## this seat's prompt to Claude on every decision the seat owns.
##
## PLAYER_SCRIPTED=<name> registers the seat as a built-in baseline instead:
## `follow` (the default) or `tracker`. Any other non-empty value means
## `follow`.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <image> --name my-trick-taker \
##     --run /bin/trick-taking-player \
##     --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

const
  Baselines = ["follow", "tracker"]
  DefaultPrompt = """
Play every hand as if your partner is reading you, because in these games a
bid and a lead are the only things you can say. Bid what your hand is
actually worth and never more; a bid nobody can trust is worse than a low
one. Count the cards: every trick, write into your notes which high cards of
each suit are still out, who failed to follow which suit (that seat can never
hold it again), and what each cog's bidding says about its hand. Lead to a
plan - draw trumps when you have length and the contract, cash a certain
winner before it can be ruffed, and probe a short suit when you want a ruff
yourself. When your partner is winning a trick, feed them your cheapest card;
when an opponent is winning, take it as cheaply as you can, or duck it
entirely if the trick costs you nothing. In Hearts, duck everything early and
track the queen of spades. In Oh Hell, treat your bid as a contract in BOTH
directions and steer to it exactly.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scriptedEnv = getEnv("PLAYER_SCRIPTED").strip()
  let scripted = scriptedEnv.len > 0
  var baseline = scriptedEnv.toLowerAscii()
  if baseline notin Baselines:
    baseline = "follow"

  proc promptFrame(): string =
    $ %*{
      "type": "prompt",
      "prompt": prompt,
      "scripted": scripted,
      "baseline": baseline
    }

  echo "trick-taking player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "trick-taking player: prompt delivered (", prompt.len, " chars",
    (if scripted: ", scripted " & baseline else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame or a truncated read,
  ## and mummy's send only queues, so the game's quit(0) can outrun the
  ## flushed `final` frame. Without this the container exits 1
  ## intermittently and hosted certification fails as `player_error`
  ## (raid 0.1.3 -> 0.1.4).
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "trick-taking player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "trick-taking player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
            " playing ", payload{"displayName"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "trick-taking player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "trick-taking player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "trick-taking player: socket closed (", error.msg, "); exiting 0"
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
