// SPDX-License-Identifier: None

pragma solidity 0.8.17;

interface IMINTStaking {
    // --- Functions ---
    struct UserInfo {
        uint256 userStakedMint;
        uint256 unclaimedReward;
        uint256 yieldRate; // PLSPerMint: PLS yield per staked mint
        uint256 sumPLSRewardsTransferedToUser;
    }

    struct PoolInfo {
        uint256 totalStakedMint;
        uint256 yieldRateSum;
        uint256 lastDurationEndBlock;
        address stakeToken;
        uint256 stagedRewards;
    }

    function stake(uint mintAmount) external;

    function unstake(uint mintAmount) external;

    function harvest() external;

    function calculateUserProgressiveEstimatedYield(
        address _user
    ) external view returns (uint256 rewards);

    function getUserInfo(
        address _user
    ) external view returns (UserInfo memory _userInfo);

    function poolInfo() external view returns (PoolInfo memory _poolInfo);
}
