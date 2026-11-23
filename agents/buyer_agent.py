"""Buyer AI agent: hires the worker agent for a data-processing job.

Flow: publish task spec (off-chain) -> create on-chain mandate + escrow
(HSP-style bounded mandate: amount capped per-mandate and per-day) ->
wait for delivery -> verify result hash matches the delivered file ->
release payment. Also demonstrates the spend-cap guard rejecting an
over-cap mandate.

Run standalone:  python agents/buyer_agent.py
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import BUYER_KEY, SHARED_DIR, WORKER_KEY, eth, get_w3, load_contract, now_ts, send_tx  # noqa: E402
from web3 import Web3  # noqa: E402

JOB_PRICE = Web3.to_wei(0.05, "ether")  # 0.05 HSK per analysis job


def main() -> None:
    w3 = get_w3()
    contract = load_contract(w3)
    buyer = w3.eth.account.from_key(BUYER_KEY).address
    worker = w3.eth.account.from_key(WORKER_KEY).address
    print(f"[buyer] agent {buyer} online, escrow={contract.address}")
    print(f"[buyer] balances: buyer={eth(w3, buyer)} HSK  worker={eth(w3, worker)} HSK")
    print(f"[buyer] remaining daily budget: "
          f"{w3.from_wei(contract.functions.remainingDailyBudget(buyer).call(), 'ether')} HSK")

    # 1) Publish the task spec off-chain; only its hash goes on-chain.
    SHARED_DIR.mkdir(parents=True, exist_ok=True)
    task_spec = {"job": "analyze_sales_csv", "input_csv": "sales.csv",
                 "output": "json summary with revenue by product"}
    task_bytes = json.dumps(task_spec, sort_keys=True).encode()
    task_hash = Web3.keccak(task_bytes)
    deadline = now_ts() + 3600

    # 2) Create the mandate + escrow funds in one transaction.
    print(f"[buyer] creating mandate: pay {w3.from_wei(JOB_PRICE, 'ether')} HSK to worker "
          f"{worker[:10]}… for task {task_hash.hex()[:16]}…")
    receipt = send_tx(
        w3,
        contract.functions.createMandate(worker, task_hash, deadline),
        BUYER_KEY,
        value=JOB_PRICE,
    )
    event = contract.events.MandateCreated().process_receipt(receipt)[0]
    job_id = event["args"]["jobId"]
    (SHARED_DIR / f"task_{job_id}.json").write_bytes(task_bytes)
    print(f"[buyer] mandate #{job_id} funded, tx={receipt.transactionHash.hex()[:18]}… "
          f"escrow balance={eth(w3, contract.address)} HSK")

    # 3) Wait for the worker's delivery proof.
    print("[buyer] waiting for worker delivery…")
    while True:
        m = contract.functions.getMandate(job_id).call()
        if m[7] == 2:  # Delivered
            break
        time.sleep(1)
    onchain_hash = m[4]
    print(f"[buyer] delivery proof on-chain: {onchain_hash.hex()[:18]}…")

    # 4) Verify: hash of the delivered file must equal the on-chain proof.
    result_bytes = (SHARED_DIR / f"result_{job_id}.json").read_bytes()
    local_hash = Web3.keccak(result_bytes)
    assert local_hash == onchain_hash, "DELIVERY HASH MISMATCH — would dispute"
    result = json.loads(result_bytes)
    print(f"[buyer] verified ✓ result hash matches. Worker report: "
          f"{result['rows_processed']} rows, revenue=${result['total_revenue']}, "
          f"top product={result['top_product']}")

    # 5) Release payment.
    receipt = send_tx(w3, contract.functions.releasePayment(job_id), BUYER_KEY)
    print(f"[buyer] payment released tx={receipt.transactionHash.hex()[:18]}…")
    print(f"[buyer] balances now: buyer={eth(w3, buyer)} HSK  worker={eth(w3, worker)} HSK  "
          f"escrow={eth(w3, contract.address)} HSK")
    print(f"[buyer] worker reputation: completedJobs="
          f"{contract.functions.completedJobs(worker).call()}, totalEarned="
          f"{w3.from_wei(contract.functions.totalEarned(worker).call(), 'ether')} HSK")

    # 6) Spend-cap guard: an over-cap mandate must revert.
    print("[buyer] cap check: trying to escrow 5 HSK (over the 1 HSK mandate cap)…")
    try:
        send_tx(w3, contract.functions.createMandate(worker, task_hash, deadline),
                BUYER_KEY, value=Web3.to_wei(5, "ether"))
        print("[buyer] ERROR: over-cap mandate was accepted!")
    except Exception as e:
        print(f"[buyer] correctly rejected by contract caps ✓ ({type(e).__name__})")


if __name__ == "__main__":
    main()
