"""Build a mixed calibration corpus for future-attention labelling.

Fiction alone (Gutenberg) never shows the donor a "fact stated early, queried
later" pattern, so a salience head trained on it has no notion of a token whose
demand arrives thousands of tokens later. This mixes fiction with synthetic
documents that contain such long-range dependencies (facts, then questions),
so the labels cover the phenomenon the notebook policy must anticipate.

No task labels are used - only the donor's own attention becomes supervision.
"""
import argparse
import os
import random

FACT_TEMPLATES = [
    "The access code for the {place} is {num}.",
    "{name}'s locker number is {num}.",
    "The shipment from {place} weighed {num} kilograms.",
    "Record {num} was filed by {name} last spring.",
    "The reservoir near {place} holds {num} litres.",
    "{name} was assigned badge {num} on arrival.",
]
QUESTION_TEMPLATES = [
    "Question: what is the access code for the {place}? Answer: {num}.",
    "Question: what is {name}'s locker number? Answer: {num}.",
    "Question: how much did the shipment from {place} weigh? Answer: {num}.",
    "Question: who filed record {num}? Answer: {name}.",
    "Question: how much does the reservoir near {place} hold? Answer: {num}.",
    "Question: which badge was {name} given? Answer: {num}.",
]
PLACES = ["north gate", "harbour office", "old mill", "west depot", "station",
          "customs house", "lighthouse", "granary", "east wing", "dockyard"]
NAMES = ["Marta", "Ivan", "Clara", "Tobias", "Nadia", "Emil", "Rosa", "Piotr",
         "Selma", "Hugo"]
PROSE = [
    "The morning fog rolled in from the water and softened every outline along "
    "the quay. ",
    "Carts rattled over the cobbles while the gulls argued above the rooftops. ",
    "A clerk counted crates twice, then wrote the total in a narrow ledger. ",
    "Rain had washed the steps clean and the air smelled of wet stone and rope. ",
    "Lamps were lit early that week because the days had grown short and grey. ",
    "Somebody was whistling in the corridor, badly, and nobody asked them to stop. ",
]


def make_doc(rng, gap_sentences=(40, 160), n_facts=3):
    """One document: facts stated early, queried after a long stretch of prose."""
    idx = rng.sample(range(len(FACT_TEMPLATES)), n_facts)
    slots = [{"place": rng.choice(PLACES), "name": rng.choice(NAMES),
              "num": str(rng.randint(1000, 99999))} for _ in idx]
    parts = []
    for i, s in zip(idx, slots):
        parts.append(FACT_TEMPLATES[i].format(**s) + " ")
        parts.extend(rng.choice(PROSE) for _ in range(rng.randint(3, 10)))
    for _ in range(rng.randint(*gap_sentences)):
        parts.append(rng.choice(PROSE))
    order = list(range(n_facts))
    rng.shuffle(order)
    for j in order:
        parts.append(QUESTION_TEMPLATES[idx[j]].format(**slots[j]) + " ")
        parts.extend(rng.choice(PROSE) for _ in range(rng.randint(2, 8)))
    return "".join(parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fiction", default=r"D:\MemeX\data\calibration.txt")
    ap.add_argument("--out", default=r"D:\MemeX\data\corpus_mixed.txt")
    ap.add_argument("--synth-chars", type=int, default=1_200_000)
    ap.add_argument("--fiction-chars", type=int, default=1_200_000)
    ap.add_argument("--seed", type=int, default=3)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    # Fiction is optional: an offline runner (Kaggle kernel without internet)
    # can build a purely synthetic corpus, which still contains the long-range
    # fact-then-question structure the labelling needs.
    if args.fiction and os.path.exists(args.fiction):
        with open(args.fiction, encoding="utf-8", errors="ignore") as f:
            fiction = f.read()[: args.fiction_chars]
    else:
        print("fiction не найдена — корпус будет целиком синтетическим")
        fiction = ""

    synth, total = [], 0
    while total < args.synth_chars:
        d = make_doc(rng)
        synth.append(d)
        total += len(d)

    # interleave in blocks so each 1024-token chunk sees a mix
    blocks, fpos, spos = [], 0, 0
    fic_block, syn_block = 12_000, 12_000
    while fpos < len(fiction) or spos < len(synth):
        if fpos < len(fiction):
            blocks.append(fiction[fpos : fpos + fic_block])
            fpos += fic_block
        chars = 0
        while spos < len(synth) and chars < syn_block:
            blocks.append(synth[spos])
            chars += len(synth[spos])
            spos += 1
    text = "\n\n".join(blocks)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"wrote {len(text)} chars ({total} synthetic, {len(fiction)} fiction)")


if __name__ == "__main__":
    main()
