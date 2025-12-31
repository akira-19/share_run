// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./DeployHelpers.s.sol";
import "../contracts/SharedServerRuntime.sol";

/**
 * @notice Deploy script for SharedServerRuntime contract
 * @dev Reads constructor params from env:
 *      - USDC_ADDRESS
 *      - SMALL_RATE_PER_SEC
 *      - MEDIUM_RATE_PER_SEC
 *      - LARGE_RATE_PER_SEC
 */
contract DeploySharedServerRuntime is ScaffoldETHDeploy {
    function run() external ScaffoldEthDeployerRunner {
        address usdcAddress = vm.envAddress("USDC_ADDRESS");
        uint256 smallRate = vm.envUint("SMALL_RATE_PER_SEC");
        uint256 mediumRate = vm.envUint("MEDIUM_RATE_PER_SEC");
        uint256 largeRate = vm.envUint("LARGE_RATE_PER_SEC");

        new SharedServerRuntime(
            usdcAddress,
            smallRate,
            mediumRate,
            largeRate
        );
    }
}
