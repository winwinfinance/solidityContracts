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

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./Interfaces/IStakingPool.sol";
import "./Interfaces/IRandomNumber.sol";
import "./Interfaces/IWETH.sol";

contract PrizePool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Ranges {
        uint256 start; //Start ticket number
        uint256 end; //End Ticket number
    }

    struct RangeInfo {
        address userAddress; //User address
        uint256 start; //Start ticket number
        uint256 indexInUserRanges; //index of this range in user's ranges array
    }

    struct TicketInfo {
        //Total Ticket Numbers
        uint256 totalTicketNumber;
        //Total Eligble tickets for this draw
        uint256 totalEligibleForThisDraw;
        //Last draw valid ticket numbers
        uint256 lastDrawEligibleCount;
    }

    struct RewardInfo {
        //reward tokens array
        address[] rewardTokens;
        uint256[6] prizeDistributionsPercentage;
        //Draw => true/false
        mapping(uint256 => bool) rewardsAdded;
        //Draw count => rewardToken => token amount
        mapping(uint256 => mapping(address => uint256)) totalRewardTokensForTheDraw;
        //rewardToken => true/false
        mapping(address => bool) isRewardTokenSupported;
        //Draw ->reward token->  Extra Amount
        mapping(uint256 => mapping(address => uint256)) extraRewards;
    }

    struct WinnerInfo {
        //draw count => user => true/false
        mapping(uint256 => mapping(address => bool)) isWinner;
        //draw number => tier => winner address
        mapping(uint256 => mapping(uint256 => address)) tierWinner;
        //draw number => address => true/false
        mapping(uint256 => mapping(address => bool)) drawRewardsClaimed;
    }

    TicketInfo public ticketInfo;

    RewardInfo rewardInfo;

    WinnerInfo winnerInfo;

    //CONSTANT VARIABLES
    uint16 public constant TOTAL_PERCENT = 10000;

    uint16 public constant MAX_DELETED_EMPTY_INDEX = 10;

    uint16 public constant MAX_SHUFFLE_LIMIT = 3;
    //Cooldown for claiming prize
    uint32 public constant COOLDOWN_DURATION = 100;
    //Cycle duration
    uint32 public constant CYCLE_DURATION = 200;
    //Cycle start time
    uint32 public immutable cycleStartTimestamp;

    address public constant WPLS_ADDRESS =
        0x70499adEBB11Efd915E3b69E700c331778628707;

    //current draw count
    uint256 public drawCount;

    //Random numbers for previous draw
    //Total 25 random numbers 5 for each tier
    uint256[] public randomNumber;

    address public stakingPool;

    address public randomNumberAddress;

    //Empty ranges (ticket numbers)
    Ranges[] public emptyRanges;

    //user => user's ticket ranges
    mapping(address => Ranges[]) public userRanges;

    //Ending range mapping to user address
    mapping(uint256 => RangeInfo) public endingRangeToUser;

    //EndingRange of empty slots to their indexes in the empty ranges array
    mapping(uint256 => uint256) public emptyRangesIndex;
    //draw => true/false
    mapping(uint256 => bool) public drawCalled;
    //draw => isRandomNumberSet
    mapping(uint256 => bool) public isRandomNumberSet;
    //event emitted with the amount when rewards are added
    event RewardAdded(uint256 draw, address rewardToken, uint256 reward);

    event PrizesClaimed(
        uint256 draw,
        address userAddress,
        address rewardToken,
        uint256 amount
    );

    event WinnerDeclared(uint256 draw, uint256 tier, address userAddress);

    modifier onlyStakingPool() {
        require(msg.sender == stakingPool, "not staking pool");
        _;
    }

    /**
     * @param _startTimestamp  cycle start timestamp
     */
    constructor(
        uint32 _startTimestamp,
        address _stakingPoolAddress,
        uint256[6] memory _prizeDistribution
    ) {
        require(_stakingPoolAddress != address(0), "Not valid address");
        cycleStartTimestamp = _startTimestamp;
        stakingPool = _stakingPoolAddress;
        rewardInfo.prizeDistributionsPercentage = _prizeDistribution;
    }

    /**
     * @notice Receives native currency
     */
    receive() external payable {}

    /**
     * @dev sets staking pool address.Can only be called by the owner
     * @param _stakingPool staking pool address
     */
    function setStakingPool(address _stakingPool) external onlyOwner {
        require(_stakingPool != address(0), "Not valid address");
        stakingPool = _stakingPool;
    }

    /**
     * @dev sets random number contract and can only be called by the owner
     * @param _randomNumberAddress random number contract address
     */
    function setRandomNumber(address _randomNumberAddress) external onlyOwner {
        require(_randomNumberAddress != address(0), "Not valid address");
        randomNumberAddress = _randomNumberAddress;
    }

    /**
     * @dev Called on stake
     * @param _user user address
     * @param _amount amount of tickets to be minted
     * @param _slots any existing empty slot to fill in
     * @param _shuffleSlots empty slots that we need to fill by shuffling last slots
     */
    function getTickets(
        address _user,
        uint256 _amount,
        uint256[] calldata _slots,
        uint256[] calldata _shuffleSlots
    ) external onlyStakingPool {
        uint256[MAX_DELETED_EMPTY_INDEX] memory deletedEmptyIndex;
        uint256 pointer;
        if (block.timestamp > getCurrentCycleStartTimestamp()) {
            //All tickets will be non eligible after cycle starts
            (deletedEmptyIndex, pointer) = _handleNonEligbleTickets(
                _user,
                _amount,
                _slots
            );
        } else {
            //All tickets will be  eligible before cycle starts
            (deletedEmptyIndex, pointer) = _handleEligbleTickets(
                _user,
                _amount,
                _slots
            );
        }
        //Only after cooldown period. cooldown period for claiming the prize
        if (
            getCurrentCycleStartTimestamp() + COOLDOWN_DURATION <
            block.timestamp
        ) {
            _handleShuffle(_shuffleSlots);
        }

        for (uint256 i = 0; i < pointer; i++) {
            _reArrangeEmptyArray(deletedEmptyIndex[i]);
        }
    }

    /**
     * @dev to shuffle for a large empty slots or large number of slots.
     * @param _slots empty slots that we need to fill by shuffling last slots
     */
    function bigShuffle(uint256[] calldata _slots) external {
        //Only after cooldown
        if (
            getCurrentCycleStartTimestamp() + COOLDOWN_DURATION <
            block.timestamp
        ) {
            _handleShuffle(_slots);
        }
    }

    /**
     * @dev function to burn tickets
     * @param _user user address
     * @param _amount amount of tickets to be burnt
     */
    function burnTickets(
        address _user,
        uint256 _amount
    ) external onlyStakingPool {
        uint256 length = userRanges[_user].length;
        uint256[MAX_SHUFFLE_LIMIT] memory rangesToShuffle; //eligible slots that are made empty by burning
        uint256 pointer = 0;

        //traverse to all the slots of the user from the last
        for (int256 i = int256(length - 1); i >= 0; i--) {
            if (_amount == 0) {
                break;
            }
            Ranges storage range = userRanges[_user][uint256(i)];
            uint256 totalRangeAmount = range.end - range.start + 1;

            bool lastEligibleRange = false;
            bool lastNonEligibleRange = false;

            if (range.end == ticketInfo.totalEligibleForThisDraw) {
                lastEligibleRange = true;
            }
            if (range.end == ticketInfo.totalTicketNumber) {
                lastNonEligibleRange = true;
            }
            RangeInfo memory rangeInfo = endingRangeToUser[range.end];
            delete endingRangeToUser[range.end];
            if (_amount >= totalRangeAmount) {
                if (
                    (ticketInfo.totalTicketNumber !=
                        ticketInfo.totalEligibleForThisDraw &&
                        !lastNonEligibleRange) ||
                    (ticketInfo.totalTicketNumber ==
                        ticketInfo.totalEligibleForThisDraw &&
                        !lastEligibleRange)
                ) {
                    emptyRanges.push(range);
                    emptyRangesIndex[range.end] = emptyRanges.length - 1;
                    if (pointer < MAX_SHUFFLE_LIMIT) {
                        rangesToShuffle[pointer] = emptyRanges.length - 1;
                        pointer++;
                    }
                }
                userRanges[_user].pop();

                if (lastEligibleRange) {
                    ticketInfo.totalEligibleForThisDraw =
                        ticketInfo.totalEligibleForThisDraw -
                        totalRangeAmount;
                }
                if (lastNonEligibleRange) {
                    ticketInfo.totalTicketNumber =
                        ticketInfo.totalTicketNumber -
                        totalRangeAmount;
                }
                _amount = _amount - totalRangeAmount;
            } else {
                Ranges memory emptyRange = Ranges({
                    start: range.end - _amount + 1,
                    end: range.end
                });
                if (
                    (ticketInfo.totalTicketNumber !=
                        ticketInfo.totalEligibleForThisDraw &&
                        !lastNonEligibleRange) ||
                    (ticketInfo.totalTicketNumber ==
                        ticketInfo.totalEligibleForThisDraw &&
                        !lastEligibleRange)
                ) {
                    emptyRanges.push(emptyRange);
                    emptyRangesIndex[range.end] = emptyRanges.length - 1;
                    if (pointer < MAX_SHUFFLE_LIMIT) {
                        rangesToShuffle[pointer] = emptyRanges.length - 1;
                        pointer++;
                    }
                }
                range.end = range.end - _amount;
                if (lastEligibleRange) {
                    ticketInfo.totalEligibleForThisDraw =
                        ticketInfo.totalEligibleForThisDraw -
                        _amount;
                }
                if (lastNonEligibleRange) {
                    ticketInfo.totalTicketNumber =
                        ticketInfo.totalTicketNumber -
                        _amount;
                }
                endingRangeToUser[range.end] = rangeInfo;
                _amount = 0;
            }
        }

        uint256[MAX_DELETED_EMPTY_INDEX] memory deletedEmptyIndex;
        uint256[5] memory returnedDeletedEmptyIndexes;
        uint256 deletedIndexPointer = 0;
        uint256 returnedPointer = 0;

        //shuffle the slots if there are any eligible slots that are made empty
        if (
            getCurrentCycleStartTimestamp() + COOLDOWN_DURATION <
            block.timestamp
        ) {
            for (uint256 i = 0; i < pointer; i++) {
                Ranges memory lastEmptyRange = emptyRanges[rangesToShuffle[i]];

                if (
                    lastEmptyRange.start <=
                    ticketInfo.totalEligibleForThisDraw &&
                    lastEmptyRange.end <= ticketInfo.totalEligibleForThisDraw
                ) {
                    (
                        returnedDeletedEmptyIndexes,
                        returnedPointer
                    ) = _internalShuffleHandler(rangesToShuffle[i]);
                } else {
                    (
                        returnedDeletedEmptyIndexes,
                        returnedPointer
                    ) = _internalNonEligibleShuffleHandler(rangesToShuffle[i]);
                }

                for (uint256 j = 0; j < returnedPointer; j++) {
                    if (deletedIndexPointer >= MAX_DELETED_EMPTY_INDEX) {
                        break;
                    }
                    deletedEmptyIndex[
                        deletedIndexPointer
                    ] = returnedDeletedEmptyIndexes[j];
                    ++deletedIndexPointer;
                }
            }

            for (uint256 i = 0; i < deletedIndexPointer; i++) {
                _reArrangeEmptyArray(deletedEmptyIndex[i]);
            }
        }
    }

    /**
     * @dev Claim prizes according to time weighted average balance
     * @param _draw draw ids for which rewards is being claimed
     * @param _user user address
     */
    function claimPrizes(
        uint[] calldata _draw,
        address _user
    ) external nonReentrant {
        uint256[] memory totalPrizesClaimable = new uint256[](
            rewardInfo.rewardTokens.length
        );
        //iterate over all the draws
        for (uint256 i = 0; i < _draw.length; i++) {
            require(
                cycleStartTimestamp +
                    ((_draw[i] + 1) * CYCLE_DURATION) +
                    COOLDOWN_DURATION <
                    block.timestamp,
                "early"
            );

            require(
                !winnerInfo.drawRewardsClaimed[_draw[i]][_user],
                "already claimed for the draw"
            );
            uint256 tierPercentage;
            //iterate over all the tier
            for (uint256 j = 0; j < 5; j++) {
                //if there is no winner
                if (winnerInfo.tierWinner[_draw[i]][j] == address(0)) {
                    tierPercentage = rewardInfo.prizeDistributionsPercentage[j];
                    //iterate over all the reward token
                    for (
                        uint256 k = 0;
                        k < rewardInfo.rewardTokens.length;
                        k++
                    ) {
                        uint256 totalAmount = rewardInfo
                            .totalRewardTokensForTheDraw[_draw[i]][
                                rewardInfo.rewardTokens[k]
                            ];

                        rewardInfo.extraRewards[_draw[i]][
                            rewardInfo.rewardTokens[k]
                        ] += (totalAmount * tierPercentage) / TOTAL_PERCENT;
                    }
                    winnerInfo.tierWinner[_draw[i]][j] = address(this);
                }
            }
            uint64 endingCycleTime;

            endingCycleTime = uint64(
                cycleStartTimestamp + ((_draw[i] + 1) * CYCLE_DURATION)
            );

            tierPercentage = rewardInfo.prizeDistributionsPercentage[5];

            uint256 balanceOfUser = IStakingPool(stakingPool).getBalanceAt(
                _user,
                endingCycleTime
            );
            uint256 totalSupply = IStakingPool(stakingPool).getTotalSupplyAt(
                endingCycleTime
            );

            if (totalSupply > 0) {
                winnerInfo.drawRewardsClaimed[_draw[i]][_user] = true;

                for (uint256 k = 0; k < rewardInfo.rewardTokens.length; k++) {
                    uint256 totalAmount = rewardInfo
                        .totalRewardTokensForTheDraw[_draw[i]][
                            rewardInfo.rewardTokens[k]
                        ];

                    uint256 totalClaimable = rewardInfo.extraRewards[_draw[i]][
                        rewardInfo.rewardTokens[k]
                    ] + ((totalAmount * tierPercentage) / TOTAL_PERCENT);

                    uint256 transferAmount = (totalClaimable * balanceOfUser) /
                        totalSupply;
                    totalPrizesClaimable[k] += transferAmount;
                    if (transferAmount > 0) {
                        emit PrizesClaimed(
                            _draw[i],
                            _user,
                            rewardInfo.rewardTokens[k],
                            transferAmount
                        );
                    }
                }
            }
        }
        for (uint256 k = 0; k < rewardInfo.rewardTokens.length; k++) {
            if (totalPrizesClaimable[k] > 0) {
                if (rewardInfo.rewardTokens[k] == WPLS_ADDRESS) {
                    IWETH(WPLS_ADDRESS).withdraw(totalPrizesClaimable[k]);
                    (bool success, ) = _user.call{
                        value: totalPrizesClaimable[k]
                    }("");
                    require(success, "PLS rewards transfer failed");
                } else {
                    IERC20(rewardInfo.rewardTokens[k]).safeTransfer(
                        _user,
                        totalPrizesClaimable[k]
                    );
                }
            }
        }
    }

    /**
     * @dev function to claim winning for user
     * @param _userAddress user address
     * @param _rangeIndexOfUser range index for which user has won
     * @param _alreadyWinners already winner addresses
     * @param _rangeIndexOfWinners indexes of winner ranges
     * @param _tier tier for which rewards needs to be claimed
     */
    function claimWinning(
        address _userAddress,
        uint256 _rangeIndexOfUser,
        address[] calldata _alreadyWinners,
        uint256[] calldata _rangeIndexOfWinners,
        uint256 _tier
    ) external nonReentrant {
        require(_tier < 5, "invalid tier");

        uint256 validDraw = drawCount - 1;
        require(drawCalled[validDraw], "draw not called");
        require(
            getCurrentCycleStartTimestamp() + COOLDOWN_DURATION >
                block.timestamp,
            "expired"
        );
        _setRandomNumbers(validDraw);
        
        require(
            !winnerInfo.isWinner[validDraw][_userAddress],
            "already a winner"
        );


        for (uint256 k = 0; k < _alreadyWinners.length; k++) {
            if (_alreadyWinners[k] == address(0)) {
                continue;
            }
            require(
                winnerInfo.isWinner[validDraw][_alreadyWinners[k]],
                "not a winner"
            );
        }

        require(
            _alreadyWinners.length == _rangeIndexOfWinners.length,
            "not valid lengths"
        );

        require(
            winnerInfo.tierWinner[validDraw][_tier] == address(0),
            "tier already won"
        );

        require(_rangeIndexOfWinners.length < 5, "exceeding limit");

        uint256 i = 0;
        i = _tier * 5;
        uint256 winningIndex = randomNumber[i] %
            ticketInfo.lastDrawEligibleCount;
        i++;

        //Check if winning index is falling into already winner index /Empty Index
        //if yes then recalculate winning index
        if (_alreadyWinners.length > 0) {
            for (uint j = 0; j < _alreadyWinners.length; j++) {
                if (i >= ((_tier + 1) * 5)) {
                    break;
                }
                Ranges memory m;
                if (winningIndex != 0) {
                    if (_alreadyWinners[j] == address(0)) {
                        m = emptyRanges[_rangeIndexOfWinners[j]];
                    } else {
                        m = userRanges[_alreadyWinners[j]][
                            _rangeIndexOfWinners[j]
                        ];
                    }
                }

                if (
                    winningIndex == 0 ||
                    (m.start <= winningIndex && winningIndex <= m.end)
                ) {
                    winningIndex =
                        randomNumber[i] %
                        ticketInfo.lastDrawEligibleCount;
                } else {
                    break;
                }
                i++;
            }
        }

        Ranges memory range = userRanges[_userAddress][_rangeIndexOfUser];
        if (range.start <= winningIndex && range.end >= winningIndex) {
            winnerInfo.isWinner[validDraw][_userAddress] = true;
            winnerInfo.tierWinner[validDraw][_tier] = _userAddress;
            uint256 tierPercentage = rewardInfo.prizeDistributionsPercentage[
                _tier
            ];
            for (i = 0; i < rewardInfo.rewardTokens.length; i++) {
                uint256 transferAmount = (rewardInfo
                    .totalRewardTokensForTheDraw[validDraw][
                        rewardInfo.rewardTokens[i]
                    ] * tierPercentage) / TOTAL_PERCENT;

                if (transferAmount > 0) {
                    if (rewardInfo.rewardTokens[i] == WPLS_ADDRESS) {
                        IWETH(WPLS_ADDRESS).withdraw(transferAmount);
                        (bool success, ) = _userAddress.call{
                            value: transferAmount
                        }("");
                        require(success, "PLS rewards transfer failed");
                    } else {
                        IERC20(rewardInfo.rewardTokens[i]).safeTransfer(
                            _userAddress,
                            transferAmount
                        );
                    }

                    emit PrizesClaimed(
                        validDraw,
                        _userAddress,
                        rewardInfo.rewardTokens[i],
                        transferAmount
                    );
                }
            }

            emit WinnerDeclared(validDraw, _tier, _userAddress);
        }
    }

    /**
     * @dev remove zero empty ranges
     * @param _emptyArray  empty array index
     */
    function removeZerosFromEmptyRanges(uint[] calldata _emptyArray) external {
        for (uint256 i = 0; i < _emptyArray.length; i++) {
            _reArrangeEmptyArray(_emptyArray[i]);
        }
    }

    /**
     * @dev function to shuffle slots and get random numbers
     * @param _slots indexes to fill in
     */
    function drawRandomNumber(uint256[] calldata _slots) external {
        require(getCurrentCycleEndingTimestamp() < block.timestamp, "early");
        require(rewardInfo.rewardsAdded[drawCount], "rewards not added");

        _handleShuffle(_slots);
        IRandomNumber(randomNumberAddress).requestRandomWords();

        //currently for testing purpose we are taking random number as input
        //otherwise chainlink will be used
        ticketInfo.lastDrawEligibleCount = ticketInfo.totalEligibleForThisDraw;
        ticketInfo.totalEligibleForThisDraw = ticketInfo.totalTicketNumber;
        drawCalled[drawCount] = true;
        drawCount++;
    }

    /**
     * @dev function to add reward tokens
     * @param _rewardToken reward token address
     */
    function addRewardToken(address _rewardToken) external onlyOwner {
        require(
            !rewardInfo.isRewardTokenSupported[_rewardToken],
            "reward token already supported"
        );
        rewardInfo.rewardTokens.push(_rewardToken);
        rewardInfo.isRewardTokenSupported[_rewardToken] = true;
    }

    /**
     * @dev function to add prizes
     * @param _token reward token address
     * @param _amount amount of token to be added
     */
    function addPrizes(address _token, uint256 _amount) external {
        require(
            rewardInfo.isRewardTokenSupported[_token],
            "reward token not supported"
        );
        rewardInfo.totalRewardTokensForTheDraw[drawCount][_token] += _amount;
        rewardInfo.rewardsAdded[drawCount] = true;
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        emit RewardAdded(drawCount, _token, _amount);
    }

    /**
     * @dev Used to get empty ranges
     * @return _ranges all the empty ranges
     */
    function getEmptyRanges(
        uint256 _startingIndex
    ) external view returns (Ranges[] memory _ranges) {
        uint256 _endingIndex = _startingIndex + 50;
        uint256 length;

        if (emptyRanges.length < _endingIndex) {
            _endingIndex = emptyRanges.length;
        }

        length = _endingIndex - _startingIndex;

        _ranges = new Ranges[](length);

        uint256 j = 0;

        for (uint i = _startingIndex; i < _endingIndex; i++) {
            _ranges[j] = emptyRanges[i];
            j++;
        }
    }

    /**
     * @dev return number of total empty ranges
     * @return  _length number of total empty ranges
     */
    function totalEmptyRanges() external view returns (uint256 _length) {
        return emptyRanges.length;
    }

    /**
     * @dev return detail of the empty range
     * @param _index index of empty ranges array
     * @return  _ranges detail of the range
     */
    function getEmptyRangeDetail(
        uint256 _index
    ) external view returns (Ranges memory _ranges) {
        return emptyRanges[_index];
    }

    /**
     * @dev to get detials of the range
     * @param _index range index
     * @return _rangeInfo range information
     */
    function getDetailsFromEndingRange(
        uint256 _index
    ) external view returns (RangeInfo memory _rangeInfo) {
        return endingRangeToUser[_index];
    }

    /**
     * @dev to get total ranges of the user
     * @param _user user address
     * @return _length total number of user ranges
     */
    function totalUserRanges(
        address _user
    ) external view returns (uint256 _length) {
        return userRanges[_user].length;
    }

    /**
     * @dev to fetch range detial of any user
     * @param _user user address
     * @param _index  index of the user ranges
     * @return _range range information
     */
    function getRangeDetails(
        address _user,
        uint256 _index
    ) external view returns (Ranges memory _range) {
        return userRanges[_user][_index];
    }

    /**
     * @dev get draw numbers for the last draw
     * @return _randomNumbers all the random numbers
     */
    function getLastDrawRandomNumbers()
        external
        view
        returns (uint256[] memory _randomNumbers)
    {
        return randomNumber;
    }

    /**
     * @dev to fetch reward tokens
     * @return _totalRewardToken total reward Tokens
     */
    function getRewardTokensCount()
        external
        view
        returns (uint256 _totalRewardToken)
    {
        return rewardInfo.rewardTokens.length;
    }

    /**
     * @dev returns how many each token reward amount is claimable
     * @param _draw draw for which we need to calculate claimable prizes
     * @param _user user address for which we need to calculate
     * @return _amount amount of reward tokens
     */
    function getTotalClaimablePrizes(
        uint[] calldata _draw,
        address _user
    ) external view returns (uint256[] memory _amount) {
        _amount = new uint256[](rewardInfo.rewardTokens.length);

        for (uint256 i = 0; i < _draw.length; i++) {
            uint256 tierPercentage;

            uint64 endingCycleTime;
            uint256[] memory extraAmounts = new uint256[](
                rewardInfo.rewardTokens.length
            );

            endingCycleTime = uint64(
                cycleStartTimestamp + ((_draw[i] + 1) * CYCLE_DURATION)
            );

            //iterate over all the tier
            for (uint256 j = 0; j < 5; j++) {
                //if there is no winner
                if (winnerInfo.tierWinner[_draw[i]][j] == address(0)) {
                    tierPercentage = rewardInfo.prizeDistributionsPercentage[j];
                    //iterate over all the reward token
                    for (
                        uint256 k = 0;
                        k < rewardInfo.rewardTokens.length;
                        k++
                    ) {
                        uint256 totalAmount = rewardInfo
                            .totalRewardTokensForTheDraw[_draw[i]][
                                rewardInfo.rewardTokens[k]
                            ];

                        extraAmounts[k] +=
                            (totalAmount * tierPercentage) /
                            TOTAL_PERCENT;
                    }
                }
            }

            tierPercentage = rewardInfo.prizeDistributionsPercentage[5];

            uint256 balanceOfUser = IStakingPool(stakingPool).getBalanceAt(
                _user,
                endingCycleTime
            );
            uint256 totalSupply = IStakingPool(stakingPool).getTotalSupplyAt(
                endingCycleTime
            );

            if (totalSupply > 0) {
                for (uint256 k = 0; k < rewardInfo.rewardTokens.length; k++) {
                    uint256 totalAmount = rewardInfo
                        .totalRewardTokensForTheDraw[_draw[i]][
                            rewardInfo.rewardTokens[k]
                        ];

                    uint256 totalClaimable = extraAmounts[k] +
                        rewardInfo.extraRewards[_draw[i]][
                            rewardInfo.rewardTokens[k]
                        ] +
                        ((totalAmount * tierPercentage) / TOTAL_PERCENT);

                    uint256 transferAmount = (totalClaimable * balanceOfUser) /
                        totalSupply;

                    _amount[k] += transferAmount;
                }
            }
        }
    }

    /**
     * @dev handle eligible slots/tickets
     * @param _user User address
     * @param _amount amount of tickets to be minted
     * @param _slots empty slots to fill in
     */
    function _handleEligbleTickets(
        address _user,
        uint256 _amount,
        uint256[] calldata _slots
    )
        private
        returns (
            uint256[MAX_DELETED_EMPTY_INDEX] memory _deletedEmptyIndex,
            uint256 _pointer
        )
    {
        //If no slot for filling is given then add to the last
        if (_slots.length == 0) {
            _addNewSlots(_user, _amount, true);
        } else {
            (_amount, _deletedEmptyIndex, _pointer) = _fillSlots(
                _user,
                _amount,
                _slots,
                true
            );

            //If after filling all the slots given  , any amount remains
            //then allocate last slot to user for the remaining
            if (_amount > 0) {
                _addNewSlots(_user, _amount, true);
            }
        }
    }

    /**
     * @dev handles non eligible slots/tickets
     * @param _user User address
     * @param _amount amount of tickets to be minted
     * @param _slots empty slots to fill in
     */
    function _handleNonEligbleTickets(
        address _user,
        uint256 _amount,
        uint256[] calldata _slots
    )
        private
        returns (
            uint256[MAX_DELETED_EMPTY_INDEX] memory _deletedEmptyIndex,
            uint256 _pointer
        )
    {
        //No slot provided
        if (_slots.length == 0) {
            _addNewSlots(_user, _amount, false);
        } else {
            (_amount, _deletedEmptyIndex, _pointer) = _fillSlots(
                _user,
                _amount,
                _slots,
                false
            );

            //If after filling all the slots given  , any amount remains
            //then allocate last slot to user for the remaining
            if (_amount > 0) {
                _addNewSlots(_user, _amount, false);
            }
        }
    }

    /**
     * @dev adds new slot in the last
     * @param _user user address
     * @param _amount amount to be minted
     * @param _eligible true if eligible for this draw otherwise false
     */
    function _addNewSlots(
        address _user,
        uint256 _amount,
        bool _eligible
    ) private {
        Ranges memory newRange;
        newRange.start = ticketInfo.totalTicketNumber + 1;
        newRange.end = ticketInfo.totalTicketNumber + _amount;
        ticketInfo.totalTicketNumber = newRange.end;
        if (_eligible) {
            ticketInfo.totalEligibleForThisDraw = ticketInfo.totalTicketNumber;
        }
        userRanges[_user].push(newRange);
        RangeInfo memory rangeInfo = RangeInfo({
            userAddress: _user,
            start: newRange.start,
            indexInUserRanges: userRanges[_user].length - 1
        });
        endingRangeToUser[newRange.end] = rangeInfo;
    }

    /**
     * @dev fills empty  slots
     * @param _user user address
     * @param _amount amount to be minted
     * @param _slots slots indexes to be filled
     * @param _eligible true if eligible for this draw otherwise false
     */
    function _fillSlots(
        address _user,
        uint256 _amount,
        uint256[] memory _slots,
        bool _eligible
    )
        private
        returns (
            uint256 _remainingAmount,
            uint256[MAX_DELETED_EMPTY_INDEX] memory _deletedEmptyRangesIndex,
            uint256 _pointer
        )
    {
        Ranges memory newRange;
        //traverse to all the slots given
        for (uint256 i = 0; i < _slots.length; i++) {
            if (_amount == 0) {
                break;
            }
            Ranges storage emptyRange = emptyRanges[_slots[i]];
            if (emptyRange.start == 0 && emptyRange.end == 0) {
                continue;
            }

            if (!_eligible) {
                //can't fill eligible empty slots with non eligible stakes
                require(
                    emptyRange.start > ticketInfo.totalEligibleForThisDraw,
                    "can not fill eligible slots"
                );
            }
            {
                uint256 emptyRangeLength = emptyRange.end -
                    emptyRange.start +
                    1;

                //if slot given is less than amount
                //fill the empty slot and try to mint tickets of remaining amount in the next slot or in the last
                if (_amount >= emptyRangeLength) {
                    _amount = _amount - emptyRangeLength;
                    newRange.start = emptyRange.start;
                    newRange.end = emptyRange.end;
                    delete emptyRangesIndex[emptyRange.end];
                    delete emptyRanges[_slots[i]];
                    if (_pointer < MAX_DELETED_EMPTY_INDEX) {
                        _deletedEmptyRangesIndex[_pointer] = _slots[i];
                        ++_pointer;
                    }
                } else {
                    //if empty slot is big
                    newRange.start = emptyRange.start;
                    newRange.end = emptyRange.start + _amount - 1;
                    emptyRange.start = emptyRange.start + _amount;
                    _amount = 0;
                }
            }
            userRanges[_user].push(newRange);
            RangeInfo memory rangeInfo = RangeInfo({
                userAddress: _user,
                start: newRange.start,
                indexInUserRanges: userRanges[_user].length - 1
            });
            endingRangeToUser[newRange.end] = rangeInfo;
        }

        return (_amount, _deletedEmptyRangesIndex, _pointer);
    }

    /**
     * @dev shuffles slots.Fills empty given slots with the last filled slots
     * @param _slots empty slot indexes to fill in
     */
    function _handleShuffle(uint256[] calldata _slots) private {
        uint256[MAX_DELETED_EMPTY_INDEX] memory deletedEmptyIndex;
        uint256[5] memory returnedDeletedEmptyIndexes;
        uint256 pointer = 0;
        uint256 returnedPointer = 0;

        //Fills all the slots one by one
        for (uint i = 0; i < _slots.length; i++) {
            Ranges memory lastEmptyRange = emptyRanges[_slots[i]];

            if (
                lastEmptyRange.start <= ticketInfo.totalEligibleForThisDraw &&
                lastEmptyRange.end <= ticketInfo.totalEligibleForThisDraw
            ) {
                (
                    returnedDeletedEmptyIndexes,
                    returnedPointer
                ) = _internalShuffleHandler(_slots[i]);
            } else {
                (
                    returnedDeletedEmptyIndexes,
                    returnedPointer
                ) = _internalNonEligibleShuffleHandler(_slots[i]);
            }

            for (uint256 j = 0; j < returnedPointer; j++) {
                if (pointer >= MAX_DELETED_EMPTY_INDEX) {
                    break;
                }
                deletedEmptyIndex[pointer] = returnedDeletedEmptyIndexes[j];
                ++pointer;
            }
        }

        for (uint256 i = 0; i < pointer; i++) {
            _reArrangeEmptyArray(deletedEmptyIndex[i]);
        }
    }

    /**
     * @dev shuffles slot.Fills empty given slots with the last filled slots
     * works for eligible slots shuffling
     * @param _index index of the empty slot
     */
    function _internalShuffleHandler(
        uint _index
    )
        private
        returns (uint256[5] memory deletedEmptyRangesIndex, uint256 pointer)
    {
        Ranges storage lastEmptyRange = emptyRanges[_index];
        if (lastEmptyRange.start == 0 && lastEmptyRange.end == 0) {
            return (deletedEmptyRangesIndex, pointer);
        }

        uint256 emptyRangeLength = lastEmptyRange.end -
            lastEmptyRange.start +
            1;

        uint256 i = 0;

        //Looping 3 times to fill big empty slots
        //3 times means 3 different slot from the last slots
        //If after that also it is not filled then return
        while (i < 3 && emptyRangeLength != 0) {
            i++;
            RangeInfo memory rInfo = endingRangeToUser[
                ticketInfo.totalEligibleForThisDraw
            ];

            bool isOnEmptySlot = ticketInfo.totalEligibleForThisDraw ==
                lastEmptyRange.end;

            if (rInfo.userAddress == address(0) || isOnEmptySlot) {
                uint256 index = emptyRangesIndex[
                    ticketInfo.totalEligibleForThisDraw
                ];
                Ranges memory range = emptyRanges[index];
                uint256 totalEmptyRangeLength = range.end - range.start + 1;
                if (
                    ticketInfo.totalTicketNumber ==
                    ticketInfo.totalEligibleForThisDraw
                ) {
                    ticketInfo.totalTicketNumber =
                        ticketInfo.totalTicketNumber -
                        totalEmptyRangeLength;
                    delete emptyRangesIndex[range.end];
                    delete emptyRanges[index];
                    if (pointer < 5) {
                        deletedEmptyRangesIndex[pointer] = index;
                        pointer++;
                    }
                }
                ticketInfo.totalEligibleForThisDraw =
                    ticketInfo.totalEligibleForThisDraw -
                    totalEmptyRangeLength;

                if (isOnEmptySlot) {
                    break;
                } else {
                    continue;
                }
            }

            uint256 lastRangeLength = ticketInfo.totalEligibleForThisDraw -
                rInfo.start +
                1;

            delete endingRangeToUser[ticketInfo.totalEligibleForThisDraw];

            //If last range length is greater than empty slot that need to be filled
            if (lastRangeLength >= emptyRangeLength) {
                if (
                    ticketInfo.totalTicketNumber ==
                    ticketInfo.totalEligibleForThisDraw
                ) {
                    ticketInfo.totalTicketNumber =
                        ticketInfo.totalTicketNumber -
                        emptyRangeLength;
                } else {
                    Ranges memory m = Ranges({
                        start: ticketInfo.totalEligibleForThisDraw -
                            emptyRangeLength +
                            1,
                        end: ticketInfo.totalEligibleForThisDraw
                    });
                    emptyRanges.push(m);
                    emptyRangesIndex[m.end] = emptyRanges.length - 1;
                }
                ticketInfo.totalEligibleForThisDraw =
                    ticketInfo.totalEligibleForThisDraw -
                    emptyRangeLength;

                bool equal = lastRangeLength == emptyRangeLength;

                _handleSmallEmptySlot(rInfo, lastEmptyRange, _index, equal);

                if (pointer < 5) {
                    deletedEmptyRangesIndex[pointer] = _index;
                    pointer++;
                }

                break;
            } else {
                //If last range length is less than empty slot that need to be filled
                if (
                    ticketInfo.totalTicketNumber ==
                    ticketInfo.totalEligibleForThisDraw
                ) {
                    ticketInfo.totalTicketNumber =
                        ticketInfo.totalTicketNumber -
                        lastRangeLength;
                } else {
                    Ranges memory m = Ranges({
                        start: ticketInfo.totalEligibleForThisDraw -
                            lastRangeLength +
                            1,
                        end: ticketInfo.totalEligibleForThisDraw
                    });
                    emptyRanges.push(m);
                    emptyRangesIndex[m.end] = emptyRanges.length - 1;
                }
                ticketInfo.totalEligibleForThisDraw =
                    ticketInfo.totalEligibleForThisDraw -
                    lastRangeLength;

                emptyRangeLength = _handleBigEmptySlot(
                    rInfo,
                    lastEmptyRange,
                    lastRangeLength,
                    emptyRangeLength
                );
            }
        }
    }

    /**
     * @dev shuffles slot.Fills empty given slots with the last filled slots
     * works for non eligible slots shuffling
     * @param _index index of the empty slot
     */
    function _internalNonEligibleShuffleHandler(
        uint256 _index
    )
        private
        returns (uint256[5] memory deletedEmptyRangesIndex, uint256 pointer)
    {
        Ranges storage lastEmptyRange = emptyRanges[_index];
        if (lastEmptyRange.start == 0 && lastEmptyRange.end == 0) {
            return (deletedEmptyRangesIndex, pointer);
        }

        require(
            ticketInfo.totalEligibleForThisDraw < lastEmptyRange.start,
            "can not shuffle eligible slots"
        );

        uint256 emptyRangeLength = lastEmptyRange.end -
            lastEmptyRange.start +
            1;

        uint256 i = 0;

        //Looping 3 times to fill big empty slots
        //3 times means 3 different slot from the last slots
        //If after that also it is not filled then return
        while (i < 3 && emptyRangeLength != 0) {
            i++;
            RangeInfo memory rInfo = endingRangeToUser[
                ticketInfo.totalTicketNumber
            ];

            bool isOnEmptySlot = ticketInfo.totalTicketNumber ==
                lastEmptyRange.end;

            if (rInfo.userAddress == address(0) || isOnEmptySlot) {
                uint256 index = emptyRangesIndex[ticketInfo.totalTicketNumber];
                Ranges memory range = emptyRanges[index];
                uint256 totalEmptyRangeLength = range.end - range.start + 1;
                delete emptyRangesIndex[range.end];
                delete emptyRanges[index];
                if (pointer < 5) {
                    deletedEmptyRangesIndex[pointer] = index;
                    pointer++;
                }
                ticketInfo.totalTicketNumber =
                    ticketInfo.totalTicketNumber -
                    totalEmptyRangeLength;
                if (isOnEmptySlot) {
                    break;
                } else {
                    continue;
                }
            }

            uint256 lastRangeLength = ticketInfo.totalTicketNumber -
                rInfo.start +
                1;

            delete endingRangeToUser[ticketInfo.totalTicketNumber];

            //If last range length is greater than empty slot that need to be filled
            if (lastRangeLength >= emptyRangeLength) {
                ticketInfo.totalTicketNumber =
                    ticketInfo.totalTicketNumber -
                    emptyRangeLength;
                bool equal = (lastRangeLength == emptyRangeLength);
                _handleSmallEmptySlot(rInfo, lastEmptyRange, _index, equal);
                if (pointer < 5) {
                    deletedEmptyRangesIndex[pointer] = _index;
                    pointer++;
                }

                break;
            } else {
                //If last range length is less than empty slot that need to be filled

                ticketInfo.totalTicketNumber =
                    ticketInfo.totalTicketNumber -
                    lastRangeLength;

                emptyRangeLength = _handleBigEmptySlot(
                    rInfo,
                    lastEmptyRange,
                    lastRangeLength,
                    emptyRangeLength
                );
            }
        }
    }

    /**
     * @dev if empty slot is smaller than the last slot
     * @param _rInfo range info
     * @param _lastEmptyRange last empty range
     * @param _index index in the empty array
     * @param _equal true if last slot and empty slot  are equal otherwise false
     */
    function _handleSmallEmptySlot(
        RangeInfo memory _rInfo,
        Ranges storage _lastEmptyRange,
        uint256 _index,
        bool _equal
    ) private {
        Ranges storage currentRange = userRanges[_rInfo.userAddress][
            _rInfo.indexInUserRanges
        ];

        uint256 newIndex;
        //if empty slot range is equal to filling slot then pop slot from user and push empty slot to user
        //otherwise update ranges
        if (_equal) {
            currentRange.start = _lastEmptyRange.start;
            currentRange.end = _lastEmptyRange.end;
            newIndex = _rInfo.indexInUserRanges;
        } else {
            currentRange.end =
                currentRange.end -
                (_lastEmptyRange.end - _lastEmptyRange.start + 1);

            userRanges[_rInfo.userAddress].push(_lastEmptyRange);
            newIndex = userRanges[_rInfo.userAddress].length - 1;
            RangeInfo memory rangeInfo = RangeInfo({
                userAddress: _rInfo.userAddress,
                start: _rInfo.start,
                indexInUserRanges: _rInfo.indexInUserRanges
            });
            endingRangeToUser[currentRange.end] = rangeInfo;
        }

        RangeInfo memory updatedRangeInfo = RangeInfo({
            userAddress: _rInfo.userAddress,
            start: _lastEmptyRange.start,
            indexInUserRanges: newIndex
        });
        endingRangeToUser[_lastEmptyRange.end] = updatedRangeInfo;

        delete emptyRangesIndex[emptyRanges[_index].end];
        delete emptyRanges[_index];
    }

    /**
     * @dev if empty slot is bigger than the last slot
     * @param _rInfo range info
     * @param _lastEmptyRange last empty range
     * @param _lastRangeLength last range length
     * @param _emptyRangeLength empty range length
     */
    function _handleBigEmptySlot(
        RangeInfo memory _rInfo,
        Ranges storage _lastEmptyRange,
        uint256 _lastRangeLength,
        uint256 _emptyRangeLength
    ) private returns (uint256 _remainingEmptyLength) {
        Ranges storage updatedRange = userRanges[_rInfo.userAddress][
            _rInfo.indexInUserRanges
        ];
        updatedRange.start = _lastEmptyRange.start;
        updatedRange.end = _lastEmptyRange.start + _lastRangeLength - 1;

        _lastEmptyRange.start = updatedRange.end + 1;

        RangeInfo memory rangeInfo = RangeInfo({
            userAddress: _rInfo.userAddress,
            start: updatedRange.start,
            indexInUserRanges: _rInfo.indexInUserRanges
        });
        endingRangeToUser[updatedRange.end] = rangeInfo;

        return (_emptyRangeLength - _lastRangeLength);
    }

    function _setRandomNumbers(uint256 _drawCount) private {
        if (!isRandomNumberSet[_drawCount]) {
            bool fulfilled;
            uint256 requestID = IRandomNumber(randomNumberAddress)
                .lastRequestId();
            (fulfilled, randomNumber) = IRandomNumber(randomNumberAddress)
                .getRequestStatus(requestID);
            require(fulfilled, "random number not fulfilled");
            isRandomNumberSet[_drawCount] = true;
        }
    }

    /**
     * @dev rearrange empty array by removing zero indexes
     * @param _index  array indexes to be removed
     */
    function _reArrangeEmptyArray(uint256 _index) private {
        if (emptyRanges.length == 0 || _index > emptyRanges.length - 1) {
            return;
        }

        Ranges memory emptyRange = emptyRanges[_index];
        if (emptyRange.start != 0 && emptyRange.end != 0) {
            return;
        }

        if (emptyRanges.length - 1 == _index) {
            // deleted last empty range
            emptyRanges.pop();
            return;
        }

        uint256 counter = 0;
        while (counter < 5) {
            //saved the data in the memory
            Ranges memory lastRange = emptyRanges[emptyRanges.length - 1];

            // deleted last empty range
            emptyRanges.pop();

            //if last index is not zero , replace the index with last range
            if (lastRange.start != 0 && lastRange.end != 0) {
                emptyRanges[_index] = lastRange;
                emptyRangesIndex[lastRange.end] = _index;
                break;
            }

            if (emptyRanges.length == 0 || _index > emptyRanges.length - 1) {
                break;
            }

            ++counter;
        }
    }

    /**
     * @dev to get current draw start time
     * @return _startTime start time of the current draw
     */
    function getCurrentCycleStartTimestamp()
        public
        view
        returns (uint256 _startTime)
    {
        return cycleStartTimestamp + (drawCount * CYCLE_DURATION);
    }

    /**
     * @dev to get current draw end time
     * @return _endTime end time of the current draw
     */
    function getCurrentCycleEndingTimestamp()
        public
        view
        returns (uint256 _endTime)
    {
        return getCurrentCycleStartTimestamp() + CYCLE_DURATION;
    }

    /**
     * @dev to get total ticket number
     * @return the totalTicketNumber
     */
    function totalTicketNumber() external view returns (uint256) {
        return ticketInfo.totalTicketNumber;
    }

    /**
     * @dev to get totalEligibleForThisDraw
     * @return the totalEligibleForThisDraw
     */
    function totalEligibleForThisDraw() external view returns (uint256) {
        return ticketInfo.totalEligibleForThisDraw;
    }

    /**
     * @dev to get lastDrawEligibleCount
     * @return the lastDrawEligibleCount
     */
    function lastDrawEligibleCount() external view returns (uint256) {
        return ticketInfo.lastDrawEligibleCount;
    }

    /**
     * @dev to get prizeDistributionsPercentage
     * @param _drawNumber the draw number
     * @param _tier the tier
     * @return the prizeDistributionsPercentage for the tier
     */
    function tierWinner(
        uint256 _drawNumber,
        uint256 _tier
    ) external view returns (address) {
        return winnerInfo.tierWinner[_drawNumber][_tier];
    }

    /**
     * @dev to get drawRewardsClaimed
     * @param _drawNumber the draw number
     * @param _user the address of user
     * @return the if rewards are claimed or not
     */
    function drawRewardsClaimed(
        uint256 _drawNumber,
        address _user
    ) external view returns (bool) {
        return winnerInfo.drawRewardsClaimed[_drawNumber][_user];
    }

    /**
     * @dev to get if the user is Winner or not
     * @param _drawCount the draw count
     * @param _user address of the reward token
     * @return bool true or false
     */
    function isWinner(
        uint256 _drawCount,
        address _user
    ) external view returns (bool) {
        return winnerInfo.isWinner[_drawCount][_user];
    }

    /**
     * @dev to get prizeDistributionsPercentage
     * @param _index the tier index
     * @return the prizeDistributionsPercentage for the tier
     */
    function prizeDistributionsPercentage(
        uint256 _index
    ) external view returns (uint256) {
        return rewardInfo.prizeDistributionsPercentage[_index];
    }

    /**
     * @dev to get rewardTokens
     * @param _index the index
     * @return the rewardToken
     */
    function rewardTokens(uint256 _index) external view returns (address) {
        return rewardInfo.rewardTokens[_index];
    }

    /**
     * @dev to get if the RewardToken is Supported or not
     * @param _rewardToken address of the reward token
     * @return bool true or false
     */
    function isRewardTokenSupported(
        address _rewardToken
    ) external view returns (bool) {
        return rewardInfo.isRewardTokenSupported[_rewardToken];
    }

    /**
     * @dev to get total RewardTokens For The Draw
     * @param _drawCount the draw count
     * @param _rewardToken the reward token address
     * @return the totalRewardTokensForTheDraw
     */
    function totalRewardTokensForTheDraw(
        uint256 _drawCount,
        address _rewardToken
    ) external view returns (uint256) {
        return rewardInfo.totalRewardTokensForTheDraw[_drawCount][_rewardToken];
    }
}
