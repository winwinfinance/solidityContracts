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
import "../Interfaces/ILOANStaking.sol";
import "../Interfaces/IStakingPool.sol";
import "../Interfaces/IWETH.sol";
import "../Interfaces/IPrizePool.sol";

/** @title LOAN Staking Strategy contract
 * @notice This contract farms LOAN tokens and gets yield in USDL and PLS
 */
contract LOANStrategy is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    //0->_loanPrizePoolAddress
    //1->_winLOANStakingAddress
    //2->_winPrizePoolAddress
    //3->_winStakingAddress
    //4->_buyAndBurnAddress
    address[5] private _distributionAddresses;

    address public constant WPLS_ADDRESS =
        0xA1077a294dDE1B09bB078844df40758a5D0f9a27;

    uint16 public constant TOTAL_PERCENT = 10000;
    address private immutable _loanTokenAddress;
    address private immutable _usdlTokenAddress;
    address private immutable _liquidLoanLOANStakingAddress; // LOANStaking(LiquidLoans) etc

    uint256 private _wantLockedTotal = 0;

    //Increases 1 day after each claim
    uint256 public currentPrizeCycleStartTime;

    //0->_loanPrizePoolPercent
    //1->_loanStakingPercent
    //2->_winPrizePoolPercent
    //3->_winStakingPercent
    //4->_buyAndBurnPercent
    uint16[5] private _distributionPercentages;

    // --- Events ---
    event DistributedPLS(address _account, uint256 _rewardPLS);
    event DistributedUSDL(address _account, uint256 _rewardUSDL);
    event DepositedLOANTokens(address _from, uint256 _wantAmt);
    event WithdrawnLOANTokens(address _to, uint256 _wantAmt);
    event ChangeInteractingAddresses(
        address __loanPrizePoolAddress,
        address __winLOANStakingAddress,
        address __winStakingAddress,
        address __winPrizePoolAddress,
        address __buyAndBurnAddress
    );
    event UpdateDistributionPercentages(
        uint16 __loanPrizePoolPercent,
        uint16 __loanStakingPercent,
        uint16 __winPrizePoolPercent,
        uint16 __winStakingPercent,
        uint16 __buyAndBurnPercent
    );

    modifier onlyWinLOANStaking() {
        require(msg.sender == _distributionAddresses[1], "Not WinLOANStaking");
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
        address __loanTokenAddress,
        address __usdlTokenAddress,
        address __liquidLoanLOANStakingAddress,
        address[5] memory __distributionAddresses,
        uint16[5] memory __distributionPercentages
    ) {
        require(__loanTokenAddress != address(0), "Not valid address");
        require(__usdlTokenAddress != address(0), "Not valid address");
        require(
            __liquidLoanLOANStakingAddress != address(0),
            "Not valid address"
        );
        _loanTokenAddress = __loanTokenAddress;
        _usdlTokenAddress = __usdlTokenAddress;
        _liquidLoanLOANStakingAddress = __liquidLoanLOANStakingAddress;
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

    /**  @notice Receives new deposits from owner
     * @param _wantAmt is the amount to be staked
     */
    function deposit(uint256 _wantAmt) external virtual onlyWinLOANStaking {
        require(_wantAmt > 0, "_wantAmt <= 0");
        IERC20(_loanTokenAddress).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );
        _farm();
        if (block.timestamp > currentPrizeCycleStartTime + (1 days)) {
            claimAndDistributeRewards();
        }
        emit DepositedLOANTokens(_distributionAddresses[1], _wantAmt);
    }

    /** @notice Withdraws amount from LOANStaking
     *  @param _wantAmt is the amount to be staked
     */
    function withdraw(uint256 _wantAmt) external virtual onlyWinLOANStaking {
        require(_wantAmt > 0, "_wantAmt <= 0");

        if (block.timestamp > currentPrizeCycleStartTime + (1 days)) {
            claimAndDistributeRewards();
        }

        _unfarm(_wantAmt);

        IERC20(_loanTokenAddress).safeTransfer(
            _distributionAddresses[1],
            _wantAmt
        );
        emit WithdrawnLOANTokens(_distributionAddresses[1], _wantAmt);
    }

    /** @notice Changes Win LOAN staking address
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

    /** @notice Claim rewards got from staking in LOANStaking */
    function claimAndDistributeRewards() public onlyAfterOneDay nonReentrant {
        uint256 noOfDays = (block.timestamp - currentPrizeCycleStartTime) /
            86400;
        currentPrizeCycleStartTime =
            currentPrizeCycleStartTime +
            (noOfDays * 86400);
        // claiming pending rewards
        ILOANStaking(_liquidLoanLOANStakingAddress).unstake(0);
        uint256 _rewardPLS = address(this).balance;
        uint256 _rewardUSDL = IERC20(_usdlTokenAddress).balanceOf(
            address(this)
        );

        if (_rewardPLS > 0 || _rewardUSDL > 0) {
            // Distributing to Loan Prize pool
            _distributeToPrizePool(
                _rewardPLS,
                _rewardUSDL,
                _distributionAddresses[0],
                _distributionPercentages[0]
            );
            // Distributing to Loan Staking pool
            _sendToStakingContracts(
                _rewardPLS,
                _rewardUSDL,
                _distributionAddresses[1],
                _distributionPercentages[1]
            );
            // Distributing to Win Prize pool
            _distributeToPrizePool(
                _rewardPLS,
                _rewardUSDL,
                _distributionAddresses[2],
                _distributionPercentages[2]
            );
            // Distributing to Win Staking pool
            _sendToStakingContracts(
                _rewardPLS,
                _rewardUSDL,
                _distributionAddresses[3],
                _distributionPercentages[3]
            );
            // Distributing to buy and burn address
            _distributeTo(
                _rewardPLS,
                _rewardUSDL,
                _distributionAddresses[4],
                _distributionPercentages[4]
            );
        }
    }

    /**
     * getter functions
     */

    /**
     * @notice getter function for total staked Tokens
     * @return value of total staked Tokens
     */
    function getTotalStakedBalance() external view returns (uint256) {
        return
            ILOANStaking(_liquidLoanLOANStakingAddress).stakes(address(this));
    }

    /**
     * @notice getter function for PLS gain
     * @return value of PLS gain
     */
    function getPendingPLSGain() external view returns (uint256) {
        return (
            ILOANStaking(_liquidLoanLOANStakingAddress).getPendingPLSGain(
                address(this)
            )
        );
    }

    /**
     * @notice getter function for USDL gain
     * @return value of USDL gain
     */
    function getPendingUSDLGain() external view returns (uint256) {
        return (
            ILOANStaking(_liquidLoanLOANStakingAddress).getPendingUSDLGain(
                address(this)
            )
        );
    }

    /**
     * @notice getter function for LOAN Token address
     * @return address of the LOAN Token
     */
    function getLOANTokenAddress() external view returns (address) {
        return _loanTokenAddress;
    }

    /**
     * @notice getter function for USDL Token address
     * @return address of the USDL Token
     */
    function getUSDLTokenAddress() external view returns (address) {
        return _usdlTokenAddress;
    }

    /**
     * @notice getter function for win LOAN staking address
     * @return address of the win LOAN staking
     */
    function getLiquidLoanLOANStakingAddress() external view returns (address) {
        return _liquidLoanLOANStakingAddress;
    }

    /**
     * @notice getter function for Loan Prize Pool Address
     * @return address of the Loan Prize Pool
     */
    function getLoanPrizePoolAddress() external view returns (address) {
        return _distributionAddresses[0];
    }

    /**
     * @notice getter function for Win LOAN Staking Address
     * @return address of the Win LOAN Staking
     */
    function getWinLOANStakingAddress() external view returns (address) {
        return _distributionAddresses[1];
    }

    /**
     * @notice getter function for Win Prize Pool Address
     * @return address of the Win Prize Pool
     */
    function getWinPrizePoolAddress() external view returns (address) {
        return _distributionAddresses[2];
    }

    /**
     * @notice getter function for Win Staking Address
     * @return address of the Win Staking
     */
    function getWinStakingAddress() external view returns (address) {
        return _distributionAddresses[3];
    }

    /**
     * @notice getter function for BuyAndBurn Address
     * @return address of the BuyAndBurn
     */
    function getBuyAndBurnAddress() external view returns (address) {
        return _distributionAddresses[4];
    }

    /**
     * @notice getter function for total staked LOAN tokens
     * @return value of total staked LOAN tokens
     */
    function getWantLockedTotal() external view returns (uint256) {
        return _wantLockedTotal;
    }

    /**
     * @notice getter function for last claimed time of rewards
     * @return time of last claimed rewards
     */
    function getLastClaimedTime() external view returns (uint256) {
        return currentPrizeCycleStartTime;
    }

    /**
     * @notice getter function for Loan Prize Pool Percent
     * @return Loan Prize Pool Percentage
     */
    function getLoanPrizePoolPercent() external view returns (uint16) {
        return _distributionPercentages[0];
    }

    /**
     * @notice getter function for Loan Staking Percent
     * @return Loan Staking Percentage
     */
    function getLoanStakingPercent() external view returns (uint16) {
        return _distributionPercentages[1];
    }

    /**
     * @notice getter function for Win Prize Pool Percent
     * @return Win Prize Pool Percentage
     */
    function getWinPrizePoolPercent() external view returns (uint16) {
        return _distributionPercentages[2];
    }

    /**
     * @notice getter function for Win Staking Percent
     * @return Win Staking pool share
     */
    function getWinStakingPercent() external view returns (uint16) {
        return _distributionPercentages[3];
    }

    /**
     * @notice getter function for BuyAndBurn Percent
     * @return BuyAndBurn address share
     */
    function getBuyAndBurnPercent() external view returns (uint16) {
        return _distributionPercentages[4];
    }

    /** --internal functions--
     * @notice farm function stakes the LOAN tokens to LOANStaking
     */
    function _farm() internal virtual {
        uint256 wantAmt = IERC20(_loanTokenAddress).balanceOf(address(this));
        if (wantAmt > 0) {
            _wantLockedTotal = _wantLockedTotal + wantAmt;
            ILOANStaking(_liquidLoanLOANStakingAddress).stake(wantAmt);
        }
    }

    /** @notice farm function unstakes the LOAN tokens from LOANStaking */
    function _unfarm(uint256 _wantAmt) internal virtual {
        _wantLockedTotal = _wantLockedTotal - _wantAmt;
        ILOANStaking(_liquidLoanLOANStakingAddress).unstake(_wantAmt);
    }

    /**
     * @notice Distribures PLS and USDL
     * @param _rewardPLS is the total PLS reward
     * @param _rewardUSDL is the total USDL reward
     * @param _poolAddress is the address to which PLS and USDL to be sent
     * @param _poolSharePercent is the share of respective pool
     */
    function _sendToStakingContracts(
        uint256 _rewardPLS,
        uint256 _rewardUSDL,
        address _poolAddress,
        uint256 _poolSharePercent
    ) internal virtual {
        // calculating PLS rewards share of the address
        uint256 shareOfPLS = (_rewardPLS * _poolSharePercent) / TOTAL_PERCENT;
        // calculating USDL rewards share of the address
        uint256 shareOfUSDL = (_rewardUSDL * _poolSharePercent) / TOTAL_PERCENT;
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
        if (shareOfUSDL > 0) {
            // transfering USDL tokens to the address
            IERC20(_usdlTokenAddress).safeApprove(_poolAddress, shareOfUSDL);
            IStakingPool(_poolAddress).notifyRewardAmount(
                _usdlTokenAddress,
                shareOfUSDL
            );
            emit DistributedUSDL(_poolAddress, shareOfUSDL);
        }
    }

    /**
     * @notice Distribures PLS and USDL
     * @param _rewardPLS is the total PLS reward
     * @param _rewardUSDL is the total USDL reward
     * @param _poolAddress is the address to which PLS and USDL to be sent
     * @param _poolSharePercent is the share of respective pool
     */
    function _distributeTo(
        uint256 _rewardPLS,
        uint256 _rewardUSDL,
        address _poolAddress,
        uint256 _poolSharePercent
    ) internal virtual {
        // calculating PLS rewards share of the address
        uint256 shareOfPLS = (_rewardPLS * _poolSharePercent) / TOTAL_PERCENT;
        // calculating USDL rewards share of the address
        uint256 shareOfUSDL = (_rewardUSDL * _poolSharePercent) / TOTAL_PERCENT;
        //Sending PLS to the address
        if (shareOfPLS > 0) {
            (bool success, ) = payable(_poolAddress).call{value: shareOfPLS}(
                ""
            );
            if (success) {
                emit DistributedPLS(_poolAddress, shareOfPLS);
            }
        }
        if (shareOfUSDL > 0) {
            // transfering USDL tokens to the address
            IERC20(_usdlTokenAddress).safeTransfer(_poolAddress, shareOfUSDL);
            emit DistributedUSDL(_poolAddress, shareOfUSDL);
        }
    }

    /**
     * @notice Distribures PLS and USDL
     * @param _rewardPLS is the total PLS reward
     * @param _rewardUSDL is the total USDL reward
     * @param _poolAddress is the address to which PLS and USDL to be sent
     * @param _poolSharePercent is the share of respective pool
     */
    function _distributeToPrizePool(
        uint256 _rewardPLS,
        uint256 _rewardUSDL,
        address _poolAddress,
        uint256 _poolSharePercent
    ) internal virtual {
        // calculating PLS rewards share of the address
        uint256 shareOfPLS = (_rewardPLS * _poolSharePercent) / TOTAL_PERCENT;
        // calculating USDL rewards share of the address
        uint256 shareOfUSDL = (_rewardUSDL * _poolSharePercent) / TOTAL_PERCENT;
        //Sending PLS to the address
        if (shareOfPLS > 0) {
            IWETH(WPLS_ADDRESS).deposit{value: shareOfPLS}();
            IERC20(WPLS_ADDRESS).safeApprove(_poolAddress, shareOfPLS);
            IPrizePool(_poolAddress).addPrizes(WPLS_ADDRESS, shareOfPLS);
            emit DistributedPLS(_poolAddress, shareOfPLS);
        }
        if (shareOfUSDL > 0) {
            // transfering USDL tokens to the address
            IERC20(_usdlTokenAddress).safeApprove(_poolAddress, shareOfUSDL);
            IPrizePool(_poolAddress).addPrizes(_usdlTokenAddress, shareOfUSDL);
            emit DistributedUSDL(_poolAddress, shareOfUSDL);
        }
    }
}
