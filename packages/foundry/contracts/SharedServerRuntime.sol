// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*
 Stablecoin Shared Server Runtime (v1.4)

 - Instance-first model
 - startAt 到達時に全員分揃っていれば Active
 - 超過分は常に withdraw 可能
 - startAt までに揃わなければ全額 withdraw 可能
 - Provider のオンチェーン操作は withdraw のみ
*/

contract SharedServerRuntime is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* =============================================================
                                TOKEN
    ============================================================= */

    IERC20 public immutable USDC;

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

        ratePerSecond[Plan.Small] = smallRate;
        ratePerSecond[Plan.Medium] = mediumRate;
        ratePerSecond[Plan.Large] = largeRate;
    }

    /* =============================================================
                              INSTANCE
    ============================================================= */

    function createInstance(
        Plan planId,
        address provider
    ) external returns (uint64 instanceId) {
        require(provider != address(0), "PROVIDER_ZERO");

        instanceId = ++instanceCount;

        instances[instanceId] = Instance({
            planId: planId,
            provider: provider,
            enabled: true
        });

        emit InstanceCreated(instanceId, planId, provider);
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
        require(startAt > block.timestamp, "START_IN_PAST");

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
        require(block.timestamp < s.startAt, "PAST_START");

        Participant storage p = participants[sessionId][msg.sender];
        require(!p.joined, "ALREADY_JOINED");
        require(s.joinedCount < s.maxParticipants, "FULL");

        p.joined = true;
        s.joinedCount++;

        emit Joined(sessionId, msg.sender);
    }

    function deposit(uint64 sessionId, uint256 amount) external nonReentrant {
        require(amount > 0, "ZERO_AMOUNT");

        Session storage s = sessions[sessionId];
        require(s.status == SessionStatus.Funding, "NOT_FUNDING");
        require(block.timestamp < s.startAt, "PAST_START");

        Participant storage p = participants[sessionId][msg.sender];
        require(p.joined, "NOT_JOINED");

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
    }

    /* =============================================================
                         WITHDRAW (EXCESS)
    ============================================================= */

    function withdrawExcess(
        uint64 sessionId,
        uint256 amount
    ) external nonReentrant {
        require(amount > 0, "ZERO_AMOUNT");

        Session storage s = sessions[sessionId];
        require(s.status == SessionStatus.Funding, "ONLY_FUNDING");
        require(block.timestamp < s.startAt, "PAST_START");

        Participant storage p = participants[sessionId][msg.sender];
        require(p.joined, "NOT_JOINED");

        require(p.deposited >= s.requiredPerUser, "NOT_READY");
        require(p.deposited - amount >= s.requiredPerUser, "WOULD_BREAK_READY");

        p.deposited -= amount;
        s.totalDeposited -= amount;

        USDC.safeTransfer(msg.sender, amount);

        emit ExcessWithdrawn(sessionId, msg.sender, amount);
    }

    /* =============================================================
                       FINALIZE / CLOSE
    ============================================================= */

    function finalize(uint64 sessionId) external {
        Session storage s = sessions[sessionId];
        require(s.status == SessionStatus.Funding, "NOT_FUNDING");
        require(block.timestamp >= s.startAt, "TOO_EARLY");

        if (s.readyCount == s.maxParticipants) {
            s.status = SessionStatus.Active;
            s.startTime = s.startAt;
        } else {
            s.status = SessionStatus.Cancelled;
        }

        emit Finalized(sessionId, s.status);
    }

    function closeIfExpired(uint64 sessionId) external {
        Session storage s = sessions[sessionId];
        require(s.status == SessionStatus.Active, "NOT_ACTIVE");

        uint256 stopAt = uint256(s.startTime) + uint256(s.durationSec);
        require(block.timestamp >= stopAt, "NOT_EXPIRED");

        s.status = SessionStatus.Closed;
        emit Closed(sessionId);
    }

    /* =============================================================
                      WITHDRAW IF NOT STARTED
    ============================================================= */

    function withdrawIfNotStarted(uint64 sessionId) external nonReentrant {
        Session storage s = sessions[sessionId];
        require(block.timestamp >= s.startAt, "TOO_EARLY");

        bool notStarted = (s.status == SessionStatus.Cancelled) ||
            (s.status == SessionStatus.Funding &&
                s.readyCount != s.maxParticipants);

        require(notStarted, "MAY_START_OR_STARTED");

        Participant storage p = participants[sessionId][msg.sender];
        uint256 amount = p.deposited;
        require(amount > 0, "NOTHING");

        p.deposited = 0;
        s.totalDeposited -= amount;

        USDC.safeTransfer(msg.sender, amount);

        emit WithdrawnIfNotStarted(sessionId, msg.sender, amount);
    }

    /* =============================================================
                        PROVIDER WITHDRAW
    ============================================================= */

    function providerWithdraw(uint64 sessionId) external nonReentrant {
        Session storage s = sessions[sessionId];
        require(
            s.status == SessionStatus.Active ||
                s.status == SessionStatus.Closed,
            "BAD_STATUS"
        );

        Instance memory inst = instances[s.instanceId];
        require(msg.sender == inst.provider, "NOT_PROVIDER");

        uint256 rate = ratePerSecond[inst.planId];
        uint256 totalRequired = rate * uint256(s.durationSec);

        uint256 stopAt = uint256(s.startTime) + uint256(s.durationSec);
        uint256 t = block.timestamp < stopAt ? block.timestamp : stopAt;

        uint256 elapsed = t - uint256(s.startTime);
        uint256 unlocked = rate * elapsed;
        if (unlocked > totalRequired) unlocked = totalRequired;
        if (unlocked > s.totalDeposited) unlocked = s.totalDeposited;

        uint256 withdrawable = unlocked - s.withdrawnGross;
        require(withdrawable > 0, "NOTHING");

        s.withdrawnGross += withdrawable;
        USDC.safeTransfer(inst.provider, withdrawable);

        emit ProviderWithdrawn(sessionId, withdrawable);
    }

    /* =============================================================
                        REFUND AFTER CLOSE
    ============================================================= */

    function refundClosed(uint64 sessionId) external nonReentrant {
        Session storage s = sessions[sessionId];
        require(s.status == SessionStatus.Closed, "NOT_CLOSED");

        Participant storage p = participants[sessionId][msg.sender];
        require(p.deposited > 0, "NOTHING");
        require(!p.refundClaimed, "CLAIMED");

        Instance memory inst = instances[s.instanceId];
        uint256 rate = ratePerSecond[inst.planId];
        uint256 totalRequired = rate * uint256(s.durationSec);

        uint256 finalCost = totalRequired;
        if (finalCost > s.totalDeposited) finalCost = s.totalDeposited;

        uint256 refundableTotal = s.totalDeposited - finalCost;
        require(refundableTotal > 0, "NO_EXCESS");

        uint256 refund = (refundableTotal * p.deposited) / s.totalDeposited;
        require(refund > 0, "DUST");

        p.refundClaimed = true;

        USDC.safeTransfer(msg.sender, refund);
        emit RefundedClosed(sessionId, msg.sender, refund);
    }

    /* =============================================================
                               UTILS
    ============================================================= */

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
