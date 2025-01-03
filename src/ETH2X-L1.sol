// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IPool} from "@aave/core/contracts/interfaces/IPool.sol";
import {IWrappedTokenGatewayV3} from "@aave/periphery/contracts/misc/interfaces/IWrappedTokenGatewayV3.sol";
import {TransferHelper} from "@uniswap/v3-periphery/libraries/TransferHelper.sol";
import {IWETH} from "@aave/core/contracts/misc/interfaces/IWETH.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {ICheckTheChain} from "./interfaces/ICheckTheChain.sol";

/**
 * @title ETH2X
 *
 * When deposit() is called, this contract should deposit {msg.value} into Aave and borrow USDC at {tbd} rate.
 * With the USDC, the contract should swap it for ETH on Uniswap.
 * The goal is to maintain a 2x leveraged position in ETH, which anybody can help maintain via rebalance().
 *
 * Goal should be to have $2 worth of ETH for every 1 USDC in the contract.
 */
contract ETH2X is ERC20 {
    /*//////////////////////////////////////////////////////////////
                               PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // Local variables
    uint256 public lastRebalance;
    uint256 public constant TARGET_RATIO = 2e18; // 2x leverage

    // Uniswap
    address public immutable USDC;
    address public immutable WETH;
    uint24 public immutable POOL_FEE;
    ISwapRouter public immutable SWAP_ROUTER;
    ICheckTheChain public immutable CHECK_THE_CHAIN;

    // Aave
    IPool public immutable POOL;
    IWrappedTokenGatewayV3 public immutable WRAPPED_TOKEN_GATEWAY;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Mint(address indexed to, uint256 amount);
    event Redeem(address indexed to, uint256 amount);
    event Rebalance(uint256 leverageRatio, uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InsufficientCollateral();
    error NothingToRedeem();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() ERC20("ETH2X", "ETH2X") {
        USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        POOL_FEE = 500; // 0.05%
        SWAP_ROUTER = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
        CHECK_THE_CHAIN = ICheckTheChain(0x0000000000cDC1F8d393415455E382c30FBc0a84);

        POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
        WRAPPED_TOKEN_GATEWAY = IWrappedTokenGatewayV3(0xA434D495249abE33E031Fe71a969B81f3c07950D);

        // Approve the router to spend USDC and WETH
        TransferHelper.safeApprove(USDC, address(SWAP_ROUTER), type(uint256).max);
        TransferHelper.safeApprove(WETH, address(SWAP_ROUTER), type(uint256).max);

        // Approve the pool to spend USDC and WETH
        TransferHelper.safeApprove(USDC, address(POOL), type(uint256).max);
        TransferHelper.safeApprove(WETH, address(POOL), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow users to mint tokens by sending ETH to the contract
    receive() external payable {
        if (msg.sender != address(WETH)) {
            mint(msg.sender);
        }
    }

    /**
     * @notice Mint ETH2X tokens to the caller
     * @dev We don't need to rebalance internally because worst case, we have more collateral than debt.
     * @param onBehalfOf The address to mint tokens to
     */
    function mint(address onBehalfOf) public payable {
        // Supply ETH to Aave and recieve equal amount of aWETH
        WRAPPED_TOKEN_GATEWAY.depositETH{value: msg.value}(address(0), address(this), 0);

        /**
         * TODO: Determine amount of tokens to mint
         * Options: Give the caller tokens based on...
         * 1. the price of ETH at the time of deposit
         * 2. the amount of ETH deposited compared to the total amount of aWETH in the contract
         * 3. ?? I'm not sure if any of the approaches above are correct
         */

        // Mint tokens to the caller to represent ownership of the pool
        uint256 amount = calculateTokensToMint(msg.value);
        _mint(onBehalfOf, amount);
        emit Mint(onBehalfOf, amount);
    }

    /**
     * @notice Burn ETH2X tokens to redeem underlying ETH
     * @dev We DO need to rebalance internally here, because it's possible for somebody to withdraw enough ETH to
     *      where the USDC loan gets liquidated.
     * @param amount The amount of ETH2X tokens to burn
     */
    function redeem(uint256 amount) external {
        uint256 ethToRedeem = calculateEthToRedeem(amount);

        // Burn tokens from the caller which represents their ownership of the pool decreasing.
        // This includes a check to ensure the caller has enough tokens
        _burn(msg.sender, amount);

        if (ethToRedeem == 0) {
            revert NothingToRedeem();
        }

        // If we withdraw too much WETH from Aave in one go, we could get liquidated.
        // Open question: if we rebalance within the same transaction, will the loan still be liquidatable?
        // The below assumes no

        // ^ Update: I think the answer is yes. From the docs:
        // "If user has any existing debt backed by the underlying token, then the maximum `amount` available to withdraw is the `amount` that will not leave user's health factor < 1 after withdrawal."
        // https://aave.com/docs/developers/smart-contracts/pool#write-methods-withdraw

        // Withdraw the corresponding amount of WETH from Aave
        (uint256 totalCollateral,,,,,) = getAccountData();
        uint256 ethWorthOfCollateral = (totalCollateral * 1e18) / ethPrice();

        // Check if we have enough collateral to cover the withdrawal
        if (ethWorthOfCollateral < ethToRedeem) {
            revert InsufficientCollateral();
        }

        // Withdraw the corresponding amount of WETH from Aave
        POOL.withdraw(WETH, ethToRedeem, address(this));

        // Unwrap the WETH and transfer it to the caller
        IWETH(WETH).withdraw(ethToRedeem);
        TransferHelper.safeTransferETH(msg.sender, ethToRedeem);

        // Rebalance the pool
        rebalance();

        emit Redeem(msg.sender, ethToRedeem);
    }

    function rebalance() public {
        (uint256 totalCollateralBase, uint256 totalDebtBase,,,,) = getAccountData();
        uint256 leverageRatio = getLeverageRatio();

        // Goal is for totalCollateralBase to always be (TARGET_RATIO / 1e18) * totalDebtBase
        // For 2x leverage, collateral should be $100 worth of ETH for every $50 worth of borrowed USDC

        // Examples of how rebalancing should work:
        // If collateral = $3000 and debt = $0, we want to _borrowUsdcSwapForEthAndSupply(1500). That gets us to $4500 collateral and $1500 debt (not 2x yet)
        // If collateral = $4500 and debt = $1500, we want to _borrowUsdcSwapForEthAndSupply(1500). That gets us to $6000 collateral and $3000 debt (2x leverage!)
        // If collateral = $2500 and debt = $1500, we want to _withdrawEthSwapForUsdcAndRepay(500 / ethPrice()). That gets us to $2000 collateral and $1000 debt (2x leverage)

        if (leverageRatio > TARGET_RATIO) {
            uint256 amountToBorrow = ((totalCollateralBase / ((TARGET_RATIO) / 1e18)) - totalDebtBase) / 100;
            _borrowUsdcSwapForEthAndSupply(amountToBorrow);

            // Nested rebalance if we can't get far enough in one go due to Aave LTV limits
            if (getLeverageRatio() > TARGET_RATIO) {
                (uint256 totalCollateralBase2, uint256 totalDebtBase2,,,,) = getAccountData();
                uint256 amountToBorrow2 = ((totalCollateralBase2 / ((TARGET_RATIO) / 1e18)) - totalDebtBase2) / 100;
                _borrowUsdcSwapForEthAndSupply(amountToBorrow2);
            }
        } else {
            uint256 amountToWithdraw = totalCollateralBase - (totalDebtBase * TARGET_RATIO / 1e18);
            _withdrawEthSwapForUsdcAndRepay(amountToWithdraw);
        }

        lastRebalance = block.timestamp;
        emit Rebalance(leverageRatio, block.timestamp);
    }

    /**
     * @notice Returns the user account data across all the reserves
     * @return totalCollateralBase The total collateral of the user in the base currency used by the price feed
     * @return totalDebtBase The total debt of the user in the base currency used by the price feed
     * @return availableBorrowsBase The borrowing power left of the user in the base currency used by the price feed
     * @return currentLiquidationThreshold The liquidation threshold of the user
     * @return ltv The loan to value of The user
     * @return healthFactor The current health factor of the user
     */
    function getAccountData()
        public
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        return POOL.getUserAccountData(address(this));
    }

    function getLeverageRatio() public view returns (uint256) {
        (uint256 totalCollateralBase, uint256 totalDebtBase,,,,) = getAccountData();

        if (totalDebtBase == 0) {
            return type(uint256).max; // Return max value to indicate infinite leverage
        }

        // Multiply by 1e18 before division to maintain precision
        return (totalCollateralBase * 1e18) / totalDebtBase;
    }

    /**
     * @notice Calculate the amount of ETH2X tokens to mint based on the amount of ETH deposited.
     * @param depositAmount The amount of ETH to deposit
     * @return The amount of tokens to mint
     */
    function calculateTokensToMint(uint256 depositAmount) public view returns (uint256) {
        (uint256 totalCollateralBefore, uint256 totalDebtBefore,,,,) = getAccountData();
        uint256 tokenSupply = totalSupply();

        // Calculate amount of tokens to mint based on the proportional ownership
        uint256 amount;
        if (tokenSupply == 0) {
            // First deposit - set initial exchange rate of 1000 tokens = 1 ETH
            amount = depositAmount * 10000;
        } else {
            // Calculate the net value (collateral - debt) before and after deposit
            uint256 netValueBefore = totalCollateralBefore - totalDebtBefore;
            uint256 depositAmountValue = depositAmount * ethPrice();
            uint256 totalCollateralAfter = totalCollateralBefore + depositAmountValue;
            uint256 netValueAfter = totalCollateralAfter - totalDebtBefore;
            uint256 valueAdded = netValueAfter - netValueBefore;

            // Mint tokens proportional to the value added compared to existing value
            amount = (valueAdded * tokenSupply) / netValueBefore;
        }

        return amount;
    }

    /**
     * @notice Calculate the amount of ETH to redeem based on the amount of ETH2X tokens burned.
     * @param redeemAmount The amount of ETH2X tokens to burn in exchange for the underlying ETH
     * @return The amount of ETH to redeem
     */
    function calculateEthToRedeem(uint256 redeemAmount) public view returns (uint256) {
        (uint256 collateral, uint256 debt,,,,) = getAccountData();

        // Calculate the percentage of the pool that the tokens represent
        uint256 percentageOwned = (redeemAmount * 1e18) / totalSupply();

        // If we had to put all assets into ETH, how much would it be worth?
        uint256 totalCollateralValue = collateral - debt;

        // How much of that value does the redeemer own?
        uint256 redeemerValue = totalCollateralValue * percentageOwned;

        // How much ETH is that worth?
        uint256 amount = redeemerValue / ethPrice();

        return amount;
    }

    /// @return Price of ETH in USDC with 12 digits of precision
    function ethPrice() public view returns (uint256) {
        (uint256 price,) = CHECK_THE_CHAIN.checkPrice(WETH);
        // Convert to 12 digits of precision to match Aave's price feed
        return price * 100;
    }

    function _borrowUsdcSwapForEthAndSupply(uint256 amountToBorrow) internal {
        // 1. Borrow USDC (adjust for it being 6 decimals)
        POOL.borrow(USDC, amountToBorrow, 2, 0, address(this));

        // TODO: Use a live price feed for this
        uint256 expectedEthAmountOut = 0;

        // 2. Buy WETH on Uniswap: https://docs.uniswap.org/contracts/v3/guides/swaps/single-swaps
        // 2a. Set up the swap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: USDC,
            tokenOut: WETH,
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountToBorrow,
            // Allow 0.5% slippage
            amountOutMinimum: expectedEthAmountOut,
            sqrtPriceLimitX96: 0
        });

        // 2b. Execute the swap and get the amount of WETH received
        uint256 amountOut = SWAP_ROUTER.exactInputSingle(params);

        // 3. Deposit new WETH into Aave
        POOL.supply(WETH, amountOut, address(this), 0);
    }

    function _withdrawEthSwapForUsdcAndRepay(uint256 amountToWithdraw) internal {
        // 1. Withdraw enough ETH from Aave
        POOL.withdraw(WETH, amountToWithdraw, address(this));

        // TODO: Use a live price feed for this
        uint256 expectedUsdcAmountOut = 0;

        // 2. Swap WETH for USDC on Uniswap
        // 2a. Set up the swap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountToWithdraw,
            // Allow 0.5% slippage
            amountOutMinimum: expectedUsdcAmountOut - (expectedUsdcAmountOut / 200),
            sqrtPriceLimitX96: 0
        });

        // 2b. Execute the swap and get the amount of USDC received
        uint256 amountOut = SWAP_ROUTER.exactInputSingle(params);

        // 3. If we already have a loan, repay it. If we don't already have a loan, we don't need to do anything
        POOL.repay(USDC, amountOut, 2, address(this));
    }
}
