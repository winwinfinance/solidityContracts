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
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../Interfaces/IMINTStaking.sol";
import "../Interfaces/IStakingPool.sol";
import "../Interfaces/IWETH.sol";
import "../Interfaces/IPrizePool.sol";

/**
 * @title mint Staking Strategy contract
 * @notice This contract farms mint tokens and gets yield in PLS
 */
contract MINTRAStrategy is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    //0->_mintPrizePoolAddress
    //1->_winMINTStakingAddress
    //2->_winPrizePoolAddress
    //3->_winStakingAddress
    //4->_buyAndBurnAddress
    address[5] private _distributionAddresses;

    address public constant WPLS_ADDRESS =
        0xA1077a294dDE1B09bB078844df40758a5D0f9a27;

    uint16 public constant TOTAL_PERCENT = 10000;

    address private immutable _mintTokenAddress;
    address private immutable _originalMINTStakingAddress; // mintStaking etc

    uint256 private _wantLockedTotal = 0;

    //Increases 1 day after each claim
    uint256 public currentPrizeCycleStartTime;

    //0->_mintPrizePoolPercent
    //1->_mintStakingPercent
    //2->_winPrizePoolPercent
    //3->_winStakingPercent
    //4->_buyAndBurnPercent
    uint16[5] private _distributionPercentages;

    // --- Events ---
    event DistributedPLS(address _account, uint256 _rewardPLS);
    event DepositedMINTTokens(address _from, uint256 _wantAmt);
    event WithdrawnMINTTokens(address _to, uint256 _wantAmt);
    event ChangeInteractingAddresses(
        address __mintPrizePoolAddress,
        address __winMINTStakingAddress,
        address __winPrizePoolAddress,
        address __winStakingAddress,
        address __buyAndBurnAddress
    );
    event UpdateDistributionPercentages(
        uint16 __mintPrizePoolPercent,
        uint16 __mintStakingPercent,
        uint16 __winPrizePoolPercent,
        uint16 __winStakingPercent,
        uint16 __buyAndBurnPercent
    );

    modifier onlyWinMINTStaking() {
        require(msg.sender == _distributionAddresses[1], "Not WinMINTStaking");
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
        address __mintTokenAddress,
        address __originalMINTStakingAddress,
        address[5] memory __distributionAddresses,
        uint16[5] memory __distributionPercentages
    ) {
        require(__mintTokenAddress != address(0), "Not valid address");
        require(
            __originalMINTStakingAddress != address(0),
            "Not valid address"
        );
        _mintTokenAddress = __mintTokenAddress;
        _originalMINTStakingAddress = __originalMINTStakingAddress;
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
     * @notice Receives new deposits from owner
     * @param _wantAmt is the amount to be staked
     */
    function deposit(uint256 _wantAmt) external virtual onlyWinMINTStaking {
        require(_wantAmt > 0, "_wantAmt <= 0");
        IERC20(_mintTokenAddress).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );
        _farm();

        if (block.timestamp > currentPrizeCycleStartTime + (1 days)) {
            claimAndDistributeRewards();
        }
        emit DepositedMINTTokens(_distributionAddresses[1], _wantAmt);
    }

    /**
     * @notice Withdraws amount from MINTStaking
     *  @param _wantAmt is the amount to be unstaked
     */
    function withdraw(uint256 _wantAmt) external virtual onlyWinMINTStaking {
        require(_wantAmt > 0, "_wantAmt <= 0");
        if (block.timestamp > currentPrizeCycleStartTime + (1 days)) {
            claimAndDistributeRewards();
        }
        _unfarm(_wantAmt);

        IERC20(_mintTokenAddress).safeTransfer(
            _distributionAddresses[1],
            _wantAmt
        );
        emit WithdrawnMINTTokens(_distributionAddresses[1], _wantAmt);
    }

    /**
     * @notice Changes Win MINT staking address
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

    /**
     * @notice Transfers stuck tokens to a goven address
     * @param _token is address of the stuck token
     * @param _amount is te amount to be transferred
     */
    function inCaseTokensGetStuck(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOwner {
        require(_token != _mintTokenAddress, "Can not send MINT tokens");
        require(_token != WPLS_ADDRESS, "can not send pls tokens");
        IERC20(_token).safeTransfer(_to, _amount);
    }

    /**
     * @notice Claim and distribute the rewards got from staking in MINTStaking
     * User can access this function that once in a day
     * The rewards are distributed as per the share of the respectve pool.
     * */
    function claimAndDistributeRewards() public onlyAfterOneDay nonReentrant {
        uint256 noOfDays = (block.timestamp - currentPrizeCycleStartTime) /
            86400;
        currentPrizeCycleStartTime =
            currentPrizeCycleStartTime +
            (noOfDays * 86400);
        // claiming pending rewards
        IMINTStaking(_originalMINTStakingAddress).harvest();
        uint256 _rewardPLS = address(this).balance;

        if (_rewardPLS > 0) {
            // Distributing to MINT Prize pool
            _distributeToPrizePool(
                _rewardPLS,
                _distributionAddresses[0],
                _distributionPercentages[0]
            );
            // Distributing to MINT Staking pool
            _sendToStakingContracts(
                _rewardPLS,
                _distributionAddresses[1],
                _distributionPercentages[1]
            );
            // Distributing to Win Prize pool
            _distributeToPrizePool(
                _rewardPLS,
                _distributionAddresses[2],
                _distributionPercentages[2]
            );
            // Distributing to Win Staking pool
            _sendToStakingContracts(
                _rewardPLS,
                _distributionAddresses[3],
                _distributionPercentages[3]
            );
            // Distributing to buy and burn address
            _distributeTo(
                _rewardPLS,
                _distributionAddresses[4],
                _distributionPercentages[4]
            );
        }
    }

    /// getter functions

    /**
     * @notice gets pending PLS rewards value
     * @return PLS value
     */
    function getPendingPLSGain() external view returns (uint256) {
        return (
            IMINTStaking(_originalMINTStakingAddress)
                .calculateUserProgressiveEstimatedYield(address(this))
        );
    }

    /**
     * @notice getter function for Mint Token address
     * @return address of the Mint Token
     */
    function getMINTTokenAddress() external view returns (address) {
        return _mintTokenAddress;
    }

    /**
     * @notice getter function for Actual Mint Staking address
     * @return address of the actual Mint Staking contract
     */
    function getOriginalMINTStakingAddress() external view returns (address) {
        return _originalMINTStakingAddress;
    }

    /**
     * @notice getter function for Mint Prize pool address
     * @return address of the Mint prize pool
     */
    function getMINTPrizePoolAddress() external view returns (address) {
        return _distributionAddresses[0];
    }

    /**
     * @notice getter function for WinWin project's Mint Staking address
     * @return address of the WinWin project's Mint Staking pool
     */
    function getWinMINTStakingAddress() external view returns (address) {
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

    /**
     * @notice getter function for total locked tokens
     * @return value of total Mint tokens currently in use by this strategy
     */
    function getWantLockedTotal() external view returns (uint256) {
        return _wantLockedTotal;
    }

    /**
     * @notice getter function for time stamp
     * @return timestamp of rewards claimed last time
     */
    function getLastClaimedTime() external view returns (uint256) {
        return currentPrizeCycleStartTime;
    }

    /**
     * @notice getter function for MINT Prize pool percent
     * @return MINT Prize pool share of total share
     */
    function getMINTPrizePoolPercent() external view returns (uint16) {
        return _distributionPercentages[0];
    }

    /**
     * @notice getter function for MINT Staking pool percent
     * @return MINT Staking pool share of total share
     */
    function getMINTStakingPercent() external view returns (uint16) {
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

    /** --internal functions--
     * @notice farm function stakes the MINT tokens to MINTStaking
     */
    function _farm() internal virtual {
        uint256 wantAmt = IERC20(_mintTokenAddress).balanceOf(address(this));

        if (wantAmt > 0) {
            _wantLockedTotal = _wantLockedTotal + wantAmt;

            IERC20(_mintTokenAddress).safeApprove(
                _originalMINTStakingAddress,
                wantAmt
            );
            IMINTStaking(_originalMINTStakingAddress).stake(wantAmt);
        }
    }

    /** @notice farm function unstakes the MINT tokens from MINTStaking */
    function _unfarm(uint256 _wantAmt) internal virtual {
        _wantLockedTotal = _wantLockedTotal - _wantAmt;
        IMINTStaking(_originalMINTStakingAddress).unstake(_wantAmt);
    }

    /**
     * @notice Distribures PLS
     * @param _rewardPLS is the total PLS reward
     * @param _poolAddress is the address to which PLS to be sent
     * @param _poolSharePercent is the share of respective pool
     */
    function _sendToStakingContracts(
        uint256 _rewardPLS,
        address _poolAddress,
        uint256 _poolSharePercent
    ) internal virtual {
        // calculating PLS rewards share of the address
        uint256 shareOfPLS = (_rewardPLS * _poolSharePercent) / TOTAL_PERCENT;
        //Sending PLS to the address
        if (shareOfPLS > 0) {
            IWETH(WPLS_ADDRESS).deposit{value: shareOfPLS}();
            IERC20(WPLS_ADDRESS).safeApprove(_poolAddress, shareOfPLS);
            IStakingPool(_poolAddress).notifyRewardAmount(
                WPLS_ADDRESS,
                shareOfPLS
            );
            emit DistributedPLS(_poolAddress, shareOfPLS);
        }
    }

    /**
     * @notice Distribures PLS
     * @param _rewardPLS is the total PLS reward
     * @param _poolAddress is the address to which PLS to be sent
     * @param _poolSharePercent is the share of respective pool
     */
    function _distributeTo(
        uint256 _rewardPLS,
        address _poolAddress,
        uint256 _poolSharePercent
    ) internal virtual {
        // calculating PLS rewards share of the address
        uint256 shareOfPLS = (_rewardPLS * _poolSharePercent) / TOTAL_PERCENT;
        //Sending PLS to the address
        if (shareOfPLS > 0) {
            (bool success, ) = payable(_poolAddress).call{value: shareOfPLS}(
                ""
            );

            if (success) {
                emit DistributedPLS(_poolAddress, shareOfPLS);
            }
        }
    }

    /**
     * @notice Distribures PLS to PrizePool
     * @param _rewardPLS is the total PLS reward
     * @param _poolAddress is the address to which PLS to be sent
     * @param _poolSharePercent is the share of respective pool
     */
    function _distributeToPrizePool(
        uint256 _rewardPLS,
        address _poolAddress,
        uint256 _poolSharePercent
    ) internal virtual {
        // calculating PLS rewards share of the address
        uint256 shareOfPLS = (_rewardPLS * _poolSharePercent) / TOTAL_PERCENT;

        //Sending PLS to the address
        if (shareOfPLS > 0) {
            IWETH(WPLS_ADDRESS).deposit{value: shareOfPLS}();
            IERC20(WPLS_ADDRESS).safeApprove(_poolAddress, shareOfPLS);
            IPrizePool(_poolAddress).addPrizes(WPLS_ADDRESS, shareOfPLS);
            emit DistributedPLS(_poolAddress, shareOfPLS);
        }
    }
}
