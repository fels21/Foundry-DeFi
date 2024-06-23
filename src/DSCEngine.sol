// SPDX-License-Identifier: MIT

pragma solidity ^0.8.25;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
* @title DSCEngine
* @author fels21
* 
* The sistem is designed to be as minimal as possible, and have the tokkens mantain a 1 token == 1$ peg
* The stablecoin has the porprties:
    - Expgenous Collateral
    - Dollar Pegged
    - Algoritmically Stable

* It's is similr to DAI if DAI had no governance, no fees, and ws only backed by wETH and wBTC.
* Our DSC system should alwasys be "overcolateralized". At no point, should the value of all collateral <= the $ backed alue of all the DSC.
* 
* @notice This contract is the core of the DSC Systems. It handles all the logic for minting and rediming DSC, as well depositing and widrawing colllateral
* @notice This contract is VERY loosely based on the MarkerDAO DSS (DAI) system.
*
*/

contract DSCEngine is ReentrancyGuard {
    // ===========
    //   Errors
    // ===========
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TokenAdressAndPriceFeedAdressesMustBeSameLenght();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreakesHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    // ========================
    // 		 Types
    // ========================

    using OracleLib for AggregatorV3Interface;

    //   ======================
    //      State Variables
    //   ======================

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_TRESHHOLD = 50; // 200% OVER COLATERALIZED
    uint256 private constant LIQUIDATION_PRECISION = 100; // 200% OVER COLATERALIZED
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10%

    mapping(address token => address prceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //  ===========
    //      Event
    //  ===========
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );

    //  ====================
    //      Moddifiers
    //  ====================

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    //  ===================
    //      Functions
    //  ===================

    constructor(address[] memory tokenAdresses, address[] memory priceFeedAddress, address dscAddress) {
        // USD Price Feeds
        if (tokenAdresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAdressAndPriceFeedAdressesMustBeSameLenght();
        }
        for (uint256 i = 0; i < tokenAdresses.length; i++) {
            s_priceFeeds[tokenAdresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAdresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //  ========================
    //      External Functions
    //  ========================

    /**
     *
     * @param tokenCollateralAddress Address of the token to deposit as collateral
     * @param amountCollateral Amount of collateral diposit
     * @param amountDscToMint Amount of DSC tokens to mint
     * @notice This function will diposit collateral and mint DSC in one transaction
     */

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI
     * @param tokenCollateralAddress Thea address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to Deposit
     *
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
        //
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param tokenCollaterallAddress The colaterall token address to redeem
     * @param amountCollateral Amount of colaterall to redeem
     * @param amountDscToBurn Amount of DSC to
     * This fucntion burns DSC and redeeem colaterall in one transaction
     */

    function redeemCollateralForDsc(
        address tokenCollaterallAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollaterallAddress, amountCollateral);
        //Redeem colateral arleady check health factor
    }

    // In order to redeem collateral:
    // 1. Health factor must be over 1 AFTER collateral pulled
    // DRY: Don't repeat yourself
    // (C)heck, (E)ffect, (I)nteractions
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint amount of descetralized Stable Coin to mint
     * @notice they must have more collateral that amount of threshold
     *
     */

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much, revert
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amountToBurn) public moreThanZero(amountToBurn) {
        _burnDsc(amountToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); //???
    }

    /**
     * @param collateral The ERC20 collateral adddress to liquidate from the useer
     * @param user User with borowed health factor: _healtFactor < MIN_HEALT_FACTOR
     * @param debtToCover Amount of DSC you want to burn to improve the user healt factor
     *
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the user funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, the we wouldn't be able to incentive the liquidators.
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        //need to CHECK the health factor of the user
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        //We want to burn their DSC "debt" and take their collateral
        uint256 tokenAmounthFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        // and 10% liquidation bonus
        uint256 bonusCollateral = (tokenAmounthFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmounthFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        //Burn DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor(address user) external view returns (uint256 factor) {
        factor = _healthFactor(user);
    }

    //  ==========================================
    //      Private and Internal View Functions
    //  ==========================================

    /**
     * Low level inernal function, do not call unless the function calling it is checking for health fctor been broken.
     */
    function _burnDsc(uint256 amountToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountToBurn);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountToBurn);
    }

    function _redeemCollateral(
        address from,
        address to,
        address tokenColaterallAddress,
        uint256 amountCollateral
    ) private {
        s_collateralDeposited[from][tokenColaterallAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenColaterallAddress, amountCollateral);

        bool success = IERC20(tokenColaterallAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param user addres of the user to check
     * @return totalMinted Total Stablecoins minted
     * @return collValueInUSD Total usd value of diposited collateral
     */
    function _getAccountInformation(address user) private view returns (uint256 totalMinted, uint256 collValueInUSD) {
        totalMinted = s_DSCMinted[user];
        collValueInUSD = getAccountCollateralValueinUsd(user);

        return (totalMinted, collValueInUSD);
    }

    /**
     * Returns how cloes to liquidation a user is
     * If the user goes bellow 1, they can get liquidated
     * @param user address of the user to check
     * @return health factor
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total minted
        // total colaterall VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        uint256 collateralAjusedForThreshold = (collateralValueInUsd * LIQUIDATION_TRESHHOLD) / LIQUIDATION_PRECISION;

        if (totalDscMinted == 0) {
            return type(uint256).max;
        }

        return ((collateralAjusedForThreshold * PRECISION) / totalDscMinted);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreakesHealthFactor(userHealthFactor);
        }
    }

    //  ==========================================
    //      Public And External View Functions
    //  ==========================================
    function getAccountCollateralValueinUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //Loop each colateral and get prices
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    /*     function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , , ) = priceFeed.latestRoundData();

        //the returns value from CL will be price * 1e18
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    } */

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        //get price of token
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountInformation(address user) external view returns (uint256 totalMinted, uint256 collValueInUSD) {
        (totalMinted, collValueInUSD) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBallanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
