// SPDX-License-Identifier: None

pragma solidity 0.8.17;

/** @title Interface of Liquid Loans LOAN Staking contract
 */
interface ILOANStaking {
    // --- Functions ---

    function stake(uint256 _loanamount) external;

    function unstake(uint256 _loanamount) external;

    function getPendingPLSGain(address _user) external view returns (uint256);

    function getPendingUSDLGain(address _user) external view returns (uint256);

    function stakes(address _user) external view returns (uint256);
}
