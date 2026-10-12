// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;

    /// @dev Stands in for the launch factory: whoever deploys the token receives the whole supply.
    address internal factory = makeAddr("factory");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    LaunchToken internal token;

    function setUp() public {
        vm.prank(factory);
        token = new LaunchToken();
    }

    function test_mintsThePolicySupplyToTheDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply");
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000, "supply in minor units");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY, "constant");
        assertEq(token.balanceOf(factory), SUPPLY, "deployer holds everything");
    }

    function test_metadata() public view {
        assertEq(token.name(), "Skyline Loot");
        assertEq(token.symbol(), "LOOT");
        assertEq(token.decimals(), 18);
    }

    function test_transferMovesExactlyTheAmount() public {
        uint256 amount = 1_234 ether;
        vm.prank(factory);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(factory), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY, "transfer does not change supply");

        vm.prank(alice);
        assertTrue(token.transfer(bob, 234 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(bob), 234 ether);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(factory);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(factory), SUPPLY);
    }

    function test_transferRevertsWhenBalanceIsInsufficient() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(factory);
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 4 ether);
        vm.prank(bob);
        token.transferFrom(alice, bob, 4 ether);
        assertEq(token.balanceOf(bob), 4 ether);
        assertEq(token.allowance(alice, bob), 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    /// @dev No mint, owner, pause or upgrade entry points exist: every such selector reverts and
    /// the supply never moves, even for the deployer.
    function test_noAdminSurfaceChangesSupply() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burnFrom(address,uint256)",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)",
            "setMinter(address)",
            "initialize(address)"
        ];
        address attacker = makeAddr("attacker");
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool okAttacker,) = address(token).call(data);
            assertFalse(okAttacker, signatures[i]);
            vm.prank(factory);
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
