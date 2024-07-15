//SPDX-License-Identifier: None
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./Interfaces/IRandomNumber.sol";

contract RandomNumber is Ownable2Step, IRandomNumber {
    uint256 private _lastRequestId = 0;

    mapping(uint256 => HashStruct) private committedHash;

    struct HashStruct {
        bytes32[] hashes;
        uint256[] numbers;
        bool revealed;
    }

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
        // Cache the length to avoid reading it multiple times
        uint256 length = _authorized.length;
        for (uint256 i = 0; i < length; ++i) {
            require(_authorized[i] != address(0), "Can't be zero address");
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
        require(_address != address(0), "Can't be zero address");
        isAuthorized[_address] = _authorized;
    }

    /**
     * @dev Commits an array of hashes to a request ID.
     * @param _requestId The ID of the request.
     * @param _hashes The array of hashes to be committed.
     * @notice Only authorized addresses can call this function.
     * @dev This function stores the provided array of hashes in the committedHash mapping
     * under the specified request ID. It ensures that the hashes have not been set previously
     * and that exactly 25 hashes are provided.
     */
    function commitHash(
        uint256 _requestId,
        bytes32[] calldata _hashes
    ) external onlyAuthorized {
        HashStruct storage hashStruct = committedHash[_requestId];
        require(hashStruct.hashes.length == 0, "Hashes already set");
        require(_hashes.length == 25, "Hashes should be 25");
        hashStruct.hashes = _hashes;
        hashStruct.revealed = false;
    }

    /**
     * @dev Reveals the numbers corresponding to the committed hashes.
     * @param _requestId The ID of the request.
     * @param _numbers The array of numbers to be revealed.
     * @notice Anyone can call this function.
     * @dev This function checks the provided array of numbers against the committed hashes
     * and stores the numbers if they match. It ensures that the request ID is valid,
     * that the numbers have not been revealed previously, and that exactly 25 numbers are provided.
     */
    function revealHash(
        uint256 _requestId,
        uint256[] memory _numbers
    ) external {
        require(_lastRequestId >= _requestId, "no requests");
        require(_numbers.length == 25, "invalid length");
        HashStruct storage hashStruct = committedHash[_requestId];
        require(hashStruct.hashes.length > 0, "Invalid request id");
        require(!hashStruct.revealed, "hashes already revealed");
        for (uint256 i = 0; i < 25; ++i) {
            require(
                hashStruct.hashes[i] ==
                    keccak256(abi.encodePacked(_numbers[i])),
                "invalid numbers"
            );
        }
        hashStruct.numbers = _numbers;
        hashStruct.revealed = true;
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
        HashStruct memory hashStruct = committedHash[_lastRequestId];
        require(hashStruct.hashes.length > 0, "hashes not yet set");
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
        require(_lastRequestId >= _requestId, "no requests");
        HashStruct memory hashStruct = committedHash[_requestId];
        return (hashStruct.revealed, hashStruct.numbers);
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

    function getCommittedHash(
        uint256 _requestId
    ) external view returns (HashStruct memory _hashStruct) {
        return committedHash[_requestId];
    }
}
