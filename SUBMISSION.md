# DoraHacks Submission — HSK Chain Horizon Hackathon · Seoul

**Track:** 2 — Agent Payments & A2A Settlement (HSP)
**Project name:** Agent-to-Agent Settlement — HSP-Style Mandate Escrow for AI Agents
**Team:** Emilio Tecnologías (solo builder)
**GitHub:** https://github.com/emiliotecnologias/hsk-horizon-agent-settlement
**Demo video:** demo-video.mp4 (in repo root, rendered from real terminal output)

---

## Short description (for the submission form)

An agent-to-agent payment system for HSK Chain. A buyer AI agent hires a
worker AI agent under an HSP-style payment mandate — bounded amount, named
worker, task hash, deadline — with funds locked in a Solidity escrow
contract and released only against verifiable delivery: the on-chain
keccak256 hash of the delivered result, which the buyer recomputes before
paying. Per-mandate and per-day spend caps bound what a runaway agent can
spend. A settlement watcher agent keeps an independent audit log and
auto-releases payment if a buyer goes silent. Includes Foundry contract +
16 passing tests, three working Python agents, and a one-command local
end-to-end demo.

## Problem

AI agents need to hire other agents (data processing, translation, media
work) and pay them autonomously — but an unrestricted agent wallet is a
liability, and human approval for every micro-payment kills autonomy. HSP's
answer is the payment mandate: bounded, auditable spending authority. This
project implements that mandate model on-chain for HSK Chain.

## Solution / how it works

1. Buyer agent escrows payment via `createMandate(worker, taskHash,
   deadline)`; the contract enforces a per-mandate cap and a per-buyer
   daily spend cap.
2. Worker agent performs the real job (demo: CSV sales analysis → JSON
   report), delivers the file off-chain and submits its hash on-chain as
   delivery proof.
3. Buyer verifies the delivered file's hash matches the on-chain proof,
   then releases payment.
4. Safety paths: auto-release after a review window if the buyer is
   silent; refund if the deadline passes with no delivery; dispute +
   arbiter resolution for bad delivery. Worker reputation
   (completedJobs, totalEarned) is tracked on-chain.
5. Settlement watcher agent records every event in an append-only audit
   log (JSONL) and can trigger auto-release.

## Tech stack

- Solidity 0.8.26 + Foundry (16 unit/fuzz tests passing)
- Python 3 + web3.py (buyer, worker, watcher agents)
- Local anvil chain for the demo; deploy script ready for HSK testnet
  (chain 133) and mainnet (chain 177)

## Deployment status (honest)

- Local anvil: ✅ full end-to-end demo runs (`bash demo/run_demo.sh`).
- HSK testnet: deploy script ready; RPC https://testnet.hsk.xyz did not
  respond from the build environment on 22 Nov 2026 (empty response to
  `eth_chainId`), so testnet deployment is pending.
- HSK mainnet: **not deployed** — pending project-owner decision with a
  funded wallet. No real funds were used anywhere in this build; demo keys
  are the public anvil dev keys.

## AI-assisted build disclosure

Built with AI assistance (Muse Spark) under the direction of Emilio
Tecnologías during the hackathon window (22–23 Nov 2026). All code was
compiled, tested and executed locally; the demo video is rendered from
real terminal output of those runs.
