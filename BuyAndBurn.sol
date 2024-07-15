//SPDX-License-Identifier: None
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPulseXRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function getAmountsOut(
        uint amountIn,
        address[] calldata path
    ) external view returns (uint[] memory amounts);

    function WPLS() external pure returns (address);
}

/**
 * @title BuyAndBurn
 * @dev A contract for swapping tokens using PulseX Router and burning the received tokens.
 */
contract BuyAndBurn is Ownable2Step {
    using SafeERC20 for IERC20;

    /**
     * @dev The address representing the burn destination.
     */
    address private constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    /**
     * @dev The address of the WPLS Token.
     */
    address private constant WPLS_Address =
        0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    /**
     * @dev The address of the PulseX Router contract.
     */
    address public pulseXRouterAddress;

    /**
     * @dev A mapping of token addresses to their corresponding swap paths.
     */
    mapping(address => address[]) public tokenAndPath;

    uint256 public slippage = 97;

    /**
     * @dev Initializes the BuyAndBurn contract.
     */
    constructor(address _pulseXRouter) {
        require(_pulseXRouter != address(0), "Invalid router address");
        pulseXRouterAddress = _pulseXRouter;
    }

    receive() external payable {}

    /**
     * @dev Sets a token address and its corresponding swap path to the contract.
     * Only the contract owner can call this function.
     * @param tokenAddress The address of the token to add.
     * @param path The swap path for the token.
     */

    function setTokenAndPath(
        address tokenAddress,
        address[] memory path
    ) external onlyOwner {
        require(tokenAddress != address(0), "Invalid token address");
        tokenAndPath[tokenAddress] = path;
    }

    /**
     * @dev Sets pulseX router address to the contract.
     * Only the contract owner can call this function.
     * @param _routerAddress The address of the pulseX router.
     */

    function setRouterAddress(address _routerAddress) external onlyOwner {
        require(_routerAddress != address(0), "Invalid router address");
        pulseXRouterAddress = _routerAddress;
    }

    /**
     * @dev used to update the slippage
     * @param _newSlippage new slippage to be used
     */
    function updateSlippage(uint256 _newSlippage) external onlyOwner {
        slippage = _newSlippage;
    }

    /**
     * @dev Swaps and burns multiple tokens.
     * The function swaps each token in the provided `tokenAddresses` array
     * for WIN token using the corresponding swap path.
     * Tokens must be already transferred to this contract before calling this function.
     * @param tokenAddresses The addresses of the tokens to swap and burn.
     */
    function swap(address[] memory tokenAddresses) external {
        uint256 tokenLength = tokenAddresses.length;
        require(tokenLength > 0, "Empty token address list");

        for (uint i = 0; i < tokenLength; ++i) {
            // Get the token contract instance
            IERC20 token = IERC20(tokenAddresses[i]);

            // Check the balance of the token held by this contract
            uint256 amountIn = token.balanceOf(address(this));
            require(amountIn > 0, "No tokens to swap and burn");

            // Approve PulseX Router to spend the token
            token.safeApprove(pulseXRouterAddress, amountIn);

            // Retrieve the swap path for the token
            address[] memory path = tokenAndPath[tokenAddresses[i]];
            require(path.length > 0, "Path not found for token");

            uint256[] memory _amountOutMin = IPulseXRouter(pulseXRouterAddress)
                .getAmountsOut(amountIn, path);
            uint256 amountOutMin = (_amountOutMin[_amountOutMin.length - 1] *
                slippage) / 100;

            // Swap the token for WIN using PulseX Router
            IPulseXRouter(pulseXRouterAddress).swapExactTokensForTokens(
                amountIn,
                amountOutMin,
                path,
                DEAD_ADDRESS,
                block.timestamp + 600
            );
        }
    }

    /**
     * @notice Swaps the contract's PLS balance for a specified token using the PulseX Router.
     * @dev The function retrieves the swap path for the specified token and performs the swap.
     * The contract must have PLS balance available for the swap to be successful.
     * Ensure that the contract has approved the PulseX Router to spend the PLS amount.
     * Make sure to set a valid swap path for the token using the `setTokenAndPath` function.
     * The swap operation will be performed with the specified slippage and within the deadline.
     */
    function swapPLS() external {
        // Check the balance of the token held by this contract
        uint256 amountIn = address(this).balance;
        require(amountIn > 0, "No tokens to swap and burn");

        // Retrieve the swap path for the token
        address[] memory path = tokenAndPath[WPLS_Address];
        require(path.length > 0, "Path not found for token");

        uint256[] memory _amountOutMin = IPulseXRouter(pulseXRouterAddress)
            .getAmountsOut(amountIn, path);
        uint256 amountOutMin = (_amountOutMin[_amountOutMin.length - 1] *
            slippage) / 100;

        // Swap the token for WIN using PulseX Router
        IPulseXRouter(pulseXRouterAddress).swapExactETHForTokens{
            value: amountIn
        }(amountOutMin, path, DEAD_ADDRESS, block.timestamp + 600);
    }

    /**
     * @dev Returns the swap path for a given token address.
     * @param tokenAddress The address of the token.
     * @return path The swap path for the token.
     */
    function getPath(
        address tokenAddress
    ) external view returns (address[] memory path) {
        require(tokenAddress != address(0), "Invalid token address");

        path = tokenAndPath[tokenAddress];

        require(path.length > 0, "Path not found for token");

        return path;
    }
}
