# Contract interfaces

The JSON files in `docs/abi/` are complete ABI arrays, generated with the pinned compiler. `tools/export_abis.py --check` compares them to current compiler output.

## LaunchToken

`constructor()` mints `1_000_000_000 * 10^18` units to its deploying address. `name()` is `Happy Hour`, `symbol()` is `HAPY`, `decimals()` is 18, and `TOTAL_SUPPLY()` and `totalSupply()` both return `10^27`.

Standard ERC-20 methods: `balanceOf(address)`, `allowance(address,address)`, `approve(address,uint256)`, `transfer(address,uint256)`, and `transferFrom(address,address,uint256)`. Amounts are raw 18-decimal units. Transfers and approvals return `bool`. OpenZeppelin ERC-6093 errors and `Transfer` / `Approval` events are included in the ABI. There is no mint, admin, or ownership API.

## HappyHourHook

`constructor(address manager)` takes the Sepolia PoolManager `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` for deployment. `poolManager()` returns that immutable address. `getHookPermissions()` returns the 14-field v4 permissions tuple; only `afterSwap` and `afterSwapReturnDelta` are true.

| User method | Return / effect |
| --- | --- |
| `isHappyHour()` | `bool`, based on the current block's UTC timestamp |
| `currentFeeBps()` | `uint24`: 10 or 100 basis points |
| `secondsUntilNextChange()` | `uint256`, positive seconds until the next 16:00 start or 17:00 end |
| `accrued(bytes32 poolId, address currency)` | `uint256`, undonated fee units for that exact pool and currency |
| `donateFees(PoolKey key)` | Nonpayable transaction; donates both accrued currencies to in-range LPs |

`PoolKey` is the tuple `(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)`. For the launch, pass `(address(0), deployed HAPY, 3000, 60, deployed hook)`. The ID is `keccak256(abi.encode(key))`, **not** a packed encoding. Native ETH's currency address and ERC-6909 claim ID are zero; HAPY's claim ID is `uint256(uint160(tokenAddress))`. Both launch currencies use 18 decimals, but the accrued API always returns raw units.

Events:

```solidity
event FeeTaken(bytes32 indexed poolId, address indexed currency, uint256 amount, uint24 bps);
event Donated(bytes32 indexed poolId, uint256 amount0, uint256 amount1);
```

`FeeTaken` is emitted only for nonzero fees. `Donated` is emitted only after successful settlement. Filter by hook address and indexed pool ID, account for reorgs, and refresh the views after a receipt. Do not sum unconfirmed events as an authoritative balance.

User-facing errors are `WrongHook()`, `NothingAccrued()`, and propagated manager errors including `NoLiquidityToReceiveFees()` and `AlreadyUnlocked()`. Inherited errors include `NotPoolManager()`, `HookNotImplemented()`, and constructor permission validation errors. Disabled callback selectors appear in the ABI because BaseHook implements the full v4 interface; they are not permissioned or user-callable actions.

The frontend should read the clock views and both accrued values at the same block when possible, display the UTC block-time fee, and interpolate the countdown between refreshes. An unsynced local clock is not authoritative. The donate button sends the complete pool key with zero ETH value. It should report zero accrual or no active liquidity as normal conditions. It needs a wallet only for that transaction; reads need just a public Sepolia RPC and the addresses/pool ID supplied by deployment services.
