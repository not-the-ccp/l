# Lace keymap dogfood experiment

This experiment collects command-level evidence before Lace chooses a default modal keymap. It is not a typing-speed benchmark and it does not assume that Vim's `hjkl` placement is optimal.

The fixed tasks provide only a starting file and required final file. Use the editing operations you would naturally choose. Do not deliberately optimize for keystroke count.

## What is recorded

`vim_logger.vim` uses Vim's `KeyInputPre` event. It records:

- the current mode;
- the actual typed key and the post-mapping key;
- event timing;
- cursor line/column before the key is processed;
- buffer `changedtick`;
- mode transitions and resulting command sequences.

Insert/Replace/command-line text is redacted to `<text>` by default. The file contents are never recorded by the logger. Normal/Visual/operator-pending keys are retained because those are the data needed to study command frequency, runs, bigrams, trigrams, mappings, and movement behavior.

Set `LACE_KEYLOG_REDACT=0` only for synthetic fixtures if literal Insert/command-line input is useful for debugging the logger.

## Run tasks

From the repository root:

```sh
python3 experiments/lace-keymap/run_task.py 01-scope-refactor --clean
python3 experiments/lace-keymap/run_task.py 02-column-prefix --clean
python3 experiments/lace-keymap/run_task.py 03-move-function --clean
python3 experiments/lace-keymap/run_task.py 04-expression-surgery --clean
python3 experiments/lace-keymap/run_task.py 05-sparse-repeat --clean
```

`--clean` runs stock Vim without user configuration, plugins, swap, or viminfo. This gives a comparable baseline.

Then repeat the tasks without `--clean` using the Vim configuration you actually work with. That second pass answers a different question: which higher-level facilities do experienced users naturally choose when they are available?

The runner copies each fixture into a temporary directory, launches Vim, records telemetry, and compares the saved file byte-for-byte with the expected result.

Analyze one or more logs with:

```sh
python3 experiments/lace-keymap/analyze.py experiments/lace-keymap/logs/*.jsonl
```

The analyzer reports operational key frequencies, bigrams, trigrams, repeated-key runs, mode transitions, and observed cursor movement following each operational key.

## Tasks

### 01-scope-refactor

Rename two scope-local variables that currently have the same name to two different names. A whole-file substitution is therefore incorrect. This exercises search/navigation, word operations, local repetition, and potentially semantic rename if a configured editor supplies it.

### 02-column-prefix

Prefix twelve aligned numeric literals with `0x`. This intentionally makes Vim's Visual-block insertion a natural solution, but any correct solution is allowed. It is useful for studying repeated vertical movement and block-edit behavior.

### 03-move-function

Move a complete helper function above its first caller without otherwise changing the file. This exercises larger text objects/ranges, vertical navigation, delete/yank/paste, and search-based navigation.

### 04-expression-surgery

Swap two nested call arguments and then swap two outer arguments. This stresses punctuation-aware movement, text objects, character-find motions, and small-range edits.

### 05-sparse-repeat

Apply the same wrapping edit to six similar lines while leaving the interleaved lines alone. This exercises search-driven repetition, `.`-style repeat, macros, global commands, or equivalent structured operations.

## How the data will be used

The first purpose is to build a command-transition corpus rather than guess one. In particular, movement keys should be evaluated using real runs and n-grams. Four directional commands do not automatically deserve four adjacent prime keys: repeated `down` may matter far more than `down -> up`, and semantic motions may dominate single-cell horizontal motion.

Once Lace has a headless command model, the same tasks will be implemented against multiple candidate Lace grammars and QWERTY/Dvorak presets. We can then compare:

- command count;
- corrections/undo after a mistaken range;
- repeated-finger and same-finger patterns;
- finger travel and weak-finger load;
- rolls, redirects, and hand alternation;
- mode churn;
- repeated directional runs;
- how often users fall back to search or semantic navigation.

Ergonomic scoring will remain parameterized. Models such as Carpalx/Oxeylyzer are useful for identifying bad patterns, but their subjective weights are not treated as ground truth. The recorded command corpus and actual dogfooding remain the deciding evidence.

## Free dogfooding

Fixed tasks are intentionally small. They do not replace real work.

For longer sessions, source `vim_logger.vim` manually while editing L normally:

```sh
LACE_KEYLOG=/tmp/lace-real-work.jsonl \
LACE_KEYLOG_TASK=real-l-work \
vim -S experiments/lace-keymap/vim_logger.vim path/to/file.l
```

A useful initial corpus is several sessions of at least normal compiler/library/LSP work, not contrived navigation drills. Keep each participant's keyboard layout and physical keyboard description alongside the resulting log; those are required to interpret ergonomic costs later.
