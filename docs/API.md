# Contract API and indexing

Import the compiler-generated ABIs in `docs/abi/`. IDs, scores, balances and damage units must be represented with arbitrary-precision integers in clients, never JavaScript `Number`. Round and boss IDs are `uint64`. The deployed application is SqueekRaider; `renderer()` returns its child RaiderCard.

## Writes

All functions below are nonpayable and guarded against reentrancy. All actions other than `advance` first attempt 64 round steps. A failed batch reverts the whole batch, including that attempt to advance.

| Function | Caller | Effect |
| --- | --- | --- |
| `advance(uint256 maxRounds) -> uint64` | Anyone | Returns the new processed cursor; bounded best effort. Zero anchors an unanchored game but processes no steps afterward. |
| `enlist(uint256[] ids,uint8 stance)` | Each ID's controller | Register real IDs and queue first entry. |
| `enlistDemo(uint8 stance) -> uint256` | Wallet itself | Register its deterministic demo ID once. |
| `setStance(uint256[] ids,uint8 stance)` | Each controller | Queue a stance change or replace an unstarted stance/enlist change. |
| `upgrade(uint256 id)` | Controller | Pay the current level's Scrap price; queue the next level. |
| `revive(uint256 id)` | Controller | Pay 20 Scrap; queue return from KO. |
| `rest(uint256[] ids)` | Anyone | Queue free revival after six later settled Burrows. |
| `bury(uint256 id)` | Anyone | Queue permanent removal if the real NFT's `ownerOf` reverts. |
| `poke(uint256[] ids)` | Anyone | Persist up to eight boss segments per ID, without changing stance or spending Scrap. |

Stance values are 0 Striker, 1 Guard, 2 Forager, 3 Dreamer. Do not submit 4 (None). Batches contain 1–64 IDs. Before writes, show Scrap cost and simulate the exact transaction with its actual caller. `NeedsPoke` means to checkpoint separately, then retry; reverting the attempted action does not persist its partial checkpoint. `PendingLocked` includes an effective round that has already started while settlement remains behind it.

## Views

| Function / getter | Meaning |
| --- | --- |
| `core()`, `nft()`, `staking()`, `renderer()` | Immutable dependencies. |
| `anchored()`, `processedThrough()`, `processedWork()` | First source anchor and last applied round/cumulative work. |
| `GENESIS()`, `MAX_ADVANCE()` | Clock origin and 128-step cap. |
| `liveRound()`, `effectiveRound()` | In-progress round and future action round. `liveRound` is zero before genesis; `effectiveRound` rejects that time. |
| `demoId(address)`, `controllerOf(uint256)` | Demo ID and current live controller. A failed owner/depositor read returns zero from the controller view; no zero controller is assigned. |
| `raider(uint256)` | A `RaiderView`, described below. |
| `boss()`, `bossAt(uint64)` | Current or historical `Boss`, described below. Unknown historical IDs return an empty struct. |
| `bossId()`, `season()` | IDs begin at 1; seasons group three successive bosses. |
| `lastRunWork()` | Previous observed run, default 1600. |
| `pendingMove()` | `(move, napRounds, armed)`, where moves 0/1/2 mean Frenzy/Quake/Nightmare. A move display is meaningful during a nap; armed means at least 18 Burrows. |
| `burrowStreak()`, `totalBurrowRounds()` | Current consecutive idle count and all processed idle rounds since anchor. |
| `cover()` | `(targetStance, targetPower, realTarget, realGuards, blocked)`. Target power uses equipment; the last three fields use non-demo headcounts. |
| `alivePower(uint256)`, `aliveCount(uint256)`, `nonDemoCount(uint256)` | Live equipment sum, all-raider count and real-raider count for stance index 0–3. |
| `koEpoch(uint256)` | Current generation for the stance. Older generations are KO'd. |
| `totalDamageUnits()` | All inflicted damage, including overkill, in units of 1/10,000. |
| `scoreOf(uint64 bossId,uint256 id)` | Exact integer score including unpersisted credit for that boss. No checkpoint backlog limit. Invalid boss IDs return zero. |
| `seasonScoreOf(uint64 seasonId,uint256 id)` | Sum of the three boss scores. Invalid seasons return zero. |
| `cardURI(uint256)` | Base64 JSON containing a Base64 inline SVG card and attributes. Bounded preview, like `raider`. |
| `bossSVG(uint8 tier)` | Raw inline SVG, valid tiers 0–2. |

`RaiderView` contains `data`, `ko`, and `caughtUp`. `data` is the nested `Raider` tuple:

- `enlisted`, `isDemo`, `buried`, `stance`, `level` describe the projected state.
- `epoch`, `cursorBoss`, and `checkpoint` are accounting cursors. Checkpoint damage is an index numerator; Scrap and Dream indices are whole rewards per eligible member.
- `lastStanceRound` is the effective round of the last submitted stance/enlist change, used for the six-round cooldown.
- `scrap` is spendable Scrap; `dreams` and `damage` are lifetime credited totals; `bossesSlain` is the trophy count.
- `pending` contains `round`, `fromEpoch`, `from`, `to`, `level`, `kind`. Kinds are `0 None`, `1 Enlist`, `2 Stance`, `3 Upgrade`, `4 Revive`, `5 Rest`, `6 Bury`. A zero round means no pending change. NONE is 4 for from/to.

The view projects at most eight segments. When `caughtUp` is false, its totals and potentially stance/KO are an intermediate checkpoint, not a promise of current state. Persist `poke` until true before treating all those fields as current. A projected applied or KO-canceled pending change disappears from this view even before its lazy record is persisted. `scoreOf` remains exact regardless. For a never-registered ID, `data.enlisted` is false; ignore the remaining zero-value stance fields.

`Boss` contains `id`, `seasonId`, `tier`, `summonedAt`, `slainAt`, `previousRunWork`, `hpUnits`, `maxHpUnits`, `damageUnits`. Divide the last three values by **10,000** for display. `slainAt == 0` means not slain. Constructor summoning occurs at round zero. The tier multiplier applies to the HP numerator before division; maximum HP is rescaled alongside remaining HP when party weight changes.

## Events and cache reconstruction

All per-raider events index `id`. Demo status is explicit in `Enlisted` and `raider`, and follows from bit 255 in other ID events. Ignore mock/test contracts when collecting deployed application logs.

- `Anchored` establishes the starting cursor. `RoundApplied(fromRound,throughRound,wheel,work,bossId)` is a single Wheel round when `wheel` is true, or an inclusive all-idle range when false. Never assume one event per idle round.
- `Enlisted(id,controller,isDemo)` discovers participants. `ChangeQueued` records round, kind and destination. A new queue event replaces the previously canceled pending change. `ChangeApplied` and `ChangeCancelled` are lazy per-ID notifications and can arrive well after the effective round.
- `NapStarted` and `MoveLanded` report the stored move and its result. `KO(stance,epoch,bossId,round,power)` identifies an **entire cohort**. Every raider still in that stance/epoch at that round is KO'd; there is intentionally no unbounded per-raider event loop. `raider` or the documented pending/epoch rules resolve an individual membership.
- `BossSlain` reports all inflicted units on the old boss, including overkill. `BossSummoned` starts the next. `PowerChanged` reports W and the resulting remaining HP in internal units.
- `Credited(id,bossId,seasonId,damage,dreams)` reports newly persisted **whole** damage and Dreams. Fractions are retained on chain, not lost at each checkpoint. A zero-damage Dream credit is valid. `ScrapCredited` and `ScrapSpent` update the spendable counter. `TrophyCredited` is emitted once per earned boss trophy. `Checkpointed` reports cursor, KO and completion even when no new score accrued.

Discover IDs from events and query `scoreOf`/`seasonScoreOf` for leaderboard values. Summing `Credited` logs alone can omit still-lazy players. Keep demo and real leaderboards separate. Attribute current wallet standings using live owner/depositor checks; an Enlisted event's controller is only the controller at registration. Fetch API account lists in pages and confirm on-chain ownership, including staking.

Within a Multicall3 eth_call, call `advance(128)` first and then views with normal CALL semantics. It simulates state changes only for that call; send an actual Advance transaction to persist global progress. Refresh after receipts and reorgs. Log scans should start at the confirmed deployment block, use ranges of at most 10,000 blocks and cache by chain/address/block hash. Use the approved keyless RPC fallbacks (PublicNode, dRPC, Tenderly) in the separately implemented frontend.

## Errors

ABI errors carry no strings. Suggested plain-language groups:

- `NotController`: connect the current NFT holder or recorded staking depositor.
- `InvalidStance`, `InvalidBatch`, `InvalidId`, `InvalidAddress`: invalid input.
- `AlreadyEnlisted`, `NotEnlisted`: duplicate registration or missing/buried participant.
- `SourceUnavailable`: first anchoring has not succeeded; retry when the core is readable.
- `BeforeGenesis`: the round clock has not started.
- `PendingLocked`, `PendingExists`, `Cooldown`: wait for the queued action or cooldown; advance settlement when behind.
- `NeedsPoke`: checkpoint this raider separately, possibly several times.
- `KnockedOut`, `NotKnockedOut`, `NotRested`: this action is unavailable in the current KO/rest state.
- `InsufficientScrap`, `MaxLevel`: show the cost or level cap.
- `NotBurned`: only burned real NFTs can be buried.
- `Reentrant`: nested writes are rejected.

## Pure renderer

`RaiderCard.cardURI(Card)` and `cardSVG(Card)` accept a supplied presentation struct, without storage or contract calls. Fields are ID, stance, level, KO, enlisted, Burrow, demo flag, trophies, Scrap, Dreams and score. `stanceName` returns a fixed label; `bossSVG` returns a tier-tinted 16×16 owl.

The 16×16 hamster uses the approved 14 rows, exact outline/eye/belly/pink palette, and fur chosen by `keccak256(abi.encode(id)) % 4`. Closed eyes mark KO, non-enlisted cards are grey, and the backdrop is moon/Burrow or spokes/Wheel. Item colors at levels 0–5 are `#A1A5B7`, `#79C796`, `#71BCE0`, `#AA8BE3`, `#E8BD62`, `#F08DB1`. All JSON strings are fixed labels or decimal numbers; no user text is interpolated.
