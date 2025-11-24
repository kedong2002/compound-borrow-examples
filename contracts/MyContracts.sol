// SPDX-License-Identifier: MIT

// Using the recommended latest stable Solidity version for best security and gas optimization.
pragma solidity ^0.8.20;

// Custom Errors for gas efficiency (replaces string reverts)
error MintFailed(uint256 error);
error EnterMarketsFailed(uint256 errorCode);
error GetLiquidityFailed(uint256 errorCode);
error InsufficientLiquidity();
error BorrowFailed(uint256 errorCode);
error RepayFailed(uint256 errorCode);
error InvalidOption(string reason);
error AddressNotContract(address _address);

// --- Interface Definitions ---

interface Erc20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    // Added common balance/allowance views for completeness
    function balanceOf(address account) external view returns (uint256);
}


interface CErc20 {
    function mint(uint256 mintAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function borrowRatePerBlock() external view returns (uint256);
    function borrowBalanceCurrent(address account) external returns (uint256);
    function repayBorrow(uint256 repayAmount) external returns (uint256);
}


interface CEth {
    function mint() external payable;
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow() external payable; // Repay ETH by sending ETH in `value`
    function borrowBalanceCurrent(address account) external returns (uint256);
}


interface Comptroller {
    // isListed, collateralFactorMantissa
    function markets(address cToken) external view returns (bool, uint256); 
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    // error, liquidity, shortfall
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
}


interface PriceFeed {
    // Returns the underlying price in USD scaled by 1e18
    function getUnderlyingPrice(address cToken) external view returns (uint256);
}


/**
 * @title CompoundBorrowingDemo
 * @notice Demonstrates basic supply, enter market, borrow, and repay actions on Compound-like protocols.
 */
contract CompoundBorrowingDemo {
    event MyLog(string message, uint256 value);

    // Immutable addresses for core protocol components for safety and gas efficiency
    address immutable public cEthAddress;
    address immutable public comptrollerAddress;
    address immutable public priceFeedAddress;
    
    constructor(address _cEthAddress, address _comptrollerAddress, address _priceFeedAddress) {
        cEthAddress = _cEthAddress;
        comptrollerAddress = _comptrollerAddress;
        priceFeedAddress = _priceFeedAddress;
    }
    
    /**
     * @notice Supplies ETH as collateral and then borrows a specified ERC20 token.
     * @dev Assumes the caller has already seeded this contract with the underlying ERC20 token for repayment.
     * @param _cTokenAddress Address of the cToken to borrow (e.g., cDAI, cUSDC).
     * @param _underlyingDecimals Decimals of the underlying token (e.g., 18 for DAI, 6 for USDC).
     * @return Current outstanding borrow balance of the underlying token.
     */
    function borrowErc20Example(
        address _cTokenAddress,
        uint256 _underlyingDecimals
    ) public payable returns (uint256) {
        CEth cEth = CEth(cEthAddress);
        Comptroller comptroller = Comptroller(comptrollerAddress);
        PriceFeed priceFeed = PriceFeed(priceFeedAddress);
        CErc20 cToken = CErc20(_cTokenAddress);

        // 1. Supply ETH as collateral, receiving cETH in return.
        // REMOVED fixed gas limit (gas: 250000) for security.
        cEth.mint{ value: msg.value }(); 

        // 2. Enter the cETH market to enable borrowing against it.
        address[] memory cTokens = new address[](1);
        cTokens[0] = cEthAddress;
        uint256[] memory errors = comptroller.enterMarkets(cTokens);
        
        if (errors[0] != 0) {
            revert EnterMarketsFailed(errors[0]); // Use Custom Error
        }

        // 3. Get my account's current liquidity status.
        (uint256 error, uint256 liquidity, uint256 shortfall) = comptroller
            .getAccountLiquidity(address(this));
            
        if (error != 0) {
            revert GetLiquidityFailed(error); // Use Custom Error
        }
        
        // Shortfall > 0 means the account is currently underwater (subject to liquidation).
        require(shortfall == 0, "Account is underwater (shortfall > 0)");
        
        // Liquidity > 0 means we have available borrowing power.
        require(liquidity > 0, "Account has no excess collateral (liquidity = 0)");

        // 4. Calculate maximum borrowable amount based on USD liquidity.
        // liquidity is given in USD scaled by 1e18 (mantissa)
        uint256 underlyingPrice = priceFeed.getUnderlyingPrice(_cTokenAddress);
        
        // Max borrowable amount of underlying tokens (scaled to 1e18)
        uint256 maxBorrowUnderlyingBase = liquidity / underlyingPrice;

        emit MyLog("Maximum underlying Borrow (in 1e18 units)", maxBorrowUnderlyingBase);
        
        // 

        // 5. Borrow the underlying asset.
        // WARNING: Borrowing close to maxBorrowUnderlyingBase risks immediate liquidation.
        uint256 numUnderlyingToBorrow = 10;
        uint256 borrowAmount = numUnderlyingToBorrow * 10**_underlyingDecimals;
        
        uint256 borrowError = cToken.borrow(borrowAmount);
        if (borrowError != 0) {
            revert BorrowFailed(borrowError); // Use Custom Error
        }

        // 6. Verify outstanding borrow balance.
        uint256 borrows = cToken.borrowBalanceCurrent(address(this));
        emit MyLog("Current underlying borrow amount (including accrued interest)", borrows);

        return borrows;
    }
    
    /**
     * @notice Repays an outstanding ERC20 token borrow.
     * @dev Caller must ensure this contract has sufficient *unlocked* underlying ERC20 tokens.
     * @param _erc20Address Address of the underlying ERC20 token.
     * @param _cErc20Address Address of the cToken market.
     * @param amount The amount of underlying tokens to repay (including accrued interest).
     * @return True if successful.
     */
    function myErc20RepayBorrow(
        address _erc20Address,
        address _cErc20Address,
        uint256 amount
    ) public returns (bool) {
        Erc20 underlying = Erc20(_erc20Address);
        CErc20 cToken = CErc20(_cErc20Address);

        // 1. Approve the cToken contract to pull the underlying tokens from this contract.
        // This is necessary because Compound uses transferFrom.
        underlying.approve(_cErc20Address, amount);
        
        // 2. Execute the repay.
        uint256 error = cToken.repayBorrow(amount);

        if (error != 0) {
            revert RepayFailed(error); // Use Custom Error
        }
        return true;
    }

    // --- ETH BORROWING EXAMPLE (Collateral is an ERC20, Borrow is ETH) ---

    /**
     * @notice Supplies an ERC20 token as collateral and then borrows ETH.
     * @dev Uses a separate price feed for calculating max borrowable ETH.
     * @param _cTokenAddress cToken address corresponding to the ERC20 collateral.
     * @param _underlyingAddress The ERC20 token address to supply as collateral.
     * @param _underlyingToSupplyAsCollateral The amount of ERC20 to supply.
     * @return Current outstanding ETH borrow balance (in Wei).
     */
    function borrowEthExample(
        address _cTokenAddress,
        address _underlyingAddress,
        uint256 _underlyingToSupplyAsCollateral
    ) public returns (uint256) {
        CEth cEth = CEth(cEthAddress);
        Comptroller comptroller = Comptroller(comptrollerAddress);
        CErc20 cToken = CErc20(_cTokenAddress);
        Erc20 underlying = Erc20(_underlyingAddress);
        
        // 1. Approve transfer of underlying collateral to the cToken market
        // WARNING: Should only approve the amount needed, not MAX_UINT256.
        underlying.approve(_cTokenAddress, _underlyingToSupplyAsCollateral);

        // 2. Supply underlying ERC20 as collateral, get cToken in return
        uint256 error = cToken.mint(_underlyingToSupplyAsCollateral);
        if (error != 0) {
            revert MintFailed(error); // Use Custom Error
        }

        // 3. Enter the market to enable borrowing against the collateral
        address[] memory cTokensArray = new address[](1);
        cTokensArray[0] = _cTokenAddress;
        uint256[] memory errors = comptroller.enterMarkets(cTokensArray);
        
        if (errors[0] != 0) {
            revert EnterMarketsFailed(errors[0]); // Use Custom Error
        }

        // 4. Get liquidity
        (uint256 error2, uint256 liquidity, uint256 shortfall) = comptroller
            .getAccountLiquidity(address(this));
            
        if (error2 != 0) {
            revert GetLiquidityFailed(error2); // Use Custom Error
        }
        require(shortfall == 0, "Account is underwater (shortfall > 0)");
        require(liquidity > 0, "Account has no excess collateral (liquidity = 0)");

        // Liquidity is expressed in USD (1e18 units). Max ETH borrow is limited by this.
        emit MyLog("Maximum ETH Borrow based on liquidity (USD value 1e18)", liquidity);

        // 5. Borrow ETH
        uint256 numWeiToBorrow = 2000000000000000; // 0.002 ETH
        
        // Borrow ETH (underlying is ETH)
        uint256 borrowError = cEth.borrow(numWeiToBorrow);
        if (borrowError != 0) {
            revert BorrowFailed(borrowError); // Use Custom Error
        }

        uint256 borrows = cEth.borrowBalanceCurrent(address(this));
        emit MyLog("Current ETH borrow amount (Wei)", borrows);

        return borrows;
    }

    /**
     * @notice Repays an outstanding ETH borrow.
     * @dev The ETH to repay is sent along with the transaction via `msg.value`.
     * @param _cEtherAddress Address of the cETH market.
     * @param amount The amount of ETH (in Wei) to repay.
     * @param gas The original code included a gas parameter, but fixed gas limits are insecure.
     * This parameter is removed in the optimized version.
     * @return True if successful.
     */
    function myEthRepayBorrow(address _cEtherAddress)
        public
        payable
        returns (bool)
    {
        CEth cEth = CEth(_cEtherAddress);
        // Repay ETH. The amount sent via `msg.value` is repaid.
        // NOTE: If amount is 0, the full borrow balance plus accrued interest is repaid.
        cEth.repayBorrow{ value: msg.value }(); 
        return true;
    }

    // Fallback function to allow the contract to receive ETH. 
    // This is required for cEth.borrowEthExample to receive the borrowed ETH.
    receive() external payable {}
}
