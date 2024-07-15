//SPDX-License-Identifier: None
pragma solidity 0.8.17;

interface IPrizePool {
    function addPrizes(address _token, uint256 _amount) external;

    function getTickets(
        address _user,
        uint256 _amount,
        uint256[] calldata _slots,
        uint256[] calldata _shuffleSlots
    ) external;

    function burnTickets(address _user, uint256 _amount) external;
}
