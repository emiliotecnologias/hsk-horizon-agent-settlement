"""Worker AI agent: watches for mandates assigned to it, performs a real
data-processing job (CSV sales analysis -> JSON summary), writes the result
to the shared delivery folder, and submits the result hash on-chain as
verifiable delivery proof.

Run standalone:  python agents/worker_agent.py [--once]
"""
import csv
import json
import sys
import time
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import SHARED_DIR, WORKER_KEY, get_w3, load_contract, send_tx  # noqa: E402
from web3 import Web3  # noqa: E402


def analyze_sales(csv_path: Path) -> dict:
    """The actual paid work: aggregate a sales CSV into a summary report."""
    revenue_by_product = defaultdict(float)
    units_by_product = defaultdict(int)
    total_revenue = 0.0
    total_units = 0
    rows = 0
    with csv_path.open(newline="") as f:
        for row in csv.DictReader(f):
            units = int(row["units"])
            revenue = units * float(row["unit_price"])
            revenue_by_product[row["product"]] += revenue
            units_by_product[row["product"]] += units
            total_revenue += revenue
            total_units += units
            rows += 1
    top = max(revenue_by_product, key=revenue_by_product.get)
    return {
        "rows_processed": rows,
        "total_units": total_units,
        "total_revenue": round(total_revenue, 2),
        "revenue_by_product": {k: round(v, 2) for k, v in sorted(revenue_by_product.items())},
        "units_by_product": dict(sorted(units_by_product.items())),
        "top_product": top,
    }


def process_job(w3, contract, job_id: int, mandate) -> None:
    print(f"[worker] job {job_id}: taskHash={mandate[3].hex()[:16]}… amount="
          f"{w3.from_wei(mandate[2], 'ether')} HSK — starting work")
    task_file = SHARED_DIR / f"task_{job_id}.json"
    task = json.loads(task_file.read_text())
    result = analyze_sales(SHARED_DIR / task["input_csv"])
    result["job_id"] = job_id
    result_bytes = json.dumps(result, indent=2, sort_keys=True).encode()
    (SHARED_DIR / f"result_{job_id}.json").write_bytes(result_bytes)
    result_hash = Web3.keccak(result_bytes)
    print(f"[worker] job {job_id}: analyzed {result['rows_processed']} rows, "
          f"total_revenue=${result['total_revenue']}, top={result['top_product']}")
    print(f"[worker] job {job_id}: submitting delivery proof {result_hash.hex()[:18]}…")
    receipt = send_tx(w3, contract.functions.submitDelivery(job_id, result_hash), WORKER_KEY)
    print(f"[worker] job {job_id}: delivery on-chain tx={receipt.transactionHash.hex()[:18]}… "
          f"gas={receipt.gasUsed}")


def main() -> None:
    once = "--once" in sys.argv
    w3 = get_w3()
    contract = load_contract(w3)
    me = w3.eth.account.from_key(WORKER_KEY).address
    print(f"[worker] agent {me} online, escrow={contract.address}")
    seen = set()
    while True:
        next_id = contract.functions.nextJobId().call()
        for job_id in range(1, next_id):
            if job_id in seen:
                continue
            m = contract.functions.getMandate(job_id).call()
            # Mandate tuple: buyer, worker, amount, taskHash, resultHash, deadline, deliveredAt, status
            if m[1] == me and m[7] == 1:  # assigned to me, status Funded
                seen.add(job_id)
                process_job(w3, contract, job_id, m)
        if once:
            break
        time.sleep(2)


if __name__ == "__main__":
    main()
