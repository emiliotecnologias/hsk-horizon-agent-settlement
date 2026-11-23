"""Shared config/helpers for the HSK Horizon A2A settlement agents.

All keys here are the well-known PUBLIC anvil/hardhat dev keys. They are
safe to print and must never be used on any real network.
"""
import json
import os
import time
from pathlib import Path

from web3 import Web3

ROOT = Path(__file__).resolve().parent.parent
RPC_URL = os.environ.get("RPC_URL", "http://127.0.0.1:8545")

# Public anvil dev accounts (mnemonic "test test ... junk"). Local only.
BUYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # account 0
WORKER_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"  # account 1
ARBITER_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"  # account 2

ARTIFACT = ROOT / "out" / "AgentEscrow.sol" / "AgentEscrow.json"
DEPLOY_FILE = ROOT / "demo" / "deployment.json"
SHARED_DIR = ROOT / "demo" / "shared"  # simulated off-chain delivery channel


def get_w3() -> Web3:
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    assert w3.is_connected(), f"cannot connect to RPC {RPC_URL}"
    return w3


def load_contract(w3: Web3):
    artifact = json.loads(ARTIFACT.read_text())
    deployment = json.loads(DEPLOY_FILE.read_text())
    return w3.eth.contract(address=deployment["address"], abi=artifact["abi"])


def send_tx(w3: Web3, contract_fn, key: str, value: int = 0):
    acct = w3.eth.account.from_key(key)
    tx = contract_fn.build_transaction(
        {
            "from": acct.address,
            "value": value,
            "nonce": w3.eth.get_transaction_count(acct.address),
            "gas": 500_000,
            "gasPrice": w3.eth.gas_price,
        }
    )
    signed = acct.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    assert receipt.status == 1, f"tx reverted: {tx_hash.hex()}"
    return receipt


def eth(w3: Web3, address: str) -> str:
    return f"{w3.from_wei(w3.eth.get_balance(address), 'ether'):.6f}"


def now_ts() -> int:
    return int(time.time())
