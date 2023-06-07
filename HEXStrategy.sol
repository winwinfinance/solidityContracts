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
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../Interfaces/IHEXStaking.sol";
import "../Interfaces/IStakingPool.sol";
import "../Interfaces/IPrizePool.sol";

/**
 * @title hex Staking Strategy contract
 * @notice This contract farms hex tokens and gets yield in HEX
 */
contract HEXStrategy is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct WithdrawQueue {
        address user;
        uint256 amount;
        uint256 penaltyAmount;
    }

    WithdrawQueue[] private _withdrawQueue;
    mapping(uint256 => bool) private _stakedForTheDay;

    //0->_hexPrizePoolAddress
    //1->_winHEXStakingAddress
    //2->_winPrizePoolAddress
    //3->_winStakingAddress
    //4->_buyAndBurnAddress
    address[5] private _distributionAddresses;

    //0->_hexPrizePoolPercent
    //1->_hexStakingPercent
    //2->_winPrizePoolPercent
    //3->_winStakingPercent
    //4->_buyAndBurnPercent
    uint16[5] private _distributionPercentages;

    address private immutable _hexTokenAddress;

    //last length to which withdraw queue was cleared
    uint256 private _lastFulfilledLength = 0;

    //Current total stake amount for current day or accumlated hex till now after staking to hex
    uint256 private _currentTotalStakeAmount = 0;

    //total amount requested in withdraw queue
    uint256 private _withdrawQueueTotalAmount = 0;

    //Deployed time -> current day start time in main hex
    uint256 public immutable deployedTime;

    //Current 30 day cycle principle hex staked
    uint256 public currentCycle = 0;

    //Next cycle principle hex amount
    uint256 public nextCycle = 0;

    //starts from -> current day start time in main hex
    //Increases 30 days after each claim
    uint256 public currentPrizeCycleStartTime;

    //How many users can be cleared from withdraw queue in one go
    uint16 private _clearQueueLength = 30;

    //total percent of distribution
    uint16 public constant TOTAL_PERCENT = 10000;

    uint32 public constant HEX_LAUNCH_TIME = 1575331200; // 2019-12-01 00:00:00 UTC

    uint8 public constant MINIMUM_STAKE_AMOUNT = 10;

    address public constant BUY_AND_BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    // --- Events ---
    event DistributedHEX(address indexed _account, uint256 _rewardHEX);
    event DepositedHEXTokens(address indexed _from, uint256 _wantAmt);
    event WithdrawnHEXTokens(
        address indexed _to,
        uint256 _wantAmt,
        uint256 _penaltyAmt
    );
    event ChangeInteractingAddresses(
        address __hexPrizePoolAddress,
        address __winHEXStakingAddress,
        address __winPrizePoolAddress,
        address __winStakingAddress,
        address __buyAndBurnAddress
    );

    modifier onlyWinHEXStaking() {
        require(msg.sender == _distributionAddresses[1], "Not WinHEXStaking");
        _;
    }

    modifier onlyAfter30Days() {
        require(
            block.timestamp >= currentPrizeCycleStartTime + (30 days),
            "after 30 days"
        );
        _;
    }

    /** @dev constructor intializing address of tokens and contracts to variables
     * @param __hexTokenAddress is the address of hex token
     * @param __distributionAddresses is the array of addresses of distribution contracts
     * @param __distributionPercentages is the array of percentages of distribution contracts
     */
    constructor(
        address __hexTokenAddress,
        address[5] memory __distributionAddresses,
        uint16[5] memory __distributionPercentages
    ) {
        require(__hexTokenAddress != address(0), "Not valid address");
        _hexTokenAddress = __hexTokenAddress;

        for (uint8 i = 0; i < 5; i++) {
            _distributionAddresses[i] = __distributionAddresses[i];
            _distributionPercentages[i] = __distributionPercentages[i];
        }

        uint256 currentDay = IHEXStaking(__hexTokenAddress).currentDay();
        deployedTime = HEX_LAUNCH_TIME + (currentDay * 1 days);
        currentPrizeCycleStartTime = deployedTime;
    }

    /**
     * @notice Receives native currency
     */
    receive() external payable {}

    /**
     * @notice Receives new deposits from owner
     * @param _wantAmt is the amount to be staked
     */
    function deposit(uint256 _wantAmt) external virtual onlyWinHEXStaking {
        require(_wantAmt > 0, "_wantAmt <= 0");
        _currentTotalStakeAmount += _wantAmt;
        IERC20(_hexTokenAddress).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );

        if (block.timestamp >= currentPrizeCycleStartTime + (30 days)) {
            claimAndDistributeRewards();
        } else {
            _clearWithdrawQueue();

            if (
                _currentTotalStakeAmount > _withdrawQueueTotalAmount &&
                !_stakedForTheDay[_currentDayInStrategy()]
            ) {
                stakeHEX();
            }
        }

        emit DepositedHEXTokens(_distributionAddresses[1], _wantAmt);
    }

    /**
     * @notice Withdraws amount from today total stake
     * @param _wantAmt is the amount to be unstaked
     * @param _penaltyAmt is the penalty amount to be paid
     */
    function withdraw(
        address _user,
        uint256 _wantAmt,
        uint256 _penaltyAmt
    ) external virtual onlyWinHEXStaking {
        require(_wantAmt > 0, "_wantAmt <= 0");

        _withdrawQueueTotalAmount += (_wantAmt + _penaltyAmt);
        WithdrawQueue memory userRequest = WithdrawQueue(
            _user,
            _wantAmt,
            _penaltyAmt
        );
        _withdrawQueue.push(userRequest);

        if (block.timestamp >= currentPrizeCycleStartTime + (30 days)) {
            claimAndDistributeRewards();
        } else {
            _clearWithdrawQueue();

            if (
                _currentTotalStakeAmount > _withdrawQueueTotalAmount &&
                !_stakedForTheDay[_currentDayInStrategy()]
            ) {
                stakeHEX();
            }
        }
    }

    /**
     * @notice Claim and distribute the rewards got from staking in HEXStaking
     * The rewards are distributed as per the share of the respectve pool.
     * */
    function claimAndDistributeRewards() public nonReentrant onlyAfter30Days {
        currentPrizeCycleStartTime = currentPrizeCycleStartTime + (30 days);
        uint256 balanceBeforeStakeEnd = IERC20(_hexTokenAddress).balanceOf(
            address(this)
        );

        uint256 totalStakeCount = IHEXStaking(_hexTokenAddress).stakeCount(
            address(this)
        );

        if (totalStakeCount == 0) {
            return;
        }

        uint40[] memory availableUnstakable = new uint40[](totalStakeCount);
        uint256 currentDay = IHEXStaking(_hexTokenAddress).currentDay();

        for (uint256 j = 0; j < totalStakeCount; j++) {
            IHEXStaking.StakeStore memory stakeInfo = IHEXStaking(
                _hexTokenAddress
            ).stakeLists(address(this), j);

            uint256 servedDays = 0;
            if (currentDay > stakeInfo.lockedDay) {
                servedDays = currentDay - stakeInfo.lockedDay;
            }
            if (servedDays >= stakeInfo.stakedDays) {
                availableUnstakable[j] = stakeInfo.stakeId;
            }
        }

        for (uint256 j = 0; j < totalStakeCount; j++) {
            if (availableUnstakable[j] != 0) {
                uint index = 0;
                uint256 newTotalStakeCount = IHEXStaking(_hexTokenAddress)
                    .stakeCount(address(this));
                for (uint256 k = 0; k < newTotalStakeCount; k++) {
                    IHEXStaking.StakeStore memory stakeInfo = IHEXStaking(
                        _hexTokenAddress
                    ).stakeLists(address(this), k);

                    if (stakeInfo.stakeId == availableUnstakable[j]) {
                        index = k;
                        break;
                    }
                }
                _unfarm(index, availableUnstakable[j]);
            }
        }

        uint256 balanceAfterStakeEnd = IERC20(_hexTokenAddress).balanceOf(
            address(this)
        );

        uint256 stakeReturn = balanceAfterStakeEnd - balanceBeforeStakeEnd;

        uint256 _rewardHEX = 0;

        //checking if any extra rewards recieved other than staked amount
        if (stakeReturn > currentCycle) {
            _rewardHEX = stakeReturn - currentCycle;
        }

        _currentTotalStakeAmount = balanceAfterStakeEnd - _rewardHEX;

        if (_rewardHEX > 0) {
            // Distributing to HEX Prize pool
            _distributeToPrizePool(
                _rewardHEX,
                _distributionAddresses[0],
                _distributionPercentages[0]
            );

            //Distributing to hex staking pool
            uint256 shareOfHEX = (_rewardHEX * _distributionPercentages[1]) /
                TOTAL_PERCENT;

            if (shareOfHEX > 0) {
                IStakingPool(_distributionAddresses[1]).notifyRewardAmount(
                    _hexTokenAddress,
                    shareOfHEX
                );

                _currentTotalStakeAmount += shareOfHEX;
            }

            // Distributing to Win Prize pool
            _distributeToPrizePool(
                _rewardHEX,
                _distributionAddresses[2],
                _distributionPercentages[2]
            );

            //distirbuting to win staking pool
            _sendToStakingContracts(
                _rewardHEX,
                _distributionAddresses[3],
                _distributionPercentages[3]
            );

            // Distributing to buy and burn address
            _distributeTo(
                _rewardHEX,
                _distributionAddresses[4],
                _distributionPercentages[4]
            );
        }

        _clearWithdrawQueue();

        currentCycle = nextCycle;
        nextCycle = 0;

        stakeHEX();
    }

    /**
     * @notice modifies - max length of withdrawal requests in queue that can be cleared
     * @param _length is the length value
     */
    function modifyClearQueueLength(uint16 _length) external onlyOwner {
        _clearQueueLength = _length;
    }

    /**
     * @notice Changes Win HEX staking address
     * @param _updatedDistributionAddresses new distribution addresses
     */
    function changeDistributionAddresses(
        address[5] memory _updatedDistributionAddresses
    ) external virtual onlyOwner {
        for (uint256 i = 0; i < 5; i++) {
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
  
    /// getter functions

    /**
     * @return _queueLength is the length of withdraw queue
     */
    function getWithdrawQueueLength() external view returns (uint256) {
        return _withdrawQueue.length - _lastFulfilledLength;
    }

    /**
     * @param _index is the index of withdraw queue
     * @return _queue is the withdraw queue details
     */
    function getWithdrawQueueDetails(
        uint256 _index
    ) external view returns (WithdrawQueue memory _queue) {
        return _withdrawQueue[_index];
    }

    /**
     * @notice getter function for available HEX
     * @return current available HEX stake in strategy contract
     */
    function getCurrentTotalStake() external view returns (uint256) {
        return _currentTotalStakeAmount;
    }

    /**
     * @notice getter function to find total unstake requests value
     * @return current requests for HEX unstake
     */
    function getWithdrawQueueAmount() external view returns (uint256) {
        return _withdrawQueueTotalAmount;
    }

    /**
     * @notice getter function for Hex Token address
     * @return address of the Hex Token
     */
    function getHEXTokenAddress() external view returns (address) {
        return _hexTokenAddress;
    }

    /**
     * @notice getter function for WinWin project's Hex Staking address
     * @return address of the WinWin project's Hex Staking pool
     */
    function getWinHEXStakingAddress() external view returns (address) {
        return _distributionAddresses[1];
    }

    /**
     * @notice getter function for Hex Prize pool address
     * @return address of the Hex prize pool
     */
    function getHEXPrizePoolAddress() external view returns (address) {
        return _distributionAddresses[0];
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
     * @notice getter function for HEX Prize pool percent
     * @return HEX Prize pool share of total share
     */
    function getHEXPrizePoolPercent() external view returns (uint16) {
        return _distributionPercentages[0];
    }

    /**
     * @notice getter function for HEX Staking pool percent
     * @return HEX Staking pool share of total share
     */
    function getHEXStakingPercent() external view returns (uint16) {
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
     * @notice stakes amount to HEXStaking
     */
    function stakeHEX() private {
        uint256 noOfDays = _currentDayInStrategy();
        if (_stakedForTheDay[noOfDays]) {
            return;
        }

        uint256 availableToStake = _currentTotalStakeAmount -
            _withdrawQueueTotalAmount;
        if (availableToStake > MINIMUM_STAKE_AMOUNT) {
            _currentTotalStakeAmount = _withdrawQueueTotalAmount;

            uint256 stakeDays = 29;
            uint256 trackDay = (noOfDays % 30);
            if (trackDay > 0) {
                stakeDays = 59 - trackDay;
                nextCycle += availableToStake;
            } else {
                currentCycle += availableToStake;
            }

            _stakedForTheDay[noOfDays] = true;
            _farm(stakeDays, availableToStake);
        }
    }

    /** --internal functions--
     * @notice farm function stakes the HEX tokens to HEXStaking
     */
    function _farm(
        uint256 stakeDays,
        uint256 availableToStake
    ) internal virtual {
        IHEXStaking(_hexTokenAddress).stakeStart(availableToStake, stakeDays);
    }

    /** @notice farm function unstakes the LOAN tokens from LOANStaking
     * @param _stakeIndex Index of stake within stake list
     * @param _stakeIdParam The stake's id
     */
    function _unfarm(
        uint256 _stakeIndex,
        uint40 _stakeIdParam
    ) internal virtual {
        // claiming pending rewards
        IHEXStaking(_hexTokenAddress).stakeEnd(_stakeIndex, _stakeIdParam);
    }

    /**
     * @notice Distributes HEX
     * @param _rewardHex total  HEX reward
     * @param _poolAddress is the address to which HEX to be sent
     * @param _poolSharePercent pool share percentage
     */
    function _sendToStakingContracts(
        uint256 _rewardHex,
        address _poolAddress,
        uint256 _poolSharePercent
    ) internal virtual {
        // calculating PLS rewards share of the address
        uint256 shareOfHex = (_rewardHex * _poolSharePercent) / TOTAL_PERCENT;

        //Sending HEX to the address
        if (shareOfHex > 0) {
            IERC20(_hexTokenAddress).safeApprove(_poolAddress, shareOfHex);
            IStakingPool(_poolAddress).notifyRewardAmount(
                _hexTokenAddress,
                shareOfHex
            );
            emit DistributedHEX(_poolAddress, shareOfHex);
        }
    }

    /**
     * @notice Distribures HEX
     * @param _rewardHEX is the total HEX reward
     * @param _poolAddress is the address to which HEX to be sent
     * @param _poolSharePercent is the share of respective pool
     */
    function _distributeTo(
        uint256 _rewardHEX,
        address _poolAddress,
        uint256 _poolSharePercent
    ) internal virtual {
        // calculating HEX rewards share of the address
        uint256 shareOfHEX = (_rewardHEX * _poolSharePercent) / TOTAL_PERCENT;
        //Sending HEX to the address
        if (shareOfHEX > 0) {
            IERC20(_hexTokenAddress).safeTransfer(_poolAddress, shareOfHEX);
        }
    }

    /**
     * @notice Distribures HEX
     * @param _rewardHEX is the total HEX reward
     * @param _poolAddress is the address to which HEX to be sent
     * @param _poolSharePercent is the share of respective pool
     */
    function _distributeToPrizePool(
        uint256 _rewardHEX,
        address _poolAddress,
        uint256 _poolSharePercent
    ) internal virtual {
        // calculating HEX rewards share of the address
        uint256 shareOfHEX = (_rewardHEX * _poolSharePercent) / TOTAL_PERCENT;
        //Sending HEX to the address
        if (shareOfHEX > 0) {
            IERC20(_hexTokenAddress).safeApprove(_poolAddress, shareOfHEX);
            IPrizePool(_poolAddress).addPrizes(_hexTokenAddress, shareOfHEX);
        }
    }

    /** --private function */
    /**
     * @dev clears withdraw queue
     */
    function _clearWithdrawQueue() private {
        uint256 length = _clearQueueLength;
        uint256 startingIndex = _lastFulfilledLength;

        if ((_withdrawQueue.length - startingIndex) < length) {
            length = (_withdrawQueue.length - startingIndex);
        }

        // fulfilling withdrawal queue
        uint256 index;
        WithdrawQueue memory queue;
        // fulfilling withdrawal queue
        for (index = startingIndex; index < (startingIndex + length); index++) {
            queue = _withdrawQueue[index];
            uint256 totalWithrawAmount = queue.amount + queue.penaltyAmount;
            if (_currentTotalStakeAmount >= totalWithrawAmount) {
                _withdrawQueueTotalAmount -= totalWithrawAmount;
                _currentTotalStakeAmount -= totalWithrawAmount;

                IERC20(_hexTokenAddress).safeTransfer(queue.user, queue.amount);
                if (queue.penaltyAmount > 0) {
                    IERC20(_hexTokenAddress).safeTransfer(
                        BUY_AND_BURN_ADDRESS,
                        queue.penaltyAmount
                    );
                }
                emit WithdrawnHEXTokens(
                    queue.user,
                    queue.amount,
                    queue.penaltyAmount
                );
            } else {
                break;
            }
        }
        if (index != startingIndex) {
            _lastFulfilledLength = index;
        }
    }

    /**
     * @notice calculates the current day in strategy
     * @return current day in strategy
     */

    function _currentDayInStrategy() private view returns (uint256) {
        return ((block.timestamp - deployedTime) / 1 days);
    }
}
