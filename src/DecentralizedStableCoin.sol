// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;



// Layout of Contract:
// version - ok
// imports 
import {ERC20Burnable,ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol"; 

// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions


/*
* @title DecentralizedStableCoin
* @author fels21
* Collateral: Ecogenous (ETH & BTC)
* Minting: Algoritmic
* Relative Stability: Peggedd to USD
* 
* This is the contract meant to be governed by DSCEngine. This contract is just the ERC20 implementation of our Stablecoin System 
*
*/

contract DecentralizedStableCoin is ERC20Burnable,Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();


    //Ownable need constructor
    constructor() ERC20("DecentStableCoin","DSC") Ownable(msg.sender) {}
    

    function burn(uint256 _amount) public override onlyOwner{
        uint256 balance = balanceOf(msg.sender);

        if(_amount <= 0){
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }

        if(balance < _amount){
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }

        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns(bool) {
        if(_to == address(0)){
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        if(_amount <= 0 ){
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        _mint(_to,_amount);
        return true;
    }

}