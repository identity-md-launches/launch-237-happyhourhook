# Happy Hour (HAPY)

Happy Hour is a fixed-supply ERC-20 and a Uniswap v4 hook for the native ETH/HAPY pool on Sepolia. Swaps pay a hook fee of **0.1% from 16:00:00 through 16:59:59 UTC**, and **1% otherwise**. Anyone can donate accumulated fees to the pool's currently in-range LPs.

This deliverable contains contract source, real-PoolManager tests, vendored dependencies, and ABI exports. Deployment, the independently reviewed `launch.json`, source publication, attestation, admission, and the live website are separate workflow contributions. No deployment has been performed here.

## Build and verify

With Foundry and Solidity 0.8.26 installed:

```sh
forge build
forge test
forge fmt --check
python3 tools/check_dependencies.py
python3 tools/export_abis.py --check
```

The compiler is pinned in `foundry.toml`; the EVM target is Cancun, optimization is enabled with 200 runs, and `bytecode_hash = "none"`. All Solidity dependencies are ordinary files under `lib/`, so verification requires no dependency downloads. FFI and filesystem cheatcode permissions are not enabled. Tests require no RPC, environment variables, wallet, or fork.

## Contracts and deployment parameters

| Contract | Artifact | Constructor | Behavior |
| --- | --- | --- | --- |
| Token | `src/LaunchToken.sol:LaunchToken` | No arguments | Happy Hour / HAPY; 18 decimals; exactly 1,000,000,000 HAPY minted once to `msg.sender` |
| Hook | `src/HappyHourHook.sol:HappyHourHook` | One `IPoolManager` address | Immutable manager; exactly `afterSwap` and `afterSwapReturnDelta` |

Neither contract has an owner, admin, mint-after-deployment, fee setter, fee recipient, pause, proxy, or upgrade path. The token uses OpenZeppelin ERC-20 transfer and allowance behavior, with no transfer tax or burn entry point. The hook does not authenticate swappers because it gives no user or router a credit; `sender` and `hookData` are ignored. Hook data is unauthenticated and must never be treated as proof of user identity.

The launch target is **Sepolia, chain ID 11155111**. The hook constructor argument must be the literal **`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`**, with no owner or token argument. The separate manifest writer must use that address as the sole element of `constructorArgs`. The constructor accepts a manager parameter to support a real local manager in tests; chain selection and the correct canonical manager are deployment responsibilities, not an on-chain chain-ID restriction.

The factory must mine a CREATE2 salt so that `uint160(hookAddress) & 0x3fff == 0x0044`. BaseHook validates the complete bit pattern during construction. The address depends on the factory address, salt, creation code, and ABI-encoded manager argument. Permission bits are immutable. Use the built artifact for mining; changing compiler settings or constructor arguments changes the address. The suite includes a real CREATE2 deployment with a mined salt.

Factory pool parameters are `currency0 = address(0)` (native ETH), `currency1 = HAPY`, `fee = 3000`, `tickSpacing = 60`, and `hooks = deployed HappyHourHook`. Its 0.3% LP fee is independent of the hook fee; no dynamic-fee flag is needed. Initialization and liquidity callbacks are disabled, allowing the factory's token-only seed. Both exact-input and exact-output first buys are tested while the PoolManager holds zero ETH. Initial price and liquidity placement remain factory parameters; the supplied launch harness tests tick 138000 and a single token-only position below that tick.

## Fees and settlement

Each pool is identified by v4's `PoolId`, the hash of its complete `PoolKey`. Pools with non-native `currency0` get zero hook delta and no hook state. The hook learns currencies from the key, so other native-ETH pools using the same hook also accrue separately; it does not restrict participation to one token or fee tier.

The rate uses the block timestamp modulo 86,400. The happy-hour interval is `[57,600, 61,200)`. A few seconds of validator timestamp skew at the boundaries is accepted. A quote obtained before a boundary may execute at the other rate; routers must enforce the user's minimum output or maximum input.

The fee is `floor(abs(unspecified BalanceDelta amount) * bps / 10_000)`. It uses the actual filled amount, including when a price limit causes a partial fill. The specified side stays unchanged.

| Swap | Specified side | Hook fee currency | Effect on swapper |
| --- | --- | --- | --- |
| ETH → HAPY, exact input | ETH input | HAPY | Receives less HAPY |
| ETH → HAPY, exact output | HAPY output | ETH | Pays more ETH |
| HAPY → ETH, exact input | HAPY input | ETH | Receives less ETH |
| HAPY → ETH, exact output | ETH output | HAPY | Pays more HAPY |

Every nonzero fee increments `accrued[poolId][currency]`, mints an equal number of PoolManager ERC-6909 claims to the hook, and returns a **positive** `int128` unspecified hook delta. Minting creates the hook's debt; the returned credit cancels it within that same unlock. There is no withdrawal of underlying ETH or tokens during a swap and no donation during a swap. Dust fees round down to zero, mint no claims, and emit no `FeeTaken` event. Widening to `int256` before taking the absolute value avoids signed-minimum overflow; the 1% maximum rate keeps the returned fee within `int128`.

`donateFees(key)` is permissionless. It checks `key.hooks`, reads that pool's two accrued amounts, zeroes both, and unlocks the manager. The manager-only unlock callback burns the claims **before** donating exactly those amounts to that pool. Burning gives credit and donating consumes it. The hook sends no ETH or tokens to the caller. LPs subsequently collect through their usual liquidity position manager.

Donation reverts with `NothingAccrued` when both amounts are zero or `WrongHook` for a foreign hook key. With zero in-range liquidity the real PoolManager reverts with `NoLiquidityToReceiveFees`; transaction rollback restores all accrued amounts and claims. It can be retried when liquidity returns. Calls made inside an existing PoolManager unlock revert with `AlreadyUnlocked` and also preserve the fees. Donations consume the caller's gas and provide no keeper reward.

LP fee growth rises by exactly `floor(donatedAmount * 2^128 / activeLiquidity)` per currency. Individual LP collections are subject to v4's normal fixed-point rounding. **Liquidity added immediately before a donation shares fees from earlier swaps.** The test suite demonstrates this JIT capture; there is no age weighting, lockup, or timing protection.

## Accounting assumptions

The immutable PoolManager is the trusted canonical v4 implementation. Every inherited callback and `unlockCallback` checks its caller. The only external contract the production hook calls is that manager. Its claim mint/burn functions do not invoke recipient callbacks; donations have this hook's disabled donation callbacks. There is no arbitrary external-call or token-transfer surface in the hook.

For fee-generated claims, the sum of `accrued` over all participating pools equals the hook's PoolManager claim balance for each currency. Tests enforce this across two pools sharing ETH and HAPY, along with zero unsettled debt and conservation of underlying assets. ERC-6909 lets third parties transfer unrelated claims directly to any address, including this hook. Such unsolicited claims create an **unattributed surplus**, cannot be included in a particular pool's accrual, and are not spendable by `donateFees`; no recovery function exists. The strict equality invariant assumes no unsolicited claim transfers. Forced ETH or direct token gifts are likewise not fee revenue and have no recovery path.

Production support is for ordinary HAPY and native ETH. Rebasing, fee-on-transfer, or callback-enabled substitute tokens are outside the launch assumptions. Donation timing is an operational choice: fees wait as claims until someone calls, and wait indefinitely if active liquidity never returns. There is no administrator who can redirect them.

## ABI and operational handoff

ABI arrays are exported at [docs/abi/LaunchToken.json](docs/abi/LaunchToken.json) and [docs/abi/HappyHourHook.json](docs/abi/HappyHourHook.json). See [docs/ABI.md](docs/ABI.md) for units, events, and frontend calls. Regenerate them with `python3 tools/export_abis.py` after changing an interface.

The source dependency snapshot is pinned to the Identity-md starter template commit in [docs/dependencies.lock.json](docs/dependencies.lock.json); every delivered dependency source has a content hash. `test/BaseHookTest.sol` is adapted from that template for the approved no-argument token constructor and HappyHourHook artifact. Dependency licenses are retained under `lib/licenses`; SPDX headers apply per file, including the v4 core Business Source License and test-only dependencies.

The independent reviewer should attack boundary timing, all four delta signs, claim conservation across pools, burn/donate order, failed and nested donation rollback, address permissions, and JIT donation capture. Local tests are evidence for review, not an independent audit. A service-side fork rehearsal against the exact Sepolia manager, factory, and production router is still required before release; this assignment's tests deploy a real manager locally and do not claim live-network validation.

The manifest contribution writes `launch.json`; its independent review checks concrete source, constructor, policy, and authorization conflicts. Publishing, signed artifact linkage, attestation, admission, and deployment belong to services. Those later outcomes are not prerequisites for this source contribution. Deployment services must record the deployed addresses, factory salt, initialization parameters, and actual pool ID. After deployment the frontend contribution can build the one-page `lab-happy-hour-hook` static site against those addresses and a public Sepolia RPC, exporting `dist/index.html`. Operators should monitor fee claims, accrued balances, active liquidity, donation success, and UTC boundary behavior; donation remains open to every user.
