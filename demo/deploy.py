"""Deploy AgentEscrow to the connected chain (local anvil by default) and
record the address in demo/deployment.json for the agents."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "agents"))
from common import ARBITER_KEY, BUYER_KEY, DEPLOY_FILE, get_w3  # noqa: E402
from web3 import Web3  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def main() -> None:
    w3 = get_w3()
    artifact = json.loads((ROOT / "out" / "AgentEscrow.sol" / "AgentEscrow.json").read_text())
    deployer = w3.eth.account.from_key(BUYER_KEY)
    arbiter = w3.eth.account.from_key(ARBITER_KEY).address
    contract = w3.eth.contract(abi=artifact["abi"], bytecode=artifact["bytecode"]["object"])
    tx = contract.constructor(
        arbiter,
        Web3.to_wei(1, "ether"),   # max per mandate
        Web3.to_wei(2, "ether"),   # daily spend cap per buyer
        3600,                      # 1h review window
    ).build_transaction({
        "from": deployer.address,
        "nonce": w3.eth.get_transaction_count(deployer.address),
        "gas": 2_000_000,
        "gasPrice": w3.eth.gas_price,
    })
    receipt = w3.eth.wait_for_transaction_receipt(
        w3.eth.send_raw_transaction(deployer.sign_transaction(tx).raw_transaction))
    assert receipt.status == 1
    DEPLOY_FILE.write_text(json.dumps(
        {"address": receipt.contractAddress, "chainId": w3.eth.chain_id,
         "tx": receipt.transactionHash.hex()}, indent=2))
    print(f"[deploy] AgentEscrow at {receipt.contractAddress} "
          f"(chain {w3.eth.chain_id}, gas {receipt.gasUsed})")


if __name__ == "__main__":
    main()
