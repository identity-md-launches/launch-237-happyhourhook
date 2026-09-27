// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Charges the unspecified swap currency and returns accrued fees to in-range LPs.
/// @dev Only native-ETH currency0 pools participate. No token transfers occur in this hook:
///      swap fees become ERC-6909 claims, later burned to settle a permissionless donation.
contract HappyHourHook is BaseHook, IUnlockCallback {
    uint256 private constant DAY = 86_400;
    uint256 private constant START = 57_600;
    uint256 private constant END = 61_200;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Fees attributable to each pool and currency, in raw currency units.
    mapping(PoolId poolId => mapping(Currency currency => uint256 amount)) public accrued;

    error WrongHook();
    error NothingAccrued();

    event FeeTaken(PoolId indexed poolId, Currency indexed currency, uint256 amount, uint24 bps);
    event Donated(PoolId indexed poolId, uint256 amount0, uint256 amount1);

    /// @dev BaseHook validates all 14 address permission bits at construction (must be 0x0044).
    constructor(IPoolManager manager) BaseHook(manager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    /// @notice Whether the block timestamp is in [16:00:00, 17:00:00) UTC.
    function isHappyHour() public view returns (bool) {
        uint256 timeOfDay = block.timestamp % DAY;
        return timeOfDay >= START && timeOfDay < END;
    }

    /// @notice Hook fee in basis points; separate from the pool's static LP fee.
    function currentFeeBps() public view returns (uint24) {
        return isHappyHour() ? 10 : 100;
    }

    /// @notice Seconds until happy hour starts, or until it ends if currently active.
    function secondsUntilNextChange() external view returns (uint256) {
        uint256 timeOfDay = block.timestamp % DAY;
        if (timeOfDay < START) return START - timeOfDay;
        if (timeOfDay < END) return END - timeOfDay;
        return DAY - timeOfDay + START;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (!key.currency0.isAddressZero()) return (this.afterSwap.selector, 0);

        bool unspecifiedIs1 = (params.amountSpecified < 0) == params.zeroForOne;
        Currency currency = unspecifiedIs1 ? key.currency1 : key.currency0;
        // Widen before negating: the magnitude of int128.min is representable in int256.
        int256 amount = unspecifiedIs1 ? int256(delta.amount1()) : int256(delta.amount0());
        uint256 magnitude = uint256(amount < 0 ? -amount : amount);
        uint24 bps = currentFeeBps();
        uint256 fee = magnitude * bps / BPS_DENOMINATOR;

        if (fee != 0) {
            PoolId id = key.toId();
            accrued[id][currency] += fee;
            // Minting creates a debt, canceled by the positive returned hook delta.
            // This also works on the first buy, before any ETH has been settled to the manager.
            poolManager.mint(address(this), currency.toId(), fee);
            emit FeeTaken(id, currency, fee, bps);
        }

        // fee <= 1% of an int128 magnitude, hence strictly below int128.max.
        return (this.afterSwap.selector, int128(int256(fee)));
    }

    /// @notice Donate all accrued fees for this pool to its currently in-range liquidity.
    /// @dev Must be called outside an existing PoolManager unlock. A failed donation (including
    ///      no in-range liquidity) atomically restores accrued balances and claims. JIT LPs share
    ///      the donation; neither the caller nor any administrator receives a reward.
    function donateFees(PoolKey calldata key) external {
        if (address(key.hooks) != address(this)) revert WrongHook();
        PoolId id = key.toId();
        uint256 amount0 = accrued[id][key.currency0];
        uint256 amount1 = accrued[id][key.currency1];
        if (amount0 == 0 && amount1 == 0) revert NothingAccrued();

        accrued[id][key.currency0] = 0;
        accrued[id][key.currency1] = 0;
        poolManager.unlock(abi.encode(key, amount0, amount1));
        emit Donated(id, amount0, amount1);
    }

    /// @dev Only the trusted immutable manager can call this, and unlock calls back its caller.
    ///      Burning claims supplies credit; donating consumes exactly that credit in each currency.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (PoolKey memory key, uint256 amount0, uint256 amount1) = abi.decode(data, (PoolKey, uint256, uint256));
        if (amount0 != 0) poolManager.burn(address(this), key.currency0.toId(), amount0);
        if (amount1 != 0) poolManager.burn(address(this), key.currency1.toId(), amount1);
        poolManager.donate(key, amount0, amount1, "");
        return "";
    }
}
