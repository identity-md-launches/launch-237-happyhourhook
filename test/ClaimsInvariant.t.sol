// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HappyHourFixture} from "./HappyHourFixture.sol";
import {HappyHourHook} from "../src/HappyHourHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev Random sequences cross fee boundaries, trade all four modes in two pools sharing currencies,
///      and donate. The handler never catches unexpected reverts: fail_on_revert is enabled.
contract ClaimsHandler is Test {
    HappyHourHook private immutable hook;
    PoolSwapTest private immutable router;
    PoolKey[2] private pools;
    uint256 public swaps;
    uint256 public donations;

    constructor(HappyHourHook hook_, PoolSwapTest router_, LaunchToken token, PoolKey memory a, PoolKey memory b) {
        hook = hook_;
        router = router_;
        pools[0] = a;
        pools[1] = b;
        token.approve(address(router), type(uint256).max);
    }

    function trade(uint256 poolSeed, bool zeroForOne, bool exactInput, uint256 size) external {
        uint256 index = poolSeed % 2;
        PoolKey memory pool = pools[index];
        // Main pool is ~one million HAPY/ETH, the auxiliary pool starts at 1:1.
        bool specifiedIsToken = zeroForOne != exactInput;
        uint256 amount =
            index == 0 && specifiedIsToken ? bound(size, 1 ether, 100 ether) : bound(size, 0.000001 ether, 0.001 ether);
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        uint256 value = zeroForOne ? (exactInput ? amount : 1 ether) : 0;
        router.swap{value: value}(
            pool,
            SwapParams(zeroForOne, specified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        ++swaps;
    }

    function donate(uint256 poolSeed) external {
        PoolKey memory pool = pools[poolSeed % 2];
        if (hook.accrued(pool.toId(), pool.currency0) == 0 && hook.accrued(pool.toId(), pool.currency1) == 0) return;
        hook.donateFees(pool);
        ++donations;
    }

    function advanceTime(uint32 secondsForward) external {
        vm.warp(block.timestamp + uint256(secondsForward) % 2 days);
    }

    receive() external payable {}
}

contract ClaimsInvariantTest is HappyHourFixture {
    using TransientStateLibrary for IPoolManager;
    ClaimsHandler private handler;
    PoolKey private other;
    uint256 private initialEth;

    function setUp() public override {
        super.setUp();
        checkSwap(key, true, -100 ether);
        other = key;
        other.fee = 500;
        manager.initialize(other, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(other, ModifyLiquidityParams(-120, 120, 100 ether, 0), "");
        handler = new ClaimsHandler(happy, swapRouter, token, key, other);
        token.transfer(address(handler), 10_000_000 ether);
        vm.deal(address(handler), 1000 ether);
        initialEth = address(this).balance + address(handler).balance + address(manager).balance;
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = ClaimsHandler.trade.selector;
        selectors[1] = ClaimsHandler.donate.selector;
        selectors[2] = ClaimsHandler.advanceTime.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_ClaimsEqualSumOfAccruedAcrossPoolsForBothCurrencies() public view {
        assertEq(
            manager.balanceOf(address(happy), key.currency0.toId()),
            happy.accrued(key.toId(), key.currency0) + happy.accrued(other.toId(), key.currency0)
        );
        assertEq(
            manager.balanceOf(address(happy), key.currency1.toId()),
            happy.accrued(key.toId(), key.currency1) + happy.accrued(other.toId(), key.currency1)
        );
    }

    function invariant_NoUnsettledDebtOrHookCustody() public view {
        assertEq(manager.currencyDelta(address(happy), key.currency0), 0);
        assertEq(manager.currencyDelta(address(happy), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertEq(address(happy).balance, 0);
        assertEq(token.balanceOf(address(happy)), 0);
        assertEq(address(swapRouter).balance, 0);
    }

    function invariant_TotalTokenAndEthConserved() public view {
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(handler)) + token.balanceOf(address(manager)),
            token.totalSupply()
        );
        assertEq(address(this).balance + address(handler).balance + address(manager).balance, initialEth);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
