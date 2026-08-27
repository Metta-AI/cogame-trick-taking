# Tuning the scripted baselines' bidding parameters

The play side of `follow` and `tracker` is derived from the rules -- lead the
cheapest winner, duck when the partner is winning, and so on. The **bids** are
not: they carry four free numbers, and numbers like that are guesses until
something plays them against each other.

| parameter | what it does | module |
|---|---|---|
| `orderAt` | order the up-card up at this hand strength (`euchreStrength`) | euchre |
| `aloneAt` | go alone at this hand strength | euchre |
| `spadesShade` | bid this many under the counted winners | spades |
| `ohHellDrop` | do not count an off-suit ace in a suit this short (0 = off) | oh-hell |

Hearts has no bid, so it has no tunable parameter and does not appear below.

## The harness

`tools/ci/tune_baselines.nim` plays all-scripted matches. One pair of table
positions bids a **candidate** configuration, the other pair bids the
**shipped** one; nothing else differs between the two sides. Every deal is
played twice, once with the candidate on each pair, and the two are averaged,
so a seeded deal that happens to favour one pair cannot read as a parameter
effect. The score is the candidate pair's mean normalised score
(`sim.scoresOf`), where **0.5 is break-even by construction** -- which is why
the shipped row of every table below reads exactly `0.5000`. That row is the
control: if it were anything else, the comparison would be measuring seating
luck.

```
nim r -d:release --path:src tools/ci/tune_baselines.nim --matches 96
```

It is deterministic (fixed seeds) and bounded: 46 grid points x 96 deals x 2
orientations is about 8,800 matches and runs in ~7 s. `ci.yml`'s `test` job
runs it on every push, and it **exits non-zero if any grid point beats the
shipped configuration by more than `--tolerance` (default 0.005)**, so a
hand-edited threshold that the grid does not support turns CI red.

## Noise band

The same sweep was run over two independent seed sets (`--seed 17` and
`--seed 4242`, 96 deals each). Differences up to **+/-0.002** change sign
between them; everything larger reproduced with the same sign and ordering.
Read a delta under 0.002 as a tie.

## The sweep that chose the shipped values

```
grid sweep: 96 seeded deals per point (seeds 17, 1017, ...), each played twice with the candidate on either pair of positions

### euchre / follow
| parameters | mean score | win rate | vs shipped |
|---|---|---|---|
| orderAt=8 aloneAt=14 | 0.4937 | 0.510 | -0.0063 |
| orderAt=8 aloneAt=16 | 0.4948 | 0.521 | -0.0052 |
| orderAt=8 aloneAt=18 | 0.4940 | 0.516 | -0.0060 |
| orderAt=8 aloneAt=20 | 0.4935 | 0.516 | -0.0065 |
| orderAt=10 aloneAt=14 | 0.4996 | 0.536 | -0.0004 |
| orderAt=10 aloneAt=16 **(shipped)** | 0.5000 | 0.547 | +0.0000 |
| orderAt=10 aloneAt=18 | 0.4987 | 0.547 | -0.0013 |
| orderAt=10 aloneAt=20 | 0.4979 | 0.542 | -0.0021 |
| orderAt=12 aloneAt=14 | 0.4853 | 0.474 | -0.0147 |
| orderAt=12 aloneAt=16 | 0.4862 | 0.490 | -0.0138 |
| orderAt=12 aloneAt=18 | 0.4845 | 0.474 | -0.0155 |
| orderAt=12 aloneAt=20 | 0.4836 | 0.474 | -0.0164 |
| orderAt=14 aloneAt=14 | 0.4667 | 0.333 | -0.0333 |
| orderAt=14 aloneAt=16 | 0.4678 | 0.344 | -0.0322 |
| orderAt=14 aloneAt=18 | 0.4657 | 0.328 | -0.0343 |
| orderAt=14 aloneAt=20 | 0.4647 | 0.328 | -0.0353 |
best: orderAt=10 aloneAt=16 at 0.5000 (shipped: orderAt=10 aloneAt=16)

### spades / follow
| parameters | mean score | win rate | vs shipped |
|---|---|---|---|
| spadesShade=0 **(shipped)** | 0.5000 | 0.500 | +0.0000 |
| spadesShade=1 | 0.4661 | 0.214 | -0.0339 |
| spadesShade=2 | 0.4016 | 0.068 | -0.0984 |
best: spadesShade=0 at 0.5000 (shipped: spadesShade=0)

### oh-hell / follow
| parameters | mean score | win rate | vs shipped |
|---|---|---|---|
| ohHellDrop=0 **(shipped)** | 0.5000 | 0.521 | +0.0000 |
| ohHellDrop=1 | 0.4980 | 0.490 | -0.0020 |
| ohHellDrop=2 | 0.4976 | 0.443 | -0.0024 |
| ohHellDrop=3 | 0.4983 | 0.453 | -0.0017 |
best: ohHellDrop=0 at 0.5000 (shipped: ohHellDrop=0)

### euchre / tracker
| parameters | mean score | win rate | vs shipped |
|---|---|---|---|
| orderAt=8 aloneAt=14 | 0.4945 | 0.531 | -0.0055 |
| orderAt=8 aloneAt=16 | 0.4955 | 0.542 | -0.0045 |
| orderAt=8 aloneAt=18 | 0.4951 | 0.531 | -0.0049 |
| orderAt=8 aloneAt=20 | 0.4946 | 0.531 | -0.0054 |
| orderAt=10 aloneAt=14 | 0.5002 | 0.557 | +0.0002 |
| orderAt=10 aloneAt=16 **(shipped)** | 0.5000 | 0.557 | +0.0000 |
| orderAt=10 aloneAt=18 | 0.4991 | 0.562 | -0.0009 |
| orderAt=10 aloneAt=20 | 0.4983 | 0.557 | -0.0017 |
| orderAt=12 aloneAt=14 | 0.4840 | 0.474 | -0.0160 |
| orderAt=12 aloneAt=16 | 0.4840 | 0.453 | -0.0160 |
| orderAt=12 aloneAt=18 | 0.4828 | 0.453 | -0.0172 |
| orderAt=12 aloneAt=20 | 0.4820 | 0.453 | -0.0180 |
| orderAt=14 aloneAt=14 | 0.4648 | 0.333 | -0.0352 |
| orderAt=14 aloneAt=16 | 0.4647 | 0.307 | -0.0353 |
| orderAt=14 aloneAt=18 | 0.4633 | 0.292 | -0.0367 |
| orderAt=14 aloneAt=20 | 0.4623 | 0.292 | -0.0377 |
best: orderAt=10 aloneAt=14 at 0.5002 (shipped: orderAt=10 aloneAt=16)

### spades / tracker
| parameters | mean score | win rate | vs shipped |
|---|---|---|---|
| spadesShade=0 **(shipped)** | 0.5000 | 0.500 | +0.0000 |
| spadesShade=1 | 0.4640 | 0.172 | -0.0360 |
| spadesShade=2 | 0.4019 | 0.036 | -0.0981 |
best: spadesShade=0 at 0.5000 (shipped: spadesShade=0)

### oh-hell / tracker
| parameters | mean score | win rate | vs shipped |
|---|---|---|---|
| ohHellDrop=0 | 0.5018 | 0.583 | +0.0018 |
| ohHellDrop=1 | 0.5002 | 0.562 | +0.0002 |
| ohHellDrop=2 **(shipped)** | 0.5000 | 0.516 | +0.0000 |
| ohHellDrop=3 | 0.5002 | 0.516 | +0.0002 |
best: ohHellDrop=0 at 0.5018 (shipped: ohHellDrop=2)
wrote dist/tuning/sweep.json
```

## Chosen configuration

| baseline | orderAt | aloneAt | spadesShade | ohHellDrop |
|---|---|---|---|---|
| `follow` | 10 | 16 | 0 | 0 |
| `tracker` | 10 | 16 | 0 | 2 |

Pinned in `src/tricks/llm.nim` (`baselineParams`) and asserted in
`tests/test_tuning.nim`.

What the grid says, and what was done about it:

- **`orderAt = 10`.** Ordering up late is the most expensive mistake in the
  grid: 12 costs about -0.015 and 14 about -0.035, in both baselines and in
  both seed sets. 8 is also worse (-0.006): the maker's edge does not survive
  a hand that weak. `tracker` shipped at 12 before this sweep and now bids at
  10 with the rest of its counting intact.
- **`aloneAt = 16`.** Flat across 14-20 (spread 0.002, inside the noise band).
  16 is kept as the mid-point of the flat region; 14 wins by +0.0002 on one
  seed set and +0.0007 on the other, which is a tie.
- **`spadesShade = 0`.** The clearest result in the grid: shading the bid down
  by one costs -0.028 to -0.036 and by two costs -0.10, with the win rate
  falling from 50 % to 17 % and then to 6 %. Under this scoring a made
  contract is worth `10 x C` and a bag only 1, so buying safety with a lower
  contract is a bad trade. `tracker` shipped at 1 before this sweep.
- **`ohHellDrop = 2` for `tracker`, `0` for `follow`.** The whole column is
  inside the noise band (`tracker`: +0.0018 for dropping the rule on one seed
  set, +0.0014 on the other). Kept as-is: it is the rule that makes
  `tracker`'s oh-hell bid a counting bid rather than a copy of `follow`'s, and
  the grid gives no reason to remove it.

## Reproducing

```
nim r -d:release --path:src tools/ci/tune_baselines.nim --matches 96 --seed 4242
```

gives the same ordering on an independent set of deals:

```
### euchre / follow
best: orderAt=10 aloneAt=14 at 0.5000 (shipped: orderAt=10 aloneAt=16)
### spades / follow
best: spadesShade=0 at 0.5000 (shipped: spadesShade=0)
### oh-hell / follow
best: ohHellDrop=0 at 0.5000 (shipped: ohHellDrop=0)
### euchre / tracker
best: orderAt=10 aloneAt=14 at 0.5007 (shipped: orderAt=10 aloneAt=16)
### spades / tracker
best: spadesShade=0 at 0.5000 (shipped: spadesShade=0)
### oh-hell / tracker
best: ohHellDrop=0 at 0.5014 (shipped: ohHellDrop=2)
```
