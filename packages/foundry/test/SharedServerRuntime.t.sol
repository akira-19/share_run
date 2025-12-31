// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SharedServerRuntime} from "../contracts/SharedServerRuntime.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SharedServerRuntimeTest is Test {
    MockUSDC usdc;
    SharedServerRuntime runtime;

    address provider = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA01);

    uint256 smallRate;
    uint256 mediumRate;
    uint256 largeRate;

    function setUp() external {
        usdc = new MockUSDC();

        smallRate = uint256(1_000_000) / 3600; // 1 USDC/hour
        mediumRate = uint256(3_000_000) / 3600; // 3 USDC/hour
        largeRate = uint256(8_000_000) / 3600; // 8 USDC/hour

        runtime = new SharedServerRuntime(
            address(usdc),
            smallRate,
            mediumRate,
            largeRate
        );

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(carol, 1_000_000e6);

        vm.prank(alice);
        usdc.approve(address(runtime), type(uint256).max);

        vm.prank(bob);
        usdc.approve(address(runtime), type(uint256).max);

        vm.prank(carol);
        usdc.approve(address(runtime), type(uint256).max);
    }

    function _createInstanceSmall() internal returns (uint64 instanceId) {
        instanceId = runtime.createInstance(
            SharedServerRuntime.Plan.Small,
            provider
        );
    }

    function _createSession(
        uint64 instanceId,
        uint32 maxParticipants,
        uint64 startAt,
        uint32 durationSec
    ) internal returns (uint64 sessionId) {
        sessionId = runtime.createSession(
            instanceId,
            maxParticipants,
            startAt,
            durationSec
        );
    }

    function test_WithdrawExcess_AllowsOnlyAboveRequired() external {
        uint64 instanceId = _createInstanceSmall();
        uint64 startAt = uint64(block.timestamp + 2 hours);
        uint32 durationSec = 3600;

        uint64 sessionId = _createSession(instanceId, 1, startAt, durationSec);

        vm.prank(alice);
        runtime.join(sessionId);

        uint256 requiredPerUser = _requiredPerUser(sessionId);
        uint256 extra = requiredPerUser / 5;
        uint256 depositAmt = requiredPerUser + extra;

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        runtime.deposit(sessionId, depositAmt);

        vm.prank(alice);
        runtime.withdrawExcess(sessionId, extra);

        assertEq(usdc.balanceOf(alice), aliceBefore - requiredPerUser);

        vm.prank(alice);
        vm.expectRevert(bytes("WOULD_BREAK_READY"));
        runtime.withdrawExcess(sessionId, 1);
    }

    function test_WithdrawIfNotStarted_AllowsRefund() external {
        uint64 instanceId = _createInstanceSmall();
        uint64 startAt = uint64(block.timestamp + 1 hours);
        uint32 durationSec = 3600;

        uint64 sessionId = _createSession(instanceId, 2, startAt, durationSec);

        vm.prank(alice);
        runtime.join(sessionId);

        uint256 requiredPerUser = _requiredPerUser(sessionId);
        vm.prank(alice);
        runtime.deposit(sessionId, requiredPerUser);

        vm.warp(startAt + 1);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        runtime.withdrawIfNotStarted(sessionId);
        uint256 aliceAfter = usdc.balanceOf(alice);

        assertEq(aliceAfter, aliceBefore + requiredPerUser);

        vm.prank(alice);
        vm.expectRevert(bytes("NOTHING"));
        runtime.withdrawIfNotStarted(sessionId);
    }

    function test_Finalize_Cancels_WhenNotEnoughReady() external {
        uint64 instanceId = _createInstanceSmall();
        uint64 startAt = uint64(block.timestamp + 1 hours);
        uint32 durationSec = 3600;

        uint64 sessionId = _createSession(instanceId, 2, startAt, durationSec);

        vm.prank(alice);
        runtime.join(sessionId);

        uint256 requiredPerUser = _requiredPerUser(sessionId);
        vm.prank(alice);
        runtime.deposit(sessionId, requiredPerUser);

        vm.warp(startAt);
        runtime.finalize(sessionId);

        assertEq(
            uint256(_status(sessionId)),
            uint256(SharedServerRuntime.SessionStatus.Cancelled)
        );

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        runtime.withdrawIfNotStarted(sessionId);
        assertEq(usdc.balanceOf(alice), before + requiredPerUser);
    }

    function test_ProviderWithdraw_Reverts_IfNotProvider() external {
        uint64 instanceId = _createInstanceSmall();
        uint64 startAt = uint64(block.timestamp + 1 hours);
        uint32 durationSec = 3600;

        uint64 sessionId = _createSession(instanceId, 1, startAt, durationSec);

        vm.prank(alice);
        runtime.join(sessionId);

        uint256 requiredPerUser = _requiredPerUser(sessionId);
        vm.prank(alice);
        runtime.deposit(sessionId, requiredPerUser);

        vm.warp(startAt);
        runtime.finalize(sessionId);

        vm.prank(alice);
        vm.expectRevert(bytes("NOT_PROVIDER"));
        runtime.providerWithdraw(sessionId);
    }

    function test_CloseIfExpired_Reverts_IfTooEarly() external {
        uint64 instanceId = _createInstanceSmall();
        uint64 startAt = uint64(block.timestamp + 1 hours);
        uint32 durationSec = 3600;

        uint64 sessionId = _createSession(instanceId, 1, startAt, durationSec);

        vm.prank(alice);
        runtime.join(sessionId);

        uint256 requiredPerUser = _requiredPerUser(sessionId);
        vm.prank(alice);
        runtime.deposit(sessionId, requiredPerUser);

        vm.warp(startAt);
        runtime.finalize(sessionId);

        vm.expectRevert(bytes("NOT_EXPIRED"));
        runtime.closeIfExpired(sessionId);
    }

    function _requiredPerUser(
        uint64 sessionId
    ) internal view returns (uint256) {
        (, , , , , uint256 requiredPerUser, , , , , ) = runtime.sessions(
            sessionId
        );
        return requiredPerUser;
    }

    function _readyCount(uint64 sessionId) internal view returns (uint32) {
        (, , , , , , uint32 readyCount, , , , ) = runtime.sessions(sessionId);
        return readyCount;
    }

    function _totalDeposited(uint64 sessionId) internal view returns (uint256) {
        (, , , , , , , uint256 totalDeposited, , , ) = runtime.sessions(
            sessionId
        );
        return totalDeposited;
    }

    function _startTime(uint64 sessionId) internal view returns (uint64) {
        (, , , , , , , , , uint64 startTime, ) = runtime.sessions(sessionId);
        return startTime;
    }

    function _status(
        uint64 sessionId
    ) internal view returns (SharedServerRuntime.SessionStatus) {
        (, , , , , , , , , , SharedServerRuntime.SessionStatus status) = runtime
            .sessions(sessionId);
        return status;
    }
}
