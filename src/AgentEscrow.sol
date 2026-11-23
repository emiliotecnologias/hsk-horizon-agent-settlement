// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title AgentEscrow — HSP-style agent-to-agent settlement escrow for HSK Chain
/// @notice A buyer AI agent escrows native HSK under a signed "mandate"
///         (worker, task hash, deadline, amount). A worker AI agent performs
///         the task off-chain and submits a delivery proof hash. Funds are
///         released to the worker when the buyer confirms delivery, or
///         automatically after a review window if the buyer stays silent.
///         If the deadline passes with no delivery, the buyer is refunded.
///         Per-buyer daily spend caps and a per-mandate cap bound the blast
///         radius of a runaway or compromised agent — the core HSP mandate
///         idea (bounded, auditable agent spending) implemented on-chain.
/// @dev    Hackathon build for HSK Chain Horizon · Seoul (Track 2: Agent
///         Payments & A2A Settlement). Native-token escrow; an ERC-20/USDT
///         variant is a drop-in extension (see docs/ARCHITECTURE.md).
contract AgentEscrow {
    // ------------------------------------------------------------------ types
    enum Status {
        None,
        Funded, // escrowed, waiting for worker delivery
        Delivered, // worker submitted proof, in buyer review window
        Released, // paid to worker (terminal)
        Refunded, // returned to buyer (terminal)
        Disputed // frozen pending arbiter decision
    }

    struct Mandate {
        address buyer;
        address worker;
        uint256 amount;
        bytes32 taskHash; // keccak256 of the task spec (off-chain document)
        bytes32 resultHash; // keccak256 of the delivered result (0 until delivered)
        uint64 deadline; // unix time: delivery must happen before this
        uint64 deliveredAt; // unix time of delivery (0 until delivered)
        Status status;
    }

    // ------------------------------------------------------------------ state
    address public owner;
    address public arbiter;

    /// @notice Max value a single mandate may escrow.
    uint256 public maxMandateAmount;
    /// @notice Max total value one buyer agent may escrow per UTC day.
    uint256 public dailySpendCap;
    /// @notice Seconds after delivery during which the buyer may dispute;
    ///         afterwards anyone may trigger auto-release to the worker.
    uint64 public reviewWindow;

    uint256 public nextJobId = 1;
    mapping(uint256 => Mandate) public mandates;
    /// @dev buyer => dayIndex (timestamp / 1 days) => total escrowed that day
    mapping(address => mapping(uint256 => uint256)) public spentOnDay;
    /// @dev worker => number of completed (released) jobs, for reputation reads
    mapping(address => uint256) public completedJobs;
    /// @dev worker => total earned, for reputation reads
    mapping(address => uint256) public totalEarned;

    bool private _locked;

    // ----------------------------------------------------------------- events
    event MandateCreated(
        uint256 indexed jobId, address indexed buyer, address indexed worker,
        uint256 amount, bytes32 taskHash, uint64 deadline
    );
    event DeliverySubmitted(uint256 indexed jobId, address indexed worker, bytes32 resultHash);
    event PaymentReleased(uint256 indexed jobId, address indexed worker, uint256 amount, bool autoReleased);
    event Refunded(uint256 indexed jobId, address indexed buyer, uint256 amount, string reason);
    event Disputed(uint256 indexed jobId, address indexed buyer, string reason);
    event DisputeResolved(uint256 indexed jobId, bool paidToWorker, uint256 amount);
    event CapsUpdated(uint256 maxMandateAmount, uint256 dailySpendCap, uint64 reviewWindow);
    event ArbiterUpdated(address indexed arbiter);

    // ----------------------------------------------------------------- errors
    error NotOwner();
    error NotArbiter();
    error NotBuyer();
    error NotWorker();
    error ZeroAmount();
    error ZeroAddress();
    error ExceedsMandateCap(uint256 amount, uint256 cap);
    error ExceedsDailyCap(uint256 wouldSpend, uint256 cap);
    error DeadlineInPast();
    error WrongStatus(Status actual);
    error DeadlinePassed();
    error DeadlineNotReached();
    error ReviewWindowActive(uint64 unlocksAt);
    error TransferFailed();
    error Reentrant();

    // -------------------------------------------------------------- modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address _arbiter, uint256 _maxMandateAmount, uint256 _dailySpendCap, uint64 _reviewWindow) {
        if (_arbiter == address(0)) revert ZeroAddress();
        owner = msg.sender;
        arbiter = _arbiter;
        maxMandateAmount = _maxMandateAmount;
        dailySpendCap = _dailySpendCap;
        reviewWindow = _reviewWindow;
    }

    // ------------------------------------------------------------ admin (caps)
    /// @notice Update spend caps / review window. Owner-only: caps are the
    ///         safety boundary, so agents themselves cannot raise them.
    function setCaps(uint256 _maxMandateAmount, uint256 _dailySpendCap, uint64 _reviewWindow) external onlyOwner {
        maxMandateAmount = _maxMandateAmount;
        dailySpendCap = _dailySpendCap;
        reviewWindow = _reviewWindow;
        emit CapsUpdated(_maxMandateAmount, _dailySpendCap, _reviewWindow);
    }

    function setArbiter(address _arbiter) external onlyOwner {
        if (_arbiter == address(0)) revert ZeroAddress();
        arbiter = _arbiter;
        emit ArbiterUpdated(_arbiter);
    }

    // ------------------------------------------------------------- core flow
    /// @notice Buyer agent creates a mandate and escrows payment in one call.
    /// @param worker     Worker agent address that must deliver.
    /// @param taskHash   keccak256 of the off-chain task specification.
    /// @param deadline   Unix timestamp by which delivery must occur.
    /// @return jobId     Sequential mandate id.
    function createMandate(address worker, bytes32 taskHash, uint64 deadline)
        external
        payable
        nonReentrant
        returns (uint256 jobId)
    {
        if (worker == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert DeadlineInPast();
        if (msg.value > maxMandateAmount) revert ExceedsMandateCap(msg.value, maxMandateAmount);

        uint256 day = block.timestamp / 1 days;
        uint256 wouldSpend = spentOnDay[msg.sender][day] + msg.value;
        if (wouldSpend > dailySpendCap) revert ExceedsDailyCap(wouldSpend, dailySpendCap);
        spentOnDay[msg.sender][day] = wouldSpend;

        jobId = nextJobId++;
        mandates[jobId] = Mandate({
            buyer: msg.sender,
            worker: worker,
            amount: msg.value,
            taskHash: taskHash,
            resultHash: bytes32(0),
            deadline: deadline,
            deliveredAt: 0,
            status: Status.Funded
        });

        emit MandateCreated(jobId, msg.sender, worker, msg.value, taskHash, deadline);
    }

    /// @notice Worker agent submits verifiable delivery proof (hash of result).
    function submitDelivery(uint256 jobId, bytes32 resultHash) external {
        Mandate storage m = mandates[jobId];
        if (msg.sender != m.worker) revert NotWorker();
        if (m.status != Status.Funded) revert WrongStatus(m.status);
        if (block.timestamp > m.deadline) revert DeadlinePassed();

        m.resultHash = resultHash;
        m.deliveredAt = uint64(block.timestamp);
        m.status = Status.Delivered;

        emit DeliverySubmitted(jobId, msg.sender, resultHash);
    }

    /// @notice Buyer confirms delivery and releases escrow to the worker.
    function releasePayment(uint256 jobId) external nonReentrant {
        Mandate storage m = mandates[jobId];
        if (msg.sender != m.buyer) revert NotBuyer();
        if (m.status != Status.Delivered) revert WrongStatus(m.status);
        _payWorker(jobId, m, false);
    }

    /// @notice After the review window, anyone (e.g. the settlement watcher)
    ///         may release payment — a silent buyer cannot freeze a worker.
    function autoRelease(uint256 jobId) external nonReentrant {
        Mandate storage m = mandates[jobId];
        if (m.status != Status.Delivered) revert WrongStatus(m.status);
        uint64 unlocksAt = m.deliveredAt + reviewWindow;
        if (block.timestamp < unlocksAt) revert ReviewWindowActive(unlocksAt);
        _payWorker(jobId, m, true);
    }

    /// @notice Buyer reclaims escrow when the deadline passed with no delivery.
    function refundExpired(uint256 jobId) external nonReentrant {
        Mandate storage m = mandates[jobId];
        if (msg.sender != m.buyer) revert NotBuyer();
        if (m.status != Status.Funded) revert WrongStatus(m.status);
        if (block.timestamp <= m.deadline) revert DeadlineNotReached();

        uint256 amount = m.amount;
        m.status = Status.Refunded;
        emit Refunded(jobId, m.buyer, amount, "deadline passed without delivery");
        _send(m.buyer, amount);
    }

    /// @notice Buyer disputes a delivery during the review window.
    function dispute(uint256 jobId, string calldata reason) external {
        Mandate storage m = mandates[jobId];
        if (msg.sender != m.buyer) revert NotBuyer();
        if (m.status != Status.Delivered) revert WrongStatus(m.status);
        m.status = Status.Disputed;
        emit Disputed(jobId, msg.sender, reason);
    }

    /// @notice Arbiter resolves a dispute: pay worker or refund buyer.
    function resolveDispute(uint256 jobId, bool payWorker) external nonReentrant {
        if (msg.sender != arbiter) revert NotArbiter();
        Mandate storage m = mandates[jobId];
        if (m.status != Status.Disputed) revert WrongStatus(m.status);

        uint256 amount = m.amount;
        if (payWorker) {
            m.status = Status.Released;
            completedJobs[m.worker] += 1;
            totalEarned[m.worker] += amount;
            emit DisputeResolved(jobId, true, amount);
            _send(m.worker, amount);
        } else {
            m.status = Status.Refunded;
            emit DisputeResolved(jobId, false, amount);
            _send(m.buyer, amount);
        }
    }

    // ------------------------------------------------------------------ views
    function getMandate(uint256 jobId) external view returns (Mandate memory) {
        return mandates[jobId];
    }

    /// @notice Remaining amount this buyer may still escrow today.
    function remainingDailyBudget(address buyer) external view returns (uint256) {
        uint256 spent = spentOnDay[buyer][block.timestamp / 1 days];
        return spent >= dailySpendCap ? 0 : dailySpendCap - spent;
    }

    // --------------------------------------------------------------- internal
    function _payWorker(uint256 jobId, Mandate storage m, bool autoReleased) internal {
        uint256 amount = m.amount;
        address worker = m.worker;
        m.status = Status.Released;
        completedJobs[worker] += 1;
        totalEarned[worker] += amount;
        emit PaymentReleased(jobId, worker, amount, autoReleased);
        _send(worker, amount);
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
