# Metta post-training data

The native simulator and published `tracker` policy export supervised examples
for all four certified Trick-Taking variants:

```sh
nimby sync nimby.lock
for variant in euchre spades hearts oh-hell; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/trick-taking-${variant}" 10 1 "$variant"
done
```

Each run reads the variant configuration from the Coworld manifest, adds the
per-seat tokens supplied by the hosted platform, and plays complete seeded
matches without spectator delays. At each decision, it records the acting
seat's hosted system and user prompts and a `tracker` move accepted by the
game's reply parser. The parsed move advances the simulation. Whole matches
stay in one split. The output manifest records source revision, variant,
scores, hands scored, and row counts. Existing output directories are never
overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/trick-taking-euchre \
  --output /tmp/trick-taking-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete matches yielded 1,560 training and 394 validation examples for
Euchre; 1,792 and 448 for Spades; 1,760 and 440 for Hearts; and 1,504 and 376
for Oh Hell. All 8,274 examples fit the Qwen2.5-0.5B-Instruct tokenizer in
4,096 tokens; the maximum was 1,414. These examples distill the scripted
teacher; they do not establish stronger league play. One CPU optimizer step
per variant with a local tiny model included every example and reduced heldout
loss in each run, verifying the Metta post-training path.
