# HSK Horizon — Agent-to-Agent Settlement (A2A Escrow)

**HSK Chain Horizon Hackathon · Seoul — Track 2: Agent Payments & A2A Settlement (HSP)**

A working agent-to-agent payment system for HSK Chain: a **buyer AI agent**
hires a **worker AI agent** under an HSP-style **payment mandate** — bounded
amount, named worker, task hash, deadline — with funds locked in a Solidity
escrow contract and released only against **verifiable delivery** (the
on-chain hash of the delivered result). A third **settlement watcher** agent
keeps an independent audit log and can auto-release payment when a buyer
goes silent, so workers are never frozen by a crashed counterparty.

Built by **Emilio Tecnologías** (solo builder, Miami) — 22–23 Nov 2026.

## What's real (and what isn't)

- ✅ **Real**: `AgentEscrow.sol` compiles under Foundry/solc 0.8.26 and
  passes **16 unit + fuzz tests**. The Python agents run a full
  hire → deliver → verify → pay cycle against a local anvil chain
  (`demo/run_demo.sh`); `demo/demo_output.txt` is a captured real run and
  `demo-video.mp4` is rendered from that real terminal output.
- ✅ **Real work**: the worker agent performs an actual data-processing job
  (CSV sales analysis → JSON report) — the result file's keccak256 hash is
  the on-chain delivery proof, verified by the buyer before payment.
- ⚠️ **Not deployed to HSK testnet/mainnet yet**: deploy scripts are ready
  (`script/Deploy.s.sol`), but the HSK testnet RPC did not respond from the
  build environment and mainnet deployment needs a funded wallet — that is
  a pending owner decision (see below). All demo keys are the public
  anvil dev keys; no real funds anywhere.

## How it works

1. **Buyer agent** publishes a task spec off-chain and calls
   `createMandate(worker, taskHash, deadline)` with payment escrowed.
   The contract enforces a **per-mandate cap** and a **per-buyer daily
   spend cap** — the HSP mandate safety model.
2. **Worker agent** sees the mandate, does the job, writes the result
   off-chain and submits `submitDelivery(keccak256(result))`.
3. **Buyer** recomputes the hash of the delivered file; if it matches the
   on-chain proof, it calls `releasePayment`.
4. Fallbacks: buyer silent past the review window → `autoRelease` by
   anyone (the watcher does this); no delivery by deadline → buyer refund;
   bad delivery → dispute + arbiter resolution.
5. **Watcher** logs every event to an append-only audit trail; worker
   reputation (`completedJobs`, `totalEarned`) is readable on-chain.

Full design: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## Quick start

Requirements: [Foundry](https://getfoundry.sh) (`forge`, `anvil`), Python 3.10+.

```bash
# 1. Contracts: build + test
forge install foundry-rs/forge-std --no-git
forge test -v            # 16 tests

# 2. Agents: one-time env
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

# 3. Full local end-to-end demo (anvil + deploy + 3 agents)
bash demo/run_demo.sh
```

Expected tail of the demo:

```
[buyer] verified ✓ result hash matches. Worker report: 12 rows, revenue=$3449.94, top product=Wireless Earbuds
[buyer] payment released tx=60af0cf95d2da4eff6…
[buyer] balances now: buyer=9999.946623 HSK  worker=10000.049905 HSK  escrow=0.000000 HSK
[buyer] correctly rejected by contract caps ✓
```

## Deploying to HSK Chain

```bash
# HSK testnet (chain 133) — needs testnet HSK from the faucet
forge script script/Deploy.s.sol --rpc-url https://testnet.hsk.xyz \
  --private-key $DEPLOYER_KEY --broadcast

# HSK mainnet (chain 177) — ⚠️ only with the project owner's funded wallet
forge script script/Deploy.s.sol --rpc-url https://mainnet.hsk.xyz \
  --private-key $DEPLOYER_KEY --broadcast
```

Then point the agents at it with `RPC_URL=<rpc>` and funded agent keys
(replace the anvil dev keys in `agents/common.py` via your own key store —
never commit real keys).

## Repo layout

```
src/AgentEscrow.sol        escrow + mandates + spend caps + disputes
test/AgentEscrow.t.sol     16 Foundry tests (incl. fuzz)
script/Deploy.s.sol        deploy script (env-configurable caps)
agents/buyer_agent.py      hires, verifies, pays
agents/worker_agent.py     does the job, submits delivery proof
agents/settlement_watcher.py  audit log + auto-release
agents/common.py           shared config (public anvil dev keys only)
demo/run_demo.sh           one-command local end-to-end demo
demo/deploy.py             python deploy helper used by the demo
docs/ARCHITECTURE.md       design + deployment status
SUBMISSION.md              DoraHacks submission text
```

## AI-assisted build disclosure

This project was built with AI assistance (Muse Spark) under the
direction of Emilio Tecnologías during the hackathon window
(22–23 Nov 2026). All code was compiled, tested and executed locally;
claims in this README reflect those verified runs.

## License

MIT
