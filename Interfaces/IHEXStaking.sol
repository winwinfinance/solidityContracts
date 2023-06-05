// SPDX-License-Identifier: None

pragma solidity 0.8.17;

interface IHEXStaking {
    struct StakeStore {
        uint40 stakeId;
        uint72 stakedHearts;
        uint72 stakeShares;
        uint16 lockedDay;
        uint16 stakedDays;
        uint16 unlockedDay;
        bool isAutoStake;
    }

    // --- Functions ---

    function stakeStart(
        uint256 newStakedHearts,
        uint256 newStakedDays
    ) external;

    function stakeGoodAccounting(
        address stakerAddr,
        uint256 stakeIndex,
        uint40 stakeIdParam
    ) external;

    function stakeEnd(uint256 stakeIndex, uint40 stakeIdParam) external;

    function currentDay() external view returns (uint256);

    function stakeLists(
        address stakerAddr,
        uint256 stakeIndex
    ) external view returns (StakeStore memory);

    function stakeCount(address stakerAddr) external view returns (uint256);
}
