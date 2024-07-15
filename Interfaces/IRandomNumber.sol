//SPDX-License-Identifier: None
pragma solidity 0.8.17;

interface IRandomNumber {
    function lastRequestId() external returns (uint256);

    function requestRandomWords() external returns (uint256 requestId);

    function getRequestStatus(
        uint256 _requestId
    ) external view returns (bool fulfilled, uint256[] memory randomWords);
}
