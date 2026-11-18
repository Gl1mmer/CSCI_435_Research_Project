"""Behaviour of the scripted agents: workers, requesters, verifier, challenger, arbiter.

Every agent is a plain function of its type, the hidden ground truth, the judge's
error rates and a random number generator. Nothing in this file talks to the chain.
plan_task() returns the contract calls one task makes, in order, and the runner sends
them. outcome_of() reads the final outcome off such a plan, so the runner can check
that the chain agrees and the analytic model can use the same plans without a chain.

How the runner uses it, for task number `index` of a run with seed `seed`:

    rng = task_rng(seed, index)
    worker = draw_worker_type(rng, faulty_share)
    requester = draw_requester_type(rng, free_rider_share)
    steps = plan_task("C", worker, requester, JudgeRates(far=0.10, frr=0.10), rng)
    for step in steps:
        ...  # send step.function(taskId, *step.args) from the account of step.role

The three draws must happen in this order, because they share one generator.

Contract function names and their rules are in docs/DESIGN.md.
"""

import random
from dataclasses import dataclass

WORKER_TYPES = ("honest", "lazy", "plausible_wrong", "no_show")
FAULTY_TYPES = ("lazy", "plausible_wrong", "no_show")
REQUESTER_TYPES = ("honest", "free_rider")
MECHANISMS = ("A", "C", "B")

# How the faulty share is split over the three faulty types, unless the run says otherwise.
# (type, share) pairs, not a dict: the order decides which type each random draw gets,
# so two orders are two different settings, and a tuple cannot be changed by accident.
FAULT_MIX = (("lazy", 0.34), ("plausible_wrong", 0.33), ("no_show", 0.33))

# What each worker type submits. The runner turns the label into the bytes32 hash of
# that output's text. None means the worker accepts the task and never submits.
OUTPUT_OF = {
    "honest": "correct",
    "lazy": "junk",
    "plausible_wrong": "plausible_wrong",
    "no_show": None,
}

# A step that is not a transaction: the runner mines blocks until the task's current
# deadline has passed, so that a timeout function (reclaim, finalize) becomes callable.
PASS_DEADLINE = "pass_deadline"

# Final functions that always end in Paid or always end in Refunded.
# attest and resolve depend on their argument and are handled in outcome_of().
PAYS = {"approve", "claimAfterTimeout", "finalize"}
REFUNDS = {"reject", "reclaim", "verifierTimeout", "arbiterTimeout"}


@dataclass(frozen=True)
class Step:
    """One action in a task's life-cycle."""

    role: str  # requester, worker, verifier, challenger, arbiter, or runner
    function: str  # contract function name, or PASS_DEADLINE
    args: tuple = ()  # arguments after taskId; createTask's (worker, payment) come from the runner


@dataclass(frozen=True)
class JudgeRates:
    """Error rates of a judge: the requester in A, the verifier in C, the challenger in B."""

    far: float  # false-accept rate: share of wrong work the judge passes
    frr: float  # false-reject rate: share of correct work the judge fails

    def __post_init__(self):
        if not (0 <= self.far <= 1 and 0 <= self.frr <= 1):
            raise ValueError("far and frr must be between 0 and 1")


def task_rng(seed: int, index: int) -> random.Random:
    """The random number generator of one task.

    It depends only on the seed and the task's index, not on the mechanism. So task
    `index` gets the same worker, the same requester and the same judge draws under
    A, C and B, and the mechanisms are compared on identical tasks.
    This file calls only rng.random(), the one method whose output Python promises
    not to change between versions for the same seed.
    """
    return random.Random(f"{seed}-{index}")


def validate_shares(
    faulty_share: float = 0.0, free_rider_share: float = 0.0, fault_mix: tuple = FAULT_MIX
) -> None:
    """Raise an error unless both shares are between 0 and 1 and fault_mix is valid.

    A valid fault_mix is a tuple of (faulty type, share) pairs that names each type at
    most once, has no negative share, and adds up to 1.
    """
    for name, share in (("faulty_share", faulty_share), ("free_rider_share", free_rider_share)):
        if not 0 <= share <= 1:
            raise ValueError(f"{name} must be between 0 and 1")
    if not isinstance(fault_mix, tuple):
        raise TypeError("fault_mix must be a tuple of (type, share) pairs, like FAULT_MIX")
    kinds = [kind for kind, _ in fault_mix]
    if len(set(kinds)) != len(kinds) or set(kinds) - set(FAULTY_TYPES):
        raise ValueError(f"fault_mix must name each of {FAULTY_TYPES} at most once")
    if any(share < 0 for _, share in fault_mix):
        raise ValueError("fault_mix shares must not be negative")
    if abs(sum(share for _, share in fault_mix) - 1) > 1e-9:
        raise ValueError("fault_mix shares must add up to 1")


def draw_worker_type(rng: random.Random, faulty_share: float, fault_mix: tuple = FAULT_MIX) -> str:
    """Draw the worker type of one task."""
    validate_shares(faulty_share=faulty_share, fault_mix=fault_mix)

    u_faulty = rng.random()
    # Drawn for honest workers too, so every task uses the same number of draws.
    u_kind = rng.random()

    # A task that is faulty at share 0.2 is also faulty, with the same type, at 0.3.
    if u_faulty >= faulty_share:
        return "honest"
    cumulative = 0.0
    for kind, share in fault_mix:
        cumulative += share
        if u_kind < cumulative:
            return kind
    return kind  # only reached when the shares add up to slightly less than 1


def draw_requester_type(rng: random.Random, free_rider_share: float) -> str:
    """Draw the requester type of one task."""
    validate_shares(free_rider_share=free_rider_share)
    return "free_rider" if rng.random() < free_rider_share else "honest"


def judge_passes(output_correct: bool, rates: JudgeRates, rng: random.Random) -> bool:
    """A noisy judge's verdict on one submitted result. True means pass."""
    u = rng.random()
    if output_correct:
        return u >= rates.frr  # correct work fails with probability frr
    return u < rates.far  # wrong work passes with probability far


def requester_approves(requester_type: str, output_correct: bool, rates: JudgeRates, rng: random.Random) -> bool:
    """Mechanism A: does the requester approve the submitted result?"""
    if requester_type == "free_rider":
        # Rejects everything to get its money back, and keeps the result anyway.
        return False
    return judge_passes(output_correct, rates, rng)


def challenger_challenges(
    output_correct: bool, rates: JudgeRates, rng: random.Random, reward: float, cost: float
) -> bool:
    """Mechanism B: does the challenger dispute the submitted result?

    It challenges only if its judge says the work is wrong and the reward is larger
    than its cost. reward is what it gains from an upheld challenge (the worker's bond),
    cost is the gas of its challenge transaction, both in the same unit, computed by
    the runner from the bond and the gas price. The rule ignores the risk of losing
    its own bond on a false challenge.
    """
    if reward <= cost:
        return False  # cannot profit, so it does not check
    return not judge_passes(output_correct, rates, rng)


def arbiter_rules_for_worker(output_correct: bool) -> bool:
    """Mechanism B: the arbiter's ruling, True when the worker wins.

    The arbiter always knows the ground truth. This is a stated limitation.
    """
    return output_correct


def plan_task(
    mechanism: str,
    worker_type: str,
    requester_type: str,
    rates: JudgeRates,
    rng: random.Random,
    challenge_reward: float = 0.0,
    challenge_cost: float = 0.0,
) -> list:
    """The ordered list of Steps that one task goes through under one mechanism.

    challenge_reward and challenge_cost are used by mechanism B only.
    """
    if mechanism not in MECHANISMS:
        raise ValueError(f"unknown mechanism {mechanism!r}")
    if worker_type not in WORKER_TYPES:
        raise ValueError(f"unknown worker type {worker_type!r}")
    if requester_type not in REQUESTER_TYPES:
        raise ValueError(f"unknown requester type {requester_type!r}")

    steps = [Step("requester", "createTask"), Step("worker", "acceptTask")]

    output = OUTPUT_OF[worker_type]
    if output is None:
        # Absent worker: the requester takes its deposit back once the submit window
        # has passed. In B this also gives the requester the worker's bond.
        return steps + [Step("runner", PASS_DEADLINE), Step("requester", "reclaim")]

    steps.append(Step("worker", "submitResult", (output,)))
    correct = output == "correct"

    if mechanism == "A":
        if requester_approves(requester_type, correct, rates, rng):
            steps.append(Step("requester", "approve"))
        else:
            steps.append(Step("requester", "reject"))
    elif mechanism == "C":
        # The requester has no say in C, so a free rider behaves like an honest requester.
        steps.append(Step("verifier", "attest", (judge_passes(correct, rates, rng),)))
    else:
        if challenger_challenges(correct, rates, rng, challenge_reward, challenge_cost):
            steps.append(Step("challenger", "challenge"))
            steps.append(Step("arbiter", "resolve", (arbiter_rules_for_worker(correct),)))
        else:
            # Nobody challenged: after the challenge window the worker finalizes,
            # because it is the one who gets paid.
            steps.append(Step("runner", PASS_DEADLINE))
            steps.append(Step("worker", "finalize"))
    return steps


def outcome_of(steps: list) -> str:
    """'paid' or 'refunded', read from the last step of a plan."""
    last = steps[-1]
    if last.function in ("attest", "resolve"):
        return "paid" if last.args[0] else "refunded"
    if last.function in PAYS:
        return "paid"
    if last.function in REFUNDS:
        return "refunded"
    raise ValueError(f"{last.function!r} does not settle a task")


def is_faulty(worker_type: str) -> bool:
    """Ground truth: did this worker type do faulty work (or no work)?"""
    return worker_type != "honest"
