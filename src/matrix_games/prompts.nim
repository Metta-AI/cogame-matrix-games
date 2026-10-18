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
  PromptBankVersion* = "matrix-games-rules-v1"

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

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection, alias, variant: string): string =
  result = case selection.selectedVariant
    of pvCanonical: "You are <ALIAS>, one of eight cogs in a walled yard playing MATRIX GAMES, variant <VARIANT>.\n"
    of pvPlain: "In MATRIX GAMES, variant <VARIANT>, you play <ALIAS>, one of eight cogs in a walled yard.\n"
    of pvNumbered: "1. Game: MATRIX GAMES, variant <VARIANT>. 2. You are <ALIAS>. 3. Eight cogs play in a walled yard.\n"
    of pvQuestions: "What are you playing? MATRIX GAMES, variant <VARIANT>. Who are you? <ALIAS>, one of eight cogs in a walled yard.\n"
    of pvReordered: "Eight cogs play in a walled yard in MATRIX GAMES, variant <VARIANT>. You are <ALIAS>.\n"
    of pvHeldoutBriefing: "MATRIX GAMES briefing: variant <VARIANT>; setting, a walled yard; participants, eight cogs. Your identity is <ALIAS>.\n"
    of pvHeldoutReference: "Game record: MATRIX GAMES. Variant: <VARIANT>. Location: walled yard. Players: eight cogs. Your name: <ALIAS>.\n"
    of pvMixed: raise newException(Defect, "unresolved mixed wording")
  result = result.replace("<ALIAS>", alias).replace("<VARIANT>", variant)
