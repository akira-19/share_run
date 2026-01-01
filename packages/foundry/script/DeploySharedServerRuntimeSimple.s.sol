// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./DeployHelpers.s.sol";
import "../contracts/SharedServerRuntimeSimple.sol";

/**
 * @notice Deploy script for SharedServerRuntimeSimple contract
 * @dev Reads constructor params from env:
 *      - USDC_ADDRESS
 *      - SMALL_RATE_PER_SEC
 *      - MEDIUM_RATE_PER_SEC
 *      - LARGE_RATE_PER_SEC
 */
contract DeploySharedServerRuntimeSimple is ScaffoldETHDeploy {
    function run() external ScaffoldEthDeployerRunner {
        address usdcAddress = vm.envAddress("USDC_ADDRESS");
        uint256 smallRate = vm.envUint("SMALL_RATE_PER_SEC");
        uint256 mediumRate = vm.envUint("MEDIUM_RATE_PER_SEC");
        uint256 largeRate = vm.envUint("LARGE_RATE_PER_SEC");

        new SharedServerRuntimeSimple(
            usdcAddress,
            smallRate,
            mediumRate,
            largeRate
        );
    }
}
