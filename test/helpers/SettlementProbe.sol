// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HappyHourHook} from "../../src/HappyHourHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @dev Exercises actual settlement, including intentionally unpaid debts. No mocked manager calls.
contract SettlementProbe is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    enum Fault {
        None,
        UnderpayOne,
        OvertakeOne,
        IgnoreHookFee
    }

    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, Fault fault)
        external
        payable
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(msg.sender, key, params, fault)), (BalanceDelta));
        if (address(this).balance != 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, address(this).balance);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (address payer, PoolKey memory key, SwapParams memory params, Fault fault) =
            abi.decode(data, (address, PoolKey, SwapParams, Fault));
        HappyHourHook hook = HappyHourHook(address(key.hooks));
        Currency charged = params.amountSpecified < 0
            ? (params.zeroForOne ? key.currency1 : key.currency0)
            : (params.zeroForOne ? key.currency0 : key.currency1);
        uint256 accruedBefore = hook.accrued(key.toId(), charged);
        BalanceDelta delta = manager.swap(key, params, "");

        // Inspect transient debt inside unlock: the hook's claim mint must already be settled,
        // while the router must owe exactly the returned (fee-adjusted) swap delta.
        require(manager.currencyDelta(address(hook), key.currency0) == 0, "hook currency0 debt");
        require(manager.currencyDelta(address(hook), key.currency1) == 0, "hook currency1 debt");
        require(manager.currencyDelta(address(this), key.currency0) == delta.amount0(), "router currency0 delta");
        require(manager.currencyDelta(address(this), key.currency1) == delta.amount1(), "router currency1 delta");

        uint256 input = uint256(-int256(params.zeroForOne ? delta.amount0() : delta.amount1()));
        uint256 output = uint256(int256(params.zeroForOne ? delta.amount1() : delta.amount0()));
        if (fault == Fault.UnderpayOne) input -= 1;
        if (fault == Fault.OvertakeOne) output += 1;
        if (fault == Fault.IgnoreHookFee) {
            uint256 fee = hook.accrued(key.toId(), charged) - accruedBefore;
            require(fee > 0, "test must omit a nonzero fee");
            if (params.amountSpecified < 0) output += fee;
            else input -= fee;
        }

        (params.zeroForOne ? key.currency0 : key.currency1).settle(manager, payer, input, false);
        (params.zeroForOne ? key.currency1 : key.currency0).take(manager, payer, output, false);
        return abi.encode(delta);
    }

    receive() external payable {}
}
