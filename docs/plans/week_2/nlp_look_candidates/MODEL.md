# The Custom Model — Why We Built It, What It Is, How It Works

> **For students.** This is the canonical explainer for the little neural network
> that powers `look_candidates` inside `inspect_room`. It answers three questions
> in order: **why** we had to build a custom model at all, **what** it actually
> is, and **how** we built and shipped it.
>
> The working record lives beside this file and goes deeper on every point:
> [`README.md`](README.md) (the plan), [`DATASET.md`](DATASET.md) (the corpus and
> label quality), [`RESULTS.md`](RESULTS.md) (every measurement), and
> [`JOURNAL.md`](JOURNAL.md) (the narrative). The runtime wiring is in
> [`../look_candidates_runtime.md`](../look_candidates_runtime.md). This document
> is the one to read first.

---

## TL;DR

- **The problem:** when the agent walks into a room, which nouns in the
  description are worth trying `look <noun>` on? MUD builders hide extra detail
  behind ordinary words — a *statue* you can examine, a *drain* you can reach
  into — and the game never lists them. Every other field of a room survey a
  Ruby script can read straight off the screen. This one needs judgement.
- **Why not just ask an LLM?** We did — that was the original design, at ~34s and
  3 LLM calls per room. A **41-million-parameter model we trained ourselves beats
  a paid LLM** on this task, runs in ~7ms, and costs nothing per room. That is
  the headline result, and it surprised us.
- **What it is:** a **BERT-medium token classifier** (41M params — tiny by modern
  standards) that reads the room description and scores every word for "is this
  examinable *here*?" Exported to ONNX, quantized to int8 (41MB), and run **from
  Ruby** with no Python and no LLM in the loop.
- **How we built it:** the game's own world files record every hidden
  description, so we had **12,668 rooms of free ground truth**. We turned a
  judgement problem into a supervised-learning problem, measured five approaches
  honestly, and shipped the one that won.
- **What shipped** (from [`manifest.json`](../../../../.boukensha/models/look_candidates/manifest.json)):
  precision **55.6%**, recall **55.2%**, F1 **55.4%**, speaking in **26.8%** of
  rooms at **0.42 probes/room**, **7.3ms** per room.

---

## 1. Why this had to be a model at all

`inspect_room` used to be an LLM subagent: 34 seconds and 3 model calls to survey
one room. Almost all of that work is *mechanical* — the room name, exits, mobs,
objects, and events are all printed on screen, and a Ruby script parses them for
free (see [`../scripted_room_survey.md`](../scripted_room_survey.md)).

One field refused to be scripted. `look_candidates` asks:

> Which nouns in this room's description are worth trying `look <noun>` on?

In a MUD, builders write hidden "extra-descriptions" attached to ordinary words.
Standing in Market Square, `look statue` returns a paragraph the room text never
told you was there. The game gives you no list. You have to *guess from the
prose* — and that is a genuine judgement call, not a parse.

So the real question wasn't "which model" — it was **"can a machine make this
guess well enough to be worth shipping, and if so, what is the cheapest machine
that can?"** We refused to answer from intuition and measured instead. Three of
our four confident predictions turned out to be wrong, which was the most useful
part of the exercise:

| We predicted | Reality |
|---|---|
| A learned word list is the sensible free default | **Wrong.** Barely above random once measured honestly. |
| The task is basically vocabulary, so a neural net is overkill | **Wrong.** Vocabulary is nearly useless here; only a *context-aware* model made progress. |
| Use an LLM as a "teacher" to train a cheap local model | **Wrong.** The student beat the teacher — the game's own files are better supervision than an LLM's priors. |
| Subtract neighbouring room names (they're navigation, not scenery) | **Wrong.** Rooms are often *named after* the very thing you examine next door. |

### 1.1 Why a word list can't work — the key insight

The instinct is: "just learn which words are examinable — `statue` yes, `wall`
no." That fails, and not narrowly. **Whether a word is examinable is a property
of the *room*, not the word.** Measured across the whole corpus:

| word | examinable | not examinable | "purity" |
|---|---:|---:|---:|
| `trees` | 87 | 593 | 12.8% |
| `path` | 69 | 965 | 6.7% |
| `wall` | 46 | 1,202 | **3.7%** |
| `floor` | 40 | 1,067 | 3.6% |
| `sign` | 63 | 191 | 24.8% |

Read the `wall` row: when "wall" appears in a description, it is examinable only
**3.7% of the time**. A dictionary that fires on `wall` is wrong 27 times out of
28. **89% of words that are ever examinable are also frequently not.** There is
no fixed answer to "is `wall` examinable?" — only "is `wall` examinable *in this
room*?" That single fact is why a word list fails and why we needed a model that
reads the surrounding context. (Full analysis: [`DATASET.md`](DATASET.md) §3.)

### 1.2 Why not just pay an LLM per room

That was the original design and the bar everything had to clear. We tested it
properly — same rooms, same scoring:

| approach | precision | recall | cost |
|---|---:|---:|---:|
| **Our free model** | **~56%** | ~55% | **$0** |
| A 7B open LLM (zero-shot) | 9% | 26% | $0 (local) |
| Haiku, best setup | 20% | 39% | $0.037 / 340 rooms |
| Haiku, one room per call with memory | 11% | 42% | **$4.32** at full scale |

The LLM has priors; our model has **9,860 rooms of ground truth**. On this task,
supervision beats priors. The LLM also over-fires badly — it suggests something
in ~45% of rooms when only ~15% actually have hidden scenery, because it has no
calibration for "most rooms have nothing." (Full comparison:
[`RESULTS.md`](RESULTS.md) §4c.)

> **The design flip:** we *planned* to use the LLM as a teacher and distill a
> cheap local model from it. It turned out the local model is the stronger party.
> The teacher became the fallback.

---

## 2. What the model is

A **token-classification transformer**: `google/bert_uncased_L-8_H-512_A-8`,
known as **BERT-medium** — 8 layers, hidden size 512, **~41 million parameters**.
That is tiny (BERT-base is 110M; a 7B LLM is ~170× larger) and it trains in about
two minutes on a desktop GPU.

**What "token classification" means here:** the model reads the whole room
description at once and, for *each word*, outputs a probability that the word is
examinable in *this* room. It is the same architecture used for named-entity
recognition — "label each token" — pointed at a game-specific question.

```
input:   "A large, peculiar looking statue is standing in the middle..."
             │      │        │       │  ← every word gets a score
scores:    0.02   0.01    0.04   0.91  ...
output:  ["statue"]   ← keep scores ≥ threshold, ranked, top-k
```

Because the whole sentence is in the encoder's attention window, the model can
represent "a *large statue is standing*" (scenery) differently from "to the west
*is* the alley" (navigation) — exactly the room-dependent judgement a word list
cannot make.

### 2.1 What feeds in, and what deliberately does not

The encoder sees `[CLS] <context> [SEP] <description> [SEP]`. The **context** is
the room name plus the names of the rooms the exits lead to — both of which the
runtime already has from the survey's `look` and `check(exits)` calls. Only the
**description** words carry labels; context is there to be attended to, never
scored.

> **A subtle trap we caught before shipping:** the model was originally trained
> with the room's `sector` (`CITY`, `FOREST`, `WATER_NOSWIM`, …) as context. But
> `sector` comes from the *world file* — the MUD never prints it to a player.
> Shipping that recipe would feed the runtime an empty string where training
> always had a real token: textbook **train/serve skew**. We measured the cost of
> dropping it (**nothing** — the room name already carried that signal) and
> removed it. This is the kind of bug that degrades quietly instead of crashing.
> ([`../look_candidates_runtime.md`](../look_candidates_runtime.md) §5.1.)

### 2.2 Where it runs — Ruby, no Python, no LLM

The trained weights are exported to **ONNX** and run inside the Ruby agent via the
`onnxruntime` gem (a prebuilt binary — no compiler, no Python at runtime). The
WordPiece tokenizer is ~50 lines of pure Ruby that reproduce the training
tokenization **exactly** (verified: 0 token-id mismatches, scores match Python to
1.6e-06). The runtime code is
[`week2_capable/boukensha/lib/boukensha/extractors/model.rb`](../../../../week2_capable/boukensha/lib/boukensha/extractors/model.rb).

Every inference parameter — threshold, top-k, max length, which fields form the
context — is read from `manifest.json`, never hard-coded. Weights and thresholds
are built together and drift together, so the threshold is a property of *one
build*, not of the design (see §4.3).

---

## 3. How we built the dataset (the move that made everything possible)

**The game already knows every answer.** CircleMUD/tbaMUD world files record each
hidden description explicitly as an `E` block:

```
#3014
Market Square~
   You are standing on the market square... A large, peculiar looking statue
is standing in the middle of the square...
~
30 0 1
...
E
statue~                          ← the label: "statue" is examinable here
What you see is the Midgaard Worm, stretching around the Palace of Midgaard.
~
S
```

That single observation turns a judgement problem into a **supervised** one:
**12,668 rooms with free ground truth**. And because our Docker container
bind-mounts those very files as the live MUD, the labels describe *exactly* the
game we play — no assumptions, no parity gap. This is the single most important
move in the whole project; everything after it is ordinary engineering.

Two data decisions mattered more than any modelling choice:

- **A prediction is a hit if it matches *any* alias.** Builders give each thing
  several names (`["swords weapons armor halberds whips"]` is one object, five
  aliases). Scoring per-word instead of per-thing silently deflates recall ~40%.
- **The runtime never reads world files.** Training on them is fine and is the
  entire reason a 41M model beats an LLM. But a real player has no access to
  them, so the *runtime* takes only strings the MUD prints — a hard boundary the
  code physically cannot cross ([Human note in `JOURNAL.md`]).

Full corpus notes, schema, and label-quality caveats: [`DATASET.md`](DATASET.md).

---

## 4. How we chose and trained the model

We didn't guess which approach would win — we built a **tier ladder** from
cheapest to most expensive and made each rung earn its place by beating the one
below it, honestly measured.

### 4.1 The bake-off

| Tier | Approach | Result (best F1) |
|---|---|---:|
| T0 | predict nothing / all words / learned dictionary | floor — dictionary barely above random |
| T1 | logistic regression (hand-built features) | plateaus at the dictionary |
| T2 | fastText (subword n-grams) | memorizes vocabulary, doesn't generalize |
| **T3** | **contextual transformer (BERT)** | **wins — the only tier that breaks the plateau** |
| TL | LLM (Haiku / local 7B) reference | loses to T3 |

Everything that *isn't* a contextual model — word list, hand-built features,
subword n-grams — clustered in the same narrow band. They are, for practical
purposes, the same model wearing different hats, because none of them can
represent "examinable *in this room*." Only the transformer could. Full table and
ablations: [`RESULTS.md`](RESULTS.md).

### 4.2 The two evaluation decisions that mattered most

This is the part most worth teaching: **how we measured moved the results more
than any model change did.**

- **Split by zone, not by room.** Rooms in the same zone share an author and a
  vocabulary. Testing on rooms from zones we'd trained on inflated every score by
  2–3× and made the *worst* approach look like the best. Had we not caught it,
  we'd have shipped a model that mostly recognizes places it has already read.
- **Train only on rooms a player can actually reach.** tbaMUD ships ~150 builder
  scratch zones ("Ultima Description Room") that no player can walk to — and they
  were **85% of our data**. Walking the map from the temple found the ~1,861
  reachable rooms. Training on a *sixth* of the data, but the *right* sixth, beat
  every larger model trained on everything — the scratch zones were teaching the
  wrong base rate (hidden scenery is nearly twice as common in the real world).

> **Two bugs that produced believable-but-wrong answers**, both of which would
> have shipped a false conclusion: (1) a local model scored a clean 0% because it
> spent its whole token budget on hidden "thinking" and returned empty — which
> read as "can't do the task"; (2) a bad edit scored one experiment against the
> wrong rooms, making the walkable-rooms idea (the biggest win) look like a
> failure. Silent zeros and mismatched comparisons don't announce themselves.
> Both scripts now **refuse to score** rather than quietly return nothing.

### 4.3 Why the threshold lives in the build, not the code

Retraining with a different random seed swings F1 by **±5 points** — but the
*ranking* of words stays put. In other words the model reliably knows which words
are more examinable than which; the absolute probability scale wobbles run to run.
So the decision threshold ("how confident before we speak") is a property of *one
trained artifact*, not of the design. The build pipeline trains 3 seeds, keeps the
**median** (taking the best would be cheating — selecting on the test set), and
sweeps the threshold on the kept model, writing it into `manifest.json`.

### 4.4 From weights to a shipped artifact

`build_model.rb` runs the whole pipeline end to end and is re-runnable:

```
train 3 seeds  →  keep the median  →  export ONNX (fp32 + int8)
      →  re-score BOTH through the *production Ruby extractor*, sweeping
         thresholds under a precision floor  →  write model.onnx + vocab.json
         + manifest.json
```

Two details worth calling out:

- **We re-score through the Ruby runtime, not the Python trainer.** The number
  written into the manifest is then one the shipping code can actually
  reproduce — not one from a scorer that never ships.
- **int8 quantization is chosen on its own threshold.** Quantizing shifts the
  score distribution, so an int8 model that inherited the fp32 threshold would
  *measure* worse than it is. Swept separately, int8 (41MB) came out smaller,
  faster, *and* better at the operating point we want.

The model file (41MB) is too big to commit to a 476KB repo, so the repo commits
only `manifest.json` — which carries the download URL and a **sha256** — and
`rake model:fetch` downloads and verifies it. If it's absent, `look_candidates`
degrades to an empty list with one warning; the survey still returns everything
else. (Rationale: [`../look_candidates_runtime.md`](../look_candidates_runtime.md) §9.9.)

---

## 5. What it actually buys us

The useful way to judge this isn't raw accuracy — it's **saved effort** for an
agent that's exploring anyway:

| approach | words probed / room | time / room | hidden things found |
|---|---:|---:|---:|
| try every word | 20.4 | 24.5s | 89.5% (the ceiling) |
| **our model, top 3** | **3.0** | **3.6s** | **80.4%** |
| do nothing | 0 | 0s | 0% |

**Seven times less probing for ninety percent of what's findable.** The remaining
~10% is unreachable by *anything* — scenery the room text never mentions at all
(a "red grate" in a description that never says "grate"), a hard ceiling no
text-based method can beat.

In production the model runs at the **precision-and-silence** operating point:
top-3 at threshold 0.8, speaking in only **26.8% of rooms** (close to the ~15–20%
that truly have scenery) at **0.42 probes/room** and **7.3ms**. A wrong
suggestion costs a real MUD round trip and pollutes the record the agent reasons
over; a missed one costs nothing, because the agent can always reason its way to
`look statue` when it cares.

For the whole `inspect_room` action this replaced **3 LLM calls and 34 seconds
with 0 calls and ~7ms of model** — the model is **0.25% of the latency budget**.
Total spent on API calls across the *entire* investigation: **$0.13**.

---

## 6. What's still open (good student questions)

- **How good could *anything* be?** We never measured how much of the remaining
  error is pure authorial whim — a builder's coin-flip about whether to write an
  `E` block. Until we do, we can't tell "our model is mediocre" from "the task is
  unpredictable." It's the cheapest remaining experiment and should come first.
- **Would a stronger LLM help?** We tested Haiku (the cheap tier) and a local 7B.
  Sonnet/Opus is untested (~$0.11 for a full run). Our model would still have to
  be *beaten* to change the recommendation.
- **Would combining approaches win?** Our model is precise; the LLM catches more.
  If they find *different* things, an ensemble could beat either.

---

## 7. Key takeaway

> The game's own world files were better teachers than a paid language model — and
> deciding **what to measure**, and **which data to throw away**, mattered far
> more than how big a model we trained.

A 41M-parameter model, trained on free ground truth the game shipped with itself,
running in Ruby in ~7ms, beats a paid LLM on the one field of room-survey that
needs judgement. That is the whole lesson: reach for the data before you reach
for the biggest model.
