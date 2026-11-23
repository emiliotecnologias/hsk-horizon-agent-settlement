// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {AgentEscrow} from "../src/AgentEscrow.sol";

/// @notice Deploy AgentEscrow. Parameters come from env vars so the same
///         script works for local anvil, HSK testnet and (later, only with
///         the project owner's explicit decision) HSK mainnet.
///
/// Local anvil (default dev keys):
///   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 \
///     --private-key $DEPLOYER_KEY --broadcast
///
/// HSK Chain testnet (chain id 133, RPC https://testnet.hsk.xyz):
///   RPC_URL=https://testnet.hsk.xyz forge script script/Deploy.s.sol \
///     --rpc-url $RPC_URL --private-key $DEPLOYER_KEY --broadcast
///
/// HSK Chain mainnet (chain id 177, RPC https://mainnet.hsk.xyz):
///   ⚠️ OWNER DECISION REQUIRED — do not deploy to mainnet without the
///   project owner approving the funded wallet and gas spend.
contract Deploy is Script {
    function run() external returns (AgentEscrow escrow) {
        address arbiter = vm.envOr("ARBITER", msg.sender);
        uint256 maxMandate = vm.envOr("MAX_MANDATE_WEI", uint256(1 ether));
        uint256 dailyCap = vm.envOr("DAILY_CAP_WEI", uint256(2 ether));
        uint64 reviewWindow = uint64(vm.envOr("REVIEW_WINDOW_SECONDS", uint256(1 hours)));

        vm.startBroadcast();
        escrow = new AgentEscrow(arbiter, maxMandate, dailyCap, reviewWindow);
        vm.stopBroadcast();
    }
}
