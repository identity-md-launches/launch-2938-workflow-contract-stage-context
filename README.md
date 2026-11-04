# SqueekRaider

Immutable cooperative hamster raid for **Sepolia TEST NETWORK (11155111)**. This is an unofficial community game, not the Squeek mint. It has no fees, prizes, payouts, ERC-20s, treasury, owner, admin, pause, upgrade path, or custody of NFTs. Scrap, Dreams and score are internal game counters. Transactions cost network gas.

This contribution implements the contract stage: application source, tests, ABI exports and deployment/integration documentation. The separate manifest and independent review stages prepare and review `launch.json`; launch services publish source, attest, admit, deploy and verify it. Website implementation and publication follow that handoff. No deployment transaction or manifest is included here.

## Build and test

```sh
forge build
forge test
forge fmt --check
python3 scripts/export-abis.py
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer runs **1**, via IR, and `bytecode_hash = "none"`. Do not change these settings for deployment: runtime size and reproducible bytecode depend on them. Dependencies are ordinary vendored files, with no submodules or install step. `lib/forge-std` is version **v1.9.7**, used only by tests, with its MIT/Apache licenses retained. Production contracts use only internal libraries from `src/`.

The configured fuzz seed is `0x1bf8c676888b7bef9fd1b4cbb8405725ee55dd74682c47db0b1055f1d9fe94a9`; the default is 256 cases per fuzz test. Tests use no environment variables, FFI, filesystem cheatcodes or RPC in the default run. Network tests explicitly skip unless the test runner already has a Sepolia fork:

```sh
forge test --fork-url https://ethereum-sepolia-rpc.publicnode.com \
  --fork-block-number 12059021 --no-storage-caching \
  --match-contract SepoliaIntegrationTest -vv
```

The fork tests verify the real interfaces, a controller, anchoring, and historical active/idle replay. They do not impersonate a production transaction: all changes remain in the local fork. See [validation](docs/VALIDATION.md) for results and coverage.

## Deployment parameters

Deploy **SqueekRaider** only, with zero ETH and these three static address arguments, in order:

| Argument | Sepolia value |
| --- | --- |
| `core_` | `0x980b4424c007caf7a1f3670b48c8eaef7ebc3d44` |
| `nft_` | `0xcb98349c134ab983da5bfd80527dfe2552bdb70f` |
| `staking_` | `0x4b67b739dfd832f4eac67a7aa3bc244fb74cea4f` |

These are the approved workflow's addresses, confirmed through the fork tests. The constructor stores them as immutables, rejects zero addresses, performs no external reads, and creates one **RaiderCard** with `new`. The renderer is pure, has no storage, and its address is available from `renderer()`. Do not deploy another renderer as a separate application or pass an owner argument. The factory and launch wallet acquire no authority.

ABIs are [SqueekRaider](docs/abi/SqueekRaider.json) and [RaiderCard](docs/abi/RaiderCard.json). [API documentation](docs/API.md) describes units, nested tuples and events.

## Rules and accounting

- Stances are `0 STRIKER`, `1 GUARD`, `2 FORAGER`, `3 DREAMER`; `4 NONE` is internal/inactive. A real raider has an ID below `2**255`. Its current controller is `ownerOf(id)`, or `staking.depositor(nft,id)` when the staking contract holds it. Transfers carry the entire game state and any pending change with the NFT. Approvals are not controllers.
- Free play registers one permanent demo per wallet, with ID `2**255 | uint160(wallet)`. Demos are not transferable, can coexist with real raiders, and have maximum level 3 rather than 5. Demo guards and demo targets do not count toward guard cover. If a non-demo target exists, one non-demo guard covers two non-demo targets; a successful block protects the whole target stance, including demos. A demo-only target has no cover. Cover uses **headcounts** so that levels boost damage only.
- Every write has a reentrancy guard. Every action first attempts `advance(64)`. `advance` catches source outages, malformed returns and invalid pages by stopping at the last valid cursor. It has no application-level failure on those paths. Sufficient EVM gas is still required; a reentrant invocation is rejected.
- Round `r` ends at `1793022600 + 600*r`. `liveRound()` is `floor((timestamp-1793022600)/600)+1`. Every gameplay change takes effect at `E = liveRound()+1`, even under settlement lag. Replacement freezes when E **starts**, not when the core eventually settles it. Pending transitions apply before E's move and rewards.
- The first successful source read anchors at its settled round; historical rewards are not granted. An active record is Wheel even if its work is zero. Settled missing rounds are Burrow. A nap starts on the second consecutive Burrow. One intervening idle round does not end a run. At nap start, the last observed run's work is stored, initially 1600; no pre-anchor history is inferred.
- Wheel damage is `work * stanceMultiplier * (100+10*level) / 10000`, with multipliers `150, 50, 80, 25`. Every live raider gains one Scrap per Wheel. On Burrow streak positions 2 through 37 inclusive, Foragers gain one Scrap and Dreamers one Dream. Later idle rounds give neither. Score is damage plus `300*Dreams`. Rewards stop at a KO snapshot.
- A nap's move is `uint256(keccak256(abi.encode(lastWheelDataHash, bossId))) % 3`: Frenzy targets Strikers, Quake Foragers, Nightmare Dreamers. It lands only on the first Wheel after at least 18 consecutive Burrows, before damage. Guards are never targets. This uses settled hamster data and is not a claim of unpredictable or financially valuable randomness.
- `W = sum(alivePower[s]*multiplier[s])/150`, with `alivePower` the sum of live equipment multipliers. Boss HP is `3*clamp(lastRunWork,1000,12000)*(100+W)*150/10000 * 13**tier/10**tier`. Tiers 0,1,2 cycle; three bosses form a season. When W changes, remaining HP and displayed maximum HP both scale by `(100+newW)/(100+oldW)`, preserving the bar's proportion apart from integer rounding. Positive HP has a minimum of one internal unit after rescaling.
- All damage and HP are stored in **1/10,000 damage units**. Per-boss credit retains fractional remainders until display, so repeatedly calling `poke` cannot lose or manufacture credit. Boss overkill belongs entirely to the slain boss; only one boss can die per Wheel. Every participant with positive integer score on that boss gets one trophy lazily, including a KO'd or subsequently buried participant.
- Checkpoints process at most eight boss **segments** (a stance/level change can split one boss). `raider(id)` previews the same bounded work and exposes `caughtUp`. Repeated `poke([id])` advances persisted checkpoints until caught up. `scoreOf` is exact for any single boss even with a large backlog; a season reads three bosses.

## Actions and chosen bounds

`enlist(ids,stance)` is permanent registration while the NFT exists. Initial registration and later stance changes share a six-effective-round cooldown; replacement of the same still-unstarted stance/enlist change is allowed. There is one pending change per raider. Batches contain 1–64 IDs. Duplicate enlist, upgrade or revive attempts revert atomically.

`upgrade(id)` pays `10 * 2**currentLevel` Scrap immediately and changes level at E. It cannot be replaced by a stance change. `revive(id)` pays 20 Scrap and rejoins the current stance at E. KO'd raiders cannot change stance or upgrade. A KO **before** E cancels a queued live-raider change, with no refund of already paid upgrade Scrap. A stance change applied at E can avoid that same round's move. These cancellation semantics prevent resurrecting a killed cohort through stale queue entries.

`rest(ids)` is permissionless and free after six **settled Burrow rounds since that raider's KO**. These six need not be consecutive. It queues revival for E and does not bypass an existing pending change. `bury(id)` is permissionless for a non-demo whose `ownerOf` reverts. It queues unpowering and terminal burial at E, cancels a replaceable pending action, and retains historical score. It may supersede an unstarted upgrade for a burned NFT; paid Scrap is not refunded. An intervening KO cannot cancel burn cleanup. Buried IDs cannot register again, and this assumes the Squeek collection does not reuse burned IDs.

`advance(maxRounds)` processes at most **128 active or queued round steps** per call and fetches at most **8 pages of 16 active records**. An active and queued event at the same round use one step. Idle gaps are processed arithmetically, split at queued rounds, with constant work per gap. Source reads receive a **500,000 gas cap** and bounded return buffers. The actual Sepolia page is a single dynamic struct with an outer ABI offset; the reader also accepts the equivalent flat tuple in the brief. Invalid certification, ordering or cumulative work halts progress without skipping unprocessed records.

A move increments one stance's KO epoch and snapshots its indices; it never iterates raiders. A queued round applies a fixed 5×5 transition matrix for current source epochs. Thus processing work depends on selected rounds and fixed stance counts, not party size. Registration data, boss snapshots and pending boundaries remain in storage for historical score queries.

## After launch

There are **no owner-settable settings or initialization calls**. The three external dependencies are fully specified and immutable. The independent reviewer and launch services must verify those arguments, compiled bytes and constructor/renderer deployment before release. Tests are not an independent security audit. No Slither or Mythril result is claimed.

Launch services publish the accepted contract and site source, deploy through the approved factory, verify SqueekRaider and its child renderer on Blockscout, and hand the confirmed address and deployment block to the frontend. Only that handoff populates the site config; this repository contains no guessed deployment address. Signed artifacts, policy linkage and admission are service responsibilities.

Any wallet may advance the game, checkpoint raiders, rest eligible KO'd raiders, and bury burned NFTs. There is no appointed operator and no economic incentive beyond play; a stalled core means the game stays at its last certified state. External controller reads are performed on each restricted action. The game trusts the approved core's settled history and the NFT/staking ownership semantics; there is no recovery admin if those dependencies fail or change incompatibly.

The frontend should label Sepolia TEST NETWORK and no prizes, simulate writes, show Scrap costs, and keep writes pending until receipts. A single Multicall3 **eth_call** can perform `advance(128)` followed by views so reads share an ephemeral advanced state; this must use normal calls, not STATICCALL. Use `advance(64)` for the explicit Advance button. Show `liveRound()-processedThrough()` as the specified lag metric (it includes the in-progress live round), and `caughtUp`/pending changes from each raider. Page logs from the deployment block in ranges of at most 10,000 blocks, cache them, and expand idle range/cohort KO events as described in the API documentation. Real Squeek art and account discovery come from the approved Squeekchain API; the on-chain card renderer supplies the prescribed hamster card and is not an NFT metadata fetcher.
