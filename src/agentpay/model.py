"""Analytic model: the rates the experiment should find, worked out by hand.

The agents in agents.py follow fixed rules, so the expected outcome of a task can be
written down for every setting. Any measured rate outside its confidence interval
around these values is a bug in the contracts, the runner or this file, not a result.

Notation, for one setting:
    a = FAR, the judge's false-accept rate
    b = FRR, the judge's false-reject rate
    r = share of free-riding requesters
    q = share of absent workers among the faulty ones, the "no_show" share in fault_mix
    f = share of faulty workers
    k = whether a challenge pays in B (reward > cost)

Probability that a task is paid, by worker:

    worker                      A               C        B
    honest                      (1 - r)(1 - b)  1 - b    1
    faulty, submitted something (1 - r) a       a        a if k, else 1
    absent                      0               0        0

    A: an honest requester pays when its judge passes the work; a free rider never pays.
    C: the verifier pays when its judge passes the work.
    B: good work is always paid, because the arbiter rejects any challenge against it.
       Wrong work is paid when the challenger's judge passes it (a), or always when a
       challenge does not pay, because then nobody challenges.

The reported rates follow from that table:

    honest-loss rate                    1 - P(paid | honest)
    wrongful-payment rate, submitted    P(paid | faulty, submitted)
    wrongful-payment rate, all faulty   (1 - q) P(paid | faulty, submitted)   (SRS FR-11)
    wrongful payments per task          f (1 - q) P(paid | faulty, submitted)

Only the last one depends on f. The two rates are shares of faulty or honest tasks, and
no agent here changes its behaviour with the share of faulty workers.

simulate() runs the same agents without a chain, drawing in the same order as the
runner, so its counts can be compared with expected() and, for the same seed, with
the runner's results task by task.
"""

import math
from dataclasses import dataclass

from agentpay.agents import (
    FAULT_MIX,
    JudgeRates,
    draw_requester_type,
    draw_worker_type,
    is_faulty,
    outcome_of,
    plan_task,
    task_rng,
    validate_shares,
)


@dataclass(frozen=True)
class Setting:
    """One cell of the experiment grid, apart from the mechanism and the seed.

    Every field is a number or a tuple, so a Setting cannot change after it is made and
    can be used as a dictionary key, for example to group results by setting.
    """

    faulty_share: float
    rates: JudgeRates
    free_rider_share: float = 0.0
    fault_mix: tuple = FAULT_MIX  # (type, share) pairs, see agents.FAULT_MIX
    challenge_reward: float = 0.0  # B only, see agents.challenger_challenges
    challenge_cost: float = 0.0

    def __post_init__(self):
        validate_shares(self.faulty_share, self.free_rider_share, self.fault_mix)

    @property
    def challenge_pays(self) -> bool:
        return self.challenge_reward > self.challenge_cost


@dataclass(frozen=True)
class Expected:
    honest_loss: float
    wpr_submitted: float
    wpr_all_faulty: float
    wrongful_per_task: float


def expected(mechanism: str, setting: Setting) -> Expected:
    """The expected rates of one mechanism in one setting (the table above)."""
    a, b = setting.rates.far, setting.rates.frr
    r = setting.free_rider_share
    q = dict(setting.fault_mix).get("no_show", 0.0)

    if mechanism == "A":
        paid_honest = (1 - r) * (1 - b)
        paid_faulty = (1 - r) * a
    elif mechanism == "C":
        paid_honest = 1 - b
        paid_faulty = a
    elif mechanism == "B":
        paid_honest = 1.0
        paid_faulty = a if setting.challenge_pays else 1.0
    else:
        raise ValueError(f"unknown mechanism {mechanism!r}")

    wpr_all_faulty = (1 - q) * paid_faulty
    return Expected(
        honest_loss=1 - paid_honest,
        wpr_submitted=paid_faulty,
        wpr_all_faulty=wpr_all_faulty,
        wrongful_per_task=setting.faulty_share * wpr_all_faulty,
    )


def _ratio(part: int, whole: int) -> float:
    # A rate over zero tasks is undefined, for example the wrongful-payment rate at f = 0.
    return part / whole if whole else math.nan


@dataclass(frozen=True)
class Counts:
    """What one run produced, counted per task."""

    tasks: int
    honest: int
    honest_paid: int
    faulty: int
    faulty_submitted: int
    faulty_paid: int

    @property
    def honest_loss(self) -> float:
        return _ratio(self.honest - self.honest_paid, self.honest)

    @property
    def wpr_submitted(self) -> float:
        return _ratio(self.faulty_paid, self.faulty_submitted)

    @property
    def wpr_all_faulty(self) -> float:
        return _ratio(self.faulty_paid, self.faulty)

    @property
    def wrongful_per_task(self) -> float:
        return _ratio(self.faulty_paid, self.tasks)


def simulate(mechanism: str, setting: Setting, seed: int, n_tasks: int) -> Counts:
    """One run of n_tasks tasks without a chain: plan every task and settle it on paper."""
    honest = honest_paid = faulty = faulty_submitted = faulty_paid = 0
    for index in range(n_tasks):
        # Same order of draws as the runner, so the same seed gives the same tasks.
        rng = task_rng(seed, index)
        worker = draw_worker_type(rng, setting.faulty_share, setting.fault_mix)
        requester = draw_requester_type(rng, setting.free_rider_share)
        steps = plan_task(
            mechanism, worker, requester, setting.rates, rng,
            setting.challenge_reward, setting.challenge_cost,
        )
        paid = outcome_of(steps) == "paid"

        if is_faulty(worker):
            faulty += 1
            if worker != "no_show":
                faulty_submitted += 1
            if paid:
                faulty_paid += 1
        else:
            honest += 1
            if paid:
                honest_paid += 1
    return Counts(n_tasks, honest, honest_paid, faulty, faulty_submitted, faulty_paid)
