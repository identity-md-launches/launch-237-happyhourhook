// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHookTest} from "./BaseHookTest.sol";
import {HappyHourHook} from "../src/HappyHourHook.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

abstract contract HappyHourFixture is BaseHookTest {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    HappyHourHook internal happy;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant FEE_EVENT = keccak256("FeeTaken(bytes32,address,uint256,uint24)");
    uint256 internal constant Q128 = 1 << 128;

    struct SwapSnapshot {
        uint256 balance0;
        uint256 balance1;
        uint256 accrued0;
        uint256 accrued1;
    }

    function setUp() public virtual override {
        super.setUp();
        happy = HappyHourHook(address(hook));
        vm.warp(10 days + 12 hours);
    }

    /// @dev Compare against the real manager's pre-hook Swap event, not an inverse fee formula.
    function checkSwap(PoolKey memory pool, bool zeroForOne, int256 specified) internal returns (uint256 fee) {
        SwapSnapshot memory beforeSwap = SwapSnapshot(
            pool.currency0.balanceOf(address(this)),
            pool.currency1.balanceOf(address(this)),
            happy.accrued(pool.toId(), pool.currency0),
            happy.accrued(pool.toId(), pool.currency1)
        );
        vm.recordLogs();
        BalanceDelta net = zeroForOne && pool.currency0.isAddressZero() && specified > 0
            ? swapNativeInput(pool, zeroForOne, specified, "", 10 ether)
            : swap(pool, zeroForOne, specified, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        BalanceDelta raw = rawSwap(logs, pool.toId());
        bool unspecifiedIs1 = (specified < 0) == zeroForOne;
        fee = pool.currency0.isAddressZero()
            ? abs(unspecifiedIs1 ? raw.amount1() : raw.amount0()) * expectedFeeBps() / 10_000
            : 0;

        assertEq(int256(net.amount0()), int256(raw.amount0()) - int256(unspecifiedIs1 ? 0 : fee));
        assertEq(int256(net.amount1()), int256(raw.amount1()) - int256(unspecifiedIs1 ? fee : 0));
        // These trades are small enough to fill. Check that the specified side stays exact.
        assertEq(int256(zeroForOne == (specified < 0) ? net.amount0() : net.amount1()), specified);
        assertEq(int256(pool.currency0.balanceOf(address(this))) - int256(beforeSwap.balance0), net.amount0());
        assertEq(int256(pool.currency1.balanceOf(address(this))) - int256(beforeSwap.balance1), net.amount1());
        assertEq(happy.accrued(pool.toId(), pool.currency0), beforeSwap.accrued0 + (unspecifiedIs1 ? 0 : fee));
        assertEq(happy.accrued(pool.toId(), pool.currency1), beforeSwap.accrued1 + (unspecifiedIs1 ? fee : 0));
        checkFeeEvent(logs, pool, unspecifiedIs1 ? pool.currency1 : pool.currency0, fee);
        assertEq(manager.currencyDelta(address(hook), pool.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), pool.currency1), 0);
        assertEq(manager.currencyDelta(address(swapRouter), pool.currency0), 0);
        assertEq(manager.currencyDelta(address(swapRouter), pool.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    function rawSwap(Vm.Log[] memory logs, PoolId id) internal view returns (BalanceDelta) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                assertEq(logs[i].topics[1], PoolId.unwrap(id));
                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return toBalanceDelta(amount0, amount1);
            }
        }
        revert("missing manager Swap event");
    }

    function checkFeeEvent(Vm.Log[] memory logs, PoolKey memory pool, Currency currency, uint256 fee) internal view {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != FEE_EVENT) continue;
            ++count;
            assertEq(logs[i].topics[1], PoolId.unwrap(pool.toId()));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(Currency.unwrap(currency)))));
            (uint256 eventFee, uint24 bps) = abi.decode(logs[i].data, (uint256, uint24));
            assertEq(eventFee, fee);
            assertEq(bps, expectedFeeBps());
        }
        assertEq(count, fee == 0 ? 0 : 1);
    }

    function assertClaims(PoolKey memory pool) internal view {
        assertEq(manager.balanceOf(address(hook), pool.currency0.toId()), happy.accrued(pool.toId(), pool.currency0));
        assertEq(manager.balanceOf(address(hook), pool.currency1.toId()), happy.accrued(pool.toId(), pool.currency1));
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(address(manager)), token.totalSupply());
    }

    function accrueBoth() internal {
        checkSwap(key, true, -10 ether);
        checkSwap(key, false, -100_000 ether);
        assertGt(happy.accrued(key.toId(), key.currency0), 0);
        assertGt(happy.accrued(key.toId(), key.currency1), 0);
        assertClaims(key);
    }

    function abs(int128 value) internal pure returns (uint256) {
        return value < 0 ? uint256(-int256(value)) : uint256(int256(value));
    }

    /// @dev Independent oracle: do not let a wrong hook view validate its own swap fee.
    function expectedFeeBps() internal view returns (uint24) {
        return (block.timestamp / 1 hours) % 24 == 16 ? 10 : 100;
    }
}
