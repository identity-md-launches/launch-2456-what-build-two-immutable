# Local verification

This records the builder's checks, not an independent audit or approval.

## Results

Using the Solidity 0.8.26 compiler and settings pinned in `foundry.toml`:

| Check | Result |
| --- | --- |
| `forge build` | Passed; compiler successful, lint warnings reviewed below |
| `forge test --summary` with the supplied seed | 65 passed, 0 failed, 0 skipped |
| `forge fmt --check` | Passed |
| Original source comparison | Registry, administration base, and exact-transfer library byte-identical to the pinned source |
| Application runtime sizes | Registry: 9,035 bytes; escrow: 9,108 bytes; both below EIP-170's 24,576-byte limit |
| Application creation code sizes | Registry: 9,063 bytes; escrow: 9,482 bytes before its 64 bytes of constructor arguments |
| Library linking | No application link references |
| Deployment regression | Explicit owner retained through factory deployment; no external code needed by constructor; no forbidden runtime escape opcodes |

Seed: `0x593cecbfc6012a81e1df3bd130b0c0742c86c5d1c56b1479d6ea8fa357e50b0b`.

Each of the two stateful suites passed 128 runs of 128 calls (16,384 calls per suite), with zero reverts. The handlers exercise boosts as well as the original custody operations. Each sequence starts with successful third-party boosts, checks independent records of contributed amounts against contract accounting, and finishes by settling every open placement and withdrawing all credits. Unit fuzz tests use 256 cases each.

## Source review

The review concentrated on the changed fund flows. A boost debits only the caller's available balance and adds the same amount to total escrow; it cannot debit a wallet or change placement terms. Cancellation computes the original base-price refund before adding the entire boost to proceeds. Settlement releases base plus boost. Neither close path clears the historical boost or allows a second release. Expired but unsettled records remain fully accounted for while becoming ineligible for boosts or display. The `featured` scan writes ads and totals at the same index and truncates both arrays to the same result count.

Existing trust and withdrawal boundaries remain: only the pinned recipient can claim its proceeds, only depositors can spend their own available credits, and owner rotation cannot redirect existing escrow. The new boost entry point shares the existing reentrancy guard. Token callbacks attempting boost during deposit, withdrawal, or proceeds withdrawal are tested and rejected. Fee, malformed, failing, and no-movement transfers revert the entire attempted withdrawal so credit is preserved.

## Build lint output

No source changes were made merely to suppress warnings in the pinned code. The emitted categories were reviewed as follows:

| Category | Assessment for this implementation |
| --- | --- |
| `non-reentrant-not-first` | The original `configureToken` places `onlyOwner` first. That modifier performs only a storage comparison and makes no external call before the guard. |
| `missing-zero-check` | `configureToken` rejects `token.code.length == 0`, including the zero address. Tests cover this rejection. |
| `uninitialized-local` | Local `uint256 count` counters are zero-initialized by Solidity. Empty and sparse pagination cases are tested. |
| `reentrancy-events` | Transfer events follow verified external token movement under the shared guard. Callback regression tests cover attempted custody reentry. |
| `block-timestamp` | Deadlines and the requested 24-hour lifecycle intentionally use timestamps; last-second and exact-expiry behavior are tested. |
| `require-revert-in-loop` | The unchanged registry validates bounded metadata labels: at most 16 labels, each at most 32 bytes. Validation failure must revert atomically. |

Live-chain IMD behavior, production transactions, explorer verification, Slither, Mythril, and an independent contributor's security review were not part of these local checks. The README identifies the owner's configuration duties and token assumptions; the final deployment and independent release review remain separate steps.
