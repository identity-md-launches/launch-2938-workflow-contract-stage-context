# Validation record

The delivered sources were built with the repository's Solidity 0.8.26 configuration. The following checks completed successfully:

| Check | Result |
| --- | --- |
| `forge build` | Pass |
| `forge build --sizes` | Application runtime and initcode below protocol limits |
| `forge test -vv` with the requested seed | **52 passed, 0 failed**; network-only suite skipped in the default offline run |
| `forge fmt --check` | Pass |
| Sepolia fork at block **12059021** | **2 passed**, real dependencies and historical round replay |
| ABI export | Both JSON ABIs match the compiled artifacts |

The seed was both pinned in `foundry.toml` and supplied as `FOUNDRY_FUZZ_SEED=0x1bf8c676888b7bef9fd1b4cbb8405725ee55dd74682c47db0b1055f1d9fe94a9` for the final offline test command. Each of four fuzz tests runs 256 cases. Default tests are independent of network, caller environment and test order. The fork suite uses the caller-provided fork and contains no automatic RPC connection, environment reads or credentials.

## Deployment sizes

| Contract | Runtime bytes | Creation bytes | Initcode including launch arguments |
| --- | ---: | ---: | ---: |
| SqueekRaider | 24,542 | 33,907 | 34,003 |
| RaiderCard | 7,997 | 8,023 | 8,023 |

SqueekRaider's creation code already includes its child renderer's creation code. Runtime must remain below 24,576 bytes and initcode below 49,152 bytes. Runtime margin is only 34 bytes, so compiler settings must stay pinned and any future source revision must repeat the size check. There are no external library link placeholders.

`DeploymentTest` uses CREATE2 with the three canonical addresses on an otherwise empty local dependency set. It verifies that the constructor succeeds, the renderer exists, no `owner()` authority is exposed, and both application runtimes pass the same reachable-opcode scan used by the supplied protected floor (no DELEGATECALL, CALLCODE or SELFDESTRUCT). This rehearsal does not replace the launch service's actual signed transaction simulation.

## Behavioral coverage

- Future-round entry, initial anchoring without retroactive rewards, replacement boundaries, six-round stance cooldown, and action timing under 100 rounds of settlement lag.
- Exact 17/18-round move boundary, all three move targets, guard immunity, real guard cover, demo exclusions, and level-independent cover.
- KO between submission and E, a stance escape at E before the move, upgrade payment cancellation, repeated KO epochs, and no ghost cohort power.
- Paid revive while another raider kills the boss, permissionless free rest after six later Burrows, insufficient Scrap, invalid and duplicate actions, and KO restrictions.
- HP ratios on entry, upgrade, stance and removal; previous-run sizing, tier and season progression; overkill attribution; lazy trophies including burned contributors.
- Controller changes following NFT transfers and staking deposits, one demo per wallet, real/demo level caps, and permanent burn cleanup despite an intervening KO.
- Zero-work runs stored in `lastRunWork` and clamped on the next boss; a nap before the first processed Wheel storing nothing and landing nothing, with the following nap normal; no stance item on a card whose raider has no applied stance.
- Bounded active pagination, cursor resumption, million-round idle gaps, reward cutoff at nap round 37, and eight-segment checkpoint progression across twenty bosses.
- Randomized multi-raider histories with stance changes, upgrades, KOs, revives, idle gaps, staggered checkpoint frequency and boss kills. For every boss, summed integer damage credits never exceed inflicted damage and differ by less than one unit per raider; the sum across bosses equals lifetime credited totals.
- Separate randomized Dreamer histories independently count eligible idle rewards per boss, verifying both Dream attribution and damage flooring with level changes.
- Reentrant callbacks into all nine writes must return the guard's exact error. Read failures, malformed and oversized return data, invalid certifications, future settlements, unordered records and decreasing cumulative work fail closed without moving the cursor.
- Base64 RFC 4648 vectors and randomized round trips, strict decoded JSON parsing, nested SVG equality, the supplied hamster palette, KO eyes, grey cards, level-tinted items, backdrop and owl tiers.

## Live-interface observation

The Sepolia core returns `roundPage` as a **single dynamic struct**, whose ABI encoding begins with an outer offset of 32 bytes. The reader validates that envelope and also accepts the flat tuple notation in the brief. Both encodings have dedicated local tests. The fork replay processes 48 real historical rounds, checks certified cursors and cumulative work, and confirms that no unregistered participants receive damage.

## Gas and review limits

A focused gas report measured a representative pure renderer `cardURI` call at approximately **6.2 million gas**, down from 13.3 million after materializing the Base64 alphabet only once per encoding. The card is intended for eth_call; clients should bound how many images they include in one RPC request. A full application `cardURI` also includes its bounded raider preview. Idle gap processing is constant work; the million-round test asserts a sub-700,000-gas path including its mock setup calls. A queued round's first boundary costs about 312,000 gas, so `advance` and the advance inside every action stop on a gas bound (10,000,000 spent or 2,000,000 left). `RoundBoundariesTest` drains 64 queued active rounds under the 2^24 transaction cap and matches a one-step-at-a-time game, shows the stopping point does not depend on a caller's higher limit, and fits a 64-ID enlist under the cap during that backlog. Forge does not enforce the cap itself; these tests pass it as the call's gas limit.

Foundry's advisory build lints report patterns including timestamp-based round scheduling, deliberately zero-initialized local counters, range-checked narrow casts, validation reverts inside bounded batches, and events after guarded read-only calls. Those warnings were inspected; the targeted tests cover their relevant behavior. No lint configuration was used to disable the launch's forbidden-opcode or source checks.

This is an implementation and local validation record, **not an independent security audit**. Slither and Mythril were not run. The separate independent reviewer must assess the accepted source and manifest. Publication, signed artifact/policy linkage, admission, deployment, Blockscout verification and frontend address handoff remain launch-service responsibilities.
