# Source provenance

The base is the requester-selected repository [identity-md-launches/launch-1811-build-technical-foundation-hooks](https://github.com/identity-md-launches/launch-1811-build-technical-foundation-hooks/tree/46e17ea70534e8a7ac2c4ff78501a3c183d32da8), pinned to commit `46e17ea70534e8a7ac2c4ff78501a3c183d32da8`. Files were retrieved from that exact commit, not a moving branch. The task describes this as the audited source; this deliverable does not independently attest the upstream audit.

## Production source

The following `src/store/` files are copied byte for byte:

| File | SHA-256 |
| --- | --- |
| `HookListingRegistry.sol` | `b868400163017d67a3ab81618bc3e3bb5acf939098a90e769486e6ec5d4f4052` |
| `StoreAdmin.sol` | `20714eb0b2a724ca8bcb9cc3581e4451f3d59e3414a559deb736f3cfacb76337` |
| `ExactStoreToken.sol` | `b745c4cee9e13edd71cd8290f52720197cf58da07bc7a5db9021d610719bf387` |

The original `FeaturedPlacements.sol` has SHA-256 `38c8dfdda297d9107f69da9908c0d257f62b2a0af70508de39f69e634a517f7d`. Its replacement is `FeaturedPlacementsV2.sol`, with these changes:

- Rename the contract and set `DURATION = 24 hours`; preserve the price.
- Add guarded `boost`, historical `totalBoost`, and `rankOf`.
- Move boosted amounts from available credit into escrow; include them entirely in the pinned recipient's proceeds on cancellation or settlement without changing base-refund rounding.
- Add aligned total-paid values to the bounded `featured` scan. Ranking stays in the website: total descending, then ID ascending.
- Add a labelled boost event, and include `#ad` in cancellation and settlement events so every placement lifecycle event is labelled. The purchase event and stored placement label are retained.
- Document those changes in NatSpec. Remaining constructor, administration, registry, deposit, withdrawal, purchase, token checks, and guard behavior are retained.

## Tests

Imported from the same commit:

- `test/HookListingRegistry.t.sol`
- `test/FeaturedPlacements.t.sol`
- `test/FeaturedAdversarial.t.sol`
- `test/FeaturedTransfer.t.sol`
- `test/FeaturedInvariant.t.sol`
- `test/FeaturedTransferInvariant.t.sol`
- `test/helpers/StoreFixture.sol`
- `test/helpers/StoreTokenMock.sol`
- `test/helpers/TestToken.sol`

Adaptations rename the referenced contract, set the shared duration to 24 hours, consume the new `featured` return shape, and move two day-one operations to half-duration so they continue to exercise pre-expiry behavior. The original invariants now include boosts, ghost input accounting, live-placement uniqueness and total-paid pagination. The hostile-token suite additionally exercises boosts and boosted proceeds. `FeaturedBoost.t.sol` and `Deployment.t.sol` are new. No original store test is discarded.

## Vendored test dependencies

All dependencies are ordinary source files copied from the same pinned repository commit:

| Dependency | Included paths | Upstream tree/blob at the pinned repository commit | License |
| --- | --- | --- | --- |
| Forge standard library | `lib/forge-std/src/**`, both license files | Tree `7a194b20239b9f7dac295c9f33216f5a1e1025ca` for `lib/forge-std` | MIT / Apache-2.0 |
| Solmate test token base | `lib/solmate/src/tokens/ERC20.sol`, `lib/solmate/LICENSE` | Exact file from the pinned source commit | AGPL-3.0-only as declared in the source; accompanying license retained |

These dependencies are used only by tests. Application source imports only the four local store files and requires no linked library deployment. `LICENSE` preserves the upstream Hooks Store contributors' MIT license; vendored files retain their own notices.
