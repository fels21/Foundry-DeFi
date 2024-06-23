// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDsc.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 private constant PRECISION = 1e18;
    uint256 public constant MAX_COLATERAL_VALUE = 20000 * PRECISION; //10 Eth VALUE
    uint256 public constant DEFAULT_MINTED_TOKENS = MAX_COLATERAL_VALUE / 10; // 10% OF allocation

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, ) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(address(engine), STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE * 10);
    }

    // ========================
    // 		Constructor test
    // ========================

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLenghtdoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAdressAndPriceFeedAdressesMustBeSameLenght.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    // ====================================
    // 		Deposit Collateral Test
    // ====================================

    function testRevertsIfCollateralZero() public {
        vm.prank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertIfTokenIsNotAllowed() public {
        ERC20Mock ftokenMock = new ERC20Mock("TOKEN", "TOKEN", msg.sender, 1000e18);
        address ftokenAddr = address(ftokenMock);

        ERC20Mock(ftokenAddr).mint(USER, STARTING_ERC20_BALANCE);

        vm.prank(USER);
        ERC20Mock(ftokenAddr).approve(address(engine), AMOUNT_COLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(ftokenAddr), 1e18);
        vm.stopPrank();
    }

    //Mofifier to diposit 10 eth as colateral automaticly
    modifier depostedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depostedCollateral {
        (uint256 totalDSCMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDSCMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLATERAL, expectedDepositAmount);
    }

    // ========================
    // 		Mint Test
    // ========================

    function testSuccesfulMinting() public depostedCollateral {
        vm.prank(USER);
        engine.mintDsc(DEFAULT_MINTED_TOKENS);

        (uint256 mintedAmount, ) = engine.getAccountInformation(USER);
        assertEq(mintedAmount, DEFAULT_MINTED_TOKENS);
    }

    function testRevertMintingOfZero() public depostedCollateral {
        vm.prank(USER);
        //(uint256 mintedAmount, ) = engine.getAccountInformation(USER);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mintDsc(0);
    }

    function testRevertWhileExceededMaxAmountOfMint() public depostedCollateral {
        uint256 amountTokensToMint = MAX_COLATERAL_VALUE;
        (, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        vm.prank(USER);
        console.log("Max to mint");
        console.log(collateralValueInUsd);
        uint256 expectedHF = PRECISION / 2; //0.5 HF
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakesHealthFactor.selector, expectedHF));
        engine.mintDsc(amountTokensToMint);
    }

    // ===========================================
    // 		depositCollateralAndMintDsc
    // ===========================================
    // Deposited 10 eth
    // colateral value 10 * 2k usd
    // max value 50% -> 20 000 / 2 -> 10 k
    // Minted 2k
    // hf expected is  5e18
    function testDepositCollateralAndMintSuccesfully() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLATERAL, MAX_COLATERAL_VALUE / 10); //2000 uusdt minted
        vm.stopPrank();

        uint256 healthFactorAfterDeposit = engine.getHealthFactor(USER);
        console.log("MaxCollateral readeble is %s", MAX_COLATERAL_VALUE / PRECISION);
        console.log("NOW HF IS %s", healthFactorAfterDeposit / PRECISION);
        assertEq(healthFactorAfterDeposit, 5 * PRECISION);
    }

    // ============================
    // 		redeem Collateral test
    // ============================

    //Mint 10% of allowance
    modifier mintedDsc() {
        vm.startPrank(USER);
        engine.mintDsc(DEFAULT_MINTED_TOKENS);
        vm.stopPrank();
        _;
    }

    function testRevertsIfRedeemIsZero() public {
        vm.prank(USER);
        DecentralizedStableCoin(dsc).approve(address(engine), AMOUNT_COLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateral(address(dsc), 0);
        vm.stopPrank();
    }

    // Deposited 10 eth
    // colateral value 10 * 2k usd
    // max value 50% -> 20 000 / 2 -> 10 k
    // Minted 2k
    // hf expected is  5e18
    // Max safe collateral to widraw 8eth with 1 HF
    function testWidrawMaxSafeCollateral() public depostedCollateral mintedDsc {
        uint256 safeWidrawAmount = 8 ether;
        vm.startPrank(USER);
        engine.redeemCollateral(weth, safeWidrawAmount);
        vm.stopPrank();

        uint256 healthFactorAfterDeposit = engine.getHealthFactor(USER);
        assertEq(healthFactorAfterDeposit, 1 * PRECISION);
    }

    function testRevertOnExededWidraw() public depostedCollateral mintedDsc {
        uint256 notSafeWidrawAmount = 9 ether;
        uint256 expectedHF = PRECISION / 2; //0.5 HF
        vm.startPrank(USER);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakesHealthFactor.selector, expectedHF));
        engine.redeemCollateral(weth, notSafeWidrawAmount);

        vm.stopPrank();
    }

    function testRedeemCollateralSuccesfuly() public depostedCollateral {
        vm.startPrank(USER);
        engine.redeemCollateral(weth, AMOUNT_COLATERAL);
        vm.stopPrank();

        (, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        assert(collateralValueInUsd == 0);
    }

    // ========================
    // 		Burn Test
    // ========================

    function testSuccesfulBurn() public depostedCollateral mintedDsc {
        (uint256 initalMinted, ) = engine.getAccountInformation(USER);
        assertEq(initalMinted, DEFAULT_MINTED_TOKENS);

        vm.startPrank(USER);
        DecentralizedStableCoin(dsc).approve(address(engine), DEFAULT_MINTED_TOKENS);
        engine.burnDsc(DEFAULT_MINTED_TOKENS);

        vm.stopPrank();

        (uint256 afterBurn, ) = engine.getAccountInformation(USER);
        assertEq(afterBurn, 0);
    }

    function testBurnZeroTokens() public depostedCollateral mintedDsc {
        (uint256 initalMinted, ) = engine.getAccountInformation(USER);
        assertEq(initalMinted, DEFAULT_MINTED_TOKENS);

        vm.startPrank(USER);
        DecentralizedStableCoin(dsc).approve(address(engine), 0);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    modifier safeWidrawed() {
        uint256 safeWidrawAmount = 8 ether;
        vm.startPrank(USER);
        engine.redeemCollateral(weth, safeWidrawAmount);
        vm.stopPrank();
        _;
    }

    function testBurnMoreTokens() public depostedCollateral mintedDsc safeWidrawed {
        //assertEq(initalMinted, DEFAULT_MINTED_TOKENS);
        uint256 tokesnToBurn = DEFAULT_MINTED_TOKENS * 10;
        vm.startPrank(USER);
        DecentralizedStableCoin(dsc).approve(address(engine), tokesnToBurn);
        vm.expectRevert();
        engine.burnDsc(tokesnToBurn);

        vm.stopPrank();
    }

    // ================================================
    // 		    redeem Collateral For Dsc test
    // ================================================

    function testRedeemAndBurnOk() public depostedCollateral mintedDsc {
        vm.startPrank(USER);
        DecentralizedStableCoin(dsc).approve(address(engine), DEFAULT_MINTED_TOKENS);

        engine.redeemCollateralForDsc(weth, AMOUNT_COLATERAL, DEFAULT_MINTED_TOKENS);
        vm.stopPrank();
        (uint256 tokensMinted, uint256 collateralDiposited) = engine.getAccountInformation(USER);
        assertEq(tokensMinted, 0);
        assertEq(collateralDiposited, 0);
    }

    // ========================
    // 		Liquidation test
    // ========================

    /*     function testChangeEthPrice() public depostedCollateral mintedDsc {
        logUserHfactor(USER);
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(200e8);
        logUserHfactor(USER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLATERAL * 5);
        engine.depositCollateral(weth, AMOUNT_COLATERAL * 5);
        engine.mintDsc(DEFAULT_MINTED_TOKENS * 2);

        engine.liquidate(weth, USER, DEFAULT_MINTED_TOKENS);
        vm.stopPrank();
    } */

    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));

        uint256 amountToMint = 100 ether;
        uint256 collateralToCover;
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLATERAL);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLATERAL, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        mockDsc.approve(address(mockDsce), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockDsce.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    function logUserHfactor(address user) internal view {
        uint256 hf = (engine.getHealthFactor(user)) / PRECISION;
        console.log("Atual hf is: %s", hf);
    }

    // ========================
    // 		Price Feed test
    // ========================

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        //15e18 *2000/eth = 30,000e18 usd
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    function testgetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;

        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedWeth, actualWeth);
    }

    //Todo Tests
}
