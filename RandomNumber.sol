//SPDX-License-Identifier: None
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Interfaces/IRandomNumber.sol";

contract RandomNumber is Ownable, IRandomNumber {
    uint256 private _lastRequestId = 0;

    //Random numbers for previous draw
    //Total 25 random numbers 5 for each tier
    uint256[] public randomNumber;

    mapping(uint256 => bool) public isFulfilled;

    mapping(address => bool) public isAuthorized;

    modifier onlyAuthorized() {
        require(isAuthorized[msg.sender], "not authorized");
        _;
    }

    /**
     * @dev Contract constructor.
     * @param _authorized The array of authorized addresses.
     * @notice Initializes the contract by setting the authorized addresses.
     * The addresses provided in the `_authorized` array are granted permission
     * to perform authorized actions.
     * The `_authorized` array cannot contain zero addresses.
     */
    constructor(address[] memory _authorized) {
        for (uint256 i = 0; i < _authorized.length; i++) {
            require(_authorized[i]!=address(0), "Can't be zero address");
            isAuthorized[_authorized[i]] = true;
        }
    }

    /**
     * @dev Updates the authorization status for an address.
     * @param _address The address for which the authorization status will be updated.
     * @param _authorized The new authorization status for the address.
     * @notice Only the contract owner can call this function.
     * @dev This function allows the contract owner to update the authorization status
     * for a specific address. The authorization status determines whether the address
     * is allowed to perform authorized actions in the contract.
     * The `_address` parameter cannot be the zero address.
     */
    function UpdateAuthorization(
        address _address,
        bool _authorized
    ) external onlyOwner {
        require(_address!=address(0), "Can't be zero address");
        isAuthorized[_address] = _authorized;
    }

    /**
     * @dev Sets the random number array.
     * @param _randomNumber The array of random numbers to be set.
     * @notice Only authorized addresses can call this function.
     * @dev This function allows authorized addresses to set the array of random numbers.
     * The `randomNumber` array represents the random numbers for the previous draw.
     */
    function setRandomNumber(
        uint256[] calldata _randomNumber
    ) external onlyAuthorized {
        randomNumber = _randomNumber;
    }

    /**
     * @dev Requests random words.
     * @return requestId The ID of the requested random words.
     * @notice Only authorized addresses can call this function.
     * @dev This function allows authorized addresses to request random words.
     * It increments the `_lastRequestId` variable, marks the request as fulfilled,
     * and returns the request ID.
     */
    function requestRandomWords()
        external
        override
        onlyAuthorized
        returns (uint256 requestId)
    {
        ++_lastRequestId;
        isFulfilled[_lastRequestId] = true;
        return _lastRequestId;
    }

    /**
     * @dev Retrieves the status of a specific request.
     * @param _requestId The ID of the request.
     * @return fulfilled Whether the request has been fulfilled.
     * @return randomWords The array of random words associated with the request.
     * @notice This function provides information about the status of a specific request.
     * @dev This function retrieves the status of a specific request identified by the given `_requestId`.
     * It returns a tuple containing a boolean indicating whether the request has been fulfilled and
     * the array of random words associated with the request.
     */
    function getRequestStatus(
        uint256 _requestId
    )
        external
        view
        override
        returns (bool fulfilled, uint256[] memory randomWords)
    {
        return (isFulfilled[_requestId], randomNumber);
    }

    /**
     * @dev Retrieves the array of random numbers.
     * @return randomNumbers The array of random numbers.
     * @notice This function allows anyone to retrieve the array of random numbers.
     * @dev This function returns the array of random numbers representing the random numbers
     * for the previous draw.
     */
    function getRandomNumber() external view returns (uint256[] memory) {
        return randomNumber;
    }

    /**
     * @dev Retrieves the ID of the last request made.
     * @return requestId The ID of the last request made.
     * @notice This function allows anyone to retrieve the ID of the last request made.
     * @dev This function returns the ID of the last request made, which is stored in the
     * `_lastRequestId` variable.
     */
    function lastRequestId() external view override returns (uint256) {
        return _lastRequestId;
    }
}
