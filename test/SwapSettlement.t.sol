// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HappyHourFixture} from "./HappyHourFixture.sol";
import {SettlementProbe} from "./helpers/SettlementProbe.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract SwapSettlementTest is HappyHourFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    SettlementProbe private probe;

    struct Snapshot {
        uint256 user0;
        uint256 user1;
        uint256 manager0;
        uint256 manager1;
        uint256 accrued0;
        uint256 accrued1;
    }

    function setUp() public override {
        super.setUp();
        probe = new SettlementProbe(manager);
        token.approve(address(probe), type(uint256).max);
    }

    function test_AllFourModesSettleAtEveryHourBoundary() public {
        checkSwap(key, true, -20 ether);
        uint256[4] memory times = [uint256(57_599), 57_600, 61_199, 61_200];
        for (uint256 t; t < times.length; ++t) {
            vm.warp(20 days + times[t]);
            for (uint256 mode; mode < 4; ++mode) {
                _checkedSwap(_params(mode), false);
            }
        }
    }

    function testFuzz_FirstBuySettlesWithoutPreexistingEth(bool exactInput, uint96 seed, uint64 timestamp) public {
        vm.warp(timestamp);
        assertEq(address(manager).balance, 0);
        uint256 size = exactInput ? bound(seed, 1 gwei, 1 ether) : bound(seed, 1 ether, 100_000 ether);
        _checkedSwap(SwapParams(true, exactInput ? -int256(size) : int256(size), MIN_PRICE_LIMIT), false);
        assertGt(address(manager).balance, 0);
    }

    function test_AllFourModesChargeActualPartialFill() public {
        checkSwap(key, true, -20 ether);
        for (uint256 rate; rate < 2; ++rate) {
            vm.warp(20 days + (15 + rate) * 1 hours);
            for (uint256 mode; mode < 4; ++mode) {
                _checkedSwap(_partialParams(mode, 10), true);
            }
        }
    }

    function testFuzz_PartialFillFeeAndSettlement(uint8 modeSeed, uint8 tickSeed, uint64 timestamp) public {
        checkSwap(key, true, -20 ether);
        vm.warp(timestamp);
        _checkedSwap(_partialParams(modeSeed % 4, uint24(bound(tickSeed, 1, 20))), true);
    }

    function test_AllFourModesRejectUnpaidFeeAndOneWeiDeficits() public {
        checkSwap(key, true, -20 ether);
        for (uint256 rate; rate < 2; ++rate) {
            vm.warp(20 days + (15 + rate) * 1 hours);
            for (uint256 mode; mode < 4; ++mode) {
                for (uint256 fault = 1; fault <= 3; ++fault) {
                    _expectAtomicRevert(
                        _params(mode),
                        SettlementProbe.Fault(fault),
                        abi.encodeWithSelector(IPoolManager.CurrencyNotSettled.selector)
                    );
                }
                // The same input succeeds once paid in full, after every failed attempt.
                _checkedSwap(_params(mode), false);
            }
        }
    }

    function testFuzz_FailedSettlementPreservesClaims(uint8 modeSeed, uint8 faultSeed, uint64 timestamp) public {
        checkSwap(key, true, -20 ether);
        vm.warp(timestamp);
        SwapParams memory params = _params(modeSeed % 4);
        _expectAtomicRevert(
            params,
            SettlementProbe.Fault(1 + faultSeed % 3),
            abi.encodeWithSelector(IPoolManager.CurrencyNotSettled.selector)
        );
        _checkedSwap(params, false);
    }

    function test_RevokedTokenAllowanceRollsBackFeeMintAndSwap() public {
        checkSwap(key, true, -20 ether);
        token.approve(address(probe), 0);
        _expectAtomicRevert(
            _params(2),
            SettlementProbe.Fault.None,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(probe), 0, 1000 ether)
        );
        token.approve(address(probe), type(uint256).max);
        _checkedSwap(_params(2), false);
    }

    function testFuzz_DustAndFeeFloorInAllFourModes(uint16 sizeSeed) public {
        checkSwap(key, true, -1 ether);
        // A 1:1 pool lets both currencies' raw unspecified amounts cross the 100/1000-wei
        // fee thresholds without the launch price magnifying token dust into a large fee.
        PoolKey memory dustPool = key;
        dustPool.fee = 500;
        manager.initialize(dustPool, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(
            dustPool, ModifyLiquidityParams(-120, 120, 100 ether, 0), ""
        );
        uint256 amount = bound(sizeSeed, 1, 2000);
        for (uint256 rate; rate < 2; ++rate) {
            vm.warp(20 days + (15 + rate) * 1 hours);
            for (uint256 mode; mode < 4; ++mode) {
                // Include one-wei swaps deterministically, as well as the fuzzed fee boundary.
                assertEq(checkSwap(dustPool, mode < 2, mode % 2 == 0 ? int256(-1) : int256(1)), 0);
                checkSwap(dustPool, mode < 2, mode % 2 == 0 ? -int256(amount) : int256(amount));
            }
        }
        assertEq(
            manager.balanceOf(address(happy), key.currency0.toId()),
            happy.accrued(key.toId(), key.currency0) + happy.accrued(dustPool.toId(), key.currency0)
        );
        assertEq(
            manager.balanceOf(address(happy), key.currency1.toId()),
            happy.accrued(key.toId(), key.currency1) + happy.accrued(dustPool.toId(), key.currency1)
        );
    }

    function test_ZeroAmountAndInvalidLimitsDoNotAccrue() public {
        checkSwap(key, true, -20 ether);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        for (uint256 mode; mode < 4; ++mode) {
            SwapParams memory params = _params(mode);
            params.amountSpecified = 0;
            _expectAtomicRevert(
                params, SettlementProbe.Fault.None, abi.encodeWithSelector(IPoolManager.SwapAmountCannotBeZero.selector)
            );
            params = _params(mode);
            params.sqrtPriceLimitX96 = price;
            _expectAtomicRevert(
                params,
                SettlementProbe.Fault.None,
                abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, price, price)
            );
            params.sqrtPriceLimitX96 = params.zeroForOne ? TickMath.MIN_SQRT_PRICE : TickMath.MAX_SQRT_PRICE;
            _expectAtomicRevert(
                params,
                SettlementProbe.Fault.None,
                abi.encodeWithSelector(Pool.PriceLimitOutOfBounds.selector, params.sqrtPriceLimitX96)
            );
        }
    }

    function _params(uint256 mode) private pure returns (SwapParams memory) {
        bool buy = mode < 2;
        bool exactInput = mode % 2 == 0;
        uint256 amount = buy == exactInput ? 0.01 ether : 1000 ether;
        return SwapParams(buy, exactInput ? -int256(amount) : int256(amount), buy ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
    }

    function _partialParams(uint256 mode, uint24 ticks) private view returns (SwapParams memory params) {
        params = _params(mode);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        params.sqrtPriceLimitX96 =
            TickMath.getSqrtPriceAtTick(params.zeroForOne ? tick - int24(ticks) : tick + int24(ticks));
        // These requests exceed the liquidity available before the nearby price limit.
        uint256 amount = params.zeroForOne == (params.amountSpecified < 0) ? 10 ether : 10_000_000 ether;
        params.amountSpecified = params.amountSpecified < 0 ? -int256(amount) : int256(amount);
    }

    function _snapshot() private view returns (Snapshot memory s) {
        s = Snapshot(
            address(this).balance,
            token.balanceOf(address(this)),
            address(manager).balance,
            token.balanceOf(address(manager)),
            happy.accrued(key.toId(), key.currency0),
            happy.accrued(key.toId(), key.currency1)
        );
    }

    function _checkedSwap(SwapParams memory params, bool partialFill) private {
        Snapshot memory beforeSwap = _snapshot();
        vm.recordLogs();
        BalanceDelta net = probe.swap{value: params.zeroForOne ? 20 ether : 0}(key, params, SettlementProbe.Fault.None);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        BalanceDelta raw = rawSwap(logs, key.toId());
        bool exactInput = params.amountSpecified < 0;
        bool charge0 = exactInput ? !params.zeroForOne : params.zeroForOne;
        uint256 fee = abs(charge0 ? raw.amount0() : raw.amount1()) * expectedFeeBps() / 10_000;
        assertGt(fee, 0, "exercise a nonzero fee");
        assertEq(int256(net.amount0()), int256(raw.amount0()) - int256(charge0 ? fee : 0));
        assertEq(int256(net.amount1()), int256(raw.amount1()) - int256(charge0 ? 0 : fee));
        int128 specified = params.zeroForOne == exactInput ? net.amount0() : net.amount1();
        if (partialFill) {
            assertGt(abs(specified), 0);
            assertLt(abs(specified), uint256(exactInput ? -params.amountSpecified : params.amountSpecified));
            (uint160 price,,,) = manager.getSlot0(key.toId());
            assertEq(price, params.sqrtPriceLimitX96, "must reach the limit");
        } else {
            assertEq(int256(specified), params.amountSpecified);
        }
        assertEq(int256(address(this).balance) - int256(beforeSwap.user0), int256(net.amount0()));
        assertEq(int256(token.balanceOf(address(this))) - int256(beforeSwap.user1), int256(net.amount1()));
        assertEq(int256(address(manager).balance) - int256(beforeSwap.manager0), -int256(net.amount0()));
        assertEq(int256(token.balanceOf(address(manager))) - int256(beforeSwap.manager1), -int256(net.amount1()));
        assertEq(happy.accrued(key.toId(), key.currency0), beforeSwap.accrued0 + (charge0 ? fee : 0));
        assertEq(happy.accrued(key.toId(), key.currency1), beforeSwap.accrued1 + (charge0 ? 0 : fee));
        checkFeeEvent(logs, key, charge0 ? key.currency0 : key.currency1, fee);
        // Fee collection must remain claims; there must be no implicit donation in a swap.
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager)) {
                assertTrue(logs[i].topics[0] != keccak256("Donate(bytes32,address,uint256,uint256)"));
            }
        }
        _assertSettled();
        assertClaims(key);
    }

    function _expectAtomicRevert(SwapParams memory params, SettlementProbe.Fault fault, bytes memory reason) private {
        bytes32 beforeState = _stateHash();
        vm.expectRevert(reason);
        probe.swap{value: params.zeroForOne ? 20 ether : 0}(key, params, fault);
        assertEq(_stateHash(), beforeState, "failed swap must roll back all effects");
        _assertSettled();
    }

    function _stateHash() private view returns (bytes32) {
        PoolId id = key.toId();
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(id);
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(id);
        return keccak256(
            abi.encode(
                _snapshot(),
                price,
                tick,
                protocolFee,
                lpFee,
                growth0,
                growth1,
                manager.getLiquidity(id),
                manager.balanceOf(address(happy), key.currency0.toId()),
                manager.balanceOf(address(happy), key.currency1.toId())
            )
        );
    }

    function _assertSettled() private view {
        assertEq(manager.currencyDelta(address(happy), key.currency0), 0);
        assertEq(manager.currencyDelta(address(happy), key.currency1), 0);
        assertEq(manager.currencyDelta(address(probe), key.currency0), 0);
        assertEq(manager.currencyDelta(address(probe), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertEq(address(probe).balance, 0);
        assertEq(token.balanceOf(address(probe)), 0);
    }
}
