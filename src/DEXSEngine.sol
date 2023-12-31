//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {DEXStablecoin} from "./DEXStablecoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DEXSEngine
 * @author Stefania Pozzi
 *
 * This contract keeps the value of 1 DEXS == 1 $
 * @notice It handles all the logic for
 * 1. minting and burning tokens
 * 2. deposit and withdraw collateral
 * @notice system similar to MakerDAO (overcollatereralisation)
 * This protocol always has to be overcollateralised
 * -> it always has more collateral than DEXS
 */
contract DEXSEngine is ReentrancyGuard {
    error DEXSEngine_NeedsMoreThanZero();
    error DEXSEngine_TokensPriceFeedArrayMismatched();
    error DEXSEngine_TokenNotAllowed();
    error DEXSEngine_TransferFailed();
    error DEXSEngine_HealthFactorIsBelowThreshold();
    error DEXSEngine_MintFailed();
    error DEXSEngine_CannotLiquidate();
    error DEXSEngine_HealthFactorNotImproved();
    error DEXSEngine_LiquidatorHealthFactorNegative();
    error DEXSEngine_TokenNotSupportedAsCollateral();

    using OracleLib for AggregatorV3Interface;

    uint256 private constant PRECISION10 = 1e10;
    uint256 private constant PRECISION18 = 1e18;
    uint256 private constant PRECISION8 = 1e8;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; //Health factor should be 11e17 (1.1) due to bonus for liquidator
    uint256 private constant LIQUIDATION_PERCENTAGE = 10;
    uint256 private constant LIQUIDATION_BASIS = 100;

    address[] s_collateralTokenSupported;
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dexminted) private s_dexsminted;

    DEXStablecoin private immutable i_dexstablecoin;

    event DEXSEngine_CollateralAdded(address indexed user, address indexed token, uint256 indexed amount);
    event DEXSEngine_CollateralRedeemed(
        address indexed from, address indexed to, address indexed token, uint256 amount
    );

    modifier needsMoreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DEXSEngine_NeedsMoreThanZero();
        }
        _;
    }

    modifier isCollateralTokenAllowed(address _token) {
        if (s_priceFeeds[_token] == address(0)) {
            revert DEXSEngine_TokenNotAllowed();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        bool isSupported = false;
        for (uint256 i = 0; i < s_collateralTokenSupported.length; i++) {
            if (s_collateralTokenSupported[i] == token) {
                isSupported = true;
            }
        }
        if (!isSupported) {
            revert DEXSEngine_TokenNotSupportedAsCollateral();
        }
        _;
    }

    /**
     * It sets the allowed collateral tokens and
     * deploys the DEXStablecoin contract
     */
    constructor(
        address[] memory collateralTokensAddresses,
        address[] memory collateralPriceFeedAddressess,
        address _dexsaddress
    ) {
        if (collateralTokensAddresses.length != collateralPriceFeedAddressess.length) {
            revert DEXSEngine_TokensPriceFeedArrayMismatched();
        }
        i_dexstablecoin = DEXStablecoin(_dexsaddress);
        for (uint256 i = 0; i < collateralTokensAddresses.length; i++) {
            s_priceFeeds[collateralTokensAddresses[i]] = collateralPriceFeedAddressess[i];
            s_collateralTokenSupported.push(collateralTokensAddresses[i]);
        }
    }

    /*
    * -------------------------------------------------------- 1. DEPOSIT & MINT COLLATERAL -------------------------------------------------------- *
    */

    /**
     *
     * Deposit the collateral on the current engine
     *
     * @param _token wBTC or wETH
     * @param _amount in ethWEI
     */
    function depositCollateral(address _token, uint256 _amount)
        public
        needsMoreThanZero(_amount)
        nonReentrant
        isAllowedToken(_token)
    {
        s_collateralDeposited[msg.sender][_token] += _amount;
        emit DEXSEngine_CollateralAdded(msg.sender, _token, _amount);
        (bool success) = IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        if (!success) {
            revert DEXSEngine_TransferFailed();
        }
    }

    /**
     * Minting is possible only if the caller of this function has collateral
     * > 200% of the minted DEXS
     * @param amount amount of DEXS the callers wants to mint in WEI
     *
     * @dev we add the amount to s_dexminted anyway because
     * we use it to calculate the Health Factor in the method _revertIfHealthFactorIsBroken.
     * If this function reverts, s_dexsminted will go back to its original state.
     */
    function mintDEXS(uint256 amount) public needsMoreThanZero(amount) nonReentrant {
        s_dexsminted[msg.sender] += amount;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dexstablecoin.mint(msg.sender, amount);
        if (!minted) {
            revert DEXSEngine_MintFailed();
        }
    }

    function depositCollateralAndMint(address _token, uint256 _tokenAmount, uint256 _dexsAmount) external {
        depositCollateral(_token, _tokenAmount);
        mintDEXS(_dexsAmount);
    }

    /*
    * -------------------------------------------------------- 2. REDEEM & BURN COLLATERAL -------------------------------------------------------- *
    */

    /**
     * Burns an amount of DEXS on behalf of an address (target).
     * Performed by a liquidator contract (from).
     *
     * @param amount the amount of DEXS to be burned
     * @param target the address of whom are we burning from, whose debt is paying down
     * @param from the liquidator who pays the debt for the target (DEXS) and get back the target collateral (ETH|BTC)
     *
     * @dev do not call this directly: it does not check the health factor
     */
    function _burnDEXSFrom(uint256 amount, address from, address target)
        private
        needsMoreThanZero(amount)
        nonReentrant
    {
        s_dexsminted[target] -= amount;
        //the debt is given to the engine contract to be burned
        bool success = i_dexstablecoin.transferFrom(from, address(this), amount);
        if (!success) {
            revert DEXSEngine_TransferFailed();
        }
        i_dexstablecoin.burn(amount);
    }

    function burnDEXS(uint256 amount) public needsMoreThanZero(amount) {
        _burnDEXSFrom(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * Health factor must remain > 1 after the collateral is redeemed
     * @notice solidity compiler throws an error if the user is trying to redeem more than he has deposited
     * @notice it's possible to check the health factor before sending the collateral but that's gas inefficient
     */

    function _redeemCollateralFrom(address token, uint256 amount, address from, address to)
        public
        needsMoreThanZero(amount)
        nonReentrant
    {
        s_collateralDeposited[from][token] -= amount;
        emit DEXSEngine_CollateralRedeemed(from, to, token, amount);
        bool success = IERC20(token).transfer(to, amount);
        if (!success) {
            revert DEXSEngine_TransferFailed();
        }
    }

    function redeemCollateral(address token, uint256 amount) public needsMoreThanZero(amount) {
        _redeemCollateralFrom(token, amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnAndRedeemCollateral(address token, uint256 amount) external {
        burnDEXS(amount);
        redeemCollateral(token, amount);
    }

    /**
     * Liquidates some user's debt
     *
     * @notice it's possible to partially liquidate a user
     * @notice a bonus (10% of the debt) is granted to the caller of this function
     *
     * @dev When to liquidate
     * 1. if insolvent users' health factor is broken
     * 2. if liquidator's health factor is broken
     * 3. if at the end of the liquidation, the user is not insolvent anymore
     * Otherwise we revert all txs
     *
     * Redeem collateral
     * 1. estimate how much ETH|BTC the debt (DEXS) was worth -> actual debt worth (actualDebtWorthToken)
     * 2. bonus: send 10% of the actual debt worth to the caller of this function
     * 3. transfer the debt + bonus to the liquidator
     *
     * Burn DEXS
     * 3. the liquidator burns !its own! DEXS (in order to cover the target's DEXS debt)
     * And he gets the redeemedCollateralWithBonus (ETH or BTC)
     *
     * @param token the token address of the collateral to remove from the user
     * @param user the insolvent user
     * @param debtUSDWEI the amount of DEXS to burn to cover user's debt
     *
     * @dev codehawks audit BUG >> when the bonus is fixed (10%)
     * and the bonus+debt exceeds user's collateral,
     * we need to take this bonus from somewhere else >>
     * Make user to be liquidate when Health Factor == 1.1,
     * so we can have room for bonus
     */

    /*
    * -------------------------------------------------------- 3. LIQUIDATION -------------------------------------------------------- *
    */

    function liquidate(address token, address user, uint256 debtUSDWEI) external needsMoreThanZero(debtUSDWEI) {
        uint256 userStartingHealthFactor = healthFactor(user);

        if (userStartingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DEXSEngine_CannotLiquidate();
        }

        uint256 actualDebtToken = usdToToken(debtUSDWEI, token);
        uint256 bonus = ((actualDebtToken * LIQUIDATION_PERCENTAGE) / LIQUIDATION_BASIS);
        uint256 redeemedCollateral = actualDebtToken + bonus;

        uint256 totalDepositedCollateral = getCollateralDeposited(user, token);

        if (redeemedCollateral > totalDepositedCollateral) {
            redeemedCollateral = totalDepositedCollateral;
        }
        _redeemCollateralFrom(token, redeemedCollateral, user, msg.sender);
        _burnDEXSFrom(debtUSDWEI, msg.sender, user);

        uint256 userEndingHealthFactor = healthFactor(user);
        if (userEndingHealthFactor <= MIN_HEALTH_FACTOR) {
            revert DEXSEngine_HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice It calculates the Health Factor for a user starting from his account information.
     * The liquidation threshold is set to double its collateral.
     *
     * @dev Overcollateralisation has to at least double the DEXS minted for each user
     *
     * @return healthFactorWEI the health factor in wei precision.
     * It will be 1 if the collateral amount is 2x the minted amount.
     */
    function healthFactor(address user) public view returns (uint256 healthFactorWEI) {
        (uint256 dexsOwned, uint256 collateralUSDWEI) = _accountInfo(user);
        if (dexsOwned == 0) return type(uint256).max;
        return _healthFactorCalculation(dexsOwned, collateralUSDWEI);
    }

    function _healthFactorCalculation(uint256 dexs, uint256 collateralUSDWEI)
        public
        pure
        returns (uint256 healthFactorWEI)
    {
        uint256 reducedCollateralWithLiquidationThresholdUSDWEI = ((collateralUSDWEI * 50) / 100);
        healthFactorWEI = ((reducedCollateralWithLiquidationThresholdUSDWEI * PRECISION18) / dexs);
    }

    /**
     * Reverts if user's Health Factor goes below the MIN_HEALTH_FACTOR
     * @dev it calls the main healthFactor function
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DEXSEngine_HealthFactorIsBelowThreshold();
        }
    }

    /*
    * -------------------------------------------------------- 4. UTILS & STATE -------------------------------------------------------- *
    */

    function getCollateralUSDWEI(address user) public view returns (uint256 collateralValue) {
        for (uint256 i = 0; i < s_collateralTokenSupported.length; i++) {
            address token = s_collateralTokenSupported[i];
            uint256 collateral = s_collateralDeposited[user][token];
            collateralValue += tokenToUsd(token, collateral);
        }
    }

    /**
     * Gives user basic information:
     * @return dexsMinted DEXS amount that belongs to the user
     * @return collateralUSDWEI USD value in WEI that corresponds to the deposited
     * collateral (originally in ETH|BTC)
     */
    function _accountInfo(address user) private view returns (uint256 dexsMinted, uint256 collateralUSDWEI) {
        dexsMinted = s_dexsminted[user];
        collateralUSDWEI = getCollateralUSDWEI(user);
    }

    /**
     * @return conversion to usdWEI
     */
    function tokenToUsd(address token, uint256 ethWEI) public view returns (uint256) {
        int256 price = getLatestRoundData(s_priceFeeds[token]);
        uint256 pricePRECISION18 = uint256(price) * PRECISION10;
        return ((pricePRECISION18 * ethWEI) / PRECISION18);
    }

    /**
     * Converts from USD with WEI precision to ETH|BTC in WEI precision
     *
     * @dev Procedure:
     * 1. uses the method getLatestRoundData to get the latest price
     * of the collateral (ETH|BTC) -> precision is 8 decimals
     * 2. it converts all the information to WEI precision
     * !! the price feed gives 2e8 for 2$,
     * meaning that the dollar amount has to be further scaled up 1e8 !!
     * 3. the token price is calculate DOLLAR_AMOUNTwei/TOKEN_PRICEwei
     * @dev The price feed returns the value of 1ETH = e.g. 2000$
     * -> 2000$ = 1ETH
     * -> 1$ = 1/2000 ETH
     * -> 50$ = 50/2000 ETH
     *
     * @param amountUSDWEI the amount of usd (in wei precision) to be converted into token (wei precision)
     * @param token the token which latest Price is obtained through priceFeeds
     *
     * @return amountTokenWEI must have 1e18 precision (WEI)
     * buecause solidity does not handle floating points !
     */
    function usdToToken(uint256 amountUSDWEI, address token) public view returns (uint256 amountTokenWEI) {
        int256 feedPrice_PRECISION8 = getLatestRoundData(s_priceFeeds[token]);
        uint256 feedPrice_PRECISION18 = uint256(feedPrice_PRECISION8) * PRECISION10;

        // fixed-point arithmetic -> x / y:
        // 1. multiply both members per desired PRECISION18
        // 2. perform division
        // 3. divide the result for PRECISION18
        // 4. after arithmetic semplifications, the result will be equal to (x*PRECISION18)/y
        // because we need the result in wei
        // otherwise division between integers will result into 0 (integer rounding)

        amountTokenWEI = ((amountUSDWEI * PRECISION18) / feedPrice_PRECISION18);
    }

    /**
     * Uses the AggregatorV3Interface to get the latest price for the collateral
     * @param priceFeedAddress the network pegged price feed for the specific token
     * @return price dollar with 8 decimals precision
     */
    function getLatestRoundData(address priceFeedAddress) public view returns (int256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return price;
    }

    function getLatestRoundDataFromToken(address token) public view returns (int256) {
        address priceFeedAddress = s_priceFeeds[token];
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return price;
    }

    function getPriceFeed(address token) public view returns (address) {
        return s_priceFeeds[token];
    }

    function getUsdMinted(address user) public view returns (uint256) {
        return s_dexsminted[user];
    }

    function getStablecoinAddress() public view returns (address) {
        return address(i_dexstablecoin);
    }

    function getSupportedCollateral() public view returns (address[] memory) {
        return s_collateralTokenSupported;
    }

    function getCollateralDeposited(address user, address token) public view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountInformation(address user) public view returns (uint256 dexs, uint256 collateral) {
        (dexs, collateral) = _accountInfo(user);
    }

    function subtractTest(uint256 amountToSubtract, address user, address token) public view returns (uint256 result) {
        result = s_collateralDeposited[user][token] - amountToSubtract;
    }

    function getWethAddress() public view returns (address) {
        return s_collateralTokenSupported[0];
    }

    function getCollateralTokens() public view returns (address[] memory) {
        return s_collateralTokenSupported;
    }
}
