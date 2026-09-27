// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HappyHourFixture} from "./HappyHourFixture.sol";
import {HappyHourHook} from "../src/HappyHourHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";

contract NestedDonation is IUnlockCallback {
    IPoolManager private immutable manager;
    HappyHourHook private immutable hook;

    constructor(IPoolManager manager_, HappyHourHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function attempt(PoolKey memory key) external {
        manager.unlock(abi.encode(key));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        hook.donateFees(abi.decode(data, (PoolKey)));
        return "";
    }
}

contract DonationTest is HappyHourFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function test_DonationBurnsClaimsAndCreditsExactlyTheAccruedAmounts() public {
        accrueBoth();
        PoolId id = key.toId();
        uint256 amount0 = happy.accrued(id, key.currency0);
        uint256 amount1 = happy.accrued(id, key.currency1);
        uint128 liquidity = manager.getLiquidity(id);
        (uint256 before0, uint256 before1) = manager.getFeeGrowthGlobals(id);
        uint256 ethBefore = address(manager).balance;
        uint256 tokenBefore = token.balanceOf(address(manager));

        vm.expectEmit(true, false, false, true, address(happy));
        emit HappyHourHook.Donated(id, amount0, amount1);
        vm.prank(address(0xBEEF));
        happy.donateFees(key);

        (uint256 after0, uint256 after1) = manager.getFeeGrowthGlobals(id);
        assertEq(after0 - before0, FullMath.mulDiv(amount0, Q128, liquidity));
        assertEq(after1 - before1, FullMath.mulDiv(amount1, Q128, liquidity));
        assertEq(happy.accrued(id, key.currency0), 0);
        assertEq(happy.accrued(id, key.currency1), 0);
        assertEq(address(manager).balance, ethBefore);
        assertEq(token.balanceOf(address(manager)), tokenBefore);
        assertEq(manager.currencyDelta(address(happy), key.currency0), 0);
        assertEq(manager.currencyDelta(address(happy), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertClaims(key);
        vm.expectRevert(HappyHourHook.NothingAccrued.selector);
        happy.donateFees(key);
    }

    function test_DonationWorksWithOnlyEitherCurrencyAccrued() public {
        checkSwap(key, true, -1 ether);
        happy.donateFees(key);
        assertClaims(key);
        assertEq(happy.accrued(key.toId(), key.currency1), 0);
        checkSwap(key, false, -100_000 ether);
        happy.donateFees(key);
        assertClaims(key);
        assertEq(happy.accrued(key.toId(), key.currency0), 0);
    }

    function test_NothingAccruedReverts() public {
        vm.expectRevert(HappyHourHook.NothingAccrued.selector);
        happy.donateFees(key);
    }

    function test_WrongHookAndWrongPoolCannotSpendClaims() public {
        accrueBoth();
        PoolKey memory wrong = key;
        wrong.hooks = IHooks(address(0xBEEF));
        vm.expectRevert(HappyHourHook.WrongHook.selector);
        happy.donateFees(wrong);
        wrong = key;
        wrong.fee = 500;
        vm.expectRevert(HappyHourHook.NothingAccrued.selector);
        happy.donateFees(wrong);
        assertClaims(key);
    }

    function test_NoInRangeLiquidityRevertsAndRestoresClaimsThenRetrySucceeds() public {
        accrueBoth();
        PoolId id = key.toId();
        uint256 amount0 = happy.accrued(id, key.currency0);
        uint256 amount1 = happy.accrued(id, key.currency1);
        uint128 liquidity = manager.getLiquidity(id);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams(tickLower, tickUpper, -int256(uint256(liquidity)), 0), ""
        );
        assertEq(manager.getLiquidity(id), 0);
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(id);
        vm.expectRevert(Pool.NoLiquidityToReceiveFees.selector);
        happy.donateFees(key);
        assertEq(happy.accrued(id, key.currency0), amount0);
        assertEq(happy.accrued(id, key.currency1), amount1);
        (uint256 after0, uint256 after1) = manager.getFeeGrowthGlobals(id);
        assertEq(after0, growth0);
        assertEq(after1, growth1);
        assertClaims(key);

        modifyLiquidityRouter.modifyLiquidity{value: 20 ether}(
            key, ModifyLiquidityParams(tickLower, tickUpper, int256(uint256(liquidity)), 0), ""
        );
        happy.donateFees(key);
        assertEq(happy.accrued(id, key.currency0), 0);
        assertEq(happy.accrued(id, key.currency1), 0);
        assertClaims(key);
    }

    function test_NestedUnlockCannotEraseAccruedFees() public {
        accrueBoth();
        uint256 amount0 = happy.accrued(key.toId(), key.currency0);
        uint256 amount1 = happy.accrued(key.toId(), key.currency1);
        NestedDonation nested = new NestedDonation(manager, happy);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        nested.attempt(key);
        assertEq(happy.accrued(key.toId(), key.currency0), amount0);
        assertEq(happy.accrued(key.toId(), key.currency1), amount1);
        assertClaims(key);
        happy.donateFees(key);
        assertClaims(key);
    }

    function test_PoolsSharingCurrenciesKeepIndependentAccrual() public {
        accrueBoth();
        PoolKey memory other = key;
        other.fee = 500;
        manager.initialize(other, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(other, ModifyLiquidityParams(-120, 120, 100 ether, 0), "");
        checkSwap(other, true, -0.001 ether);
        checkSwap(other, false, -0.001 ether);
        uint256 original0 = happy.accrued(key.toId(), key.currency0);
        uint256 original1 = happy.accrued(key.toId(), key.currency1);
        assertEq(
            manager.balanceOf(address(happy), key.currency0.toId()),
            original0 + happy.accrued(other.toId(), key.currency0)
        );
        assertEq(
            manager.balanceOf(address(happy), key.currency1.toId()),
            original1 + happy.accrued(other.toId(), key.currency1)
        );
        (uint256 before0, uint256 before1) = manager.getFeeGrowthGlobals(key.toId());
        happy.donateFees(other);
        (uint256 after0, uint256 after1) = manager.getFeeGrowthGlobals(key.toId());
        assertEq(before0, after0);
        assertEq(before1, after1);
        assertEq(happy.accrued(key.toId(), key.currency0), original0);
        assertEq(happy.accrued(key.toId(), key.currency1), original1);
        assertEq(happy.accrued(other.toId(), key.currency0), 0);
        assertEq(happy.accrued(other.toId(), key.currency1), 0);
        assertClaims(key);
    }

    function test_JitLiquidityCapturesItsShareOfPastFees() public {
        accrueBoth();
        PoolId id = key.toId();
        uint128 jitLiquidity = manager.getLiquidity(id) / 1000;
        bytes32 jitSalt = keccak256("JIT position");
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(
            key, ModifyLiquidityParams(tickLower, tickUpper, int256(uint256(jitLiquidity)), jitSalt), ""
        );
        uint256 amount0 = happy.accrued(id, key.currency0);
        uint256 amount1 = happy.accrued(id, key.currency1);
        uint128 totalLiquidity = manager.getLiquidity(id);
        happy.donateFees(key);
        BalanceDelta jitFees =
            modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(tickLower, tickUpper, 0, jitSalt), "");
        assertEq(
            abs(jitFees.amount0()), FullMath.mulDiv(FullMath.mulDiv(amount0, Q128, totalLiquidity), jitLiquidity, Q128)
        );
        assertEq(
            abs(jitFees.amount1()), FullMath.mulDiv(FullMath.mulDiv(amount1, Q128, totalLiquidity), jitLiquidity, Q128)
        );
        assertGt(jitFees.amount0(), 0);
        assertGt(jitFees.amount1(), 0);
        assertClaims(key);
    }

    function test_ExistingLpCanCollectTheDonationWithOnlyCoreRoundingDust() public {
        accrueBoth();
        ModifyLiquidityParams memory poke = ModifyLiquidityParams(tickLower, tickUpper, 0, 0);
        // Collect the ordinary 0.3% LP swap fees before isolating the donation proceeds.
        modifyLiquidityRouter.modifyLiquidity(key, poke, "");
        uint256 amount0 = happy.accrued(key.toId(), key.currency0);
        uint256 amount1 = happy.accrued(key.toId(), key.currency1);
        happy.donateFees(key);
        BalanceDelta fees = modifyLiquidityRouter.modifyLiquidity(key, poke, "");
        assertApproxEqAbs(abs(fees.amount0()), amount0, 1);
        assertApproxEqAbs(abs(fees.amount1()), amount1, 1);
        assertClaims(key);
    }
}
