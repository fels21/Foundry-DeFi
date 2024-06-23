# Stablecoin Implementation

This project is an implementation of a stablecoin based on the [Cyfrin Foundry DeFi Stablecoin](https://github.com/Cyfrin/foundry-defi-stablecoin-f23) project. It is part of the full Solidity course provided by Cyfrin, which can be found [here](https://github.com/Cyfrin/foundry-full-course-f23) or [here](https://updraft.cyfrin.io/courses/advanced-foundry/develop-defi-protocol/). This is a personal learning project aimed at enhancing my understanding of Solidity and decentralized finance (DeFi).

## Stablecoin Features

1. **Relative Stability: Anchored or Pegged**
   - Utilizes Chainlink price feeds.
   - Includes functions to exchange ETH and BTC for USD.

2. **Stability Mechanism (Minting): Algorithmic (Decentralized)**
   - Users can only mint stablecoins if they provide sufficient collateral.

3. **Collateral: Exogenous (Crypto)**
   - Accepts wETH (Wrapped Ether).
   - Accepts wBTC (Wrapped Bitcoin).

## Design Guidelines

### Layout of Contract:
- **Version**
- **Imports**
- **Interfaces, Libraries, Contracts**
- **Errors**
- **Type Declarations**
- **State Variables**
- **Events**
- **Modifiers**
- **Functions**

### Layout of Functions:
- **Constructor**
- **Receive Function** (if exists)
- **Fallback Function** (if exists)
- **External Functions**
- **Public Functions**
- **Internal Functions**
- **Private Functions**
- **View & Pure Functions**

## Getting Started

To get started with the project, clone the repository and follow the instructions provided in the course materials.

## License

This project is licensed under the MIT License. See the LICENSE file for details.