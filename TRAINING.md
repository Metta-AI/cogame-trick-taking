# Training

The authoritative game records private native Messages requests, responses,
all retries, actual served model and platform call identifiers when
`COGAME_SAVE_TRAJECTORY_URI` is set. Supply `COWORLD_EPISODE_ID`,
`COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION`; absent pins fail before play.
Recording finishes before results trigger player teardown.

Each accepted proposal is compared with the independently recorded engine event.
The corpus retains every seat, consumed fallback, forced action, and complete
participant outcome. Missing credentials, external timeouts, deadlines, and
engine-forced actions are fallback evidence, never teacher labels.
Public replay and live spectator events exclude private memory. Stored replay
readers retain their existing format; archived files are not rewritten.

Native calls default to explicit `COWORLD_LLM_TEMPERATURE=1`.
Use `0` for greedy evaluation. Nonfinite or out-of-range settings fail at client
construction. Checkpoint routes carry actual model, tokenizer, template identity,
and draw-time tokens/log probabilities when the serving engine provides them.
Greedy or absent probabilities remain absent and cannot qualify for policy-gradient
training. A loopback HTTP fixture does not establish Kubernetes deployment parity.

## Prompt diversity

The game-owned trick-taking-rules-v2 bank varies the seat introduction and the
briefing about hidden hands, partner communication, private memory and legal
actions. Each of the four rule modules keeps its exact card and scoring rules.
Private observations, operator guidance and the output contract stay fixed.
Canonical preserves the original system prompt byte for byte. Plain, numbered,
questions, and reordered are training wordings; heldout-briefing and
heldout-reference are evaluation only.

Runtime config and bridge reset accept promptVariant and promptSeed.
Mixed requires an explicit nonnegative prompt seed and selects one of the five
training wordings by modulo five. Selection stays fixed throughout the episode
and never consumes the simulation random generator. The default is canonical.
Bridge reset requires split=validation for held-out wording.
Private trajectory observations and bridge semantic views carry prompt_template:
bank, requested selection, resolved variant, seed, and SHA-256 hashes of the base
system/user prompts. Native attempts retain the exact sent prompt, including
retry hints.

## Language and numeric bridges

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/trick-taking-bridge tools/train_bridge.nim
python3 tools/test_language_bridge.py /tmp/trick-taking-bridge
python3 tools/test_prompt_games.py /tmp/trick-taking-bridge
python3 tools/test_train_bridge.py /tmp/trick-taking-bridge
```

Run the bridge with `coworld_manifest_template.json VARIANT --language` for the
ordinary hosted prompt, JSON extraction, reply parser, private notes, and action
execution. The `tracker` teacher uses the same acting-player view.
The default fixed numeric action catalog is a separate research interface; its
restricted actions omit free-text memory and do not establish language-policy parity.
Hidden-hand permutation tests compare the teacher and prompts across every variant.

## Complete teacher corpus

Commit source before export. Use a fresh destination outside this checkout.

```sh
nim c -d:release --path:src -o:/tmp/trick-taking-export tools/export_posttrain.nim
for variant in euchre spades hearts oh-hell; do
  /tmp/trick-taking-export "/tmp/trick-taking-${variant}" 10 1 "$variant"
done
```

The existing schema-v2 exporter retains complete private episodes and writes
train.jsonl and validation.jsonl containing accepted scripted-tracker labels.
Fallback turns remain in the episodes and do not become teacher labels. All
wordings and rule modules for the same game seed stay in the same split. Each
manifest run records its selected prompt bank, wording and independent seed.

Append PROMPT_VARIANT [PROMPT_SEED] after the variant to select wording. Mixed
selection cycles independently within training and validation, so both splits
can contain every training wording. Fixed wordings retain the supplied prompt
seed. Episode IDs and trajectory filenames include the selected wording and
prompt seed; seed-family grouping stays unchanged.
Held-out wordings are rejected before creating outputs. Files use umask 077,
episode writes are exclusive, and existing destinations are refused.

Use the current [Metta post-training workflow](https://github.com/Metta-AI/posttraining-research/tree/main/packages/metta-posttraining)
to import and independently review complete episodes, then split by seed family
before exporting selected training examples.
Runtime, training, and evaluation must use the same manifest variant,
operator prompt, model tokenizer/template, and output/context budgets. Serving a
learner through the sidecar requires a platform-owned authenticated route;
players cannot choose arbitrary checkpoint URLs. Production rollout remains separate
from local teacher/native protocol tests.

Episode IDs and trajectory filenames include requested selection, resolved wording,
and prompt seed, distinguishing explicit and mixed collections with identical text.
Scenario-family grouping remains unchanged.
