// SPDX-License-Identifier: None

pragma solidity 0.8.17;

/** @title LOAN Staking Strategy interface
 */
interface IHEXStrategy {
    function deposit(uint256 _wantAmt) external;

    function withdraw(
        address _user,
        uint256 _wantAmt,
        uint256 _burnAmount
    ) external;

    function stakeHEX() external;

    function claimAndDistributeRewards(
        uint256 stakeIndex,
        uint40 stakeIdParam,
        uint256 stakedAmount,
        uint256 lockedDay,
        uint256 stakedDays,
        uint256 currentDay
    ) external;
}
