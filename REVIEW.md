# Implementation security review

This is the implementer's adversarial review and reproducible test record, **not an independent contributor audit**. An independent network review and successful mainnet fork rehearsal remain release prerequisites. No deployment, broadcast, wallet access or RPC secret was used.

## Findings and dispositions

| Finding tested | Disposition and evidence |
|---|---|
| Invalid launch manifest kind in the earlier attempt | `launch.json` uses `univ4_hook`, contract names without paths, the five permitted flag names, and `$poolManager`/`$token` constructor arguments. Field shapes were compared with the public worker's `UniV4HookManifest`; `scripts/check-launch.py` checks the delivered values against the compiled ABIs. |
| Arbitrary allowance source in the earlier router attempt | The sole production `safeTransferFrom` uses `msg.sender` as source in the external guarded swap entry point. The callback settles the router's own prefunded tokens using `safeTransfer`. There is no payer parameter. `test_routerCannotSpendAnApprovedVictim` exercises an approved victim and another caller. |
| Fee overcharge or negative proceeds on partial specified-side fills | Reverting self-only preview caps the reserved fee to the actual IMD fill. Regression tests cover partial input buys and partial output sells for **both currency orderings**. Empty liquidity produces no fee or reward. |
| Forged hookData redirects rewards | Only the constructor-created router authenticates recipients; other routers' data are ignored. Malformed and forged data do not block those swaps or earn rewards. |
| Fresh pool lacks IMD during callback | Transfer failure falls back to ERC-6909 fee claims. A genuinely token-only pool with zero manager IMD successfully executes its first buy, records rewards, settles and pays later. |
| Reentrant callback triggers reward payout | Claims are excluded for the entire manager unlock. An adversarial token calls payRecorded from the fee transfer and receives ManagerUnlocked without interrupting the swap. |
| Reentrant payout or failed transfer erases/reuses debt | CEI plus ReentrancyGuard prevents recursive payout. Failed payout/redeem rolls back debt and preserves claims. Repeated successful payout returns zero. |
| Fee or rewards underfunding | Real-manager integration and bounded fuzzing check fee formulas, actual trader balances and settlement. The invariant handler mixes both swap types/directions, two buyers, claims, third-party payments and fee collection. Assets cover owedTotal, pending sums equal owedTotal, and collected fees equal remaining assets plus payments. |
| Wrong permissions, callbacks, pool or mutable implementation | Constructor validates 0x20cc address bits. Every enabled callback and unlock callback rejects non-manager callers. Only the fixed pool may initialize. Runtime opcode scans reject SELFDESTRUCT, DELEGATECALL and CALLCODE in hook, router and token. |

## Accounting reasoning

All fee deltas are positive credits to the hook in IMD only. A take or ERC-6909 mint creates the equal negative transient delta at the manager. After the router settles, all deltas are zero. The preview's entire call frame reverts, including the inner swap, so it creates no retained credit, event or changed pool state. `beforeSwap` never replaces an entire nonzero swap with a fee. `afterSwap` touches the unspecified currency only when that currency is IMD. The LP override return is always zero.

For exact-input buys, the fee is 2% of actual gross spend, rounded down. For exact-output buys, the fee is 2% of AMM IMD input; the reward is 1% of total spend including that fee. At the 10 IMD threshold the fee always exceeds the reward despite rounding. Sells only contribute assets. Clearing debt before transferring and restoring it on revert preserves solvency. The surplus has no extraction function.

The contract binds its manager/token/router immutably. There is no trust in tx.origin, signatures, mutable allowlists, owner roles or user-selected payout recipients. The fixed router ensures payer = output recipient = credited buyer. Arbitrary external routers are unsupported for reward attribution, since a v4 callback alone cannot prove their final recipient.

## Verification performed

- Foundry 1.8.3, solc 0.8.26, optimizer 200, Cancun, metadata hash none.
- Offline build, complete unit/integration/fuzz/invariant suite and format check.
- Additional fuzz seed with 2,000 actual runs per fuzz test using the extended profile; each core swap-order suite also declares a 1,000-run default and the invariant declares 256 sequences of depth 32 with fail-on-revert enabled. Explicit extended-profile inline settings override the inherited 1,000-run defaults.
- Invariant campaign: 8,192 handler calls, zero reverts.
- Exact pinned protected input tests were copied unchanged apart from local import paths into disposable `test/scratch/` and run with compiled creation code and local probe configuration: **4 hook checks and 7 token checks passed**, none skipped. This included factory initialization, permission agreement, full 1e27 supply and deployed opcode scans. The temporary copies were removed afterward; submitted tests read no environment variables.
- Manifest/ABI/opcode/size cross-check and local CREATE2 deployment script smoke test.
- Mainnet fork code is delivered but default offline tests explicitly skip it. Live probes to three public Ethereum endpoints returned HTTP errors; no fork run completed.

Slither and Mythril are not installed and were not run. No formal proof, independent audit, live liquidity rehearsal, production gas guarantee or deployed-address attestation is claimed. Gas scales with the number of ticks traversed; the specified-side preview traverses them twice. Use normal trade limits and include hook fees in wallet estimates. The real mainnet IMD transfer behavior and current PoolManager must be verified by the deployer before launch.
