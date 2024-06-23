// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
//import {StdInvariant} from "forge-std/StdInvariant.sol";
//import {DeployDSC} from "../../script/DeployDsc.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

//import {HelperConfig} from "../../script/HelperConfig.s.sol";
//import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";

//price feed
//weth/wbtc tokens

contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timesMintisCalled;
    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 MAX_DIPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
    }

    // redeem collateral <-
    function depositCollateral(uint256 collateralSeed, uint256 amountCollalteral) public {
        ERC20Mock collateral = _getCollateralFromsSeed(collateralSeed);
        amountCollalteral = bound(amountCollalteral, 1, MAX_DIPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollalteral);
        collateral.approve(address(engine), amountCollalteral);
        engine.depositCollateral(address(collateral), amountCollalteral);
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalMinted, uint256 collValueInUSD) = engine.getAccountInformation(sender);

        int256 maxDscToMint = (int256(collValueInUSD / 2) - int256(totalMinted));
        if (maxDscToMint < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxDscToMint));

        if (amount == 0) {
            return;
        }

        vm.startPrank(sender);
        engine.mintDsc(amount);
        vm.stopPrank();

        timesMintisCalled++;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collatral = _getCollateralFromsSeed(collateralSeed);
        uint256 maxCollateralToReeem = engine.getCollateralBallanceOfUser(msg.sender, address(collatral));
        amountCollateral = bound(amountCollateral, 0, maxCollateralToReeem);
        if (amountCollateral == 0) {
            return;
        }

        engine.redeemCollateral(address(collatral), amountCollateral);
    }

    function updateCollateralPrice(uint96 newPrice) public{
        int256 newPriceInt = int256(uint256(newPrice));
        ethUsdPriceFeed.updateAnswer(newPriceInt);
    }

    //Helper Functions
    function _getCollateralFromsSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
