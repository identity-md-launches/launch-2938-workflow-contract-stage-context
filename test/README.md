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
| `GameEvents.t.sol` | Indexed identities, future change boundaries, compressed idle ranges, fractional credit events, KO ordering, and trophy/credit idempotence. |
| `RaiderCard.t.sol` additions | Decimal and Base64 comparison against Foundry's independent codecs, every metadata field through strict JSON, integer extremes, nested SVG equality, and game-level lazy KO/Dream/demo metadata. |

The invariant runner performs 256 sequences of 96 handler calls with `fail_on_revert = true`. Only the handler's ten selected methods are fuzz targets; arbitrary mock setters and cheatcodes are excluded. Input bounds are encoded directly rather than discarded with `assume`. An explicit smoke test checks that every handler action succeeds and that both recovery methods execute, so guarded no-op paths cannot be mistaken for coverage.

The accounting oracle assigns rewards eagerly to individual raiders every round. It does not reproduce the contract's indices, checkpoint segmentation, aggregate pending deltas, or epoch snapshots. After every handler call, the suite checks individual Scrap earned minus spending, Dreams, damage and score per boss, trophies, cohort counts/power, KO epochs, rest timing, and exact damage conservation before per-boss flooring. Zero-work active records are included. Boss allocation uses the current public boss ID; boss sizing and tier rules have separate unit tests.

Lazy views are bounded to eight boss segments. When a view is incomplete, the handler explicitly pokes it until it converges and asserts completeness before comparing it with the model. It never silently skips the accounting invariant because a view is behind. A separate partition property compares histories processed with budgets of 1–17 against processing with the maximum budget, including multiple queued boundaries and trailing idle rounds.

The supplied conservation, transitions, rounding, adversarial-input, and queue/protocol discovery guides informed the property selection. No subagents, live accounts, keys, external packages, Slither, or Mythril are used.

## Reported implementation defect

The independently executed proof in `.imd-findings.json` demonstrates that a zero-work Wheel run leaves `lastRunWork` at its default or previous nonzero value when the next nap begins. The approved rule requires recording that run's total work, zero. The submitted suite does not assert the stale value as correct. The failing proof is embedded in the report instead of being included as a passing regression test; the oracle deliberately makes no assertion about `lastRunWork`, while continuing to test zero-work accounting. Positive-work run sizing remains covered.

The pre-existing Sepolia tests are opt-in and skipped by the ordinary offline suite. They require a caller-provided fork; no test added here connects to an RPC or changes environment variables.

## Local verification

`forge build`, formatting, and the seeded `forge test --offline --summary` passed: **82 tests passed, 0 failed, 1 optional fork suite skipped**. The invariant completed **24,576 calls with 0 reverts**. The standalone finding proof was separately executed and failed at the expected `lastRunWork` assertion (`1600 != 0`).

An explicit attempt to run the existing Sepolia suite at its documented block **12059021** stopped during setup: PublicNode returned RPC error **-32000**, `historical state ... is not available`. No application assertion was reached in that attempt; live fork verification remains unconfirmed in this run.
