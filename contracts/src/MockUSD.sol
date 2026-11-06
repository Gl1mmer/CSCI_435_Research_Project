// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSD
/// @notice Test stablecoin used to pay for tasks. It has no value and exists only so the
///         escrow contracts move a real ERC-20 token in tests and experiments.
contract MockUSD is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    /// @notice 6 decimals like USDC, so 1 mUSD = 1_000_000 units and US$0.001 = 1_000 units.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Anyone can mint. That is acceptable only because this is a test token:
    ///         the experiment runner needs to fund agents without an owner key.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
