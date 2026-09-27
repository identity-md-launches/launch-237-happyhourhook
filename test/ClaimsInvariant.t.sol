// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HappyHourFixture} from "./HappyHourFixture.sol";
import {HappyHourHook} from "../src/HappyHourHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @dev Random sequences cross fee boundaries, trade all four modes in two pools sharing currencies,
///      and donate. The handler never catches unexpected reverts: fail_on_revert is enabled.
contract ClaimsHandler is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    HappyHourHook private immutable hook;
    PoolSwapTest private immutable router;
    IPoolManager private immutable manager;
    PoolKey[2] private pools;
    uint256 public swaps;
    uint256 public donations;
    uint256[4] public swapModes;

    // Ghost ledger from gross PoolManager swap events and UTC time, never from hook fee events/views.
    mapping(PoolId => mapping(Currency => uint256)) public earned;
    mapping(PoolId => mapping(Currency => uint256)) public donated;

    constructor(
        HappyHourHook hook_,
        PoolSwapTest router_,
        LaunchToken token,
        PoolKey memory a,
        PoolKey memory b,
        uint256 initialTokenFee
    ) {
        hook = hook_;
        router = router_;
        manager = router_.manager();
        pools[0] = a;
        pools[1] = b;
        earned[a.toId()][a.currency1] = initialTokenFee;
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
        _trade(
            pool,
            SwapParams(zeroForOne, specified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            value
        );
        ++swapModes[(zeroForOne ? 0 : 2) + (exactInput ? 0 : 1)];
        ++swaps;
    }

    function _trade(PoolKey memory pool, SwapParams memory params, uint256 value) private {
        uint256 before0 = pool.currency0.balanceOf(address(this));
        uint256 before1 = pool.currency1.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta net = router.swap{value: value}(pool, params, PoolSwapTest.TestSettings(false, false), "");
        _recordFee(pool, params.zeroForOne, params.amountSpecified < 0, net, vm.getRecordedLogs());
        assertEq(int256(pool.currency0.balanceOf(address(this))) - int256(before0), int256(net.amount0()));
        assertEq(int256(pool.currency1.balanceOf(address(this))) - int256(before1), int256(net.amount1()));
        assertEq(
            int256(params.zeroForOne == (params.amountSpecified < 0) ? net.amount0() : net.amount1()),
            params.amountSpecified
        );
        assertEq(manager.currencyDelta(address(router), pool.currency0), 0);
        assertEq(manager.currencyDelta(address(router), pool.currency1), 0);
    }

    function _recordFee(PoolKey memory pool, bool buy, bool exactInput, BalanceDelta net, Vm.Log[] memory logs)
        private
    {
        uint256 matches;
        BalanceDelta raw;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager)
                    && logs[i].topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) {
                assertEq(logs[i].topics[1], PoolId.unwrap(pool.toId()));
                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                raw = toBalanceDelta(amount0, amount1);
                ++matches;
            }
        }
        assertEq(matches, 1, "one real swap per handler action");
        bool chargeEth = exactInput ? !buy : buy;
        int256 gross = chargeEth ? int256(raw.amount0()) : int256(raw.amount1());
        uint256 fee = uint256(gross < 0 ? -gross : gross) * ((block.timestamp / 1 hours) % 24 == 16 ? 10 : 100) / 10_000;
        earned[pool.toId()][chargeEth ? pool.currency0 : pool.currency1] += fee;
        assertEq(int256(net.amount0()), int256(raw.amount0()) - int256(chargeEth ? fee : 0));
        assertEq(int256(net.amount1()), int256(raw.amount1()) - int256(chargeEth ? 0 : fee));
    }

    function donate(uint256 poolSeed) external {
        PoolKey memory pool = pools[poolSeed % 2];
        PoolId id = pool.toId();
        uint256 amount0 = earned[id][pool.currency0] - donated[id][pool.currency0];
        uint256 amount1 = earned[id][pool.currency1] - donated[id][pool.currency1];
        if (amount0 == 0 && amount1 == 0) {
            vm.expectRevert(HappyHourHook.NothingAccrued.selector);
            hook.donateFees(pool);
            return;
        }
        uint128 liquidity = manager.getLiquidity(id);
        (uint256 before0, uint256 before1) = manager.getFeeGrowthGlobals(id);
        hook.donateFees(pool);
        (uint256 after0, uint256 after1) = manager.getFeeGrowthGlobals(id);
        assertEq(after0 - before0, FullMath.mulDiv(amount0, 1 << 128, liquidity));
        assertEq(after1 - before1, FullMath.mulDiv(amount1, 1 << 128, liquidity));
        donated[id][pool.currency0] += amount0;
        donated[id][pool.currency1] += amount1;
        assertEq(hook.accrued(id, pool.currency0), 0);
        assertEq(hook.accrued(id, pool.currency1), 0);
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
        uint256 initialTokenFee = checkSwap(key, true, -100 ether);
        other = key;
        other.fee = 500;
        manager.initialize(other, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(other, ModifyLiquidityParams(-120, 120, 100 ether, 0), "");
        handler = new ClaimsHandler(happy, swapRouter, token, key, other, initialTokenFee);
        token.transfer(address(handler), 10_000_000 ether);
        vm.deal(address(handler), 1000 ether);
        initialEth = address(this).balance + address(handler).balance + address(manager).balance;
        // Exercise every mode in both pools and a repeated donation before random interleavings.
        // Counters below keep this deterministic coverage explicit.
        for (uint256 pool; pool < 2; ++pool) {
            for (uint256 mode; mode < 4; ++mode) {
                handler.trade(pool, mode < 2, mode % 2 == 0, 42);
            }
        }
        handler.donate(0);
        handler.donate(0);
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

    function invariant_AccrualEqualsIndependentFeesMinusDonations() public view {
        for (uint256 i; i < 2; ++i) {
            PoolKey memory pool = i == 0 ? key : other;
            PoolId id = pool.toId();
            assertEq(
                happy.accrued(id, pool.currency0),
                handler.earned(id, pool.currency0) - handler.donated(id, pool.currency0)
            );
            assertEq(
                happy.accrued(id, pool.currency1),
                handler.earned(id, pool.currency1) - handler.donated(id, pool.currency1)
            );
        }
    }

    function invariant_EverySwapModeAndDonationWereExercised() public view {
        for (uint256 i; i < 4; ++i) {
            assertGe(handler.swapModes(i), 2);
        }
        assertGe(handler.donations(), 1);
    }

    function invariant_NoUnsettledDebtOrHookCustody() public view {
        assertEq(manager.currencyDelta(address(happy), key.currency0), 0);
        assertEq(manager.currencyDelta(address(happy), key.currency1), 0);
        assertEq(manager.currencyDelta(address(swapRouter), key.currency0), 0);
        assertEq(manager.currencyDelta(address(swapRouter), key.currency1), 0);
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
