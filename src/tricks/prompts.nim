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
  PromptBankVersion* = "trick-taking-rules-v1"

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
