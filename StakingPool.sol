//SPDX-License-Identifier: None
pragma solidity 0.8.17;
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../Interfaces/IWETH.sol";
import "../Interfaces/IPrizePool.sol";
import "../libraries/TwabLib.sol";

/**
 * @notice Contract performs mulit token along with Win Token Staking, Unstaking and Claim Rewards.
 */
abstract contract StakingPool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /**
     * @dev stores information of every reward token
     * @param periodFinish stores when current reward period will end
     * @param rewardRate reward rate stores at which rate reward token are being ditributed per second
     * @param lastUpdateTime timestamp when rewards were calculated or applied
     * @param rewardPerTokenStored reward token stored per token from the very beginning
     */
    struct Reward {
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }

    /**
     * @dev stores the balance of the user
     * @param amount number of staked tokens
     * @param unlockTime unlock time of this stake
     * @param rewards stored rewards of all the tokens
     * @param userRewardPerTokenPaid paid rewards of all the reward tokens
     */
    struct Balance {
        uint256 amount;
        uint256 unlockTime;
        mapping(address => uint256) rewards;
        mapping(address => uint256) userRewardPerTokenPaid;
    }

    struct RewardData {
        address token;
        uint256 amount;
    }

    IERC20 public immutable stakingToken;

    address public constant BUY_AND_BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    address private constant WPLS_ADDRESS =
        0x8a810ea8B121d08342E9e7696f4a9915cBE494B7;

    uint32 public constant REWARDS_DURATION = 200;

    uint32 public constant LOCK_DURATION = 100;

    uint256 public totalSupply;

    /// @notice Record of token holders TWABs for each account.
    mapping(address => TwabLib.Account) private userTwabs;

    /// @notice Record of tickets total supply and ring buff parameters used for observation.
    TwabLib.Account private totalSupplyTwab;

    // reward token -> distributor -> is approved to add rewards
    mapping(address => mapping(address => bool)) public rewardDistributors;

    mapping(address => uint256) public totalBalances;

    mapping(address => Reward) private _rewardData;

    mapping(address => Balance[]) private _balances;

    //User address => index from where stakes are available
    mapping(address => uint256) public userUnstakeIndex;

    mapping(address => bool) public isOptedForPrizePool;

    address[] private _rewardTokens;

    address private _prizePoolAddress;

    event RewardAdded(address rewardToken, uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardPaid(
        address indexed user,
        address indexed rewardsToken,
        uint256 reward
    );

    /**
     * @dev Updates the reward per token, stores the last updated timestamp, calculates the total
     * rewards earned by user. Modifier is called everytime user stakes, withdraw, change Reward Rate
     * or claim Rewards
     */
    modifier updateReward() {
        address token;
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            token = _rewardTokens[i];
            _rewardData[token].rewardPerTokenStored = _rewardPerToken(token);
            _rewardData[token].lastUpdateTime = lastTimeRewardApplicable(token);
        }
        _;
    }

    /**
     * @dev Constructor intialized the staking token
     * @param __stakingToken address of staking token
     */
    constructor(address __stakingToken) Ownable() {
        require(__stakingToken != address(0), "Not valid address");
        stakingToken = IERC20(__stakingToken);
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
     * @dev Modify approval for an address to become distributor, distributor can than
     * call notifyRewardAmount
     * @param _rewardsToken reward token address
     * @param _distributor distributor account address
     * @param _approved bool value of status of distributor
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
     * @dev Transfer amount of rewards token to contract and later sets the Reward Rate
     * @param _rewardsToken Specify the reward token address which want to transfer
     * @param _rewardAmount Total amount of reward token
     */
    function notifyRewardAmount(
        address _rewardsToken,
        uint256 _rewardAmount
    ) external updateReward {
        require(
            rewardDistributors[_rewardsToken][msg.sender],
            "Caller not approved to add rewards"
        );
        require(_rewardAmount > 0, "No reward");
        _notifyReward(_rewardsToken, _rewardAmount);
        IERC20(_rewardsToken).safeTransferFrom(
            msg.sender,
            address(this),
            _rewardAmount
        );
        emit RewardAdded(_rewardsToken, _rewardAmount);
    }


    /**
     * @dev Stake amount of tokens so user can later receive rewards
     * @param _amount total amount of tokens user want to stake
     * @param _slots any existing empty slot to fill in
     * @param _shuffleSlots empty slots that we need to fill by shuffling last slots
     * @param _isOptedForPrizePool if user is opting for prizePool or not.
     * @notice User cannot change its preference before unstaking all the staked tokens.
     */
    function stake(
        uint256 _amount,
        uint256[] calldata _slots,
        uint256[] calldata _shuffleSlots,
        bool _isOptedForPrizePool
    ) external nonReentrant updateReward {
        require(_amount > 0, "Cannot stake 0");
        if (totalBalances[msg.sender] != 0) {
            require(
                isOptedForPrizePool[msg.sender] == _isOptedForPrizePool,
                "Cannot change PrizePool Preference."
            );
        } else {
            isOptedForPrizePool[msg.sender] = _isOptedForPrizePool;
        }
        Balance[] storage bal = _balances[msg.sender];
        uint256 unlockTime = block.timestamp + LOCK_DURATION;
        uint256 idx = _balances[msg.sender].length;
        if (idx == 0 || bal[idx - 1].unlockTime < unlockTime) {
            Balance storage newBalance = bal.push();
            newBalance.amount = _amount;
            newBalance.unlockTime = unlockTime;
            for (uint256 i = 0; i < _rewardTokens.length; i++) {
                newBalance.rewards[_rewardTokens[i]] = 0;
                newBalance.userRewardPerTokenPaid[
                    _rewardTokens[i]
                ] = _rewardData[_rewardTokens[i]].rewardPerTokenStored;
            }
        } else {
            bal[idx - 1].amount = bal[idx - 1].amount + _amount;
        }
        totalSupply += _amount;
        totalBalances[msg.sender] += _amount;

        if (_isOptedForPrizePool) {
            _increaseUserTwab(msg.sender, _amount);
            _increaseTotalSupplyTwab(_amount);
            IPrizePool(_prizePoolAddress).getTickets(
                msg.sender,
                _amount,
                _slots,
                _shuffleSlots
            );
        }

        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);

        _deposit(_amount);
        emit Staked(msg.sender, _amount);
    }

    /**
     * @dev Withdraw staked tokens and transfer back to user
     * @param _amount total amount to withdraw
     */

    function unstake(uint256 _amount) external nonReentrant updateReward {
        require(_amount > 0, "Cannot unstake 0");
        require(
            totalBalances[msg.sender] >= _amount,
            "Insufficient Staked Balance"
        );
        Balance[] storage bal = _balances[msg.sender];
        uint256 index = userUnstakeIndex[msg.sender];
        uint256 remaining = _amount;

        uint256[] memory totalClaimableRewards = new uint256[](
            _rewardTokens.length
        );
        uint256[] memory totalPenaltyRewards = new uint256[](
            _rewardTokens.length
        );
        uint256 percentage;
        for (uint256 i = index; i < bal.length; i++) {
            if (remaining == 0) {
                break;
            }
            uint256 stakedAmount = bal[i].amount;
            if (stakedAmount == 0) {
                continue;
            }
            if (stakedAmount >= remaining) {
                percentage = (remaining * 1e18) / stakedAmount;
            } else {
                percentage = 1e18;
            }

            for (uint256 j = 0; j < _rewardTokens.length; j++) {
                address _rewardToken = _rewardTokens[j];
                bal[i].rewards[_rewardToken] = _earned(
                    msg.sender,
                    i,
                    _rewardToken,
                    bal[i].amount
                );

                bal[i].userRewardPerTokenPaid[_rewardToken] = _rewardData[
                    _rewardToken
                ].rewardPerTokenStored;

                if (bal[i].unlockTime > block.timestamp) {
                    uint256 penaltyRewards;
                    penaltyRewards =
                        (bal[i].rewards[_rewardToken] * percentage) /
                        1e18;
                    totalPenaltyRewards[j] += penaltyRewards;
                    bal[i].rewards[_rewardToken] =
                        bal[i].rewards[_rewardToken] -
                        penaltyRewards;
                } else {
                    totalClaimableRewards[j] += bal[i].rewards[_rewardToken];
                    bal[i].rewards[_rewardToken] = 0;
                }
            }
            if (remaining < stakedAmount) {
                bal[i].amount -= remaining;
                remaining = 0;
                break;
            } else {
                remaining -= stakedAmount;
                delete bal[i];
                userUnstakeIndex[msg.sender] = i + 1;
            }
        }

        _withdraw(_amount);
        totalBalances[msg.sender] -= _amount;
        totalSupply -= _amount;

        if (isOptedForPrizePool[msg.sender]) {
            _decreaseUserTwab(msg.sender, _amount);
            _decreaseTotalSupplyTwab(_amount);
            IPrizePool(_prizePoolAddress).burnTickets(msg.sender, _amount);
        }
        if (totalBalances[msg.sender] == 0) {
            delete isOptedForPrizePool[msg.sender];
        }

        stakingToken.safeTransfer(msg.sender, _amount);
        bool weth;
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            address _rewardToken = _rewardTokens[i];
            weth = _rewardToken == WPLS_ADDRESS;

            if (totalPenaltyRewards[i] > 0) {
                uint256 zeroAddressReward = totalPenaltyRewards[i] / 2;

                uint256 remainingReward = totalPenaltyRewards[i] -
                    zeroAddressReward;

                _notifyReward(_rewardToken, remainingReward);
                if (weth) {
                    _processPLSCLaim(BUY_AND_BURN_ADDRESS, zeroAddressReward);
                } else {
                    IERC20(_rewardToken).safeTransfer(
                        BUY_AND_BURN_ADDRESS,
                        zeroAddressReward
                    );
                }
            }
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
        }
        emit Unstaked(msg.sender, _amount);
    }

    /**
     * @dev used to claim the rewards
     * All the rewards are claimed for the _user
     * @param _user user address
     */
    function claim(address _user) external nonReentrant updateReward {
        Balance[] storage bal = _balances[_user];
        uint256 index = userUnstakeIndex[_user];
        uint256 totalAccumlatedRewards;
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            address _rewardToken = _rewardTokens[i];
            for (uint256 j = index; j < bal.length; j++) {
                if (bal[j].unlockTime > block.timestamp) {
                    break;
                }

                bal[j].rewards[_rewardToken] = _earned(
                    _user,
                    j,
                    _rewardToken,
                    bal[j].amount
                );

                bal[j].userRewardPerTokenPaid[_rewardToken] = _rewardData[
                    _rewardToken
                ].rewardPerTokenStored;

                totalAccumlatedRewards += bal[j].rewards[_rewardToken];
                bal[j].rewards[_rewardToken] = 0;
            }
            if (totalAccumlatedRewards > 0) {
                if (_rewardToken == WPLS_ADDRESS) {
                    _processPLSCLaim(_user, totalAccumlatedRewards);
                } else {
                    IERC20(_rewardToken).safeTransfer(
                        _user,
                        totalAccumlatedRewards
                    );
                }
                totalAccumlatedRewards = 0;
                emit RewardPaid(_user, _rewardToken, totalAccumlatedRewards);
            }
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
     * @dev calculates the penalties and penalized amounts
     * of user for removing given shares
     * @param _userAddress user address
     * @param _amount amount of the users
     * @return _totalClaimableRewards total Claimable rewards amounts
     * @return _totalPenaltyRewards total penalties rewards amount
     * @return _penalizedAmount penalized amount
     */
    function calculatePenalties(
        address _userAddress,
        uint256 _amount
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
        uint256 remaining = _amount;

        _totalClaimableRewards = new uint256[](_rewardTokens.length);
        _totalPenaltyRewards = new uint256[](_rewardTokens.length);
        uint256 percentage;
        for (uint256 i = index; i < bal.length; i++) {
            if (remaining == 0) {
                break;
            }
            uint256 stakedAmount = bal[i].amount;
            if (stakedAmount == 0) {
                continue;
            }
            if (stakedAmount >= remaining) {
                percentage = (remaining * 1e18) / stakedAmount;
            } else {
                percentage = 1e18;
            }

            bool locked = bal[i].unlockTime > block.timestamp;
            if (locked) {
                _penalizedAmount += (bal[i].amount * percentage) / 1e18;
            }

            for (uint256 j = 0; j < _rewardTokens.length; j++) {
                uint256 penaltyRewards;
                uint256 rewardsAmount = _earned(
                    _userAddress,
                    i,
                    _rewardTokens[j],
                    bal[i].amount
                );
                if (locked) {
                    penaltyRewards = (rewardsAmount * percentage) / 1e18;
                    _totalPenaltyRewards[j] += penaltyRewards;
                } else {
                    _totalClaimableRewards[j] += rewardsAmount;
                }
            }
            if (remaining < stakedAmount) {
                remaining = 0;
                break;
            } else {
                remaining -= stakedAmount;
            }
        }
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
     * @dev Function counts the number of stakes
     * @param _userAddress address of User
     */

    function getStakeCount(
        address _userAddress
    ) external view returns (uint256) {
        return _balances[_userAddress].length;
    }

    /**
     * @dev returns the reward data
     * @param _rewardToken reward token address of which
     * reward data needs to be fetched
     * @return _reward reward Data
     */
    function getRewardData(
        address _rewardToken
    ) external view returns (Reward memory _reward) {
        return _rewardData[_rewardToken];
    }

    /**
     * @dev User can fetch staked amount, unlock time, total rewards of every staked index
     * @param _userAddress address of User
     * @param _index index of any particular stake
     * @param _rewardToken reward Token address
     * @return _stakedAmount stake amount
     * @return _unlockTime unlock time of the stake
     * @return _rewardAmount reward amount of the given reward token
     * @return _userRewardPerTokenPaid  reward per token paid to user for given reward token
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
            uint256 _unlockTime,
            uint256 _rewardAmount,
            uint256 _userRewardPerTokenPaid
        )
    {
        return (
            _balances[_userAddress][_index].amount,
            _balances[_userAddress][_index].unlockTime,
            _balances[_userAddress][_index].rewards[_rewardToken],
            _balances[_userAddress][_index].userRewardPerTokenPaid[_rewardToken]
        );
    }

    /**
     * @dev Shows Reward Per Token value for any reward token added
     * @param _rewardsToken address of reward token
     * @return _perTokenReward reward per token amount
     */
    function rewardPerToken(
        address _rewardsToken
    ) external view returns (uint256 _perTokenReward) {
        return _rewardPerToken(_rewardsToken);
    }

    /**
     * @dev Check total rewards that will be distributed through out the duration defined
     * @param _rewardsToken address of reward token
     * @return _totalRewards total reward for the duration
     */
    function getRewardForDuration(
        address _rewardsToken
    ) external view returns (uint256 _totalRewards) {
        uint8 decimals = IERC20Metadata(_rewardsToken).decimals();
        return
            (_rewardData[_rewardsToken].rewardRate * (REWARDS_DURATION)) /
            (10 ** (18 - decimals));
    }

    /**
     * @dev Shows the amount of all rewards tokens any particular user include both
     * locked duration and unlock duration rewards
     * @param _userAddress user's account address
     * @return _rewardsData rewards amount with reward token address
     */
    function getTotalUserRewards(
        address _userAddress
    ) external view returns (RewardData[] memory _rewardsData) {
        _rewardsData = new RewardData[](_rewardTokens.length);
        Balance[] storage bal = _balances[_userAddress];
        uint256 index = userUnstakeIndex[_userAddress];
        for (uint256 i = 0; i < _rewardsData.length; i++) {
            _rewardsData[i].token = _rewardTokens[i];
            for (uint256 j = index; j < bal.length; j++) {
                _rewardsData[i].amount += _earned(
                    _userAddress,
                    j,
                    _rewardTokens[i],
                    bal[j].amount
                );
            }
        }
    }

    /**
     * @dev Function for all Unlocked Rewards after lock Duration completes
     * @param _userAddress user's account address
     * @return _unlockReward rewards amount with reward token address
     */

    function getClaimableRewards(
        address _userAddress
    ) external view returns (RewardData[] memory _unlockReward) {
        _unlockReward = new RewardData[](_rewardTokens.length);
        Balance[] storage bal = _balances[_userAddress];
        uint256 index = userUnstakeIndex[_userAddress];
        for (uint256 i = 0; i < _unlockReward.length; i++) {
            _unlockReward[i].token = _rewardTokens[i];
            for (uint256 j = index; j < bal.length; j++) {
                if (bal[j].unlockTime > block.timestamp) {
                    break;
                }
                _unlockReward[i].amount += _earned(
                    _userAddress,
                    j,
                    _rewardTokens[i],
                    bal[j].amount
                );
            }
        }
    }

    /**
     * @dev Accumlates all the reward of any particular reward token of all the stakes
     * @param _userAddress address of user
     * @param _index index of individual stake
     * @return _rewardsData rewards amount with reward token address
     */
    function getTotalRewardsOfStake(
        address _userAddress,
        uint256 _index
    ) external view returns (uint256[] memory _rewardsData) {
        _rewardsData = new uint256[](_rewardTokens.length);
        Balance[] storage bal = _balances[_userAddress];
        for (uint256 j = 0; j < _rewardsData.length; j++) {
            _rewardsData[j] += _earned(
                _userAddress,
                _index,
                _rewardTokens[j],
                bal[_index].amount
            );
        }
    }

    /**
     * @dev calculates and returns unlocked stakes amount
     * @param _userAddress user address
     * @return _amount amount of unlocked stakes
     */
    function getWithdrawableShares(
        address _userAddress
    ) external view returns (uint256 _amount) {
        Balance[] storage bal = _balances[_userAddress];
        uint256 index = userUnstakeIndex[_userAddress];
        for (uint256 j = index; j < bal.length; j++) {
            if (bal[j].unlockTime > block.timestamp) {
                break;
            }
            _amount += bal[j].amount;
        }
    }

    /**
     * @dev Check the minimum time between latest timestamp or reward finish period
     * @param _rewardsToken address of reward Token
     * @return _lastTimeReward last timestamp at which rewards were calculated
     */
    function lastTimeRewardApplicable(
        address _rewardsToken
    ) public view returns (uint256 _lastTimeReward) {
        return
            Math.min(block.timestamp, _rewardData[_rewardsToken].periodFinish);
    }

    /**
     * @dev calculate and set the reward rate based on timestamp of function called
     * @param _rewardsToken reward token address
     * @param _reward total amount of reward tokens
     */
    function _notifyReward(address _rewardsToken, uint256 _reward) private {
        uint8 decimals = IERC20Metadata(_rewardsToken).decimals();
        _reward = _reward * (10 ** (18 - decimals));
        if (block.timestamp >= _rewardData[_rewardsToken].periodFinish) {
            _rewardData[_rewardsToken].rewardRate = _reward / REWARDS_DURATION;
        } else {
            uint256 remaining = (_rewardData[_rewardsToken].periodFinish -
                block.timestamp);
            uint256 leftover = remaining *
                _rewardData[_rewardsToken].rewardRate;
            _rewardData[_rewardsToken].rewardRate =
                (_reward + leftover) /
                REWARDS_DURATION;
        }
        _rewardData[_rewardsToken].lastUpdateTime = block.timestamp;
        _rewardData[_rewardsToken].periodFinish =
            block.timestamp +
            REWARDS_DURATION;
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
     * @dev Checks the total supply and calculates the reward per token
     * @param _rewardsToken address of reward token
     */
    function _rewardPerToken(
        address _rewardsToken
    ) private view returns (uint256) {
        if (totalSupply == 0) {
            return _rewardData[_rewardsToken].rewardPerTokenStored;
        }
        uint8 decimals = IERC20Metadata(_rewardsToken).decimals();
        uint256 multiplicationFactor = 22 - (18 - decimals);
        return
            _rewardData[_rewardsToken].rewardPerTokenStored +
            (_rewardData[_rewardsToken].rewardRate *
                (lastTimeRewardApplicable(_rewardsToken) -
                    _rewardData[_rewardsToken].lastUpdateTime) *
                (10 ** multiplicationFactor)) /
            totalSupply;
    }

    /**
     * @dev calculates the total rewards token earned by a user
     * @param _user user account address
     * @param _index index of staked amount which has reward stored
     * @param _rewardsToken reward token address
     * @param _balance total balance of the user
     */
    function _earned(
        address _user,
        uint256 _index,
        address _rewardsToken,
        uint256 _balance
    ) private view returns (uint256) {
        Balance[] storage bal = _balances[_user];
        return
            ((_balance *
                (_rewardPerToken(_rewardsToken) -
                    bal[_index].userRewardPerTokenPaid[_rewardsToken])) /
                1e22) + bal[_index].rewards[_rewardsToken];
    }

    function _deposit(uint256 _amount) internal virtual;

    function _withdraw(uint256 _amount) internal virtual;

    // TWAB FUNCTIONS //

    /**
     * @notice Increase `_to` TWAB balance.
     * @param _to Address of the user.
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
     * @param _to Address of the user.
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

    /**
     * @notice Decreases the total supply twab.
     * @param _amount The amount to decrease the total by
     */
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

    /**
     * @notice Increases the total supply twab.
     * @param _amount The amount to increase the total by
     */
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
