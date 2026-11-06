// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockUSD} from "../src/MockUSD.sol";

contract MockUSDTest is Test {
    MockUSD token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new MockUSD();
    }

    function test_NameSymbolDecimals() public view {
        assertEq(token.name(), "Mock USD");
        assertEq(token.symbol(), "mUSD");
        assertEq(token.decimals(), 6);
    }

    function test_StartsWithNoSupply() public view {
        assertEq(token.totalSupply(), 0);
    }

    function test_AnyoneCanMint() public {
        vm.prank(bob);
        token.mint(alice, 5_000_000);

        assertEq(token.balanceOf(alice), 5_000_000);
        assertEq(token.totalSupply(), 5_000_000);
    }

    function test_TransferMovesBalance() public {
        token.mint(alice, 1_000);

        vm.prank(alice);
        token.transfer(bob, 400);

        assertEq(token.balanceOf(alice), 600);
        assertEq(token.balanceOf(bob), 400);
    }
}
