// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_MetadataAndEntireFixedSupplyToDeployer() public view {
        assertEq(token.name(), "Happy Hour");
        assertEq(token.symbol(), "HAPY");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_ConstructorUsesActualDeployer() public {
        vm.prank(ALICE);
        LaunchToken another = new LaunchToken();
        assertEq(another.balanceOf(ALICE), another.totalSupply());
        assertEq(another.balanceOf(address(this)), 0);
    }

    function testFuzz_TransfersAndAllowanceConserveSupply(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, token.totalSupply());
        assertTrue(token.transfer(ALICE, amount));
        vm.prank(ALICE);
        assertTrue(token.approve(BOB, amount));
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, amount));
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
        assertEq(token.allowance(ALICE, BOB), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_InfiniteAllowanceDoesNotDecrease() public {
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(address(this), ALICE, 1 ether);
        assertEq(token.allowance(address(this), BOB), type(uint256).max);
    }

    function test_InsufficientBalanceAndAllowanceRevertWithoutChangingBalances() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        vm.prank(BOB);
        token.transferFrom(address(this), ALICE, 1);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_ZeroRecipientIsRejected() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_NoMintAdminOrUpgradeEntryPoints() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, type(uint128).max);
            (bool deployerSuccess,) = address(token).call(data);
            assertFalse(deployerSuccess);
            vm.prank(ALICE);
            (bool attackerSuccess,) = address(token).call(data);
            assertFalse(attackerSuccess);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_RuntimeHasNoUpgradeOrDestructionOpcodes() public view {
        bytes memory code = address(token).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}
