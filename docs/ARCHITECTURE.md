# Architecture — Agent-to-Agent Settlement on HSK Chain

## Problem

AI agents increasingly need to hire *other* agents (data processing,
translation, media work) and pay them without a human in the loop for every
micro-job. Handing an agent an unrestricted wallet is dangerous; routing
every payment through a human defeats autonomy. The HSP (HashKey agentic
payment protocol) answer is the **payment mandate**: a bounded, auditable
authorization — pay *this* worker, at most *this* amount, for *this* task,
before *this* deadline. This project implements that mandate model on-chain
for HSK Chain, with working Python buyer/worker/watcher agents.

## Components

```
┌──────────────┐   1. createMandate(worker, taskHash, deadline) + escrow
│  Buyer Agent │ ───────────────────────────────────────────────┐
│  (Python)    │                                                ▼
└──────┬───────┘                                        ┌───────────────┐
       │ 4. verify result hash == on-chain proof        │  AgentEscrow  │
       │ 5. releasePayment()                            │  (Solidity,   │
       │                                                │   HSK Chain)  │
┌──────┴───────┐   2. poll mandates, do the real job    └──────┬────────┘
│ Worker Agent │   3. submitDelivery(resultHash)               │ events
│  (Python)    │ ──────────────────────────────────────────────┤
└──────────────┘                                               ▼
                                              ┌────────────────────────┐
                                              │ Settlement Watcher     │
                                              │ (Python): audit log,   │
                                              │ receipts, auto-release │
                                              └────────────────────────┘
```

### 1. `AgentEscrow.sol` (Solidity 0.8.26, Foundry)

- **Mandates**: `createMandate(worker, taskHash, deadline)` escrows native
  HSK in the same call. Only the task *hash* goes on-chain; the task spec
  itself travels off-chain.
- **Spend caps (the HSP safety core)**:
  - `maxMandateAmount` — no single job can exceed it.
  - `dailySpendCap` — per-buyer, per-UTC-day ceiling, tracked in
    `spentOnDay`. A compromised or hallucinating buyer agent can lose at
    most one day's cap, and only into escrow (recoverable via refund).
  - Caps are owner-set only; agents cannot raise their own limits.
- **Verifiable delivery**: the worker submits `keccak256(result)`. The buyer
  recomputes the hash of the delivered file before releasing — payment is
  bound to the exact bytes delivered.
- **Settlement paths**:
  - Buyer confirms → `releasePayment`.
  - Buyer silent past `reviewWindow` → anyone may `autoRelease` (workers
    can't be frozen by a crashed buyer).
  - No delivery by deadline → buyer `refundExpired`.
  - Bad delivery → buyer `dispute` freezes funds; `arbiter` resolves.
- **Reputation reads**: `completedJobs` / `totalEarned` per worker, so buyer
  agents can price trust before hiring.
- Safety: checks-effects-interactions + reentrancy lock on all value paths;
  custom errors; full event trail for off-chain audit.

### 2. Python agents (`agents/`)

- **`buyer_agent.py`** — publishes the task spec off-chain, creates the
  mandate, waits for delivery, verifies the result hash, releases payment,
  and demonstrates the cap guard rejecting an over-cap mandate.
- **`worker_agent.py`** — polls for mandates assigned to it, performs a real
  job (CSV sales analysis → JSON report), delivers the file off-chain and
  the proof hash on-chain.
- **`settlement_watcher.py`** — independent observer: append-only JSONL
  audit log of every escrow event, settlement receipts, optional
  auto-release when a buyer goes silent.

### 3. Demo (`demo/`)

`demo/run_demo.sh` boots a local anvil chain, deploys the contract, starts
worker + watcher, and runs the buyer through a full hire → deliver →
verify → pay cycle, ending with the audit log. `demo_output.txt` in the
repo is a captured real run.

## Deployment targets

| Network | Chain ID | RPC | Status |
|---|---|---|---|
| Local anvil | 31337 | http://127.0.0.1:8545 | ✅ demo + tests run here |
| HSK Chain testnet | 133 | https://testnet.hsk.xyz | deploy script ready (`script/Deploy.s.sol`); RPC not reachable from the build VM on 22 Nov 2026 (empty response), so not yet deployed |
| HSK Chain mainnet | 177 | https://mainnet.hsk.xyz | ⛔ **PENDING OWNER DECISION** — requires a funded wallet; not deployed |

## Extensions (post-hackathon)

- ERC-20/USDT escrow variant (same mandate logic, `transferFrom` instead of
  `msg.value`) for stablecoin-denominated agent payments.
- EIP-712 signed mandates so a human/treasury can pre-authorize an agent's
  mandate envelope off-chain.
- Worker discovery + bidding: buyer posts an open mandate, workers bid,
  cheapest qualified (by on-chain reputation) wins.
