// SPDX-License-Identifier: None

pragma solidity 0.8.17;

interface IStabilityPool {
    // --- Functions ---
    struct FrontEnd {
        uint kickbackRate;
        bool registered;
    }

    struct Deposit {
        uint initialValue;
        address frontEndTag;
    }

    function deposits(
        address _user
    ) external view returns (Deposit memory _deposit);

    function provideToSP(uint _amount, address _frontEndTag) external;

    function withdrawFromSP(uint _amount) external;

    function getPLS() external view returns (uint);

    function getTotalUSDLDeposits() external view returns (uint);

    function getDepositorPLSGain(
        address _depositor
    ) external view returns (uint);

    function getDepositorLOANGain(
        address _depositor
    ) external view returns (uint);

    function getFrontEndLOANGain(
        address _frontEnd
    ) external view returns (uint);

    function getCompoundedUSDLDeposit(
        address _depositor
    ) external view returns (uint);

    function getCompoundedFrontEndStake(
        address _frontEnd
    ) external view returns (uint);

    function registerFrontEnd(uint _kickbackRate) external;

    function frontEnds(
        address _frontEnd
    ) external view returns (FrontEnd memory);
}
