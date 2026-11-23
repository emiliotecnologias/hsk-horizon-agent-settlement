"""Settlement watcher: an independent agent that observes escrow events,
keeps an append-only audit log (JSONL), prints settlement receipts, and can
trigger auto-release when a buyer stays silent past the review window.

Run standalone:  python agents/settlement_watcher.py [--once] [--auto-release]
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import ARBITER_KEY, get_w3, load_contract, now_ts, send_tx  # noqa: E402

LOG = Path(__file__).resolve().parent.parent / "demo" / "settlement_log.jsonl"
EVENT_NAMES = ["MandateCreated", "DeliverySubmitted", "PaymentReleased",
               "Refunded", "Disputed", "DisputeResolved"]


def log_event(name: str, args: dict) -> None:
    record = {"ts": now_ts(), "event": name,
              "args": {k: (v.hex() if isinstance(v, (bytes, bytearray)) else v)
                       for k, v in args.items()}}
    with LOG.open("a") as f:
        f.write(json.dumps(record) + "\n")
    print(f"[watcher] {name}: {record['args']}")


def main() -> None:
    once = "--once" in sys.argv
    auto = "--auto-release" in sys.argv
    w3 = get_w3()
    contract = load_contract(w3)
    print(f"[watcher] watching escrow {contract.address} (auto-release={'on' if auto else 'off'})")
    last_block = w3.eth.block_number
    while True:
        current = w3.eth.block_number
        if current > last_block:
            for name in EVENT_NAMES:
                event = getattr(contract.events, name)
                for entry in event.get_logs(from_block=last_block + 1, to_block=current):
                    log_event(name, dict(entry["args"]))
            last_block = current
        if auto:
            review = contract.functions.reviewWindow().call()
            for job_id in range(1, contract.functions.nextJobId().call()):
                m = contract.functions.getMandate(job_id).call()
                if m[7] == 2 and now_ts() >= m[6] + review:  # Delivered + window passed
                    print(f"[watcher] job {job_id}: review window passed, auto-releasing…")
                    send_tx(w3, contract.functions.autoRelease(job_id), ARBITER_KEY)
        if once:
            break
        time.sleep(2)


if __name__ == "__main__":
    main()
