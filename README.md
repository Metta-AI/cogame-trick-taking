# Trick-Taking

**One engine, four rule modules, no talking allowed.** Euchre · Spades · Hearts · Oh Hell.

Four cogs sit at one card table. One engine deals, enforces follow-suit, decides who takes the
trick and rotates the deal; a **rule module** supplies the deck, the bidding, the trump rule, the
hand scoring and the "what your partner just told you" annotation. Nothing crosses the table but
cards: **there is no chat channel, no `say` field, no table talk of any kind.** Everything a
partner knows about your hand, it inferred from what you bid and what you led. That is the whole
game.

**A policy is just a prompt.** Every decision is made server-side: the game sends the acting
seat's policy prompt plus its own hand, the public record of the hand, its private notes and the
**precomputed legal move set** to Claude, and applies the reply. Field a policy by reusing the
published player runnable and setting `PLAYER_PROMPT`.

```bash
coworld upload-policy coworld-trick-taking:latest \
  --name my-trick-taker --run /bin/trick-taking-player \
  --secret-env PLAYER_PROMPT="<your strategy>"
```

Two scripted baselines ship in the same image and are fieldable policies in their own right:
`PLAYER_SCRIPTED=follow` and `PLAYER_SCRIPTED=tracker`. They are also the no-credentials
fallback, so an episode always completes.

## The four modules

| variant | seats | motive | hands | the catch |
| --- | --- | --- | --- | --- |
| `euchre` | 4, partnerships (positions 0&2 vs 1&3) | team zero-sum | 8 | 24 cards, bowers, stick the dealer, going alone |
| `spades` | 4, partnerships | team zero-sum | 4 | spades always trump, a bid of 0 is nil and worth ±100 |
| `hearts` | 4, individual | avoid tricks | 4 | 26 penalty points a hand, and shooting the moon flips them |
| `oh-hell` | 4, individual | predict exactly | 11 | the hook forbids the dealer the balanced bid; one over is as bad as three under |

**Partners are server-assigned and re-drawn every episode.** A seed-derived permutation
`seatOrder` maps table positions to policy slots, so a policy has a different partner from episode
to episode and can never arrange to be partnered with itself. Every results array and every event
is indexed by **slot**; only the renderer converts to table position.

## Scoring — one formula, all four modules, higher is better

Each module defines a zero-sum per-slot `net_h` per hand and a **proven swing cap**. Over the
hands actually scored:

```
net[i]    = sum of net_h[i]              # zero-sum
NORM      = sum of swingCap
scores[i] = 0.5 + net[i] / (2 * NORM)    # in [0, 1]; no clamp needed
win[i]    = (net[i] == max(net))
```

A seat that breaks even scores exactly **0.5** and the four scores sum to exactly **2.0**. The
score is unit-free, so one Elo ladder ranks all four variants equally. `results` also carries the
raw legible numbers for the endcard. Full detail in
[`docs/plans/2026-08-26-trick-taking-design.md`](docs/plans/2026-08-26-trick-taking-design.md).

## What a seat sees

Its own hand, the module's rules, the current phase's legal options, the hand number and dealer,
its partner's alias, the trump state, every bid made this hand, the current trick, every completed
trick of this hand, the known voids, the standings, its own private notes, and the precomputed
legal move set. **Not**: any other seat's cards, the kitty, the euchre discard, anyone else's
hearts pass or notes, completed hands' transcripts, the seed, the seating permutation, the `tell`
annotations, the audit, or any policy's real name.

**Spectators see everything** — all four hands, the kitty, the discard, every pass, every note,
the tells and the soft-play audit.

## Layout

| path | what |
| --- | --- |
| `src/trick_taking.nim` | entrypoint: runtime contract, seed, budget fit, live or replay server |
| `src/tricks/types.nim` | config, the event vocabulary, the `Sim` state, `truncateRunes` |
| `src/tricks/cards.nim` | card encoding, `cardCode`/`cardGlyph`/`parseCard`, `beats`, the bowers |
| `src/tricks/rules.nim` | the `RuleModule` record |
| `src/tricks/{euchre,spades,hearts,ohhell}.nim` | one rule module each |
| `src/tricks/sim.nim` | the engine: deal, phases, `legalMoves`, `applyMove`, tricks, scoring, replay |
| `src/tricks/audit.nim` | the soft-play audit, a pure function of the event log |
| `src/tricks/llm.nim` | prompts, reply parsing, the two scripted baselines |
| `src/tricks/server.nim` | the Coworld game contract |
| `src/trick_taking_player.nim` | the player runnable: deliver a prompt, idle until `final` |
| `client/` | the shared renderer and chrome, and the three live pages |
| `replay-viewer/` | the static wasm replay viewer: same Nim engine, compiled to wasm |
| `tools/build_replay_viewer.sh` | the `coworld build` hook |
| `tools/ci/` | the docker smoke, the viewer smoke, the renderer fixture, the policy set |

Adding a fifth game is **one new file, one registry line and one manifest variant**.

## Replays

Replays are a **static file plus a browser wasm viewer, never a pod**. The manifest declares
`"replay_viewer": {"bundle": "static-replay-viewer"}`; `tools/build_replay_viewer.sh` compiles
`replay-viewer/trick_taking_replay.nim` — the *same* sim module — to wasm and bundles it with
`renderer.js`, `chrome.css` and the art. Everything the viewer needs (names, policy names, config,
seed, every dealt card, the whole event log, the results) lives in the replay bytes; nothing else
is ever fetched.

## Building

The Docker build is self-contained (nimby 0.1.26, Nim 2.2.4). Locally:

```bash
nimby use 2.2.4
nimby --global sync nimby.lock
# nim.cfg pins the AUTHOR's package paths; regenerate it for this machine:
rm -f nim.cfg
for pkg in "$HOME"/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg
nim r --path:src tests/test_sim.nim
docker compose build
```

CI is the harness: `.github/workflows/ci.yml` runs every test twice (debug and `-d:release`),
builds the production image and plays one real episode of the certification fixture in raw docker,
then builds the wasm bundle and **opens it in headless Chromium** against that episode's replay,
against the committed `tools/ci/fixtures/hearts_moon.replay` worst-case fixture, and against the
renderer text-bounds fixture at 360 px, 960 px and 1440 px.

MIT licensed.
