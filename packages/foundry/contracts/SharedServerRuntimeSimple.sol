// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*
    SharedServerRuntime Simple
    - Interface compatible with SharedServerRuntime
    - Ignores time gating; uses durationSec to compute target amount
    - Emits Finalized when totalDeposited reaches target
*/
contract SharedServerRuntimeSimple is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* =============================================================
                                TOKEN
    ============================================================= */

    IERC20 public immutable USDC;
    address public immutable owner;

    /* =============================================================
                                PLAN
    ============================================================= */

    enum Plan {
        Small,
        Medium,
        Large
    }

    // USDC per second
    mapping(Plan => uint256) public ratePerSecond;

    /* =============================================================
                               INSTANCE
    ============================================================= */

    struct Instance {
        Plan planId;
        address provider;
        bool enabled;
    }

    uint64 public instanceCount;
    mapping(uint64 => Instance) public instances;

    /* =============================================================
                                SESSION
    ============================================================= */

    enum SessionStatus {
        Funding,
        Active,
        Cancelled,
        Closed
    }

    struct Session {
        uint64 instanceId;
        uint32 maxParticipants;
        uint32 joinedCount;
        uint64 startAt;
        uint32 durationSec;
        uint256 requiredPerUser;
        uint32 readyCount;
        uint256 totalDeposited;
        uint256 withdrawnGross;
        uint64 startTime;
        SessionStatus status;
    }

    struct Participant {
        bool joined;
        uint256 deposited;
        bool refundClaimed;
    }

    uint64 public sessionCount;

    mapping(uint64 => Session) public sessions;
    mapping(uint64 => mapping(address => Participant)) public participants;

    /* =============================================================
                                EVENTS
    ============================================================= */

    event InstanceCreated(
        uint64 indexed instanceId,
        Plan planId,
        address provider
    );

    event SessionCreated(
        uint64 indexed sessionId,
        uint64 indexed instanceId,
        uint64 startAt,
        uint32 durationSec,
        uint32 maxParticipants,
        uint256 requiredPerUser
    );

    event Joined(uint64 indexed sessionId, address indexed user);
    event Deposited(
        uint64 indexed sessionId,
        address indexed user,
        uint256 amount,
        uint256 totalUserDeposit
    );
    event ExcessWithdrawn(
        uint64 indexed sessionId,
        address indexed user,
        uint256 amount
    );

    event Finalized(uint64 indexed sessionId, SessionStatus status);
    event Closed(uint64 indexed sessionId);

    event ProviderWithdrawn(uint64 indexed sessionId, uint256 amount);
    event WithdrawnIfNotStarted(
        uint64 indexed sessionId,
        address indexed user,
        uint256 amount
    );
    event RefundedClosed(
        uint64 indexed sessionId,
        address indexed user,
        uint256 amount
    );

    /* =============================================================
                              CONSTRUCTOR
    ============================================================= */

    constructor(
        address usdc,
        uint256 smallRate,
        uint256 mediumRate,
        uint256 largeRate
    ) {
        require(usdc != address(0), "USDC_ZERO");

        USDC = IERC20(usdc);
        owner = msg.sender;

        ratePerSecond[Plan.Small] = smallRate;
        ratePerSecond[Plan.Medium] = mediumRate;
        ratePerSecond[Plan.Large] = largeRate;
    }

    /* =============================================================
                              INSTANCE
    ============================================================= */

    function createInstance(Plan planId) external returns (uint64 instanceId) {
        instanceId = ++instanceCount;

        instances[instanceId] = Instance({
            planId: planId,
            provider: owner,
            enabled: true
        });

        emit InstanceCreated(instanceId, planId, owner);
    }

    /* =============================================================
                              SESSION
    ============================================================= */

    function createSession(
        uint64 instanceId,
        uint32 maxParticipants,
        uint64 startAt,
        uint32 durationSec
    ) external returns (uint64 sessionId) {
        Instance memory inst = instances[instanceId];
        require(inst.provider != address(0), "INSTANCE_NOT_FOUND");
        require(inst.enabled, "INSTANCE_DISABLED");

        require(maxParticipants > 0, "BAD_MAX");
        require(durationSec > 0, "BAD_DURATION");

        uint256 rate = ratePerSecond[inst.planId];
        require(rate > 0, "RATE_NOT_SET");

        uint256 totalRequired = rate * uint256(durationSec);
        uint256 requiredPerUser = _ceilDiv(totalRequired, maxParticipants);

        sessionId = ++sessionCount;

        Session storage s = sessions[sessionId];
        s.instanceId = instanceId;
        s.maxParticipants = maxParticipants;
        s.startAt = startAt;
        s.durationSec = durationSec;
        s.requiredPerUser = requiredPerUser;
        s.status = SessionStatus.Funding;

        emit SessionCreated(
            sessionId,
            instanceId,
            startAt,
            durationSec,
            maxParticipants,
            requiredPerUser
        );
    }

    /* =============================================================
                             JOIN / DEPOSIT
    ============================================================= */

    function join(uint64 sessionId) external {
        Session storage s = sessions[sessionId];
        require(s.maxParticipants != 0, "SESSION_NOT_FOUND");
        require(s.status == SessionStatus.Funding, "NOT_FUNDING");

        _joinIfNeeded(s, sessionId);
    }

    function deposit(uint64 sessionId, uint256 amount) external nonReentrant {
        require(amount > 0, "ZERO_AMOUNT");

        Session storage s = sessions[sessionId];
        require(s.status == SessionStatus.Funding, "NOT_FUNDING");
        require(s.maxParticipants != 0, "SESSION_NOT_FOUND");

        Participant storage p = _joinIfNeeded(s, sessionId);

        uint256 beforeAmount = p.deposited;

        USDC.safeTransferFrom(msg.sender, address(this), amount);

        p.deposited = beforeAmount + amount;
        s.totalDeposited += amount;

        if (
            beforeAmount < s.requiredPerUser && p.deposited >= s.requiredPerUser
        ) {
            s.readyCount += 1;
        }

        emit Deposited(sessionId, msg.sender, amount, p.deposited);

        _emitFinalizedIfReady(s, sessionId);
    }

    /* =============================================================
                           FINALIZE / CLOSE
    ============================================================= */

    function finalize(uint64 sessionId) external {
        Session storage s = sessions[sessionId];
        require(s.status == SessionStatus.Funding, "NOT_FUNDING");
        require(s.maxParticipants != 0, "SESSION_NOT_FOUND");

        _emitFinalizedIfReady(s, sessionId);
        require(s.status == SessionStatus.Active, "NOT_READY");
    }

    function closeIfExpired(uint64) external pure {
        revert("NOT_SUPPORTED");
    }

    /* =============================================================
                         WITHDRAW / REFUND (STUBS)
    ============================================================= */

    function withdrawExcess(uint64, uint256) external pure {
        revert("NOT_SUPPORTED");
    }

    function withdrawIfNotStarted(uint64) external pure {
        revert("NOT_SUPPORTED");
    }

    function providerWithdraw(uint64 sessionId) external nonReentrant {
        Session storage s = sessions[sessionId];
        require(s.status == SessionStatus.Active, "NOT_ACTIVE");

        Instance memory inst = instances[s.instanceId];
        require(msg.sender == inst.provider, "NOT_PROVIDER");

        uint256 withdrawable = s.totalDeposited - s.withdrawnGross;
        require(withdrawable > 0, "NOTHING");

        s.withdrawnGross += withdrawable;
        USDC.safeTransfer(inst.provider, withdrawable);

        emit ProviderWithdrawn(sessionId, withdrawable);
    }

    function refundClosed(uint64) external pure {
        revert("NOT_SUPPORTED");
    }

    /* =============================================================
                                UTILS
    ============================================================= */

    function _emitFinalizedIfReady(
        Session storage s,
        uint64 sessionId
    ) internal {
        if (s.status != SessionStatus.Funding) return;

        Instance memory inst = instances[s.instanceId];
        uint256 rate = ratePerSecond[inst.planId];
        uint256 totalRequired = rate * uint256(s.durationSec);

        if (s.totalDeposited >= totalRequired) {
            s.status = SessionStatus.Active;
            emit Finalized(sessionId, s.status);
        }
    }

    function _joinIfNeeded(
        Session storage s,
        uint64 sessionId
    ) internal returns (Participant storage p) {
        p = participants[sessionId][msg.sender];
        if (!p.joined) {
            require(s.joinedCount < s.maxParticipants, "FULL");
            p.joined = true;
            s.joinedCount++;
            emit Joined(sessionId, msg.sender);
        }
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
