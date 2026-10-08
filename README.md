# SIMDTEST launch

An immutable Uniswap v4 hook collects IMD fees and records deferred buyer rewards. The separate standard ERC-20 mints exactly **1,000,000,000 SIMDTEST (1e27 base units)** to its deployer. There is no owner, upgrade path, transfer tax, post-deployment mint, fee setter or withdrawal of surplus fees.

## Launch parameters and responsibilities

| Item | Value |
|---|---|
| Chain | Ethereum mainnet, chain ID 1; requires Cancun |
| PoolManager constructor argument | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| IMD, 18 decimals | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Hook constructor | `SIMDTESTHook(IPoolManager manager, address launchToken)` |
| Token constructor | `SIMDTEST()`, name and symbol `SIMDTEST` |
| Static LP fee | `12500` millionths = 1.25% |
| Tick spacing | 60 |
| Hook address mask | low 14 bits equal **0x20cc**, decimal 8396 |
| Manifest opening-price provenance | `79228162514264337593543950336` |

`launch.json` has kind `univ4_hook`. The network resolves `$poolManager` to the above mainnet manager and `$token` to the token it deploys immediately before the hook. The hook itself is deployed directly by CREATE2; its address must encode beforeInitialize, beforeSwap, afterSwap and both swap-return-delta flags. Constructor validation rejects incorrect bits. There is no wrapper or proxy.

The factory holds the **entire** initial supply. It seeds 90%, distributes the swarm's 10% using its external Merkle distributor, and handles any economically configured remainder. Neither contract performs that allocation. The factory calculates the opening price from launch economics; the manifest price is provenance only. It must deploy and initialize atomically. The initialization callback accepts only this token/IMD pool, static fee 12500 and spacing 60, and is callable only by the manager. It adds no sender restriction to the factory's initialization.

All required addresses are fixed at construction; there are no settings to configure after launch. The hook constructor creates its immutable `SIMDTESTRouter` and exposes it as `rewardRouter()`. This helper routes trades directly through the PoolManager; it does not sit between the pool and its hook. The returned router address, not a guessed or precomputed address, is the trading entry point.

## Fees and rewards

`buyerRewardFeeBps() = 200`, `minBuyUnits() = 10e18` and `poolFeeBps() = 12500` are constants. The last getter retains the requested name but uses v4's **millionths**, not basis points. No dynamic fee flag, LP fee override or `updateDynamicLPFee` is used.

| Swap | IMD fee and execution |
|---|---|
| Exact-input buy | The IMD input budget includes the fee: `floor(budget / 50)` is reserved before swapping. |
| Exact-output buy | Adds `floor(actual pool IMD input / 50)` to the IMD owed by the buyer. |
| Exact-input sell | Withholds `floor(actual pool IMD output / 50)` from proceeds. |
| Exact-output sell | The requested IMD is net proceeds. Adds `floor(requested net / 49)` to the pool output target. |

The hook charges only IMD. The pool's unchanged 1.25% LP fee applies separately. Fractions round down to base units. For a qualifying buy, `spent` is actual IMD debited from the trader, **including** the hook fee and the pool's input fee. If `spent >= 10e18` and the pool produced SIMDTEST, the hook records `floor(spent / 100)` for that buyer. Sells, zero fills and smaller buys record nothing.

Specified-side fees require knowing the fill before the real swap. `beforeSwap` makes a self-only, deliberately reverting PoolManager preview, which v4 executes without recursively calling this hook. The preview rolls back its entire pool state, deltas and events. If a price limit or a gap in liquidity prevents a complete fill, the reserved fee is capped at `floor(actual pool input / 49)` for buys, or `floor(actual gross output / 50)` for sells. This prevents charging fees on unspent input or turning a partial sell's proceeds into an IMD debt. It adds the gas cost of one simulated swap on those two paths. There is no full-swap interception or NoOp custom AMM: the outer before-swap delta represents only the fee; the actual trade executes in the canonical pool.

During callbacks, fees are taken to the hook. If the manager cannot transfer IMD yet (notably a freshly seeded token-only pool), it instead mints IMD ERC-6909 claims **owned by the hook**. Return deltas settle that fee credit. After settlement, anyone may call `collectFees()` to redeem the claims into IMD at the hook; neither the caller nor another recipient can receive them. Claims are also redeemed as needed when paying rewards. Failed redemption leaves the claims and reward debt intact.

Accrued IMD plus manager claims always back pending rewards. The unallocated fee surplus remains permanently held by the hook: the brief names no surplus recipient and grants no owner or sweep power. Unsolicited transfers are also not recoverable.

## Authenticated buying and claiming

v4 callbacks identify the calling router, not its payer or final recipient. The hook never interprets untrusted `hookData` as buyer identity. It recognizes only its own constructor-created router. All other routers remain able to trade, pay the same fees and receive **no rewards**. This is the explicit integration boundary needed to prevent reward impersonation without an admin-maintained allowlist.

1. Read `rewardRouter()` and approve that address to spend the trade's maximum input token amount.
2. Call `swap(buy, amountSpecified, maxInput, minOutput, sqrtPriceLimitX96, deadline)`. Negative `amountSpecified` means exact input; positive means exact output. For exact input, `maxInput` must equal its magnitude. Supply your own slippage limits and deadline.
3. The router pulls **only from `msg.sender`** before unlocking the manager. It has no payer or recipient argument. Output and unused input go only to that caller. Exact-output trades must fully fill or the router rolls the trade back; exact-input trades may partially fill and return unused input.
4. Read `pending(buyer)` and `owedTotal()`.
5. The buyer calls `claimRewards()`, or any address calls `payRecorded(buyer)`. Both pay IMD only to the recorded buyer and return the amount. An empty claim returns zero.

No reward is paid or triggered by a swap callback. Payout and fee-redemption entry points reject calls during **any** active PoolManager unlock, including attempts from token transfer callbacks. Payouts clear debt before interaction and use a reentrancy guard. A failed transfer reverts the accounting changes, preserving the beneficiary's claim. Contract wallets can buy and claim in the same manner as EOAs.

The intended IMD is the fixed mainnet ERC-20. The implementation tolerates fee-collection transfer failure and ERC-20 missing/false return values, but it does not support rebasing or fee-on-transfer accounting. If IMD permanently prevents transfers to the hook or beneficiary, existing rewards remain recorded until transfers can succeed.

## Offline build and checks

Dependencies are ordinary vendored files under `lib/`; no submodules or downloads are required. Foundry 1.8.3 and cached solc **0.8.26** were used. Configuration pins Cancun, optimizer 200 runs, metadata bytecode hash `none`, FFI disabled and empty filesystem permissions.

```sh
forge build --offline
forge test --offline
forge fmt --check
python3 scripts/check-launch.py
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
FOUNDRY_PROFILE=extended forge test --offline --match-test testFuzz --fuzz-seed 0x12345678 --fuzz-runs 2000
```

`script/Deploy.s.sol` is a **chain-31337-only local smoke rehearsal** and reads no keys or environment variables. It creates local dependencies and deploys one mined hook through its local factory between broadcast markers. Running it as shown does not send transactions. Its `mine(factory, manager, token)` function can also calculate a salt for the actual launch factory and constructor arguments. Production deployment belongs to the network's deployer, which uses the reviewed `launch.json`, actual CREATE2 factory and fresh token; the local smoke factory is not a production dependency. No transaction is authorized by this repository.

For an operator-controlled mainnet rehearsal, configure Foundry's `FOUNDRY_ETH_RPC_URL` outside this repository, then run with a pinned block:

```sh
forge test --offline --match-contract MainnetForkTest --fork-block-number "$MAINNET_BLOCK" --no-storage-caching -vv
```

Fork tests use the actual mainnet manager and IMD code, CREATE2-deploy the hook, open a new pool, seed liquidity and exercise both swap directions/modes and both payout paths. Test balances are funded by Foundry's storage-aware `deal`; this is not a production funding plan. The default offline run explicitly skips the fork suite. **A live fork run was attempted but could not execute: all three public endpoint probes returned HTTP errors.** No live-state compatibility is claimed. The network's deployer must run that rehearsal and independent security review before deployment.

## Configuration and references

Configuration choice: general custom hook implementing the v4 ABI, no base-hook dependency, no shares, no access-control roles, no pause, no configurable inputs. Enabled permissions are exactly the five manifest entries. Checked casts are from v4's SafeCast; ERC-20 handling and payout guards are from vendored OpenZeppelin. A single temporary storage word carries the previewed specified fee between callbacks and is cleared before external fee transfer. v4 transient-state reads prevent payouts during an unlock.

The checked semantics are visible in the vendored `lib/v4-core/src/libraries/Hooks.sol` and `PoolManager.sol`. Upstream references: [Uniswap custom accounting](https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting) and [Identity-md's public manifest definitions](https://github.com/Identity-md/worker/blob/main/dist/cli.js). See `REVIEW.md` for adversarial cases and limitations, `docs/DEPENDENCIES.md` for vendoring, and `docs/abi/` for exported interfaces.
