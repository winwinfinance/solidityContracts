// SPDX-License-Identifier: None

pragma solidity 0.8.17;

interface IMINTStaking {
    // --- Functions ---
    struct UserInfo {
        uint256 shares; // How many LP tokens the user has provided.
        uint256 rewardDebt;
    }

    function deposit(uint mintAmount) external;

    function withdraw(uint mintAmount) external;

    function harvest() external;

    function pendingRewards(address account) external view returns (uint256);

    function getUserInfo(
        address account
    ) external view returns (UserInfo memory);
}
