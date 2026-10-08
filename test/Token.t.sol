// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";

contract TokenTest is Test {
    SIMDTEST token;
    address alice;
    address bob;

    function setUp() public {
        token = new SIMDTEST();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function test_entireSupplyToDeployerNoTax() public {
        assertEq(token.name(), "SIMDTEST");
        assertEq(token.symbol(), "SIMDTEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        token.transfer(alice, 9e26);
        assertEq(token.balanceOf(alice), 9e26);
        assertEq(token.balanceOf(address(this)), 1e26);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_noAdminOrMint() public {
        bytes4[4] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("upgradeTo(address)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], alice, 1 ether));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
    }

    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: extended.fuzz.runs = 2000
    function testFuzz_allowanceCannotBeExceeded(uint96 raw) public {
        uint256 amount = bound(raw, 1, 1e27);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.approve(bob, amount - 1);
        vm.startPrank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, amount - 1, amount)
        );
        token.transferFrom(alice, bob, amount);
        token.transferFrom(alice, bob, amount - 1);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(bob), amount - 1);
        assertEq(token.totalSupply(), 1e27);
    }
}
