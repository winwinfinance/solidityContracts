// SPDX-License-Identifier: None

pragma solidity 0.8.17;

interface IWETH {
    function deposit() external payable;

    function balanceOf(address account) external view returns (uint256);

    function withdraw(uint wad) external;

    function approve(address guy, uint wad) external returns (bool);

    function transfer(address dst, uint wad) external returns (bool);

    function transferFrom(
        address src,
        address dst,
        uint wad
    ) external returns (bool);
}
