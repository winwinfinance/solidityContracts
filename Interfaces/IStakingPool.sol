//SPDX-License-Identifier: None
pragma solidity 0.8.17;

interface IStakingPool {
    function notifyRewardAmount(
        address _rewardsToken,
        uint256 _rewardAmount
    ) external;

    function getBalanceAt(
        address _user,
        uint64 _target
    ) external view returns (uint256);

    function getTotalSupplyAt(uint64 _target) external view returns (uint256);
}
