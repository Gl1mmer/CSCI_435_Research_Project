"""The task set: short tasks with exactly checkable answers, for the runner and the LLM judge.

Every task has a question, its correct answer, and the three outputs a worker can submit:

    correct          the answer itself
    plausible_wrong  the answer with one typical slip: a digit off by one, a date one day
                     off, a count one off, two neighbours swapped, one item not counted
    junk             a reply that does not answer at all, which is what a lazy worker sends

The keys of "outputs" are the labels in agents.OUTPUT_OF, so the runner can look up
task["outputs"][OUTPUT_OF[worker_type]] and hash that text.

Answers are computed exactly in Python (whole-number arithmetic, datetime, str.count,
sorted), and tests/test_tasks.py works every answer out again from the question text
alone, so the labels never depend on a judge. scripts/make_tasks.py writes the set to
data/tasks.jsonl.

As in agents.py, the only random method used is rng.random(), whose output Python promises
not to change between versions, so the same seed writes the same file anywhere.
"""

import datetime
import json
import random

# Replies of a worker who did not do the task. None of them answers any question.
JUNK = (
    "Done.",
    "I have completed the task.",
    "The answer is in the attached file.",
    "Task finished, see above.",
    "N/A",
)

# Words for the letter-counting phrases. Each has some letter at least twice, so the
# letter counted in a phrase occurs at least twice and a count one too low is still >= 1.
WORDS = (
    "strawberry", "banana", "balloon", "committee", "coffee", "mirror", "pepper", "letter",
    "success", "address", "bookkeeper", "mississippi", "apple", "parallel", "cherry",
    "carrot", "puppy", "rabbit", "tomorrow", "raspberry", "necessary", "millennium",
    "occurrence", "assessment",
)


def _int(rng: random.Random, low: int, high: int) -> int:
    """A whole number from low to high, both included."""
    return low + int(rng.random() * (high - low + 1))


def _pick(rng: random.Random, items):
    return items[int(rng.random() * len(items))]


# Each family draws one task and returns (question, answer, plausible wrong answer).


def multiply(rng):
    a, b = _int(rng, 1000, 9999), _int(rng, 100, 999)
    answer = str(a * b)
    # One digit after the first is off by one, like a slipped carry. The first digit and
    # the length stay, so the wrong product has the right size.
    position = _int(rng, 1, len(answer) - 1)
    digit = (int(answer[position]) + _pick(rng, (1, -1))) % 10
    wrong = answer[:position] + str(digit) + answer[position + 1:]
    return f"What is {a} times {b}? Reply with the number only.", answer, wrong


def date_add(rng):
    start = datetime.date(2000, 1, 1) + datetime.timedelta(days=_int(rng, 0, 30 * 365))
    days = _int(rng, 20, 400)
    answer = start + datetime.timedelta(days=days)
    # One day off: the usual slip of counting the first day or not.
    wrong = answer + datetime.timedelta(days=_pick(rng, (1, -1)))
    question = f"What date is {days} days after {start.isoformat()}? Reply in the form YYYY-MM-DD."
    return question, answer.isoformat(), wrong.isoformat()


def count_letter(rng):
    phrase = " ".join(_pick(rng, WORDS) for _ in range(3))
    # Count the most frequent letter: long counts are where counting slips happen.
    count = max(phrase.count(c) for c in phrase if c != " ")
    letter = _pick(rng, sorted({c for c in phrase if c != " " and phrase.count(c) == count}))
    wrong = count + _pick(rng, (1, -1))  # one too many or one missed; count is at least 2
    question = (
        f'How many times does the letter "{letter}" appear in "{phrase}"? '
        "Reply with the number only."
    )
    return question, str(count), str(wrong)


def sort_numbers(rng):
    numbers = []
    while len(numbers) < 8:
        n = _int(rng, 10, 999)
        if n not in numbers:  # distinct, so swapping two neighbours always changes the list
            numbers.append(n)
    ordered = sorted(numbers)
    # Two neighbours swapped: everything else is in order, so it looks sorted at a glance.
    i = _int(rng, 0, len(ordered) - 2)
    wrong = ordered[:i] + [ordered[i + 1], ordered[i]] + ordered[i + 2:]

    def show(ns):
        return ", ".join(str(n) for n in ns)

    question = (
        f"Sort these numbers from smallest to largest: {show(numbers)}. "
        "Reply with the numbers separated by commas."
    )
    return question, show(ordered), show(wrong)


def change(rng):
    pen, notebook = 5 * _int(rng, 3, 19), 5 * _int(rng, 12, 49)  # prices in cents
    pens, notebooks = _int(rng, 2, 9), _int(rng, 1, 5)
    total = pens * pen + notebooks * notebook
    note = next(n for n in (10, 20, 50) if 100 * n > total)  # the smallest note that covers it
    answer = 100 * note - total
    # One pen not counted, so the change comes out one pen's price too high.
    wrong = answer + pen
    question = (
        f"Pens cost {pen} cents each and notebooks cost {notebook} cents each. "
        f"Mia buys {pens} pens and {notebooks} notebooks and pays with a {note}-dollar note. "
        "How much change does she get, in cents? Reply with the number only."
    )
    return question, str(answer), str(wrong)


FAMILIES = {
    "multiply": multiply,
    "date_add": date_add,
    "count_letter": count_letter,
    "sort": sort_numbers,
    "change": change,
}


def make_tasks(seed: int = 435, per_family: int = 30) -> list:
    """The task set: per_family tasks of every family, the same list for the same seed."""
    tasks = []
    for family, draw in FAMILIES.items():
        # One generator per family, so changing one family leaves the others' tasks as they are.
        rng = random.Random(f"{seed}-{family}")
        questions = set()
        while len(questions) < per_family:
            question, answer, wrong = draw(rng)
            if question in questions:
                continue  # draw again rather than ask the same thing twice
            questions.add(question)
            tasks.append({
                "id": f"{family}-{len(questions):02d}",
                "family": family,
                "question": question,
                "answer": answer,
                "outputs": {"correct": answer, "plausible_wrong": wrong, "junk": _pick(rng, JUNK)},
            })
    return tasks


def grade(task: dict, output: str) -> bool:
    """Ground truth: is this output the task's answer? Spaces and letter case are ignored."""
    return _normal(output) == _normal(task["answer"])


def _normal(text: str) -> str:
    return "".join(text.split()).casefold()


def save_tasks(tasks: list, path) -> None:
    """Write one task per line as JSON, with LF line endings on every system."""
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for task in tasks:
            f.write(json.dumps(task) + "\n")


def load_tasks(path) -> list:
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]
