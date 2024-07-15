/**
  ██╗   ███╗   ██╗ ██╗ ███╗   ██╗ ██╗   ███╗   ██╗ ██╗ ███╗   ██╗
  ██║  ██╔██╗  ██║ ██║ ████╗  ██║ ██║  ██╔██╗  ██║ ██║ ████╗  ██║           
  ██║ ██╔╝╚██╗ ██║ ██║ ██╔██╗ ██║ ██║ ██╔╝╚██╗ ██║ ██║ ██╔██╗ ██║          
  ██║██╔╝  ╚██╗██║ ██║ ██║╚██╗██║ ██║██╔╝  ╚██╗██║ ██║ ██║╚██╗██║         
  ████╔╝    ╚████║ ██║ ██║ ╚████║ ████╔╝    ╚████║ ██║ ██║ ╚████║         
  ╚═══╝      ╚═══╝ ╚═╝ ╚═╝  ╚═══╝ ╚═══╝      ╚═══╝ ╚═╝ ╚═╝  ╚═══╝
*/

//SPDX-License-Identifier: None
pragma solidity 0.8.17;

import "./StakingPool.sol";
import "../Interfaces/IStrategy.sol";

contract YieldStakingPool is StakingPool {
    using SafeERC20 for IERC20;

    address private _strategyAddress;

    constructor(address __stakingToken) StakingPool(__stakingToken) {}

    /**
     * @dev Updates strategy address
     * @param _strategy address of strategy contract
     */
    function modifyStrategyAddress(address _strategy) external onlyOwner {
        require(_strategy != address(0), "Not valid address");
        require(
            _strategy != _strategyAddress,
            "This is current strategy address."
        );
        _strategyAddress = _strategy;
    }

    /**
     * @dev returns the strategy contract address
     */
    function getStrategyAddress() external view returns (address) {
        return _strategyAddress;
    }

    /**
     * @dev deposits to the Strategy
     * @param _amount amount to be deposited
     */
    function _deposit(uint256 _amount) internal override {
        stakingToken.safeApprove(_strategyAddress, _amount);

        IStrategy(_strategyAddress).deposit(_amount);
    }

    /**
     * @dev withdraw from the Strategy
     * @param _amount amount to withdraw
     */
    function _withdraw(uint256 _amount) internal override {
        IStrategy(_strategyAddress).withdraw(_amount);
    }
}
