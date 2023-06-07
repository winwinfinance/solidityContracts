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

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../Interfaces/IWETH.sol";
import "../Interfaces/IPrizePool.sol";
import "../libraries/TwabLib.sol";

contract WinStakingPool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /**
     * @dev stores information of every reward token
     * @param periodFinish stores when current reward period will end
     * @param rewardRate reward rate stores at which rate reward token are being ditributed per second
     * @param lastUpdateTime timestamp when rewards were calculated or applied
     * @param rewardPerShareStored reward token stored per share from the very beginning
     */
    struct Reward {
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerShareStored;
    }

    /**
     * @dev stores information of win reward token
     * @param totalRemainingReward total remaining win token to be distributed
     * @param rewardRate reward rate stores at which rate
     * win reward token are being ditributed per second
     * @param lastUpdateTime timestamp when rewards were calculated or applied
     * @param currentDayStartTime current day start timestamp
     * @param penaltyRewardRate penalty win token reward rate
     * @param penaltyPeriodFinish penalty reward period completion time
     * @param penaltyLastUpdateTime timestamp when penalty rewards were calculated or applied
     */
    struct WinReward {
        uint256 totalRemainingReward;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 currentDayStartTime;
        uint256 penaltyRewardRate;
        uint256 penaltyPeriodFinish;
        uint256 penaltyLastUpdateTime;
    }

    /**
     * @dev stores the balance of the user
     * @param stakedAmount number of staked tokens
     * @param shares total shares of the user in the pool
     * @param unlockTime unlock time of this stake
     * @param rewards stored rewards of all the tokens
     * @param userRewardPerSharePaid paid rewards of all the reward tokens
     */
    struct Balance {
        uint256 stakedAmount;
        uint256 shares;
        uint256 unlockTime;
        mapping(address => uint256) rewards;
        mapping(address => uint256) userRewardPerSharePaid;
    }

    //Staking token address
    IERC20 public immutable stakingToken;

    //Reward duration.Added rewards should be ditrbuted in this duration
    uint32 public constant REWARDS_DURATION = 200;

    //Reward duration.Added rewards should be ditrbuted in this duration
    uint32 public constant LOCK_DURATION = 100;

    //Duration after which win reward rate will change
    uint32 public constant WIN_REWARD_DURATION = 86400;

    // constant to calculate win reward rate
    uint16 public constant R_CONSTANT = 10;

    address public constant BUY_AND_BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    address public constant BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    address public constant WPLS_ADDRESS =
        0x70499adEBB11Efd915E3b69E700c331778628707;

    address public constant HEX_ADDRESS =
        0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39;

    // reward token -> distributor -> is approved to add rewards
    mapping(address => mapping(address => bool)) public rewardDistributors;

    //total locked tokens => total staked win + rewarded win
    uint256 public totalLockedTokens;

    //total number of shares in the pool
    uint256 public sharesTotal = 0;

    //User address => totalShares
    mapping(address => uint256) public userShares;

    //User address => index from where stakes are available
    mapping(address => uint256) public userUnstakeIndex;

    mapping(address => bool) public isOptedForPrizePool;

    address private _prizePoolAddress;

    //reward tokens address array
    address[] private _rewardTokens;

    //Mapping from  reward token => Reward
    mapping(address => Reward) private _rewardData;

    //Mapping from wintoken => Reward
    mapping(address => WinReward) private _winRewardData;

    // user address => Balances
    mapping(address => Balance[]) private _balances;

    /// @notice Record of token holders TWABs for each account.
    mapping(address => TwabLib.Account) private userTwabs;

    /// @notice Record of tickets total supply and ring buff parameters used for observation.
    TwabLib.Account private totalSupplyTwab;

    //event emitted with the amount when rewards are added
    event RewardAdded(address rewardToken, uint256 reward);

    //event emitted with the amount and user address when tokens are staked
    event Staked(address indexed user, uint256 amount);

    //event emitted with the amount and user address when tokens are unstaked
    event Unstaked(address indexed user, uint256 amount, uint256 shares);

    //event emitted with user address , reward token address and reward amount when rewards are claimed
    event RewardPaid(
        address indexed user,
        address indexed rewardsToken,
        uint256 reward
    );


    /**
     * @dev modifier for calculating , updating and storing the rewards
     * Takes account as input and autocompound accumlated win  reward token
     * and calculate the accumated rewards for other reward tokens and stores it for the user.
     */
    modifier updateReward() {
        uint256 rewardsAccumlated;
        uint256 burnAmount;
        WinReward storage winReward = _winRewardData[_rewardTokens[0]];

        (
            rewardsAccumlated,
            winReward.rewardRate,
            winReward.totalRemainingReward,
            winReward.currentDayStartTime,
            burnAmount
        ) = _getRewardsAccumlated();

        if (totalLockedTokens != 0) {
            totalLockedTokens += rewardsAccumlated;
            if (burnAmount > 0) {
                stakingToken.safeTransfer(BURN_ADDRESS, burnAmount);
            }
        } else {
            if (rewardsAccumlated + burnAmount > 0) {
                stakingToken.safeTransfer(
                    BURN_ADDRESS,
                    rewardsAccumlated + burnAmount
                );
            }
        }

        winReward.lastUpdateTime = block.timestamp;
        winReward.penaltyLastUpdateTime = lastTimeWinPenaltyRewardApplicable();

        address token;
        for (uint256 i = 1; i < _rewardTokens.length; i++) {
            token = _rewardTokens[i];

            _rewardData[token].rewardPerShareStored = _rewardPerShare(token);
            _rewardData[token].lastUpdateTime = lastTimeRewardApplicable(token);
        }
        _;
    }

    /**
     * @dev constructor also initialize Ownable library.
     * It stores staking token as a first reward token (Win - Win)
     * @param __stakingToken staking token address
     */
    constructor(
        address __stakingToken,
        uint256 __startTimestamp,
        uint256 __totalReward
    ) Ownable() {
        require(__stakingToken != address(0), "Not valid address");
        stakingToken = IERC20(__stakingToken);
        _rewardTokens.push(__stakingToken);
        WinReward memory winReward = WinReward({
            lastUpdateTime: __startTimestamp,
            currentDayStartTime: __startTimestamp,
            totalRemainingReward: __totalReward,
            rewardRate: (__totalReward / R_CONSTANT) / WIN_REWARD_DURATION,
            penaltyRewardRate: 0,
            penaltyPeriodFinish: 0,
            penaltyLastUpdateTime: 0
        });

        _winRewardData[__stakingToken] = winReward;
    }

    /**
     * @notice Receives native currency
     */
    receive() external payable {}

    // EXTERNAL FUNCTIONS //

    /**
     * @notice Gets a users twab context. This is a struct with their balance, next twab index, and cardinality.
     * @param _user The user for whom to fetch the TWAB context.
     * @return The TWAB context, which includes { balance, nextTwabIndex, cardinality }
     */
    function getAccountDetails(
        address _user
    ) external view returns (TwabLib.AccountDetails memory) {
        return userTwabs[_user].details;
    }

    /**
     * @notice Retrieves `_user` TWAB balance.
     * @param _user Address of the user whose TWAB is being fetched.
     * @param _target Timestamp at which we want to retrieve the TWAB balance.
     * @return The TWAB balance at the given timestamp.
     */
    function getBalanceAt(
        address _user,
        uint64 _target
    ) external view returns (uint256) {
        TwabLib.Account storage account = userTwabs[_user];

        return
            TwabLib.getBalanceAt(
                account.twabs,
                account.details,
                uint32(_target),
                uint32(block.timestamp)
            );
    }

    /**
     * @notice Retrieves the total supply TWAB balance at the given timestamp.
     * @param _target Timestamp at which we want to retrieve the total supply TWAB balance.
     * @return The total supply TWAB balance at the given timestamp.
     */
    function getTotalSupplyAt(uint64 _target) external view returns (uint256) {
        return
            TwabLib.getBalanceAt(
                totalSupplyTwab.twabs,
                totalSupplyTwab.details,
                uint32(_target),
                uint32(block.timestamp)
            );
    }

    /**
     * @dev Add a new reward token to be distributed to stakers
     * @param _rewardsToken address of reward token
     * @param _distributor approve an account address as distributor for reward tokens
     */
    function addReward(
        address _rewardsToken,
        address _distributor
    ) external onlyOwner {
        require(
            _rewardData[_rewardsToken].lastUpdateTime == 0,
            "Reward Token already added"
        );
        _rewardTokens.push(_rewardsToken);
        _rewardData[_rewardsToken].lastUpdateTime = block.timestamp;
        _rewardData[_rewardsToken].periodFinish = block.timestamp;
        rewardDistributors[_rewardsToken][_distributor] = true;
    }

    /**
     * @dev admin function to be called to approve/reject any distributor for any reward tokens
     * @param _rewardsToken reward token address
     * @param _distributor distributor address
     * @param _approved true if want to approve otherwise false
     */
    function approveRewardDistributor(
        address _rewardsToken,
        address _distributor,
        bool _approved
    ) external onlyOwner {
        require(
            _rewardData[_rewardsToken].lastUpdateTime > 0,
            "Reward Token not added"
        );
        rewardDistributors[_rewardsToken][_distributor] = _approved;
    }

    /**
     * @dev reward distributor function to be called for adding rewards
     * also calculates previous rewards and stores it.
     * @param _rewardsToken reward token address
     * @param _reward reward amount
     */
    function notifyRewardAmount(
        address _rewardsToken,
        uint256 _reward
    ) external updateReward {
        require(
            rewardDistributors[_rewardsToken][msg.sender],
            "User not Approved"
        );
        require(_reward > 0, "No reward");
        _notifyReward(_rewardsToken, _reward);
        // handle the transfer of reward tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the reward amount
        IERC20(_rewardsToken).safeTransferFrom(
            msg.sender,
            address(this),
            _reward
        );
        emit RewardAdded(_rewardsToken, _reward);
    }

    /**
     * @dev user function to be called for staking tokens
     * calculates and saves previous rewards
     * @param _amount number of tokens to be staked
     */
    function stake(
        uint256 _amount,
        uint256[] calldata _slots,
        uint256[] calldata _shuffleSlots,
        bool _isOptedForPrizePool
    ) external nonReentrant updateReward {
        require(_amount > 0, "Cannot stake 0");
        if (userShares[msg.sender] != 0) {
            require(
                isOptedForPrizePool[msg.sender] == _isOptedForPrizePool,
                "Cannot change PrizePool Preference."
            );
        } else {
            isOptedForPrizePool[msg.sender] = _isOptedForPrizePool;
        }
        uint256 sharesAdded = _amount;
        if (totalLockedTokens > 0 && sharesTotal > 0) {
            sharesAdded = (_amount * sharesTotal) / totalLockedTokens;
        }
        Balance[] storage bal = _balances[msg.sender];
        {
            uint256 unlockTime = block.timestamp + LOCK_DURATION;
            uint256 idx = bal.length;

            if (idx == 0 || bal[idx - 1].unlockTime < unlockTime) {
                Balance storage newBalance = bal.push();
                newBalance.stakedAmount = _amount;
                newBalance.shares = sharesAdded;
                newBalance.unlockTime = unlockTime;
                for (uint256 i = 1; i < _rewardTokens.length; i++) {
                    newBalance.rewards[_rewardTokens[i]] = 0;
                    newBalance.userRewardPerSharePaid[
                        _rewardTokens[i]
                    ] = _rewardData[_rewardTokens[i]].rewardPerShareStored;
                }
            } else {
                bal[idx - 1].stakedAmount = bal[idx - 1].stakedAmount + _amount;
                bal[idx - 1].shares = bal[idx - 1].shares + sharesAdded;
            }
        }

        sharesTotal = sharesTotal + sharesAdded;
        totalLockedTokens = totalLockedTokens + _amount;
        userShares[msg.sender] += sharesAdded;

        if (_isOptedForPrizePool) {
            _increaseUserTwab(msg.sender, sharesAdded);
            _increaseTotalSupplyTwab(sharesAdded);
            IPrizePool(_prizePoolAddress).getTickets(
                msg.sender,
                sharesAdded,
                _slots,
                _shuffleSlots
            );
        }
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        emit Staked(msg.sender, _amount);
    }

    /**
     * @dev Unstakes/ Withdraw the staked tokens
     * calculates,  saves , transfers the rewards
     * also applies penalty on early unstakers
     * @param _shares the number of shares user want to remove
     */
    function unstake(uint256 _shares) external nonReentrant updateReward {
        require(_shares > 0, "Cannot unstake 0");
        uint256 totalShares = userShares[msg.sender];
        require(totalShares >= _shares, "Not enough shares");
        Balance[] storage bal = _balances[msg.sender];

        uint256[] memory totalClaimableRewards = new uint256[](
            _rewardTokens.length
        );
        uint256[] memory totalPenaltyRewards = new uint256[](
            _rewardTokens.length
        );

        uint256 totalWinRewardsClaimed = 0;

        {
            uint256 percentage;
            uint256 remainingShares = _shares;
            uint256 index = userUnstakeIndex[msg.sender];
            for (uint256 i = index; i < bal.length; i++) {
                if (remainingShares == 0) {
                    break;
                }
                if (bal[i].shares == 0) {
                    continue;
                }
                if (bal[i].shares >= remainingShares) {
                    percentage = (remainingShares * 1e18) / bal[i].shares;
                } else {
                    percentage = 1e18;
                }
                for (uint256 j = 1; j < _rewardTokens.length; j++) {
                    address _rewardToken = _rewardTokens[j];
                    bal[i].rewards[_rewardToken] = _earned(
                        msg.sender,
                        _rewardToken,
                        bal[i].shares,
                        i
                    );
                    bal[i].userRewardPerSharePaid[_rewardToken] = _rewardData[
                        _rewardToken
                    ].rewardPerShareStored;
                    if (bal[i].unlockTime > block.timestamp) {
                        uint256 penaltyPer = (bal[i].rewards[_rewardToken] *
                            percentage) / 1e18;
                        totalPenaltyRewards[j] += penaltyPer;
                        bal[i].rewards[_rewardToken] -= penaltyPer;
                    } else {
                        totalClaimableRewards[j] += bal[i].rewards[
                            _rewardToken
                        ];
                        bal[i].rewards[_rewardToken] = 0;
                    }
                }

                uint256 totalRewardedWin = _calculateWinRewards(
                    bal[i].shares,
                    totalLockedTokens,
                    sharesTotal,
                    bal[i].stakedAmount
                );

                if (bal[i].unlockTime > block.timestamp) {
                    bal[i].stakedAmount -=
                        (bal[i].stakedAmount * percentage) /
                        1e18;
                    totalPenaltyRewards[0] +=
                        (totalRewardedWin * percentage) /
                        1e18;
                } else {
                    totalWinRewardsClaimed += totalRewardedWin;
                }

                if (remainingShares < bal[i].shares) {
                    bal[i].shares -= remainingShares;
                    remainingShares = 0;
                    break;
                } else {
                    remainingShares -= bal[i].shares;
                    delete bal[i];
                    userUnstakeIndex[msg.sender] = i + 1;
                }
            }
        }

        uint256 amountRemoved = _getWinAmount(
            _shares,
            totalLockedTokens,
            sharesTotal
        );

        sharesTotal = sharesTotal - _shares;
        userShares[msg.sender] -= _shares;
        totalLockedTokens = totalLockedTokens - amountRemoved;
        if (isOptedForPrizePool[msg.sender]) {
            _decreaseUserTwab(msg.sender, _shares);
            _decreaseTotalSupplyTwab(_shares);
            IPrizePool(_prizePoolAddress).burnTickets(msg.sender, _shares);
        }
        if (userShares[msg.sender] == 0) {
            delete isOptedForPrizePool[msg.sender];
        }
        if (totalPenaltyRewards[0] > 0) {
            uint256 burnAmount = totalPenaltyRewards[0] / 2;
            _updatePenaltyRewards(totalPenaltyRewards[0] - burnAmount);
            stakingToken.safeTransfer(BURN_ADDRESS, burnAmount);
        }
        stakingToken.safeTransfer(
            msg.sender,
            amountRemoved - totalPenaltyRewards[0]
        );
        if (totalWinRewardsClaimed > 0) {
            emit RewardPaid(
                msg.sender,
                address(stakingToken),
                totalWinRewardsClaimed
            );
        }
        bool weth;
        for (uint256 i = 1; i < _rewardTokens.length; i++) {
            address _rewardToken = _rewardTokens[i];
            weth = _rewardToken == WPLS_ADDRESS;
            if (totalClaimableRewards[i] > 0) {
                if (weth) {
                    _processPLSCLaim(msg.sender, totalClaimableRewards[i]);
                } else {
                    IERC20(_rewardToken).safeTransfer(
                        msg.sender,
                        totalClaimableRewards[i]
                    );
                }

                emit RewardPaid(
                    msg.sender,
                    _rewardToken,
                    totalClaimableRewards[i]
                );
            }
            if (totalPenaltyRewards[i] > 0) {
                uint256 burnAmount = totalPenaltyRewards[i] / 2;
                if (weth) {
                    _processPLSCLaim(BUY_AND_BURN_ADDRESS, burnAmount);
                } else {
                    IERC20(_rewardToken).safeTransfer(
                        BUY_AND_BURN_ADDRESS,
                        burnAmount
                    );
                }
                _notifyReward(
                    _rewardToken,
                    totalPenaltyRewards[i] - burnAmount
                );
            }
        }
        emit Unstaked(msg.sender, amountRemoved, _shares);
    }

    /**
     * @dev claims the rewards for the user
     * calculate , saves and transfer rewards for unlocked stakes
     * @param _user the address of user whose rewards to be claimed
     */
    function claim(address _user) external nonReentrant updateReward {
        Balance[] storage bal = _balances[_user];
        uint256 index = userUnstakeIndex[_user];
        uint256 totalAccumlatedRewards;

        for (uint256 j = 1; j < _rewardTokens.length; j++) {
            address _rewardToken = _rewardTokens[j];
            for (uint256 i = index; i < bal.length; i++) {
                if (bal[i].unlockTime > block.timestamp) {
                    break;
                }

                bal[i].rewards[_rewardToken] = _earned(
                    _user,
                    _rewardToken,
                    bal[i].shares,
                    i
                );
                bal[i].userRewardPerSharePaid[_rewardToken] = _rewardData[
                    _rewardToken
                ].rewardPerShareStored;
                totalAccumlatedRewards += bal[i].rewards[_rewardToken];
                bal[i].rewards[_rewardToken] = 0;
            }
            if (totalAccumlatedRewards > 0) {
                if (WPLS_ADDRESS == _rewardToken) {
                    _processPLSCLaim(_user, totalAccumlatedRewards);
                } else {
                    IERC20(_rewardToken).safeTransfer(
                        _user,
                        totalAccumlatedRewards
                    );
                }
                emit RewardPaid(_user, _rewardToken, totalAccumlatedRewards);
            }
            totalAccumlatedRewards = 0;
        }
    }

    /**
     * @notice setter function for prizePoolAddress only owner can call
     * @param _newPrizePoolAddress new prizePoolAddress
     */
    function setPrizePoolAddress(
        address _newPrizePoolAddress
    ) external onlyOwner {
        require(_newPrizePoolAddress != address(0), "Can't be zero address");
        _prizePoolAddress = _newPrizePoolAddress;
    }

    /**
     * @dev returns reward tokens
     * @param _tokenAddress all the reward token address
     */
    function getRewardTokens()
        external
        view
        returns (address[] memory _tokenAddress)
    {
        return _rewardTokens;
    }

    /**
     * @dev returns reward tokens length
     * @param _rewardTokensCount number of reward tokens
     */
    function getRewardTokensCount()
        external
        view
        returns (uint256 _rewardTokensCount)
    {
        return _rewardTokens.length;
    }

    /**
     * @dev return balances of the user
     * @param _userAddress userAddress
     * @param _index details of a particular stake
     * @param _rewardToken reward token address
     * @return _stakedAmount staked amount
     * @return _sharesAmount share amount
     * @return _unlockTime unlock time of this stake
     * @return _rewardAmounts reward amount of the given reward address
     * and given stake
     * @return _userRewardPerTokenPaid userRewardPerTokenPaid amount of the given
     * reward address and given stake
     */
    function getBalance(
        address _userAddress,
        uint256 _index,
        address _rewardToken
    )
        external
        view
        returns (
            uint256 _stakedAmount,
            uint256 _sharesAmount,
            uint256 _unlockTime,
            uint256 _rewardAmounts,
            uint256 _userRewardPerTokenPaid
        )
    {
        return (
            _balances[_userAddress][_index].stakedAmount,
            _balances[_userAddress][_index].shares,
            _balances[_userAddress][_index].unlockTime,
            _balances[_userAddress][_index].rewards[_rewardToken],
            _balances[_userAddress][_index].userRewardPerSharePaid[_rewardToken]
        );
    }

    /**
     * @dev calculates and return updated detials of win rewards
     * @return rewardsAccumlated how much total rewards have been accumlated
     * @return rewardRate current reward rate
     * @return newTotalRemainingRewards curent remaining rewards to be distributed
     * @return newCurrentDayStartingTimestamp current day starting timestamp
     */
    function getWinRewardDetails()
        external
        view
        returns (
            uint256 rewardsAccumlated,
            uint256 rewardRate,
            uint256 newTotalRemainingRewards,
            uint256 newCurrentDayStartingTimestamp
        )
    {
        (
            rewardsAccumlated,
            rewardRate,
            newTotalRemainingRewards,
            newCurrentDayStartingTimestamp,

        ) = _getRewardsAccumlated();
    }

    /**
     * @dev return the number of user stakes
     * @param _userAddress user address
     * @return _count number of stakes of user
     */
    function getStakeCount(
        address _userAddress
    ) external view returns (uint256 _count) {
        return _balances[_userAddress].length;
    }

    /**
     * @dev provides reward token per share
     * @param _rewardsToken rewardToken address
     * @return _amountPerShare  reward token amount per share
     */
    function rewardPerShare(
        address _rewardsToken
    ) external view returns (uint256 _amountPerShare) {
        return _rewardPerShare(_rewardsToken);
    }

    /**
     * @dev calculates the total number of reward tokens in the current reward duration
     * rewardRate * reward duration
     * @param _rewardsToken reward token address
     * @return _totalRewardsForDuration total reward amount
     */
    function getRewardForDuration(
        address _rewardsToken
    ) external view returns (uint256 _totalRewardsForDuration) {
        uint8 decimals = IERC20Metadata(_rewardsToken).decimals();
        if (_rewardsToken == HEX_ADDRESS) {
            return
                (_rewardData[_rewardsToken].rewardRate *
                    REWARDS_DURATION *
                    30) / (10 ** (18 - decimals));
        }
        return
            (_rewardData[_rewardsToken].rewardRate * REWARDS_DURATION) /
            (10 ** (18 - decimals));
    }

    /**
     * @dev returns the data for the reward token
     * @param _rewardToken reward token address of which data is needed
     * @return _reward reward Data
     */
    function getRewardData(
        address _rewardToken
    ) external view returns (Reward memory _reward) {
        return _rewardData[_rewardToken];
    }

    /**
     * @dev returns the data for the win reward token
     * @return _reward win reward Data
     */
    function getWinRewardData()
        external
        view
        returns (WinReward memory _reward)
    {
        return _winRewardData[address(stakingToken)];
    }

    /**
     * @dev calculates the total number of win token
     * (staked +rewards autocompounded)
     * @param _userAddress user address
     * @return _totalWinTokens total win tokens
     */
    function getTotalWinTokens(
        address _userAddress
    ) external view returns (uint256 _totalWinTokens) {
        if (totalLockedTokens == 0 && sharesTotal == 0) {
            return 0;
        }

        (uint256 rewardsAccumlated, , , , ) = _getRewardsAccumlated();

        uint256 totalLockedWin = totalLockedTokens + rewardsAccumlated;
        Balance[] storage bal = _balances[_userAddress];
        uint256 index = userUnstakeIndex[_userAddress];
        for (uint256 i = index; i < bal.length; i++) {
            _totalWinTokens += _getWinAmount(
                bal[i].shares,
                totalLockedWin,
                sharesTotal
            );
        }
    }

    /**
     * @dev calculates the total number of withdrawable win token
     * (staked +rewards autocompounded)
     * @param _userAddress user address
     * @return _totalWinTokens total withdrawable win tokens
     */
    function getTotalWithdrawableWinTokens(
        address _userAddress
    ) external view returns (uint256 _totalWinTokens) {
        if (totalLockedTokens == 0 && sharesTotal == 0) {
            return 0;
        }
        (uint256 rewardsAccumlated, , , , ) = _getRewardsAccumlated();

        uint256 totalLockedWin = totalLockedTokens + rewardsAccumlated;
        uint256 totalWithdrawableShares = getWithdrawableShares(_userAddress);
        _totalWinTokens = _getWinAmount(
            totalWithdrawableShares,
            totalLockedWin,
            sharesTotal
        );
    }

    /**
     * @dev calculates the total claimable reward tokens
     * @param _userAddress user address
     * @return _rewardsData total number of cliamable rewards
     *  for all the stakes for different tokens
     */
    function getClaimableRewards(
        address _userAddress
    ) external view returns (uint256[] memory _rewardsData) {
        _rewardsData = new uint256[](_rewardTokens.length);
        Balance[] storage bal = _balances[_userAddress];
        uint256 index = userUnstakeIndex[_userAddress];
        //For win rewards
        (uint256 rewardsAccumlated, , , , ) = _getRewardsAccumlated();

        uint256 totalLockedWin = totalLockedTokens + rewardsAccumlated;
        for (uint256 j = 0; j < _rewardsData.length; j++) {
            for (uint256 i = index; i < bal.length; i++) {
                if (bal[i].unlockTime > block.timestamp) {
                    break;
                }
                if (j == 0) {
                    _rewardsData[j] += _calculateWinRewards(
                        bal[i].shares,
                        totalLockedWin,
                        sharesTotal,
                        bal[i].stakedAmount
                    );
                } else {
                    _rewardsData[j] += _earned(
                        _userAddress,
                        _rewardTokens[j],
                        bal[i].shares,
                        i
                    );
                }
            }
        }
    }

    /**
     * @dev Calculates and return total rewards of the user
     * @param _userAddress user address
     * @return _rewardsData total number of rewards
     * for all the stakes for different tokens
     */
    function getTotalUserRewards(
        address _userAddress
    ) external view returns (uint256[] memory _rewardsData) {
        _rewardsData = new uint256[](_rewardTokens.length);
        Balance[] storage bal = _balances[_userAddress];
        uint256 index = userUnstakeIndex[_userAddress];
        //For win rewards
        (uint256 rewardsAccumlated, , , , ) = _getRewardsAccumlated();

        uint256 totalLockedWin = totalLockedTokens + rewardsAccumlated;

        for (uint256 j = 0; j < _rewardsData.length; j++) {
            for (uint256 i = index; i < bal.length; i++) {
                if (j == 0) {
                    _rewardsData[j] += _calculateWinRewards(
                        bal[i].shares,
                        totalLockedWin,
                        sharesTotal,
                        bal[i].stakedAmount
                    );
                } else {
                    _rewardsData[j] += _earned(
                        _userAddress,
                        _rewardTokens[j],
                        bal[i].shares,
                        i
                    );
                }
            }
        }
    }

    /**
     * @dev Calculates and return total rewards of the user's individual stake
     * @param _userAddress user address
     * @param _index user's stake number of which user want reward
     * @return _rewardsData total number of rewards
     * for all the stakes for different tokens
     */
    function getTotalRewardsOfStake(
        address _userAddress,
        uint256 _index
    ) external view returns (uint256[] memory _rewardsData) {
        _rewardsData = new uint256[](_rewardTokens.length);
        Balance[] storage bal = _balances[_userAddress];
        //For win rewards
        (uint256 rewardsAccumlated, , , , ) = _getRewardsAccumlated();

        uint256 totalLockedWin = totalLockedTokens + rewardsAccumlated;

        _rewardsData[0] = _calculateWinRewards(
            bal[_index].shares,
            totalLockedWin,
            sharesTotal,
            bal[_index].stakedAmount
        );

        for (uint256 j = 1; j < _rewardsData.length; j++) {
            _rewardsData[j] += _earned(
                _userAddress,
                _rewardTokens[j],
                bal[_index].shares,
                _index
            );
        }
    }

    /**
     * @dev calculates the penalties and penalized amounts
     * of user for removing given shares
     * @param _userAddress user address
     * @param _shares share of the users
     * @return _totalClaimableRewards total Claimable rewards amounts
     * @return _totalPenaltyRewards total penalties rewards amount
     * @return _penalizedAmount penalized shares
     */
    function calculatePenalties(
        address _userAddress,
        uint256 _shares
    )
        external
        view
        returns (
            uint256[] memory _totalClaimableRewards,
            uint256[] memory _totalPenaltyRewards,
            uint256 _penalizedAmount
        )
    {
        Balance[] storage bal = _balances[_userAddress];
        uint256 index = userUnstakeIndex[_userAddress];
        (uint256 rewardsAccumlated, , , , ) = _getRewardsAccumlated();
        uint256 totalLockedWin = totalLockedTokens + rewardsAccumlated;
        _totalClaimableRewards = new uint256[](_rewardTokens.length);
        _totalPenaltyRewards = new uint256[](_rewardTokens.length);
        uint256 percentage;

        uint256 remainingShares = _shares;
        for (uint256 i = index; i < bal.length; i++) {
            if (remainingShares == 0) {
                break;
            }
            if (bal[i].shares == 0) {
                continue;
            }
            if (bal[i].shares >= remainingShares) {
                percentage = (remainingShares * 1e18) / bal[i].shares;
            } else {
                percentage = 1e18;
            }

            bool locked = bal[i].unlockTime > block.timestamp;
            if (locked) {
                _penalizedAmount += (bal[i].shares * percentage) / 1e18;
            }

            for (uint256 j = 1; j < _rewardTokens.length; j++) {
                uint256 earnedRewards = _earned(
                    _userAddress,
                    _rewardTokens[j],
                    bal[i].shares,
                    i
                );

                if (locked) {
                    uint256 penaltyPer = (earnedRewards * percentage) / 1e18;
                    _totalPenaltyRewards[j] += penaltyPer;
                } else {
                    _totalClaimableRewards[j] += earnedRewards;
                }
            }

            uint256 totalRewardedWin = _calculateWinRewards(
                bal[i].shares,
                totalLockedWin,
                sharesTotal,
                bal[i].stakedAmount
            );

            if (locked) {
                uint256 penaltyPer = (totalRewardedWin * percentage) / 1e18;
                _totalPenaltyRewards[0] += penaltyPer;
            } else {
                _totalClaimableRewards[0] += totalRewardedWin;
            }

            if (remainingShares < bal[i].shares) {
                remainingShares = 0;
                break;
            } else {
                remainingShares -= bal[i].shares;
            }
        }
    }

    /**
     * @dev calculate the last reward applicable timestamp
     * @param _rewardsToken reward token address
     * @return _lastTimestamp last reward applicable timestamp
     */
    function lastTimeRewardApplicable(
        address _rewardsToken
    ) public view returns (uint256 _lastTimestamp) {
        return _min(block.timestamp, _rewardData[_rewardsToken].periodFinish);
    }

    /**
     * @dev calculate the last win penalty reward applicable timestamp
     * @return _lastTimestamp last reward applicable timestamp
     */
    function lastTimeWinPenaltyRewardApplicable()
        public
        view
        returns (uint256 _lastTimestamp)
    {
        return
            _min(
                block.timestamp,
                _winRewardData[_rewardTokens[0]].penaltyPeriodFinish
            );
    }

    /**
     * @dev calculate and returns number of unlocked share amount
     * @param _userAddress user Address
     * @return _shares unlocked shares amount
     */
    function getWithdrawableShares(
        address _userAddress
    ) public view returns (uint256 _shares) {
        Balance[] storage bal = _balances[_userAddress];
        uint256 index = userUnstakeIndex[_userAddress];
        for (uint256 i = index; i < bal.length; i++) {
            if (bal[i].unlockTime > block.timestamp) {
                break;
            }
            _shares += bal[i].shares;
        }
    }

    /**
     * @dev calculates and sets reward rate
     * @param  _rewardsToken reward token address
     * @param _reward reward amount
     */
    function _notifyReward(address _rewardsToken, uint256 _reward) private {
        uint8 decimals = IERC20Metadata(_rewardsToken).decimals();
        _reward = _reward * (10 ** (18 - decimals));
        uint256 activeRewardDuration = REWARDS_DURATION;
        if (_rewardsToken == HEX_ADDRESS) {
            activeRewardDuration = REWARDS_DURATION * 30;
        }

        if (block.timestamp >= _rewardData[_rewardsToken].periodFinish) {
            _rewardData[_rewardsToken].rewardRate =
                _reward /
                activeRewardDuration;
        } else {
            uint256 remaining = _rewardData[_rewardsToken].periodFinish -
                block.timestamp;
            uint256 leftover = remaining *
                _rewardData[_rewardsToken].rewardRate;
            _rewardData[_rewardsToken].rewardRate =
                (_reward + leftover) /
                activeRewardDuration;
        }

        _rewardData[_rewardsToken].lastUpdateTime = block.timestamp;
        _rewardData[_rewardsToken].periodFinish =
            block.timestamp +
            activeRewardDuration;
    }

    /**
     * @dev withdraws native token and transfers it to user
     * @param _user user address
     * @param _totalAmount amount to be transfered
     */
    function _processPLSCLaim(address _user, uint256 _totalAmount) private {
        IWETH(WPLS_ADDRESS).withdraw(_totalAmount);
        (bool success, ) = _user.call{value: _totalAmount}("");
        require(success, "PLS rewards transfer failed");
    }

    /**
     * @dev calculates and sets penalty reward rate for win
     * @param _amount amount of win reward
     */

    function _updatePenaltyRewards(uint256 _amount) private {
        address token = _rewardTokens[0];
        if (block.timestamp >= _winRewardData[token].penaltyPeriodFinish) {
            _winRewardData[token].penaltyRewardRate =
                _amount /
                WIN_REWARD_DURATION;
        } else {
            uint256 remaining = _winRewardData[token].penaltyPeriodFinish -
                block.timestamp;
            uint256 leftover = remaining *
                _winRewardData[token].penaltyRewardRate;
            _winRewardData[token].penaltyRewardRate =
                (_amount + leftover) /
                WIN_REWARD_DURATION;
        }

        _winRewardData[token].penaltyLastUpdateTime = block.timestamp;
        _winRewardData[token].penaltyPeriodFinish =
            block.timestamp +
            WIN_REWARD_DURATION;
    }

    /**
     * @dev provides reward token per share
     * @param _rewardsToken rewardToken address
     * @return _amountPerShare  reward token amount per share
     */
    function _rewardPerShare(
        address _rewardsToken
    ) private view returns (uint256 _amountPerShare) {
        if (totalLockedTokens == 0) {
            return _rewardData[_rewardsToken].rewardPerShareStored;
        } else {
            uint8 decimals = IERC20Metadata(_rewardsToken).decimals();

            uint256 totalAccumlated = (lastTimeRewardApplicable(_rewardsToken) -
                _rewardData[_rewardsToken].lastUpdateTime) *
                _rewardData[_rewardsToken].rewardRate;

            uint256 multiplicationFactor = 22 - (18 - decimals);

            return
                _rewardData[_rewardsToken].rewardPerShareStored +
                ((totalAccumlated * (10 ** multiplicationFactor)) /
                    sharesTotal);
        }
    }

    /**
     * @dev calculates the earned reward tokens for the given user
     * @param _user user address
     * @param _rewardsToken rewardToken address
     * @param _shares shares of the user
     * @param _index stake index
     * @return _earnedAmount total earned reward tokens
     */
    function _earned(
        address _user,
        address _rewardsToken,
        uint256 _shares,
        uint256 _index
    ) private view returns (uint256 _earnedAmount) {
        Balance[] storage bal = _balances[_user];

        return
            ((_shares *
                (_rewardPerShare(_rewardsToken) -
                    bal[_index].userRewardPerSharePaid[_rewardsToken])) /
                (1e22)) + (bal[_index].rewards[_rewardsToken]);
    }

    /**
     * @dev calculate and returns rewards accumlated in the duration
     * @return _rewardsAccumlated rewards accumlated amount
     * @return _rewardRate updated reward rate
     * @return _newTotalRemainingRewards new total rewards to be distributed
     * @return _newCurrentDayStartingTimestamp timestamp of current day
     */
    function _getRewardsAccumlated()
        private
        view
        returns (
            uint256 _rewardsAccumlated,
            uint256 _rewardRate,
            uint256 _newTotalRemainingRewards,
            uint256 _newCurrentDayStartingTimestamp,
            uint256 _burnAmount
        )
    {
        address token = _rewardTokens[0];
        WinReward memory winData = _winRewardData[token];

        uint256 currentTimestamp = block.timestamp;

        uint256 currentDayEndingTimeStamp = winData.currentDayStartTime +
            WIN_REWARD_DURATION;

        uint256 difference = currentTimestamp - winData.lastUpdateTime;

        if (currentDayEndingTimeStamp > currentTimestamp) {
            _rewardsAccumlated += difference * winData.rewardRate;

            uint256 effectiveRewards = ((_rewardsAccumlated * 9900) / 10000);

            _burnAmount = _rewardsAccumlated - effectiveRewards;

            _rewardsAccumlated =
                effectiveRewards +
                _getWinPenaltyRewardsAccumlated();

            return (
                _rewardsAccumlated,
                winData.rewardRate,
                winData.totalRemainingReward,
                winData.currentDayStartTime,
                _burnAmount
            );
        } else {
            uint256 currentDayRemainingSeconds = currentDayEndingTimeStamp -
                winData.lastUpdateTime;

            uint256 totalRewardsForCurrentDay = winData.rewardRate *
                currentDayRemainingSeconds;

            _rewardsAccumlated += totalRewardsForCurrentDay;

            difference -= currentDayRemainingSeconds;

            _newTotalRemainingRewards =
                winData.totalRemainingReward -
                (winData.rewardRate * WIN_REWARD_DURATION);

            uint256 numberOfDays = difference / WIN_REWARD_DURATION;

            _newCurrentDayStartingTimestamp =
                winData.currentDayStartTime +
                ((numberOfDays + 1) * WIN_REWARD_DURATION);

            uint256 remainingSeconds = difference -
                (WIN_REWARD_DURATION * numberOfDays);

            _rewardRate =
                (_newTotalRemainingRewards / R_CONSTANT) /
                WIN_REWARD_DURATION;

            if (numberOfDays > 0) {
                for (uint256 i = 0; i < numberOfDays; i++) {
                    totalRewardsForCurrentDay =
                        _rewardRate *
                        WIN_REWARD_DURATION;
                    _rewardsAccumlated += totalRewardsForCurrentDay;
                    _newTotalRemainingRewards -= totalRewardsForCurrentDay;
                    _rewardRate =
                        (_newTotalRemainingRewards / R_CONSTANT) /
                        WIN_REWARD_DURATION;
                }
            }

            if (remainingSeconds > 0) {
                totalRewardsForCurrentDay = _rewardRate * remainingSeconds;
                _rewardsAccumlated += totalRewardsForCurrentDay;
            }

            uint256 effectiveRewards = ((_rewardsAccumlated * 9900) / 10000);

            _burnAmount = _rewardsAccumlated - effectiveRewards;

            _rewardsAccumlated =
                effectiveRewards +
                _getWinPenaltyRewardsAccumlated();
        }
    }

    function _getWinPenaltyRewardsAccumlated()
        private
        view
        returns (uint256 _penaltyRewardsAccumated)
    {
        address token = _rewardTokens[0];
        WinReward memory winData = _winRewardData[token];

        //Penalty Rewards calculation
        {
            uint256 validRewardsDuration = lastTimeWinPenaltyRewardApplicable() -
                    winData.penaltyLastUpdateTime;
            _penaltyRewardsAccumated =
                validRewardsDuration *
                winData.penaltyRewardRate;
        }
    }

    /**
     * @dev calculate and return given shares equivalent win token
     * @param _shares shares amount
     * @param _totalLockedAmount total locked  win amount
     * @param _totalShares total shares in the pool
     * @return win token
     */

    function _getWinAmount(
        uint256 _shares,
        uint256 _totalLockedAmount,
        uint256 _totalShares
    ) private pure returns (uint256) {
        return (_shares * _totalLockedAmount) / _totalShares;
    }

    /**
     * @dev calculate total earned win rewards
     * @param _shares share amount for which we need to check rewards
     * @param _totalLockedAmount total locked amount
     * @param _totalShares total shares in the pool
     * @param _totalStakedAmount total amount staked to gain _shares amount
     * @return _totalRewardedWin total amount of win rewards earned
     */
    function _calculateWinRewards(
        uint256 _shares,
        uint256 _totalLockedAmount,
        uint256 _totalShares,
        uint256 _totalStakedAmount
    ) private pure returns (uint256 _totalRewardedWin) {
        uint256 winAmount = _getWinAmount(
            _shares,
            _totalLockedAmount,
            _totalShares
        );

        if (winAmount > _totalStakedAmount) {
            _totalRewardedWin = winAmount - _totalStakedAmount;
        }
    }

    /**
     * @dev filters the minimum value of the two
     * @param _a first value
     * @param _b second value
     * @return _minimum minimum of give two value
     */
    function _min(
        uint256 _a,
        uint256 _b
    ) private pure returns (uint256 _minimum) {
        return _a < _b ? _a : _b;
    }

    // TWAB FUNCTIONS //

    /**
     * @notice Increase `_to` TWAB balance.
     * @param _to Address of the delegate.
     * @param _amount Amount of tokens to be added to `_to` TWAB balance.
     */
    function _increaseUserTwab(address _to, uint256 _amount) private {
        if (_amount == 0) {
            return;
        }

        TwabLib.Account storage _account = userTwabs[_to];

        (TwabLib.AccountDetails memory accountDetails, , ) = TwabLib
            .increaseBalance(
                _account,
                uint208(_amount),
                uint32(block.timestamp)
            );

        _account.details = accountDetails;
    }

    /**
     * @notice Decrease `_to` TWAB balance.
     * @param _to Address of the delegate.
     * @param _amount Amount of tokens to be added to `_to` TWAB balance.
     */
    function _decreaseUserTwab(address _to, uint256 _amount) private {
        if (_amount == 0) {
            return;
        }

        TwabLib.Account storage _account = userTwabs[_to];

        (TwabLib.AccountDetails memory accountDetails, , ) = TwabLib
            .decreaseBalance(
                _account,
                uint208(_amount),
                "twab-burn-lessthan-balance",
                uint32(block.timestamp)
            );

        _account.details = accountDetails;
    }

    /// @notice Decreases the total supply twab.  Should be called anytime a balance moves from delegated to undelegated
    /// @param _amount The amount to decrease the total by
    function _decreaseTotalSupplyTwab(uint256 _amount) private {
        if (_amount == 0) {
            return;
        }

        (TwabLib.AccountDetails memory accountDetails, , ) = TwabLib
            .decreaseBalance(
                totalSupplyTwab,
                uint208(_amount),
                "burn-amount-exceeds-total-supply-twab",
                uint32(block.timestamp)
            );

        totalSupplyTwab.details = accountDetails;
    }

    /// @notice Increases the total supply twab.  Should be called anytime a balance moves from undelegated to delegated
    /// @param _amount The amount to increase the total by
    function _increaseTotalSupplyTwab(uint256 _amount) private {
        if (_amount == 0) {
            return;
        }

        (TwabLib.AccountDetails memory accountDetails, , ) = TwabLib
            .increaseBalance(
                totalSupplyTwab,
                uint208(_amount),
                uint32(block.timestamp)
            );

        totalSupplyTwab.details = accountDetails;
    }
}
