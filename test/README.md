# Contributor test additions

The original tests remain in place. The added suites exercise the deployed hook
and the vendored real Uniswap v4 PoolManager, with CREATE2-mined permission bits.

- `RewardFailurePaths.t.sol`: independent creditors, repeated earning and claims,
  false/no-return ERC-20 transfers, rollback after fee redemption, manager-unlock
  exclusion, invalid deployment and router inputs, and partial-output rollback.
- `FillAccounting.t.sol`: 1,000 fuzz runs per property in each currency order,
  varying liquidity, price limits and all four swap modes. A separate pool without
  a hook checks that reverted previews leave price and LP fee growth unchanged.
- `AccountingSequences.t.sol`: 256 sequences of 64 calls across three buyers,
  including trades, claims, third-party payments, donations, fee redemption and
  failed payouts. Expected debts come from trader debits; expected fees come from
  actual AMM fills, independently of the hook's accounting. Each sequence ends by
  paying all creditors. Unexpected handler reverts fail the campaign.

Foundry's log recorder includes reverted preview logs. `SwapObservation` filters
by pool, manager and the actual router sender, excluding the hook's self-quote.
The failure-token mocks are adversarial local fixtures, not claims about mainnet
IMD's behavior. No production contracts, dependencies or configuration changed.

Run offline with `forge build` and `forge test`. The mainnet suite also checks
per-mode fees against real manager fills and rollback of a partial-output failure:

```sh
forge test --match-contract MainnetForkTest --fork-url "$MAINNET_RPC_URL" \
  --fork-block-number "$MAINNET_BLOCK" --no-storage-caching -vv
```

Provide an archive RPC and a pinned mainnet block where both specified contracts
exist. The suite explicitly skips without an active mainnet fork. No RPC was
configured during this contribution; two public endpoint probes returned HTTP
errors, so live fork execution remains unverified. Nothing in the default suite
downloads dependencies or requires network access.
