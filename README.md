# The Hooks Store — Ethereum contracts

Two immutable application contracts for Ethereum mainnet (chain ID **1**): a free listing registry and a 24-hour IMD advertising escrow. The implementation starts from the requester-pinned [Hooks Store source at `46e17ea70534e8a7ac2c4ff78501a3c183d32da8`](https://github.com/identity-md-launches/launch-1811-build-technical-foundation-hooks/tree/46e17ea70534e8a7ac2c4ff78501a3c183d32da8/src/store). See [source provenance](docs/SOURCE_PROVENANCE.md) for the changes and vendored dependencies.

## Build and test

Run from the repository root with Foundry and Solidity **0.8.26** installed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x593cecbfc6012a81e1df3bd130b0c0742c86c5d1c56b1479d6ea8fa357e50b0b forge test
forge fmt --check
```

Dependencies are ordinary files under `lib/`; no dependency downloads, submodules, RPC, keys, environment reads in tests, FFI, or filesystem cheatcodes are needed. The compiler is pinned by version in `foundry.toml`, with Cancun, optimizer runs 200, `bytecode_hash = "none"`, and CBOR metadata disabled. Tests use local tokens only; production source contains no token implementation.

## Deployment parameters

Deploy only these two contracts, in this order, with **zero native value**:

| Contract | Source | Constructor arguments |
| --- | --- | --- |
| `HookListingRegistry` | `src/store/HookListingRegistry.sol` | None: `HookListingRegistry()` |
| `FeaturedPlacementsV2` | `src/store/FeaturedPlacementsV2.sol` | `($owner, $contract:HookListingRegistry)` |

For this launch, `$owner` resolves to **`0x5bff2a2fecd1d6152676813b21346238733beab1`**. The second argument is the registry address from the first deployment. No token or proceeds-recipient address belongs in the constructor. Constructors make no external calls and do not require dependency code to exist. Nothing is paid at deployment.

`StoreAdmin` is abstract and `ExactStoreToken` is an internal-only library; neither is a separate application to deploy. The factory simulation and tokens under `test/` are fixtures. No token, pool, liquidity, proxy, upgrade mechanism, deployment transaction, or launch manifest is included. The launch's manifest/deployment steps supply and record the actual application addresses.

## After launch

The owner must perform and verify these two settings before advertising is usable:

| Setter on `FeaturedPlacementsV2` | Value for this launch | Responsibility |
| --- | --- | --- |
| `configureToken(address)` | Ethereum IMD **`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`**, supplied in the brief | Confirm chain, token identity, code, 18 decimals, and exact-transfer/non-rebasing behavior before calling. This choice is irreversible. |
| `setProceedsRecipient(address)` | Owner's own wallet: **`0x5bff2a2fecd1d6152676813b21346238733beab1`** | Confirm wallet control. Later changes apply only to new purchases. |

Both setters are owner-only and emit events. `configureToken` rejects absent code, invalid decimals/balance responses, and repeated configuration. Before configuration, token-dependent actions fail with `TokenNotConfigured`; purchases also require a recipient or fail with `RecipientNotConfigured`. Deposits and withdrawals work once the token is configured even if the recipient is unset. Boosting an unknown placement fails with `UnknownPlacement`; no placement can be bought before configuration.

The supplied IMD address is a deployment requirement, not a claim that this local test suite verified its live implementation. The original configurable-token mechanism is preserved: it validates compatibility, not the token's identity. The owner is responsible for choosing the stated address. Similarly, the recipient setter retains the original ability to select a nonzero wallet; the launch policy is to select the owner's wallet.

After ownership rotation, the old owner proposes with `transferOwnership`, and the proposed owner calls `acceptOwnership`. The current owner may replace or cancel a proposal. This transfers administration only; it neither moves deposits nor changes pinned recipients or already earned proceeds. Update the recipient separately for future ads if needed.

## Listings and advertising

`HookListingRegistry` is unchanged. Anyone can create a listing without an application fee (transaction gas still applies). Uniqueness is by `(chainId, hook, listingOwner)`. The listing owner controls revisions, visibility, and a two-step listing transfer. Historical metadata remains readable, and ads pin the revision purchased. A listing is a claim, not verified hook control, deployment, security, or an audit. `isAudited` remains false. There is no registry administrator.

The advertising flow is:

1. Approve the escrow on the configured IMD token and call `deposit(amount)`. Deposits credit the caller's `available` balance only after exact movement of tokens is verified.
2. The current listing owner calls `purchase(listingId, expectedRevision, expectedRecipient, deadline)`. The active listing, revision, recipient, and deadline must match. Exactly **100000000000000000 base units (0.1 IMD)** move from that caller's deposit into escrow for **86400 seconds (24 hours)**. There can be only one live placement for each listing.
3. Anyone with a deposit may call `boost(placementId, amount)` with a positive amount while the placement is open **and before `endsAt`**. Only that caller's available balance is debited. Boosts accumulate in `totalBoost`, remain escrowed until closure, and do not extend time, change the pinned revision/recipient, or confer cancellation/ownership rights. Even an archived or transferred listing retains its purchased snapshot while that ad remains live.
4. Before expiry, the original payer or current listing owner may `cancel(id)`. Only the original payer receives the unused base-price credit. All boosts are forfeited to the pinned proceeds recipient, including on immediate cancellation or cancellation by a new listing owner.
5. At or after expiry, anyone may `settle(id)`, crediting the full base and boost to the pinned recipient. Ads disappear from `featured` automatically at expiry, even before settlement. Renewal can occur before an older expired placement is settled; the two escrows remain independent.
6. A depositor calls `withdraw(amount, to)` for their available credit. A proceeds recipient calls `withdrawProceeds(amount, to)` for their own earned credit. Cancellation and settlement only change accounting; they do not push tokens. A recipient's failed withdrawal cannot block other accounts or closing placements.

For elapsed time `e < 86400` and accumulated boost `B`, cancellation uses the original rounding:

```text
baseEarned = floor(100000000000000000 * e / 86400)
refund     = 100000000000000000 - baseEarned
earned     = baseEarned + B
```

At expiry, `refund = 0` and `earned = 100000000000000000 + B`. A placement closes once. `totalBoost` and `rankOf` retain historical amounts after closure.

## Website integration and ABI changes

`rankOf(id)` returns **`PRICE + totalBoost[id]`**, not an ordinal rank. It reverts for unknown IDs; for expired or closed records it returns their historical paid total. Use `isActive(id)` or `featured` to determine display eligibility.

The V2 return signature is:

```solidity
featured(uint256 cursor, uint256 scanLimit)
    returns (Placement[] ads, uint256[] totals, uint256 nextCursor)
```

`totals[i]` belongs to `ads[i]`. Start with cursor 1 and scan at most `MAX_SCAN = 100` consecutive IDs per call. Results are in ascending placement-ID order, with cancelled, settled, and expired placements omitted. A short or empty page can still have later results: continue until `nextCursor > placementCount`. Read all pages at the same block for a consistent snapshot. Collect all results before sorting **total descending, then ID ascending**. Use integer/BigInt comparisons, not floating-point token amounts. Equal unboosted or boosted totals therefore favor the lower ID. Sorting just one page does not produce a global leaderboard.

Every `Placement` retains `label = bytes3("#ad")`. Render this label and the pinned metadata revision. All four placement lifecycle events carry it:

- `PlacementPurchased`: original fields, base price, and `#ad` label.
- `PlacementBoosted(id, booster, amount, total, label)`: `total` is the cumulative base plus boost after this contribution.
- `PlacementCancelled(id, refund, earned, label)`: `earned` includes the entire boost.
- `PlacementSettled(id, recipient, earned, label)`: `earned` includes base plus boost.

The `Placement` struct and existing financial/configuration function inputs remain unchanged. V2 adds the totals array to `featured`, and appends the label to cancellation and settlement event signatures. Consumers must use the V2 ABI. Ownership, deposit, withdrawal, and configuration events retain their original signatures.

## Accounting and operating assumptions

At every successful transition:

```text
accountedBalance = totalAvailable + totalEscrowed + totalProceeds
totalEscrowed    = sum(PRICE + totalBoost[id]) over all Status.Open placements
```

Open includes expired records awaiting settlement. With the supported exact-transfer token and no direct donations, the actual token balance equals `accountedBalance`. Unsolicited direct transfers add uncredited surplus; they cannot be recovered or swept. Depositors must use `deposit`. Rebases or a malicious token can invalidate backing assumptions; checking exact deltas cannot establish that a token is honest or prevent future token-level restrictions. Token failures on withdrawals revert atomically so credits remain retryable.

The owner can configure the token once, change the recipient for future purchases, and transfer ownership in two steps. There is no fee change, moderation power, pause, sweep, upgrade, delegated execution, or destruction capability. The owner cannot spend another account's deposit, remove another person's ad merely as administrator, reclaim boosts, or redirect existing escrow. Administrators have normal depositor/recipient rights only for their own balances.

The site/operator should settle expired records to make proceeds withdrawable, index events and pinned metadata, display `#ad` on every paid entry, and explain that third-party boosts are irrevocable even when someone else can immediately cancel the ad. There is no automatic keeper or settlement bounty. Time uses `block.timestamp`, so expiry follows chain timestamps.

## Verification scope

The tests retain the original store regressions and add third-party and repeated boosts, base-only cancellation refunds, recipient pinning, listing transfers, ranking ties, sparse pagination, exact expiry, maximum funded amounts, malformed/fee/no-return tokens, failed withdrawals, callback reentrancy, and deployment from a factory with an explicit owner. Two stateful invariants each run 128 sequences of 128 actions, start with third-party boosts, check independent boost input records and complete fund conservation, and wind down all balances after each sequence.

Tests and local source review do not constitute an independent security audit of V2 or the live IMD token. Independent adversarial review and review of the final deployment parameters remain release responsibilities. No production transactions are performed by this project.

The recorded build/test results, runtime sizes, and lint review are in [local verification](docs/VERIFICATION.md).
