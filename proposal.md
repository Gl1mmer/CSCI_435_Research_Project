CSCI 435 Blockchain and Cryptocurrencies, Research Track Project, Stage 3
Topic: Decentralized payments and coordination for agent economies

INTRODUCTION
AI agents built on large language models (LLMs) are starting to buy services from each
other. An orchestrating agent splits a job into subtasks, hires specialised agents to
complete them, and pays them on delivery. Blockchains suit this well, because agents can
hold keys without a legal identity, smart contracts can hold payments in escrow, and very
small payments are possible [1], [2]. These payments are tiny in practice: on one x402
settlement router on Base, the median agent payment was about US$0.001 [3]. The agents on
both sides are unreliable, however. They hallucinate, can be prompt-injected, and may
never deliver [4], [5]. A settlement mechanism must therefore decide cheaply, and without
a trusted intermediary, whether delegated work deserves payment. This project measures how
well different on-chain mechanisms make that decision, and what it costs.

RELATED WORK AND RESEARCH GAP
Proposals for an agent economy call for escrow, stake and verification but do not test
them. Xu's architecture releases escrowed payment when the worker submits a proof of
completion, yet the same paper calls the verification of agents' work an unsolved oracle
problem [1]. Gong identifies bounded autonomy as the central design question and argues
for spending limits enforced at the wallet [2]. Hu and Chen let insurers stake on behalf
of agents, prove that honesty is an equilibrium when the verifier is always correct, and
leave the measurement of losses to future work [4].

Implemented systems use smart contracts to coordinate and reward multi-agent work, for
example in AI model training [6], manufacturing control [7] and economic agent frameworks
[8]. However, they were designed for cooperative participants. ClawCoin, the closest
system, settles multi-hop delegations between LLM agents atomically [9], but it addresses
the unit of account. Its escrow pays out on the worker's own receipt, and its authors note
that their token cannot resolve uncertainty about service quality. Surveys map the threats
and propose benchmarks for on-chain agents [10], [11], but they report no comparison of
settlement rules. Emerging standards define registries for posting validations of agent
work [12], but leave the settlement rule open.

Research gap. Agent-economy proposals argue that escrow, stake and verification are needed
because LLM agents are unreliable, and implemented smart-contract coordination systems
assume cooperative participants, yet no study has measured on one testbed how alternative
on-chain settlement mechanisms trade gas cost against wrongful payments and honest-party
losses when hired agents fail or misbehave.

RESEARCH QUESTION
RQ: When AI agents hire other AI agents on-chain, how do requester-approve,
verifier-attested and optimistic-stake settlement compare on wrongful payments,
honest-party losses and gas cost as the share of faulty agents grows?

SQ1 (cost): What gas does each mechanism use per settled task, and how many blocks does it take to reach finality? At dated L1 and L2 gas prices, above what task value is each mechanism's extra cost worth paying?
SQ2 (trust): How do the wrongful-payment and honest-loss rates change with the share of faulty workers (0-50%) and with verifier accuracy, when that accuracy is set to the error rates measured for a real LLM judge?
SQ3 (bounded autonomy): How much loss from a compromised orchestrator does a contract-level spending guard prevent, and at what gas overhead?
METHODOLOGY Testbed. We write Solidity contracts with Foundry and OpenZeppelin. All three mechanisms share one task life-cycle: created, accepted, submitted, then paid or refunded. Payment is in a mock ERC-20 stablecoin. Python agents built with web3.py act as the orchestrator, the workers, a verifier and challengers. Every task runs as real transactions on a local Anvil chain, so gas is measured, not modelled. Time windows are counted in blocks, which keeps runs deterministic.
Mechanisms. (A) Requester-approve, the baseline: the hiring agent approves or rejects the
work, and a worker whose requester stays silent past a deadline can claim payment. (C)
Verifier-attested: a designated verifier agent passes or fails the work and is paid a fee.
(B) Optimistic stake: the worker posts a bond, and payment is released after a challenge
window unless someone challenges it. A fixed arbiter settles challenges, and the loser's
bond is slashed. Challengers act only when they detect a fault and expect a reward larger
than their gas cost. For SQ3, a BudgetGuard contract holds the orchestrator's funds and
enforces a per-task cap, a per-epoch budget and an allowlist of escrow contracts. We
compare losses in scripted compromise scenarios with and without it.

Agents and faults. Workers are honest, lazy, plausible-but-wrong, or absent. Requesters
are honest or free-riding: a free-rider rejects good work to get its payment back. Each
judge (the requester in A, the verifier in C) has a false-accept rate and a false-reject
rate. We measure both rates for one real LLM judge (Anthropic API or a local Ollama model)
on about 150 tasks with known answers, and cache every response so the result can be
reproduced.

Metrics and design. We measure:
- the wrongful-payment rate: paid faulty tasks divided by all faulty tasks
- the honest-loss rate: unpaid honest tasks divided by all honest tasks
- gas per settled task, summed over all of that task's transactions
- blocks to finality

Gas is priced at dated L1 and L2 gas prices. The experiment crosses 3 mechanisms, 6
faulty-worker shares, 4 judge-accuracy levels (one of them the measured level) and 10
seeds, with 200 tasks per run. We report means with 95% confidence intervals. About 30
tasks per mechanism are repeated on Sepolia to confirm the gas figures and to observe real
latency.

Validation. Foundry fuzz and invariant tests check that tokens are conserved and that no
task is paid twice. Slither scans the contracts. An analytic model predicts the expected
rate for every setting, and any on-chain result outside its confidence interval is treated
as a bug.

EXPECTED RESULTS
The main result is the following figure, whose caption we fix before any data exist:

Figure 2. Wrongful-payment rate vs. share of faulty workers (0-50%) for
requester-approve (A), verifier-attested (C) and optimistic-stake (B) settlement. 200
tasks per point on a local Anvil chain with fixed seeds; mean and 95% CI over 10
seeds; verifier accuracy set to the rate measured for the LLM judge. Inset: gas per
settled task.

We expect three things:
- Requester-approve will be cheapest but will expose honest workers to free-riding
requesters.
- Verifier-attested settlement will track the judge's error rates, at the price of a
fee.
- Optimistic stake will work for valuable tasks but fail for micro-tasks, where a
challenge costs more gas than it can recover.

All results, including negative ones, are reported against the baseline.

FEASIBILITY AND PLAN
All tools are on the course list. We implement no cryptography. [Week 6 spike: we settled
one task through a toy escrow from Python on Anvil, on Windows (WSL) and macOS, using ___
gas in total. Replace this with what actually happened.]

Roles. M1 (backend) builds the agents and the LLM calibration. M2 (backend) builds the
chain client, the runner and the metrics. M3 builds and tests the contracts.
Schedule. We build and measure in Weeks 8-12, start writing in Week 11, finish the full
draft at the end of Week 13, and submit in Week 14. If mechanism B is not working by Week
10, the paper compares A and C only. If time runs short, SQ3 is dropped.

LIMITATIONS
Scripted agents with set fault rates stand in for real LLM agents. Only the judge is a
real model, and its error rates may depend on the model, prompt and scaffold [13].
Mechanism B relies on one trusted arbiter. Anvil has no network latency or mempool
competition, so latency comes only from the small Sepolia replication, and L2 costs are
estimates. Delegation is mainly one level deep.

REFERENCES

[1] M. Xu, "The Agent Economy: A Blockchain-Based Foundation for Autonomous AI Agents,"
arXiv preprint arXiv:2602.14219, Feb. 2026.
[2] H. Gong, "Agent-to-Agent Finance: Blockchain Payments and Trust Infrastructure for
Autonomous AI Agents," arXiv preprint arXiv:2607.00245, v2, Sep. 2026.
[3] Y. Shen, J. Zhang, Z. Shao, W. Luo, Y. Wang, T. Chen, L. Bao, and J. Chen, "Web3 x AI
Agents: Landscape, Integrations, and Foundational Challenges," arXiv preprint
arXiv:2508.02773, v4, Oct. 2026.
[4] B. Hu and B. Chen, "Insured Agents: A Decentralized Trust Insurance Mechanism for
Agentic Economy," arXiv preprint arXiv:2512.08737, Dec. 2025.
[5] B. Hu, Y. Liu, and H. Rong, "Trustless Autonomy: Understanding Motivations, Benefits,
and Governance Dilemmas in Self-Sovereign Decentralized AI Agents," arXiv preprint
arXiv:2505.09757, v2, Sep. 2025.
[6] L. Ouyang, Y. Yuan, and F.-Y. Wang, "Learning Markets: An AI Collaboration Framework
Based on Blockchain and Smart Contracts," IEEE Internet Things J., vol. 9, no. 16, pp.
14273-14286, Aug. 2022, doi: 10.1109/JIOT.2020.3032706.
[7] J. Leng, W. Sha, Z. Lin, J. Jing, Q. Liu, and X. Chen, "Blockchained smart contract
pyramid-driven multi-agent autonomous process control for resilient individualised
manufacturing towards Industry 5.0," Int. J. Prod. Res., vol. 61, no. 13, pp.
4302-4321, 2023, doi: 10.1080/00207543.2022.2089929.
[8] D. Minarsch, M. Favorito, S. A. Hosseini, Y. Turchenkov, and J. Ward, "Autonomous
Economic Agent Framework," in Engineering Multi-Agent Systems (Lecture Notes in
Computer Science). Springer, 2022, pp. 237-253, doi: 10.1007/978-3-030-97457-2_14.
[9] S. Li, C. Zhang, H. Yu, Y. T. Hou, and W. Lou, "ClawCoin: An Agentic AI-Native
Cryptocurrency for Decentralized Agent Economies," arXiv preprint arXiv:2604.19026,
Apr. 2026.
[10] S. Alqithami, "Autonomous Agents on Blockchains: Standards, Execution Models, and
Trust Boundaries," arXiv preprint arXiv:2601.04583, Jan. 2026.
[11] M. M. Karim, D. H. Van, S. Khan, Q. Qu, and Y. Kholodov, "AI Agents Meet Blockchain:
A Survey on Secure and Scalable Collaboration for Multi-Agents," Future Internet, vol.
17, no. 2, Art. no. 57, Feb. 2025, doi: 10.3390/fi17020057.
[12] M. De Rossi, D. Crapis, J. Ellis, and E. Reppel, "ERC-8004: Trustless Agents,"
Ethereum Request for Comments (Draft), Aug. 2025. [Online]. Available:
https://github.com/ethereum/ERCs/blob/master/ERCS/erc-8004.md (accessed Oct. 16,
2026).
[13] C. Peng, L. Wu, and Y. Zhou, "Re-Evaluating EVMBench: Are AI Agents Ready for Smart
Contract Security?," arXiv preprint arXiv:2603.10795, Mar. 2026.