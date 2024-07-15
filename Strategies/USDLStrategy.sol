/**
  ██╗   ███╗   ██╗ ██╗ ███╗   ██╗ ██╗   ███╗   ██╗ ██╗ ███╗   ██╗
  ██║  ██╔██╗  ██║ ██║ ████╗  ██║ ██║  ██╔██╗  ██║ ██║ ████╗  ██║           
  ██║ ██╔╝╚██╗ ██║ ██║ ██╔██╗ ██║ ██║ ██╔╝╚██╗ ██║ ██║ ██╔██╗ ██║          
  ██║██╔╝  ╚██╗██║ ██║ ██║╚██╗██║ ██║██╔╝  ╚██╗██║ ██║ ██║╚██╗██║         
  ████╔╝    ╚████║ ██║ ██║ ╚████║ ████╔╝    ╚████║ ██║ ██║ ╚████║         
  ╚═══╝      ╚═══╝ ╚═╝ ╚═╝  ╚═══╝ ╚═══╝      ╚═══╝ ╚═╝ ╚═╝  ╚═══╝
*/

// SPDX-License-Identifier: None

pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../Interfaces/IStabilityPool.sol";
import "../Interfaces/IStakingPool.sol";
import "../Interfaces/IUniswapV2Router.sol";
import "../Interfaces/IPrizePool.sol";

/** @title USDL Stability Pool contract
 * @notice This contract deposits in stability pool of USDL token and gets rewards in Loan and PLS
 */
contract USDLStrategy is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IStabilityPool private immutable _stabilityPool;

    //0->_usdlPrizePoolAddress
    //1->_winUSDLStakingAddress
    //2->_winPrizePoolAddress
    //3->_winStakingAddress
    //4->_buyAndBurnAddress
    address[5] private _distributionAddresses;

    address public constant WPLS_ADDRESS =
        0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address public routerAddress;
    uint16 public constant TOTAL_PERCENT = 10000;

    address private immutable _loanTokenAddress;
    address private immutable _usdlTokenAddress;
    address private _frontEndTag;

    uint256 private _slippage = 97;

    address[] path;

    //Increases 1 day after each claim
    uint256 public currentPrizeCycleStartTime;

    //0->_usdlPrizePoolPercent
    //1->_usdlStakingPercent
    //2->_winPrizePoolPercent
    //3->_winStakingPercent
    //4->_buyAndBurnPercent
    uint16[5] private _distributionPercentages;

    // --- Events ---
    event DistributedLOAN(address _account, uint256 _rewardLOAN);
    event userDeposit(address indexed user, uint256 lusdAmount);
    event userWithdraw(address indexed user, uint256 lusdAmount);

    event ChangeInteractingAddresses(
        address __usdlPrizePoolAddress,
        address __winUSDLStakingAddress,
        address __winPrizePoolAddress,
        address __winStakingAddress,
        address __buyAndBurnAddress
    );
    event UpdateDistributionPercentages(
        uint16 __usdlPrizePoolPercent,
        uint16 __usdlStakingPercent,
        uint16 __winPrizePoolPercent,
        uint16 __winStakingPercent,
        uint16 __buyAndBurnPercent
    );

    modifier onlyWinUSDLStaking() {
        require(msg.sender == _distributionAddresses[1], "Not WinUSDLStaking");
        _;
    }

    modifier onlyAfterOneDay() {
        require(
            (block.timestamp - currentPrizeCycleStartTime) > 86400,
            "Wait till one-day since last claimed time"
        );
        _;
    }

    /** @dev constructor intializing address of tokens and contracts to variables
     */
    constructor(
        address _routerAddress,
        address __loanTokenAddress,
        address __usdlTokenAddress,
        address __liquidLoanStabilityPoolAddress,
        address[5] memory __distributionAddresses,
        uint16[5] memory __distributionPercentages
    ) {
        require(_routerAddress != address(0), "Not valid address");
        require(__loanTokenAddress != address(0), "Not valid address");
        require(__usdlTokenAddress != address(0), "Not valid address");
        require(
            __liquidLoanStabilityPoolAddress != address(0),
            "Not valid address"
        );
        routerAddress = _routerAddress;
        _loanTokenAddress = __loanTokenAddress;
        _usdlTokenAddress = __usdlTokenAddress;
        _stabilityPool = IStabilityPool(__liquidLoanStabilityPoolAddress);

        for (uint8 i = 0; i < 5; ++i) {
            _distributionAddresses[i] = __distributionAddresses[i];
            _distributionPercentages[i] = __distributionPercentages[i];
        }
        currentPrizeCycleStartTime = block.timestamp;
    }

    /**
     * @notice Receives native currency
     */
    receive() external payable {}

    /**
     * @dev Sets pulseX router address to the contract.
     * Only the contract owner can call this function.
     * @param _routerAddress The address of the pulseX router.
     */

    function setRouterAddress(address _routerAddress) external onlyOwner {
        require(_routerAddress != address(0), "Invalid router address");
        routerAddress = _routerAddress;
    }

    /**
     * @dev Sets swap path in the contract.
     * Only the contract owner can call this function.
     * @param _path The addresses of the path.
     */

    function setSwapPath(address[] memory _path) external onlyOwner {
        uint256 pathLength = _path.length;
        require(pathLength > 1, "Path must have at least two addresses");
        require(_path[0] == WPLS_ADDRESS, "Starting token must be WPLS");
        require(
            _path[pathLength - 1] == _usdlTokenAddress,
            "Ending token must be USDL"
        );
        delete path;
        path = new address[](pathLength);
        for (uint256 i = 0; i < pathLength; i++) {
            require(_path[i] != address(0), "Zero address");
            path[i] = _path[i];
        }
    }

    /**  @notice Receives new deposits of USDL from owner
     * @param _lusdAmount is the amount to be staked
     */
    function deposit(uint256 _lusdAmount) external onlyWinUSDLStaking {
        require(_lusdAmount > 0, "amount must be non zero");

        IERC20(_usdlTokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            _lusdAmount
        );

        uint256 rewards = _claimRewardsAndSwapsPLS();
        if (block.timestamp > currentPrizeCycleStartTime + (1 days)) {
            claimAndDistributeRewards();
        }
        _farm(_lusdAmount + rewards);

        emit userDeposit(msg.sender, _lusdAmount);
    }

    /** @notice Withdraws USDL from stability pool along with LOAN rewards and pls
     *  @param _usdlAmount is the amount to be withdraw
     */
    function withdraw(uint256 _usdlAmount) external onlyWinUSDLStaking {
        require(_usdlAmount > 0, "amount must be non zero");
        uint256 rewards = _claimRewardsAndSwapsPLS();

        uint256 _totalUSDLDeposit = getPendingUSDLGain();

        if (_usdlAmount > (_totalUSDLDeposit + rewards)) {
            _usdlAmount = _totalUSDLDeposit + rewards;
        }

        uint256 remainingAmount;
        if (rewards >= _usdlAmount) {
            remainingAmount = rewards - _usdlAmount;
            if (remainingAmount > 0) {
                _farm(remainingAmount);
            }
        } else {
            remainingAmount = _usdlAmount - rewards;
            _unfarm(remainingAmount);
        }

        IERC20(_usdlTokenAddress).safeTransfer(msg.sender, _usdlAmount);
        if (block.timestamp > currentPrizeCycleStartTime + (1 days)) {
            claimAndDistributeRewards();
        }

        emit userWithdraw(msg.sender, _usdlAmount);
    }

    /**
     * @notice Function to update FrontEnd Tag Address
     * @param _newFrontendTag  new frontend tag address
     */
    function updateFrontEndTag(address _newFrontendTag) external onlyOwner {
        require(_newFrontendTag != address(0), "Not valid address");
        _frontEndTag = _newFrontendTag;
    }

    /**
     * @dev used to update the slippage
     * @param _newSlippage new slippage to be used
     */
    function updateSlippage(uint256 _newSlippage) external onlyOwner {
        _slippage = _newSlippage;
    }

    /** @notice Changes Win USDL staking address
     * @param _updatedDistributionAddresses new distribution addresses
     */
    function changeDistributionAddresses(
        address[5] memory _updatedDistributionAddresses
    ) external virtual onlyOwner {
        for (uint256 i = 0; i < 5; ++i) {
            if (_distributionAddresses[i] != _updatedDistributionAddresses[i]) {
                _distributionAddresses[i] = _updatedDistributionAddresses[i];
            }
        }

        emit ChangeInteractingAddresses(
            _updatedDistributionAddresses[0],
            _updatedDistributionAddresses[1],
            _updatedDistributionAddresses[2],
            _updatedDistributionAddresses[3],
            _updatedDistributionAddresses[4]
        );
    }

    /**
     * @notice Updates distribution percentages
     * @param _updatedDistributionPercentages updated distribution percentages
     */
    function updateDistributionPercentages(
        uint16[5] memory _updatedDistributionPercentages
    ) external virtual onlyOwner {
        uint16 calculateTotal;
        for (uint256 i = 0; i < 5; ++i) {
            if (
                _distributionPercentages[i] !=
                _updatedDistributionPercentages[i]
            ) {
                _distributionPercentages[i] = _updatedDistributionPercentages[
                    i
                ];
            }
            calculateTotal += _updatedDistributionPercentages[i];
        }

        require(calculateTotal == TOTAL_PERCENT, "Sum of shares is not 10000.");

        emit UpdateDistributionPercentages(
            _updatedDistributionPercentages[0],
            _updatedDistributionPercentages[1],
            _updatedDistributionPercentages[2],
            _updatedDistributionPercentages[3],
            _updatedDistributionPercentages[4]
        );
    }

    /** @notice Transfers stuck tokens to a goven address
     * @param _token is address of the stuck token
     * @param _amount is te amount to be transferred
     * @param _to account to which owner want to transfer tokens
     */
    function inCaseTokensGetStuck(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOwner {
        require(_token != _loanTokenAddress, "Can not send LOAN tokens");
        require(_token != _usdlTokenAddress, "Can not send USDL tokens");
        require(_token != WPLS_ADDRESS, "Can not send WPLS tokens");
        IERC20(_token).safeTransfer(_to, _amount);
    }

    /** @notice Claim rewards got from staking in USDLStaking */
    function claimAndDistributeRewards() public onlyAfterOneDay nonReentrant {
        uint256 noOfDays = (block.timestamp - currentPrizeCycleStartTime) /
            1 days;
        currentPrizeCycleStartTime += (noOfDays * 86400);
        harvest();
        uint256 _rewardLOAN = IERC20(_loanTokenAddress).balanceOf(
            address(this)
        );

        if (_rewardLOAN > 0) {
            // Distributing to USDL Prize pool
            _distributeToPrizePool(
                _rewardLOAN,
                _distributionAddresses[0],
                _distributionPercentages[0]
            );
            // Distributing to USDL Staking pool
            _sendToStakingContracts(
                _rewardLOAN,
                _distributionAddresses[1],
                _distributionPercentages[1]
            );
            // Distributing to Win Prize pool
            _distributeToPrizePool(
                _rewardLOAN,
                _distributionAddresses[2],
                _distributionPercentages[2]
            );
            // Distributing to Win Staking pool
            _sendToStakingContracts(
                _rewardLOAN,
                _distributionAddresses[3],
                _distributionPercentages[3]
            );
            // Distributing to buy and burn address
            _distributeTo(
                _rewardLOAN,
                _distributionAddresses[4],
                _distributionPercentages[4]
            );
        }
    }

    /**
     * getter functions
     */

    /**
     * @notice returns the frontend stake amount
     * @return the frontend stake amount
     */
    function checkFrontEndStake() external view returns (uint256) {
        return _stabilityPool.getCompoundedFrontEndStake(_frontEndTag);
    }

    /**
     * @notice getter function for Frontend Tag address
     * @return address of the Frontend Tag
     */
    function getFrontEndTagAddress() external view returns (address) {
        return _frontEndTag;
    }

    /**
     * @notice getter function for Loan Token address
     * @return address of the Loan Token
     */
    function getLOANTokenAddress() external view returns (address) {
        return _loanTokenAddress;
    }

    /**
     * @notice getter function for Usdl Token address
     * @return address of the Usdl Token
     */
    function getUSDLTokenAddress() external view returns (address) {
        return _usdlTokenAddress;
    }

    /**
     * @notice getter function for Stability Pool address
     * @return address of the Stability Pool
     */
    function getLiquidLoanUSDLStabilityPoolAddress()
        external
        view
        returns (IStabilityPool)
    {
        return _stabilityPool;
    }

    /**
     * @notice getter function for Usdl Prize pool address
     * @return address of the Usdl prize pool
     */
    function getUSDLPrizePoolAddress() external view returns (address) {
        return _distributionAddresses[0];
    }

    /**
     * @notice getter function for WinWin project's Usdl Staking address
     * @return address of the WinWin project's Usdl Staking pool
     */
    function getWinUSDLStakingAddress() external view returns (address) {
        return _distributionAddresses[1];
    }

    /**
     * @notice getter function for Win Prize pool address
     * @return address of the Win Prize pool
     */
    function getWinPrizePoolAddress() external view returns (address) {
        return _distributionAddresses[2];
    }

    /**
     * @notice getter function for Win Staking address
     * @return address of the Win Staking pool
     */
    function getWinStakingAddress() external view returns (address) {
        return _distributionAddresses[3];
    }

    /**
     * @notice getter function for buyAndBurn address
     * @return address of the buyAndBurn account
     */
    function getBuyAndBurnAddress() external view returns (address) {
        return _distributionAddresses[4];
    }

    function getLastClaimedTime() external view returns (uint256) {
        return currentPrizeCycleStartTime;
    }

    function getUSDLPrizePoolPercent() external view returns (uint16) {
        return _distributionPercentages[0];
    }

    /**
     * @notice getter function for Usdl Staking pool percent
     * @return Usdl Staking pool share of total share
     */
    function getUSDLStakingPercent() external view returns (uint16) {
        return _distributionPercentages[1];
    }

    /**
     * @notice getter function for Win Prize Pool percent
     * @return Win Prize Pool share of total share
     */
    function getWinPrizePoolPercent() external view returns (uint16) {
        return _distributionPercentages[2];
    }

    /**
     * @notice getter function for win Staking pool percent
     * @return win Staking pool share of total share
     */
    function getWinStakingPercent() external view returns (uint16) {
        return _distributionPercentages[3];
    }

    /**
     * @notice getter function for buyAndBurn percent
     * @return buyAndBurn share of total share
     */
    function getBuyAndBurnPercent() external view returns (uint16) {
        return _distributionPercentages[4];
    }

    /**
     * @notice returns the depositor Loan gain amount
     * @return the depositor loan gain amount
     */
    function getDepositorLoanGain() external view returns (uint256) {
        return (_stabilityPool.getDepositorLOANGain(address(this)));
    }

    /**
     * @notice returns the frontend Loan gain amount
     * @return the frontend loan gain amount
     */
    function getFrontEndLOANGain() external view returns (uint256) {
        return _stabilityPool.getFrontEndLOANGain(_frontEndTag);
    }

    /**
     * @notice harvest function send all reward tokens to contract's address
     */

    function harvest() public {
        uint256 rewards = _claimRewardsAndSwapsPLS();
        if (rewards > 0) {
            _farm(rewards);
        }
    }

    /**
     * @notice gets pending PLS rewards value
     * @return PLS value
     */
    function getPendingPLSGain() public view returns (uint256) {
        return (_stabilityPool.getDepositorPLSGain(address(this)));
    }

    /**
     * @notice gets pending USDL rewards value
     * @return USDL value
     */
    function getPendingUSDLGain() public view returns (uint256) {
        return (_stabilityPool.getCompoundedUSDLDeposit(address(this)));
    }

    /** --internal functions--
     * @notice This function deposits usdl in contract to stability pool.
     * @param _lusdAmount amount of USDL tokens
     */

    function _farm(uint256 _lusdAmount) internal virtual {
        if (_lusdAmount > 0) {
            _stabilityPool.provideToSP(_lusdAmount, _frontEndTag);
        }
    }

    /**
     * @notice This function withdraws USDL from stability pool
     */
    function _unfarm(uint256 _lusdAmount) internal virtual {
        _stabilityPool.withdrawFromSP(_lusdAmount);
    }

    /**
     * @notice Distribures LOAN tokens
     * @param _rewardLOAN is the total Loan reward
     * @param _poolAddress is the address to which PLS and LOAN to be sent
     * @param _poolSharePercent is the share of respective pool
     */
    function _sendToStakingContracts(
        uint256 _rewardLOAN,
        address _poolAddress,
        uint256 _poolSharePercent
    ) internal virtual {
        // calculating LOAN rewards share of the address
        uint256 shareOfLOAN = (_rewardLOAN * _poolSharePercent) / TOTAL_PERCENT;
        if (shareOfLOAN > 0) {
            // transfering LOAN tokens to the address
            IERC20(_loanTokenAddress).safeApprove(_poolAddress, shareOfLOAN);
            IStakingPool(_poolAddress).notifyRewardAmount(
                _loanTokenAddress,
                shareOfLOAN
            );
            emit DistributedLOAN(_poolAddress, shareOfLOAN);
        }
    }

    /**
     * @notice Distribures of LOAN
     * @param _rewardLOAN is the total LOAN reward
     * @param _poolAddress is the address to which PLS and LOAN to be sent
     * @param _poolSharePercent is the share of respective pool
     */
    function _distributeTo(
        uint256 _rewardLOAN,
        address _poolAddress,
        uint256 _poolSharePercent
    ) internal virtual {
        // calculating LOAN rewards share of the address
        uint256 shareOfLOAN = (_rewardLOAN * _poolSharePercent) / TOTAL_PERCENT;
        if (shareOfLOAN > 0) {
            // transfering LOAN tokens to the address
            IERC20(_loanTokenAddress).safeTransfer(_poolAddress, shareOfLOAN);
            emit DistributedLOAN(_poolAddress, shareOfLOAN);
        }
    }

    /**
     * @notice Distribures of LOAN to prizePool
     * @param _rewardLOAN is the total LOAN reward
     * @param _poolAddress is the address to which PLS and LOAN to be sent
     * @param _poolSharePercent is the share of respective pool
     */
    function _distributeToPrizePool(
        uint256 _rewardLOAN,
        address _poolAddress,
        uint256 _poolSharePercent
    ) internal virtual {
        // calculating LOAN rewards share of the address
        uint256 shareOfLOAN = (_rewardLOAN * _poolSharePercent) / TOTAL_PERCENT;
        if (shareOfLOAN > 0) {
            // transfering LOAN tokens to the address
            // IERC20(_loanTokenAddress).transfer(_poolAddress, shareOfLOAN);
            IERC20(_loanTokenAddress).safeApprove(_poolAddress, shareOfLOAN);
            IPrizePool(_poolAddress).addPrizes(_loanTokenAddress, shareOfLOAN);
            emit DistributedLOAN(_poolAddress, shareOfLOAN);
        }
    }

    // --private functions--
    /**
     * @notice  claim PLS and LOAN rewards
     */
    function _claimRewards() private {
        if (getPendingUSDLGain() > 0) {
            _stabilityPool.withdrawFromSP(0);
        }
    }

    /**
     *@notice claim and swaps
     */

    function _claimRewardsAndSwapsPLS() private returns (uint256 rewards) {
        _claimRewards();
        uint256 _rewardPLS = address(this).balance;
        if (_rewardPLS > 0) {
            rewards = _swapPLSforUSDL(_rewardPLS);
        }
    }

    /** @notice Swap PLS for USDL
     *
     */
    function _swapPLSforUSDL(
        uint256 _rewardPLS
    ) private returns (uint256 amountOut) {
        uint256[] memory _amountOutMin = IUniswapV2Router(routerAddress)
            .getAmountsOut(_rewardPLS, path);
        uint256 amountOutMin = (_amountOutMin[_amountOutMin.length - 1] *
            _slippage) / 100;

        uint256[] memory amounts = IUniswapV2Router(routerAddress)
            .swapExactETHForTokens{value: _rewardPLS}(
            amountOutMin,
            path,
            address(this),
            block.timestamp + 600
        );

        return amounts[amounts.length - 1];
    }
}
