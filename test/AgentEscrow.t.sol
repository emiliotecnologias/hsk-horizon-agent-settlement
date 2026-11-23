// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentEscrow} from "../src/AgentEscrow.sol";

contract AgentEscrowTest is Test {
    AgentEscrow internal escrow;
    address internal owner = address(this);
    address internal arbiter = makeAddr("arbiter");
    address internal buyer = makeAddr("buyerAgent");
    address internal worker = makeAddr("workerAgent");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MAX_MANDATE = 1 ether;
    uint256 internal constant DAILY_CAP = 2 ether;
    uint64 internal constant REVIEW = 1 hours;

    bytes32 internal taskHash = keccak256("task: summarize sales csv");
    bytes32 internal resultHash = keccak256("result: summary json v1");

    function setUp() public {
        escrow = new AgentEscrow(arbiter, MAX_MANDATE, DAILY_CAP, REVIEW);
        vm.deal(buyer, 10 ether);
        vm.deal(worker, 1 ether);
    }

    function _create(uint256 amount) internal returns (uint256 jobId) {
        vm.prank(buyer);
        jobId = escrow.createMandate{value: amount}(worker, taskHash, uint64(block.timestamp + 1 days));
    }

    function _deliver(uint256 jobId) internal {
        vm.prank(worker);
        escrow.submitDelivery(jobId, resultHash);
    }

    // ------------------------------------------------------------ happy path
    function test_CreateEscrowsFunds() public {
        uint256 jobId = _create(0.5 ether);
        AgentEscrow.Mandate memory m = escrow.getMandate(jobId);
        assertEq(m.buyer, buyer);
        assertEq(m.worker, worker);
        assertEq(m.amount, 0.5 ether);
        assertEq(uint256(m.status), uint256(AgentEscrow.Status.Funded));
        assertEq(address(escrow).balance, 0.5 ether);
        assertEq(escrow.remainingDailyBudget(buyer), DAILY_CAP - 0.5 ether);
    }

    function test_DeliverAndBuyerReleases() public {
        uint256 jobId = _create(0.5 ether);
        _deliver(jobId);

        uint256 workerBefore = worker.balance;
        vm.prank(buyer);
        escrow.releasePayment(jobId);

        assertEq(worker.balance, workerBefore + 0.5 ether);
        assertEq(address(escrow).balance, 0);
        assertEq(escrow.completedJobs(worker), 1);
        assertEq(escrow.totalEarned(worker), 0.5 ether);
        AgentEscrow.Mandate memory m = escrow.getMandate(jobId);
        assertEq(uint256(m.status), uint256(AgentEscrow.Status.Released));
        assertEq(m.resultHash, resultHash);
    }

    function test_AutoReleaseAfterReviewWindow() public {
        uint256 jobId = _create(0.25 ether);
        _deliver(jobId);

        // too early: watcher cannot release yet
        vm.expectRevert();
        escrow.autoRelease(jobId);

        vm.warp(block.timestamp + REVIEW + 1);
        uint256 workerBefore = worker.balance;
        vm.prank(stranger); // anyone may trigger it
        escrow.autoRelease(jobId);
        assertEq(worker.balance, workerBefore + 0.25 ether);
    }

    // --------------------------------------------------------------- refunds
    function test_RefundAfterDeadlineWithoutDelivery() public {
        uint256 jobId = _create(0.5 ether);

        vm.prank(buyer);
        vm.expectRevert();
        escrow.refundExpired(jobId); // deadline not reached

        vm.warp(block.timestamp + 1 days + 1);
        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        escrow.refundExpired(jobId);
        assertEq(buyer.balance, buyerBefore + 0.5 ether);
        assertEq(address(escrow).balance, 0);
    }

    function test_DeliveryAfterDeadlineReverts() public {
        uint256 jobId = _create(0.5 ether);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(worker);
        vm.expectRevert();
        escrow.submitDelivery(jobId, resultHash);
    }

    // ------------------------------------------------------------------ caps
    function test_MandateCapEnforced() public {
        vm.prank(buyer);
        vm.expectRevert();
        escrow.createMandate{value: MAX_MANDATE + 1}(worker, taskHash, uint64(block.timestamp + 1 days));
    }

    function test_DailyCapEnforcedAndResetsNextDay() public {
        _create(1 ether);
        _create(1 ether); // daily cap now fully used
        vm.prank(buyer);
        vm.expectRevert();
        escrow.createMandate{value: 0.1 ether}(worker, taskHash, uint64(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1 days); // next UTC day bucket
        assertEq(escrow.remainingDailyBudget(buyer), DAILY_CAP);
        _create(0.1 ether);
    }

    function test_ZeroValueAndPastDeadlineRevert() public {
        vm.prank(buyer);
        vm.expectRevert();
        escrow.createMandate{value: 0}(worker, taskHash, uint64(block.timestamp + 1 days));

        vm.prank(buyer);
        vm.expectRevert();
        escrow.createMandate{value: 0.1 ether}(worker, taskHash, uint64(block.timestamp - 1));
    }

    // ------------------------------------------------------------- access ctl
    function test_OnlyWorkerCanDeliver() public {
        uint256 jobId = _create(0.5 ether);
        vm.prank(stranger);
        vm.expectRevert();
        escrow.submitDelivery(jobId, resultHash);
    }

    function test_OnlyBuyerCanRelease() public {
        uint256 jobId = _create(0.5 ether);
        _deliver(jobId);
        vm.prank(worker);
        vm.expectRevert();
        escrow.releasePayment(jobId);
    }

    function test_DoubleReleaseReverts() public {
        uint256 jobId = _create(0.5 ether);
        _deliver(jobId);
        vm.prank(buyer);
        escrow.releasePayment(jobId);
        vm.prank(buyer);
        vm.expectRevert();
        escrow.releasePayment(jobId);
    }

    function test_OnlyOwnerSetsCaps() public {
        vm.prank(stranger);
        vm.expectRevert();
        escrow.setCaps(5 ether, 5 ether, 2 hours);

        escrow.setCaps(5 ether, 5 ether, 2 hours); // owner = this contract
        assertEq(escrow.maxMandateAmount(), 5 ether);
    }

    // --------------------------------------------------------------- disputes
    function test_DisputeResolvedToWorker() public {
        uint256 jobId = _create(0.5 ether);
        _deliver(jobId);
        vm.prank(buyer);
        escrow.dispute(jobId, "result incomplete");

        // frozen: auto-release no longer possible even after window
        vm.warp(block.timestamp + REVIEW + 1);
        vm.expectRevert();
        escrow.autoRelease(jobId);

        uint256 workerBefore = worker.balance;
        vm.prank(arbiter);
        escrow.resolveDispute(jobId, true);
        assertEq(worker.balance, workerBefore + 0.5 ether);
    }

    function test_DisputeResolvedToBuyer() public {
        uint256 jobId = _create(0.5 ether);
        _deliver(jobId);
        vm.prank(buyer);
        escrow.dispute(jobId, "wrong format");

        uint256 buyerBefore = buyer.balance;
        vm.prank(arbiter);
        escrow.resolveDispute(jobId, false);
        assertEq(buyer.balance, buyerBefore + 0.5 ether);
        assertEq(escrow.completedJobs(worker), 0);
    }

    function test_OnlyArbiterResolves() public {
        uint256 jobId = _create(0.5 ether);
        _deliver(jobId);
        vm.prank(buyer);
        escrow.dispute(jobId, "x");
        vm.prank(buyer);
        vm.expectRevert();
        escrow.resolveDispute(jobId, false);
    }

    // ------------------------------------------------------------------ fuzz
    function testFuzz_CreateWithinCaps(uint256 amount) public {
        amount = bound(amount, 1, MAX_MANDATE);
        vm.deal(buyer, amount);
        uint256 jobId = _create(amount);
        assertEq(escrow.getMandate(jobId).amount, amount);
        assertEq(address(escrow).balance, amount);
    }
}
