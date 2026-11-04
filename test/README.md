# Independent Foundry tests

These tests exercise the accepted implementation against the approved SqueekRaider rules. They add no dependencies or configuration changes and run offline with the vendored forge-std.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x1bf8c676888b7bef9fd1b4cbb8405725ee55dd74682c47db0b1055f1d9fe94a9 forge test
```

| File | Properties exercised |
| --- | --- |
| `RaiderInvariant.t.sol`, `invariant/RaiderHandler.sol` | Nine actors, four stances, real and demo raiders, late entry, replaceable changes, upgrades, paid revival, permissionless rest, transfers, staking, burns, settlement lag, checkpointing, Wheel and Burrow rounds. |
| `ActionFailures.t.sol` | Genesis and source failures, 0/64/65-element batches, atomic rollback, duplicate entries, malformed ownership/depositor data, unauthorized spending, missing staked controllers, ID namespace edges, and rejection of ETH. |
| `CoreReaderAdversarial.t.sol` | Both page ABI envelopes, 0–16 valid records, malformed offsets and integers, truncated/trailing data, exact return-size limits, return-data bombs, and gas exhaustion. |
| `RoundProperties.t.sol` | Equivalence of small and large advance budgets, queued idle boundaries, the 128-active-round cap, lagged action timing, zero and maximum work, overkill, previous-run clamps, tiers and seasons. |
| `GasPartition.t.sol` | The gas-bounded `advance` (`ADVANCE_GAS`/`GAS_RESERVE`): draining a mixed active/idle/queued backlog with random per-call gas limits (directly and through actions) matches one-step processing exactly, every stop resumes, a starved call is a no-op, and a single-ID action succeeds at every gas limit with an effective round independent of processing progress. |
| `GameEvents.t.sol` | Indexed identities, future change boundaries, compressed idle ranges, fractional credit events, KO ordering, and trophy/credit idempotence. |
| `RaiderCard.t.sol` additions | Decimal and Base64 comparison against Foundry's independent codecs, every metadata field through strict JSON, integer extremes, nested SVG equality, and game-level lazy KO/Dream/demo metadata. |

The invariant runner performs 256 sequences of 96 handler calls with `fail_on_revert = true`. Only the handler's ten selected methods are fuzz targets; arbitrary mock setters and cheatcodes are excluded. Input bounds are encoded directly rather than discarded with `assume`. An explicit smoke test checks that every handler action succeeds and that both recovery methods execute, so guarded no-op paths cannot be mistaken for coverage.

The accounting oracle assigns rewards eagerly to individual raiders every round. It does not reproduce the contract's indices, checkpoint segmentation, aggregate pending deltas, or epoch snapshots. After every handler call, the suite checks individual Scrap earned minus spending, Dreams, damage and score per boss, trophies, cohort counts/power, KO epochs, rest timing, and exact damage conservation before per-boss flooring. Zero-work active records are included. Boss allocation uses the current public boss ID; boss sizing and tier rules have separate unit tests.

Lazy views are bounded to eight boss segments. When a view is incomplete, the handler explicitly pokes it until it converges and asserts completeness before comparing it with the model. It never silently skips the accounting invariant because a view is behind. A separate partition property compares histories processed with budgets of 1–17 against processing with the maximum budget, including multiple queued boundaries and trailing idle rounds.

The supplied conservation, transitions, rounding, adversarial-input, and queue/protocol discovery guides informed the property selection. No subagents, live accounts, keys, external packages, Slither, or Mythril are used.

## Revision notes

The earlier zero-work `lastRunWork` finding is fixed in the accepted revision. The oracle now models it: at each nap start it stores the ended run's total, zero included. It also models the revision's rule that a nap before the first processed Wheel keeps the default 1600 and arms no move. The invariant checks `lastRunWork` and `pendingMove()` (nap length and armed) after every call.

## Reported implementation defect

`.imd-findings.json` reports a **low** liveness issue with a runnable proof. The inner advance leaves only `GAS_RESERVE` (2,000,000 gas) for the action. During a 64-round settlement backlog, a 64-ID `enlist` therefore reverts out of gas at every limit from 4M to 13.5M, though it needs about 4M without a backlog. The suite does not assert this behaviour as correct. It also lists, as info, the documented choice that a pre-first-Wheel nap has no move.

The pre-existing Sepolia tests are opt-in and skipped by the ordinary offline suite. They require a caller-provided fork; no test added here connects to an RPC or changes environment variables.

## Local verification

`forge build` and the seeded `forge test` passed: **94 tests passed, 0 failed, 1 optional fork suite skipped**. The invariant ran 256 sequences of 96 calls with 0 reverts. The standalone finding proof was run on its own: its control passed and its backlog case failed at the expected out-of-gas assertion.
