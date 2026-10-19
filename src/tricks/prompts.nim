## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "trick-taking-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  result = selection.selectionMetadata()
  result["system_sha256"] = %sha256(system).toHex
  result["user_sha256"] = %sha256(user).toHex

proc introduction*(selection: PromptSelection, name, moduleName: string): string =
  case selection.selectedVariant
  of pvCanonical:
    "You are " & name & ", a cog at a four-seat card table playing " & moduleName & "."
  of pvPlain:
    "Four cogs sit at this card table to play " & moduleName & ". Your cog is " & name & "."
  of pvNumbered:
    "Card table: four seats. Game: " & moduleName & ". Your cog: " & name & "."
  of pvQuestions:
    "What is the game? " & moduleName & ". How many seats? Four. Which cog are you? " & name & "."
  of pvReordered:
    "At this four-seat card table, the game is " & moduleName & ". You play the cog " & name & "."
  of pvHeldoutBriefing:
    "Your table briefing: four cogs are playing " & moduleName & ". You have the role of " & name & "."
  of pvHeldoutReference:
    "Table reference: seats: four; game: " & moduleName & "; your cog identity: " & name & "."
  of pvMixed:
    raise newException(Defect, "mixed selection must resolve to a wording")

proc tableProtocol*(selection: PromptSelection): string =
  ## Game-module rules and the JSON contract are invariant; vary the player's briefing.
  case selection.selectedVariant
  of pvCanonical:
    """

- You never see another cog's cards. Everything you know about them, you
  inferred from what they bid and what they played.
- THERE IS NO TALKING AT THIS TABLE. No chat, no signals, no side deals. In
  the partnership games the ONLY thing you can tell your partner is which
  card you play and what you bid - so bid and lead as if your partner is
  reading you, because they are.
- Your notes are private to you and are handed back to you before every
  decision. Keep your card count, the voids you have spotted, and your read
  on each cog in them.
- Pick exactly one option from the legal list you are given. An illegal
  answer is replaced by a house baseline move, which is never what you want.

"""
  of pvPlain:
    """

You cannot inspect anyone else's cards. Infer their hands from their bids
and card plays. There is no table talk: chat, signals and side deals are
forbidden. In partnership games, your bids and played cards are your only
messages to your partner. Choose bids and leads with their interpretation
in mind.

Your notes are private and return before each decision. Use them to track
cards, observed voids and your assessment of each cog. Choose exactly one
of the listed legal options. An illegal reply gives control of that move
to the house baseline, so avoid it.

"""
  of pvNumbered:
    """

Decision checklist:
1. Select exactly one option from the supplied legal list. If your reply
   is illegal, a house baseline move replaces it; avoid that substitution.
2. Reason about other hands only from bids and played cards. Their cards
   are never visible to you.
3. Do not chat, signal or make side deals. At partnership tables, only
   bids and card plays communicate with your partner. Bid and lead with
   the expectation that your partner interprets those choices.
4. Maintain your private notes. They are returned before every decision;
   record your card count, observed voids and impressions of each cog.

"""
  of pvQuestions:
    """

What information reveals other hands? Only what you infer from their bids
and plays; you never see another cog's cards.
Can you talk to your partner? No. There is no chat, signalling or side
dealing. In partnership games your partner can read only your bids and
played cards, so think about what your bids and leads convey.
What carries your reasoning forward? Your own private notes, returned
before each decision. Preserve card counts, spotted voids and reads on
the other cogs there.
Which reply is valid? Exactly one option from the provided legal list.
An illegal answer is replaced by a house baseline move; avoid giving up
your choice that way.

"""
  of pvReordered:
    """

Keep card counts, observed voids and your reading of each cog in your notes.
Only you receive those notes, and they return before every decision.
At each decision, choose exactly one listed legal option: an illegal answer
causes an unwanted substitution by the house baseline.

No cog reveals its cards to you. Your knowledge of other hands comes from
interpreting bids and card plays. There is no chat, signalling or side
dealing at this table. In partnership games the only information you can
send your partner is your bid or played card. Make bids and leads knowing
that your partner will interpret them.

"""
  of pvHeldoutBriefing:
    """

Treat the public bidding and play record as your evidence about opponents'
hands: their cards are hidden from you throughout. The table permits no
conversation, signals or side agreements. If this is a partnership game,
your partner learns from your bidding and card choices alone. Account for
that when deciding what to bid or lead.

Carry your analysis in the notes returned to you at every decision; nobody
else receives them. Useful contents include the card count, known voids
and your assessment of each participant. Submit one choice from the legal
options supplied. Outside that list, the house baseline chooses your move
instead, an outcome you should avoid.

"""
  of pvHeldoutReference:
    """

Information boundary: other players' cards are never shown. Deductions
about them must come from observed bids and plays.
Communication boundary: no chat, signals or side deals. Partnership play
transmits information solely through bids and played cards. Your partner
will read those choices; factor that into bidding and leading.
Memory: notes belong to you alone and are supplied again before each
decision. Store card counts, identified voids and your reads on each cog.
Action boundary: choose one and only one supplied legal option. An illegal
answer triggers a house-baseline replacement move, which you should avoid.

"""
  of pvMixed:
    raise newException(Defect, "mixed selection must resolve to a wording")
