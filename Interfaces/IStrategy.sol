// SPDX-License-Identifier: None

pragma solidity 0.8.17;

/** @title Staking Strategy interface
 */
interface IStrategy {
    function deposit(uint256 _wantAmt) external;

    function withdraw(uint256 _wantAmt) external;

    function claimAndDistributeRewards() external;
}
