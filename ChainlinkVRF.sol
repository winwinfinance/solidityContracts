//SPDX-License-Identifier: None
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Interfaces/IRandomNumber.sol";

/**
 * Find information on LINK Token Contracts and get the latest ETH and LINK faucets here: https://docs.chain.link/docs/link-token-contracts/
 */

contract VRFv2Consumer is VRFConsumerBaseV2, Ownable, IRandomNumber {
    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(uint256 requestId, uint256[] randomWords);

    struct RequestStatus {
        bool fulfilled; // whether the request has been successfully fulfilled
        bool exists; // whether a requestId exists
        uint256[] randomWords;
    }
    mapping(uint256 => RequestStatus)
        public s_requests; /* requestId --> requestStatus */
    VRFCoordinatorV2Interface COORDINATOR;

    // Your subscription ID.
    uint64 s_subscriptionId;

    // past requests Id.
    uint256[] public requestIds;
    uint256 public lastRequestId;

    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/docs/vrf/v2/subscription/supported-networks/#configurations
    bytes32 keyHash =
        0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f;

    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Storing each word costs about 20,000 gas,
    // so 100,000 is a safe default for this example contract. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 callbackGasLimit = 1000000;

    // The default is 3, but you can set this higher.
    uint16 requestConfirmations = 3;

    // retrieve 25 random values in one request.
    // Cannot exceed VRFCoordinatorV2.MAX_NUM_WORDS.
    uint32 numWords = 25;

    mapping(address => bool) public isAuthorized;

    modifier onlyAuthorized() {
        require(isAuthorized[msg.sender], "not authorized");
        _;
    }

    /**
     * HARDCODED FOR Mumbai
     * COORDINATOR: 0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed
     */
    constructor(
        uint64 subscriptionId,
        address authorizedAddress
    ) VRFConsumerBaseV2(0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed) {
        require(authorizedAddress != address(0), "Can't be zero address");
        COORDINATOR = VRFCoordinatorV2Interface(
            0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed
        );
        s_subscriptionId = subscriptionId;
        isAuthorized[authorizedAddress] = true;
    }

    /**
     * @dev Updates the authorization status for an address.
     * @param _address The address for which the authorization status will be updated.
     * @param _authorized The new authorization status for the address.
     * @notice Only the contract owner can call this function.
     * @dev This function allows the contract owner to update the authorization status
     * for a specific address. The authorization status determines whether the address
     * is allowed to request random words using the requestRandomWords function.
     * The _address parameter cannot be the zero address.
     */
    function UpdateAuthorization(
        address _address,
        bool _authorized
    ) external onlyOwner {
        require(_address != address(0), "Can't be zero address");
        isAuthorized[_address] = _authorized;
    }
    /**
     * @dev Updates the subscription ID used for funding the requests.
     * @param _newSubscriptionId The new subscription ID.
     * @notice Only the contract owner can call this function.
     * @dev This function allows the contract owner to update the subscription ID
     * used for funding the requests. By updating the subscription ID, the contract
     * can be associated with a different funding source for future requests.
     */
    function updateSubscriptionId(
        uint64 _newSubscriptionId
    ) external onlyOwner {
        s_subscriptionId = _newSubscriptionId;
    }

    // Assumes the subscription is funded sufficiently.
    /**
     * @dev Requests random words from the Chainlink VRF service.
     * @return requestId The ID of the requested random words.
     * @notice This function can only be called by authorized addresses.
     * @dev This function sends a request to the VRFCoordinatorV2 contract to generate
     * random words using Chainlink's VRF service. The request includes the key hash,
     * subscription ID, request confirmations, callback gas limit, and the number of words
     * to request. If the request is successful, the request status is updated, and the
     * request ID is stored. The function emits a RequestSent event to notify listeners
     * about the new request. The function reverts if the subscription is not set and funded.
     */
    function requestRandomWords()
        external
        override
        onlyAuthorized
        returns (uint256 requestId)
    {
        // Will revert if subscription is not set and funded.
        requestId = COORDINATOR.requestRandomWords(
            keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );
        s_requests[requestId] = RequestStatus({
            randomWords: new uint256[](0),
            exists: true,
            fulfilled: false
        });
        requestIds.push(requestId);
        lastRequestId = requestId;
        emit RequestSent(requestId, numWords);
        return requestId;
    }

    /**
     * @dev Callback function called by the VRFCoordinatorV2 contract to fulfill a request.
     * @param _requestId The ID of the request being fulfilled.
     * @param _randomWords The array of random words generated for the request.
     * @notice This function is internal and can only be called by the contract itself.
     * @dev This function is called by the VRFCoordinatorV2 contract when a requested
     * random word generation is fulfilled. It updates the request status to mark it as fulfilled
     * and stores the generated random words. The function emits a RequestFulfilled event
     * to notify listeners about the fulfillment of the request.
     * @dev Note that this function can only be called internally within the contract.
     * External entities cannot invoke this function directly.
     */
    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        require(s_requests[_requestId].exists, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;
        emit RequestFulfilled(_requestId, _randomWords);
    }

    /**
     * @dev Retrieves the status of a specific request.
     * @param _requestId The ID of the request.
     * @return fulfilled Whether the request has been fulfilled.
     * @return randomWords The array of random words generated for the request.
     * @notice This function provides information about the status of a specific request.
     * @dev This function retrieves the request status, including whether the request has been
     * fulfilled and the array of random words generated for the request. It returns these values
     * as a tuple. The function reverts if the request ID does not exist.
     */
    function getRequestStatus(
        uint256 _requestId
    )
        external
        view
        override
        returns (bool fulfilled, uint256[] memory randomWords)
    {
        require(s_requests[_requestId].exists, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.fulfilled, request.randomWords);
    }
}
