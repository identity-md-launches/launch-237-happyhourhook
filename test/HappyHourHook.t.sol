// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HappyHourFixture} from "./HappyHourFixture.sol";
import {HappyHourHook} from "../src/HappyHourHook.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

contract HappyHourHookTest is HappyHourFixture {
    using StateLibrary for IPoolManager;

    function test_PermissionsAreExactly0044() public view {
        assertEq(flagsOf(hook.getHookPermissions()), 0x0044);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x0044);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(key.fee, 3000);
        assertEq(key.tickSpacing, 60);
    }

    function test_RuntimeHasNoEscapeHatch() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }

    function test_ConstructorRejectsWrongBits() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertTrue(uint160(predicted) & Hooks.ALL_HOOK_MASK != 0x0044);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new HappyHourHook(manager);
    }

    function test_RealCreate2DeploymentWithMinedSalt() public {
        bytes32 codeHash = keccak256(abi.encodePacked(type(HappyHourHook).creationCode, abi.encode(manager)));
        for (uint256 salt; salt < 200_000; ++salt) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), codeHash))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != 0x0044) continue;
            HappyHourHook deployed = new HappyHourHook{salt: bytes32(salt)}(manager);
            assertEq(address(deployed), predicted);
            assertEq(address(deployed.poolManager()), address(manager));
            assertEq(flagsOf(deployed.getHookPermissions()), 0x0044);
            return;
        }
        fail("no matching CREATE2 salt");
    }

    function test_FirstExactInputBuyFromTokenOnlyPool() public {
        assertEq(address(manager).balance, 0);
        assertLt(token.totalSupply() - token.balanceOf(address(manager)), 1 gwei);
        assertGt(checkSwap(key, true, -1 ether), 0);
        assertEq(address(manager).balance, 1 ether);
        assertEq(happy.accrued(key.toId(), key.currency0), 0);
        assertClaims(key);
    }

    function test_FirstExactOutputBuyFromTokenOnlyPool() public {
        assertEq(address(manager).balance, 0);
        assertGt(checkSwap(key, true, 100_000 ether), 0);
        assertGt(happy.accrued(key.toId(), key.currency0), 0);
        assertEq(happy.accrued(key.toId(), key.currency1), 0);
        assertClaims(key);
    }

    function test_AllFourSwapTypesAtBothRates() public {
        for (uint256 hour = 15; hour <= 16; ++hour) {
            vm.warp(10 days + hour * 1 hours);
            assertEq(happy.currentFeeBps(), hour == 16 ? 10 : 100);
            assertGt(checkSwap(key, true, -1 ether), 0);
            assertGt(checkSwap(key, true, 100_000 ether), 0);
            assertGt(checkSwap(key, false, -100_000 ether), 0);
            assertGt(checkSwap(key, false, 0.01 ether), 0);
            assertClaims(key);
        }
    }

    function test_HourBoundariesWithRealSwaps() public {
        uint256[4] memory secondsOfDay = [uint256(57_599), 57_600, 61_199, 61_200];
        uint256[4] memory countdown = [uint256(1), 3600, 1, 82_800];
        for (uint256 i; i < 4; ++i) {
            vm.warp(10 days + secondsOfDay[i]);
            assertEq(happy.currentFeeBps(), i == 1 || i == 2 ? 10 : 100);
            assertEq(happy.isHappyHour(), i == 1 || i == 2);
            assertEq(happy.secondsUntilNextChange(), countdown[i]);
            assertGt(checkSwap(key, true, -1 ether), 0);
        }
        assertClaims(key);
    }

    function testFuzz_ClockAcrossDays(uint64 timestamp) public {
        vm.warp(timestamp);
        uint256 timeOfDay = uint256(timestamp) % 86_400;
        bool active = timeOfDay / 3600 == 16;
        assertEq(happy.isHappyHour(), active);
        assertEq(happy.currentFeeBps(), active ? 10 : 100);
        uint256 secondsLeft = happy.secondsUntilNextChange();
        assertGt(secondsLeft, 0);
        assertLe(secondsLeft, 23 hours);
        vm.warp(uint256(timestamp) + secondsLeft - 1);
        assertEq(happy.isHappyHour(), active);
        vm.warp(uint256(timestamp) + secondsLeft);
        assertEq(happy.isHappyHour(), !active);
    }

    function testFuzz_SwapFeeAndConservation(bool zeroForOne, bool exactInput, uint96 rawAmount, uint64 timestamp)
        public
    {
        checkSwap(key, true, -10 ether);
        vm.warp(timestamp);
        uint256 amount = zeroForOne == exactInput
            ? bound(rawAmount, 0.000001 ether, 0.1 ether)
            : bound(rawAmount, 1 ether, 10_000 ether);
        checkSwap(key, zeroForOne, exactInput ? -int256(amount) : int256(amount));
        assertClaims(key);
    }

    function test_DustRoundsDownWithoutClaims() public {
        checkSwap(key, true, -1 ether);
        // Exact-output ETH sale charges token input; at this price use a tiny token input instead.
        // Selling 10 million token-wei yields only a handful of ETH-wei, below either fee threshold.
        assertEq(checkSwap(key, false, -10_000_000), 0);
        vm.warp(10 days + 16 hours);
        assertEq(checkSwap(key, false, -10_000_000), 0);
        assertClaims(key);
    }

    function test_NonNativePoolHasNoFeeOrState() public {
        (currency0, currency1) = deployMintAndApprove2Currencies();
        (PoolKey memory other,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        assertEq(checkSwap(other, true, -0.001 ether), 0);
        assertEq(checkSwap(other, false, -0.001 ether), 0);
        assertEq(checkSwap(other, true, 0.001 ether), 0);
        assertEq(checkSwap(other, false, 0.001 ether), 0);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
    }

    function test_PriceLimitChargesOnlyActualFill() public {
        SwapParams memory params = SwapParams(true, -100 ether, TickMath.getSqrtPriceAtTick(START_TICK - 60));
        vm.recordLogs();
        BalanceDelta net = swapRouter.swap{value: 100 ether}(key, params, PoolSwapTest.TestSettings(false, false), "");
        BalanceDelta raw = rawSwap(vm.getRecordedLogs(), key.toId());
        uint256 fee = abs(raw.amount1()) / 100;
        assertLt(abs(raw.amount0()), 100 ether);
        assertEq(net.amount0(), raw.amount0());
        assertEq(int256(net.amount1()), int256(raw.amount1()) - int256(fee));
        assertEq(happy.accrued(key.toId(), key.currency1), fee);
        assertClaims(key);
    }

    function test_AllCallbacksRefuseUntrustedCaller() public {
        SwapParams memory params = SwapParams(true, -1 ether, MIN_PRICE_LIMIT);
        ModifyLiquidityParams memory liq = ModifyLiquidityParams(tickLower, tickUpper, 1, 0);
        BalanceDelta zero = BalanceDelta.wrap(0);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(this), key, liq, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterAddLiquidity(address(this), key, liq, zero, zero, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(address(this), key, liq, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterRemoveLiquidity(address(this), key, liq, zero, zero, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, zero, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        happy.unlockCallback(abi.encode(key, 1 ether, 1 ether));
    }
}
