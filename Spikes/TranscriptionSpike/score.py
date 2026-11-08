#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Scores transcription-spike output with one set of rules for every engine.

  score.py ami <words folder> <meeting> <result.json> [...]   word error rate and word timing
  score.py silence <result.json> [...]                        words invented on silence
  score.py vocab <script.txt> <terms.txt> <result.json> [...] term hits and false insertions
  score.py script <script.txt> <result.json> [...]            word error rate on the read-aloud script
  score.py absent <terms.txt> <result.json> [...]             terms in audio where nobody says any

Filler sounds are removed from both sides, because some engines drop them on purpose. That's a
choice about style, not accuracy.
"""

import json
import re
import sys
import xml.etree.ElementTree as ET
from array import array
from pathlib import Path

FILLERS = {
    "um", "umm", "uh", "uhh", "ah", "ahh", "eh", "er", "erm", "hm", "hmm", "mm", "mmm", "mhm",
    "mm-hmm", "mm-mm", "uh-huh", "uh-oh", "uh-uh", "huh", "oh", "ooh", "nah",
}
# A few British and American spellings of the same spoken word. AMI uses British forms.
SPELLINGS = {
    "colour": "color", "colours": "colors", "coloured": "colored", "centre": "center",
    "organise": "organize", "organised": "organized", "recognise": "recognize",
    "recognised": "recognized", "realise": "realize", "realised": "realized", "favourite": "favorite",
    "grey": "gray", "programme": "program", "programmes": "programs", "okay": "ok", "o_k_": "ok",
    "alright": "all right", "euros": "euro",
}
ONES = (
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
    "fifteen sixteen seventeen eighteen nineteen"
).split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def number_words(value):
    if value < 20:
        return ONES[value]
    if value < 100:
        tail = f" {ONES[value % 10]}" if value % 10 else ""
        return TENS[value // 10] + tail
    if value < 1000:
        tail = f" {number_words(value % 100)}" if value % 100 else ""
        return f"{ONES[value // 100]} hundred{tail}"
    if value < 1_000_000:
        tail = f" {number_words(value % 1000)}" if value % 1000 else ""
        return f"{number_words(value // 1000)} thousand{tail}"
    return str(value)


def normalize(text):
    """Returns the scoring tokens for one piece of text."""
    text = text.lower().replace("’", "'")
    text = re.sub(r"\$(\d+)", r"\1 dollars", text)
    text = re.sub(r"€(\d+)", r"\1 euro", text)
    text = re.sub(r"(\d+)%", r"\1 percent", text)
    text = re.sub(r"(?<=\d),(?=\d)", "", text)
    tokens = []
    for raw in re.split(r"[^a-z0-9'_-]+", text):
        token = raw.strip("'-_") if raw != "o_k_" else raw
        if not token or token in FILLERS:
            continue
        if token.isdigit():
            tokens += number_words(int(token)).split()
            continue
        # Acronyms in AMI are written like r_c_.
        if re.fullmatch(r"([a-z]_)+", raw):
            tokens.append(raw.replace("_", ""))
            continue
        tokens += SPELLINGS.get(token, token).replace("-", " ").split()
    return tokens


def load_reference(folder, meeting):
    """The human transcript as (token, start seconds), in time order, across all speakers."""
    timed = []
    for path in sorted(Path(folder).glob(f"{meeting}.*.words.xml")):
        for element in ET.parse(path).getroot():
            if not element.tag.endswith("w") or element.get("punc") == "true" or not element.text:
                continue
            if element.get("trunc") == "true":
                continue
            start = element.get("starttime")
            if start is None:
                continue
            for token in normalize(element.text):
                timed.append((token, float(start)))
    timed.sort(key=lambda item: item[1])
    return timed


def align(reference, hypothesis):
    """Levenshtein with a full backtrace. Returns (substitutions, deletions, insertions, matches)."""
    rows, columns = len(reference) + 1, len(hypothesis) + 1
    moves = [None] * rows
    previous = list(range(columns))
    moves[0] = array("B", [2] * columns)
    for row in range(1, rows):
        current = [row] + [0] * (columns - 1)
        step = array("B", [1]) + array("B", [0]) * (columns - 1)
        token = reference[row - 1]
        for column in range(1, columns):
            diagonal = previous[column - 1] + (token != hypothesis[column - 1])
            delete = previous[column] + 1
            insert = current[column - 1] + 1
            best = min(diagonal, delete, insert)
            current[column] = best
            step[column] = 0 if best == diagonal else (1 if best == delete else 2)
        moves[row] = step
        previous = current

    substitutions = deletions = insertions = 0
    matches = []
    row, column = rows - 1, columns - 1
    while row > 0 or column > 0:
        move = moves[row][column]
        if row > 0 and column > 0 and move == 0:
            if reference[row - 1] == hypothesis[column - 1]:
                matches.append((row - 1, column - 1))
            else:
                substitutions += 1
            row, column = row - 1, column - 1
        elif row > 0 and move == 1:
            deletions += 1
            row -= 1
        else:
            insertions += 1
            column -= 1
    matches.reverse()
    return substitutions, deletions, insertions, matches


def hypothesis_tokens(result):
    """Tokens with a start time where the engine gave one per word, otherwise None for the time."""
    timed = []
    for word in result["words"]:
        for token in normalize(word["text"]):
            timed.append((token, word["start"]))
    if timed:
        return timed
    return [(token, None) for token in normalize(result["text"])]


def collapse_repeats(timed):
    """Drops a word that immediately repeats, like "this this", since some engines tidy those up."""
    kept = []
    for item in timed:
        if not kept or kept[-1][0] != item[0]:
            kept.append(item)
    return kept


def score_ami(folder, meeting, paths):
    reference = load_reference(folder, meeting)
    tokens = [token for token, _ in reference]
    collapsed = [token for token, _ in collapse_repeats(reference)]
    print(f"reference: {len(tokens)} words, {len(collapsed)} with repeats collapsed")
    for path in paths:
        result = json.loads(Path(path).read_text())
        heard = [token for token, _ in collapse_repeats(hypothesis_tokens(result))]
        substitutions, deletions, insertions, _ = align(collapsed, heard)
        print(
            f"{Path(path).name}: repeats collapsed WER "
            f"{100 * (substitutions + deletions + insertions) / len(collapsed):.1f}% "
            f"(sub {substitutions}, del {deletions}, ins {insertions})"
        )
    for path in paths:
        result = json.loads(Path(path).read_text())
        timed = hypothesis_tokens(result)
        heard = [token for token, _ in timed]
        substitutions, deletions, insertions, matches = align(tokens, heard)
        errors = substitutions + deletions + insertions
        offsets = sorted(
            abs(timed[h][1] - reference[r][1]) for r, h in matches if timed[h][1] is not None
        )
        median = offsets[len(offsets) // 2] * 1000 if offsets else float("nan")
        p90 = offsets[int(len(offsets) * 0.9)] * 1000 if offsets else float("nan")
        print(
            f"{Path(path).name}: WER {100 * errors / len(tokens):.1f}% "
            f"(sub {substitutions}, del {deletions}, ins {insertions}, heard {len(heard)}), "
            f"word start offset median {median:.0f} ms, p90 {p90:.0f} ms, "
            f"prepare {result['prepareSeconds']:.1f} s, "
            f"speed {result['audioSeconds'] / max(result['transcribeSeconds'], 0.001):.1f}x, "
            f"peak {result['peakFootprintMB']:.0f} MB"
        )
        # Long words carry the meaning, and short backchannels in crosstalk matter less.
        content = [r for r, _ in enumerate(tokens) if len(tokens[r]) >= 5]
        found = {r for r, _ in matches}
        recall = sum(1 for r in content if r in found) / len(content)
        print(f"  words of 5+ letters heard correctly: {100 * recall:.1f}% of {len(content)}")


def score_silence(paths):
    for path in paths:
        result = json.loads(Path(path).read_text())
        heard = normalize(result["text"])
        minutes = result["audioSeconds"] / 60
        print(
            f"{Path(path).name}: {len(heard)} words over {minutes:.1f} min "
            f"({len(heard) / minutes:.1f}/min): {' '.join(heard[:12])}"
        )


def load_terms(path):
    """(term, variants) from lines like `Tanium = tan ium, tannium`."""
    terms = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            term, _, variants = line.partition("=")
            terms.append((term.strip(), [v.strip() for v in variants.split(",") if v.strip()]))
    return terms


def term_pattern(term):
    return r"(?<![a-z0-9])" + re.escape(term.lower()) + r"(?![a-z0-9])"


def count_term(term, text):
    return len(re.findall(term_pattern(term), text.lower()))


def apply_variants(text, terms):
    """The fixed replacement step: each listed variant becomes its term, longest variants first."""
    pairs = [(variant, term) for term, variants in terms for variant in variants]
    text = text.lower()
    for variant, term in sorted(pairs, key=lambda pair: -len(pair[0])):
        text = re.sub(term_pattern(variant), term.lower(), text)
    return text


# Ordinary words in the script that sound like terms. An engine or replacement step that forces a
# term onto these is doing harm, so they're counted separately.
CONTROLS = ["titanium", "nexus", "poem", "stick", "sister", "seam", "octave", "in tune", "mist", "service desk"]


def tally(terms, said, text):
    hits = misses = extra = 0
    missed = []
    for term, _ in terms:
        found = count_term(term, text)
        hits += min(found, said[term])
        misses += max(said[term] - found, 0)
        extra += max(found - said[term], 0)
        if found < said[term]:
            missed.append(f"{term} {found}/{said[term]}")
    return hits, misses, extra, missed


def score_vocab(script, terms_path, paths):
    terms = load_terms(terms_path)
    spoken = Path(script).read_text()
    said = {term: count_term(term, spoken) for term, _ in terms}
    total = sum(said.values())
    print(f"script says {total} term occurrences across {len(terms)} terms")
    for path in paths:
        result = json.loads(Path(path).read_text())
        for label, text in (("as heard", result["text"]), ("after replacement", apply_variants(result["text"], terms))):
            hits, misses, extra, missed = tally(terms, said, text)
            print(f"{Path(path).name} {label}: {hits}/{total} hit, {extra} extra | missed: {', '.join(missed)}")
        kept = [word for word in CONTROLS if count_term(word, result["text"])]
        print(f"  ordinary look-alikes kept: {len(kept)}/{len(CONTROLS)}, lost: {sorted(set(CONTROLS) - set(kept))}")
        print(f"  notes: {result['notes']}")


def score_script(script, paths):
    reference = normalize(Path(script).read_text())
    print(f"script: {len(reference)} words")
    for path in paths:
        result = json.loads(Path(path).read_text())
        heard = normalize(result["text"])
        substitutions, deletions, insertions, _ = align(reference, heard)
        errors = substitutions + deletions + insertions
        print(
            f"{Path(path).name}: WER {100 * errors / len(reference):.1f}% "
            f"(sub {substitutions}, del {deletions}, ins {insertions})"
        )


def score_absent(terms_path, paths):
    terms = load_terms(terms_path)
    for path in paths:
        result = json.loads(Path(path).read_text())
        found = {term: count_term(term, result["text"]) for term, _ in terms}
        found = {term: count for term, count in found.items() if count}
        print(f"{Path(path).name}: {sum(found.values())} false terms, notes {result['notes']}: {found}")


def main():
    mode = sys.argv[1]
    if mode == "ami":
        score_ami(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif mode == "silence":
        score_silence(sys.argv[2:])
    elif mode == "vocab":
        score_vocab(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif mode == "script":
        score_script(sys.argv[2], sys.argv[3:])
    elif mode == "absent":
        score_absent(sys.argv[2], sys.argv[3:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
