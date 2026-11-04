// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CoreReader} from "./CoreReader.sol";
import {ISqueekCore, ISqueekNFT, ISqueekStaking} from "./interfaces/ISqueekchain.sol";
import {RaiderCard} from "./RaiderCard.sol";

/// @notice Immutable, permissionless Sepolia game. Scrap, Dreams and score have no monetary value.
/// @dev Indices are cumulative across bosses and KO epochs. Damage uses exact 1/10,000 units;
///      Scrap / Dreams use headcounts, so equipment never boosts either reward.
contract SqueekRaider {
    uint64 public constant GENESIS = 1_793_022_600;
    uint64 internal constant ROUND_SECONDS = 600;
    uint256 internal constant DEMO_BIT = 1 << 255;
    uint256 internal constant DAMAGE_SCALE = 10_000;
    uint256 public constant MAX_ADVANCE = 128;
    uint256 internal constant MAX_PAGES = 8;
    uint256 internal constant MAX_BATCH = 64;
    uint256 internal constant MAX_CHECKPOINT = 8;
    /// @dev Round processing stops after spending this much gas, so a call fits the 2^24 transaction cap.
    uint256 internal constant ADVANCE_GAS = 10_000_000;
    /// @dev No new step or page starts below this: enough for the costliest step and a small action.
    uint256 internal constant GAS_RESERVE = 2_000_000;
    uint8 internal constant STRIKER = 0;
    uint8 internal constant GUARD = 1;
    uint8 internal constant FORAGER = 2;
    uint8 internal constant DREAMER = 3;
    uint8 internal constant NONE = 4;

    address public immutable core;
    address public immutable nft;
    address public immutable staking;
    RaiderCard public immutable renderer;

    enum Change {
        None,
        Enlist,
        Stance,
        Upgrade,
        Revive,
        Rest,
        Bury
    }

    struct Index {
        uint256 damage;
        uint256 scrap;
        uint256 dreams;
    }

    struct Pending {
        uint64 round;
        uint64 fromEpoch;
        uint8 from;
        uint8 to;
        uint8 level;
        Change kind;
    }

    struct Raider {
        bool enlisted;
        bool isDemo;
        bool buried;
        uint8 stance;
        uint8 level;
        uint64 epoch;
        uint64 cursorBoss;
        uint64 lastStanceRound;
        Index checkpoint;
        uint256 scrap;
        uint256 dreams;
        uint256 damage;
        uint256 bossesSlain;
        Pending pending;
    }

    struct RaiderView {
        Raider data;
        bool ko;
        bool caughtUp;
    }

    struct Delta {
        uint256 outPower;
        uint256 inPower;
        uint256 outReal;
        uint256 inReal;
        uint256 count;
    }

    struct Boundary {
        uint64 bossId;
        Index[4] idx;
        uint64[4] epochs;
    }

    struct Knockout {
        uint64 bossId;
        uint64 round;
        uint64 burrow;
        Index idx;
    }

    struct End {
        uint64 bossId;
        Index idx;
    }

    struct Boss {
        uint64 id;
        uint64 seasonId;
        uint8 tier;
        uint64 summonedAt;
        uint64 slainAt;
        uint64 previousRunWork;
        uint256 hpUnits;
        uint256 maxHpUnits;
        uint256 damageUnits;
    }

    struct Credit {
        uint256 damageUnits;
        uint256 dreams;
        bool trophy;
    }

    struct CreditOp {
        uint64 bossId;
        uint256 damageUnits;
        uint256 dreams;
        uint256 scrap;
        bool trophy;
    }

    struct Preview {
        Raider data;
        CreditOp[8] ops;
        uint256 count;
        bool complete;
        bool applied;
        bool cancelled;
    }

    bool public anchored;
    uint64 public processedThrough;
    uint64 public processedWork;
    uint64 public lastRunWork = 1600;
    uint64 private runWork;
    uint64 public burrowStreak;
    uint64 public totalBurrowRounds;
    bytes32 private lastWheelHash;
    uint8 private napMove;
    bool private wheelSeen;
    uint64 public bossId = 1;
    uint256 public totalDamageUnits;
    uint256[4] public alivePower;
    uint256[4] public aliveCount;
    uint256[4] public nonDemoCount;
    uint64[4] public koEpoch;
    Index[4] private indices;
    mapping(uint64 => mapping(uint8 => mapping(uint8 => mapping(uint64 => Delta)))) private pendingDelta;
    mapping(uint64 => Boundary) private _boundaries;
    mapping(uint8 => mapping(uint64 => Knockout)) private knockouts;
    mapping(uint64 => Index[4]) private bossEnd;
    mapping(uint64 => Boss) private _bosses;
    mapping(uint256 => Raider) private _raiders;
    mapping(uint256 => mapping(uint64 => Credit)) private credits;
    uint64[] private _queuedRounds;
    uint256 private _queueHead;
    uint256 private _entered;

    error Reentrant();
    error InvalidAddress();
    error InvalidStance();
    error InvalidBatch();
    error InvalidId();
    error NotController();
    error AlreadyEnlisted();
    error NotEnlisted();
    error SourceUnavailable();
    error BeforeGenesis();
    error PendingLocked();
    error PendingExists();
    error NeedsPoke();
    error Cooldown();
    error KnockedOut();
    error NotKnockedOut();
    error NotRested();
    error InsufficientScrap();
    error MaxLevel();
    error NotBurned();

    event Anchored(uint64 indexed round, uint64 cumulativeWork);
    /// @dev An idle range is one event, rather than an unbounded event per missing round.
    event RoundApplied(
        uint64 indexed fromRound, uint64 indexed throughRound, bool wheel, uint64 work, uint64 bossId
    );
    event NapStarted(uint64 indexed round, uint64 indexed bossId, uint8 move, uint64 previousRunWork);
    event MoveLanded(
        uint64 indexed round, uint64 indexed bossId, uint8 move, bool blocked, uint256 targetPower
    );
    /// @dev Cohort event: every member of (stance, epoch) is KO'd, without iterating token IDs.
    event KO(uint8 indexed stance, uint64 indexed epoch, uint64 indexed bossId, uint64 round, uint256 power);
    event BossSlain(uint64 indexed bossId, uint64 indexed seasonId, uint64 round, uint256 damageUnits);
    event BossSummoned(
        uint64 indexed bossId, uint64 indexed seasonId, uint8 tier, uint256 hpUnits, uint64 previousRunWork
    );
    event PowerChanged(uint64 indexed round, uint256 previousWeight, uint256 newWeight, uint256 hpUnits);
    event Enlisted(uint256 indexed id, address indexed controller, bool isDemo);
    event ChangeQueued(uint256 indexed id, uint64 indexed round, Change kind, uint8 stance, uint8 level);
    event ChangeApplied(uint256 indexed id, uint64 indexed round, Change kind);
    event ChangeCancelled(uint256 indexed id, uint64 indexed round, Change kind);
    event ScrapSpent(uint256 indexed id, uint256 amount, Change reason);
    event Credited(
        uint256 indexed id, uint64 indexed bossId, uint64 indexed seasonId, uint256 damage, uint256 dreams
    );
    event ScrapCredited(uint256 indexed id, uint256 amount);
    event TrophyCredited(uint256 indexed id, uint64 indexed bossId);
    event Checkpointed(uint256 indexed id, uint64 indexed cursorBoss, bool ko, bool caughtUp);

    modifier nonReentrant() {
        if (_entered != 0) revert Reentrant();
        _entered = 1;
        _;
        _entered = 0;
    }

    /// @dev No external reads. The factory is deliberately given no privilege.
    constructor(address core_, address nft_, address staking_) {
        if (core_ == address(0) || nft_ == address(0) || staking_ == address(0)) revert InvalidAddress();
        core = core_;
        nft = nft_;
        staking = staking_;
        renderer = new RaiderCard();
        _summon(0);
    }

    function liveRound() public view returns (uint64) {
        if (block.timestamp < GENESIS) return 0;
        return uint64((block.timestamp - GENESIS) / ROUND_SECONDS + 1);
    }

    function effectiveRound() public view returns (uint64) {
        if (block.timestamp < GENESIS) revert BeforeGenesis();
        return liveRound() + 1;
    }

    function demoId(address wallet) public pure returns (uint256) {
        return DEMO_BIT | uint160(wallet);
    }

    function controllerOf(uint256 id) public view returns (address) {
        if (id >= DEMO_BIT) {
            address wallet = address(uint160(id));
            return id == demoId(wallet) ? wallet : address(0);
        }
        (bool ok, bytes memory data) = CoreReader.read(nft, abi.encodeCall(ISqueekNFT.ownerOf, (id)), 32);
        if (!ok || data.length != 32 || CoreReader.word(data, 0) > type(uint160).max) return address(0);
        address holder = address(uint160(CoreReader.word(data, 0)));
        if (holder != staking) return holder;
        (ok, data) = CoreReader.read(staking, abi.encodeCall(ISqueekStaking.depositor, (nft, id)), 32);
        if (!ok || data.length != 32 || CoreReader.word(data, 0) > type(uint160).max) return address(0);
        return address(uint160(CoreReader.word(data, 0)));
    }

    /// @notice Best effort; unavailable or invalid source data stops progress without reverting.
    /// @dev Like every EVM call, needs sufficient gas. maxRounds counts active/queued round steps, and
    ///      a backlog too costly for one transaction stops early: call again to resume at the cursor.
    function advance(uint256 maxRounds) external nonReentrant returns (uint64) {
        _advance(maxRounds);
        return processedThrough;
    }

    function _advance(uint256 budget) internal {
        (bool ok, uint64 settled, uint64 work) = CoreReader.readState(core);
        uint64 live = liveRound();
        if (!ok || live == 0 || settled >= live) return;
        if (!anchored) {
            anchored = true;
            processedThrough = settled;
            processedWork = work;
            emit Anchored(settled, work);
            return;
        }
        if (budget > MAX_ADVANCE) budget = MAX_ADVANCE;
        uint256 floor = gasleft();
        floor = floor > ADVANCE_GAS + GAS_RESERVE ? floor - ADVANCE_GAS : GAS_RESERVE;
        for (
            uint256 pages;
            pages < MAX_PAGES && budget != 0 && processedThrough < settled && gasleft() > floor;
            ++pages
        ) {
            CoreReader.Page memory p;
            (ok, p) = CoreReader.page(core, processedThrough, settled, processedWork);
            if (!ok) return;
            budget = _page(p, budget, floor);
        }
    }

    function _page(CoreReader.Page memory p, uint256 budget, uint256 floor) internal returns (uint256) {
        uint256 nextRecord;
        while (processedThrough < p.through && budget != 0 && gasleft() > floor) {
            uint64 active = nextRecord < p.rounds.length ? p.rounds[nextRecord].roundId : type(uint64).max;
            uint64 queued = _queueHead < _queuedRounds.length ? _queuedRounds[_queueHead] : type(uint64).max;
            uint64 next = active < queued ? active : queued;
            if (next > p.through) {
                _idle(p.through);
                break;
            }
            if (next > processedThrough + 1) _idle(next - 1);
            if (queued == next) {
                _applyQueued(next);
                ++_queueHead;
            }
            if (active == next) {
                ISqueekCore.Round memory r = p.rounds[nextRecord++];
                _wheel(r.roundId, r.cumulativeWork - processedWork, r.dataHash);
                processedWork = r.cumulativeWork;
                processedThrough = next;
            } else {
                _idle(next);
            }
            --budget;
        }
        return budget;
    }

    function _idle(uint64 through) internal {
        uint64 from = processedThrough + 1;
        if (through < from) return;
        uint64 old = burrowStreak;
        uint64 count = through - processedThrough;
        uint64 streak = old + count;
        // A nap before the first processed Wheel follows no observed run and has no known last
        // dataHash: it keeps the default lastRunWork and arms no move. Every later nap follows a Wheel.
        if (old < 2 && streak >= 2 && wheelSeen) {
            lastRunWork = runWork;
            runWork = 0;
            napMove = uint8(uint256(keccak256(abi.encode(lastWheelHash, bossId))) % 3);
            emit NapStarted(from + (1 - old), bossId, napMove, lastRunWork);
        }
        uint64 end = streak < 37 ? streak : 37;
        uint64 start = old > 1 ? old : 1;
        if (end > start) {
            indices[FORAGER].scrap += end - start;
            indices[DREAMER].dreams += end - start;
        }
        burrowStreak = streak;
        totalBurrowRounds += count;
        processedThrough = through;
        emit RoundApplied(from, through, false, 0, bossId);
    }

    function _wheel(uint64 round, uint64 work, bytes32 dataHash) internal {
        if (burrowStreak >= 18 && wheelSeen) _landMove(round);
        wheelSeen = true;
        burrowStreak = 0;
        runWork += work;
        lastWheelHash = dataHash;
        uint256 damage;
        for (uint8 s; s < 4; ++s) {
            uint256 increment = uint256(work) * multiplier(s);
            indices[s].damage += increment;
            ++indices[s].scrap;
            damage += alivePower[s] * increment;
        }
        Boss storage b = _bosses[bossId];
        b.damageUnits += damage;
        totalDamageUnits += damage;
        emit RoundApplied(round, round, true, work, bossId);
        if (damage != 0 && damage >= b.hpUnits) {
            b.hpUnits = 0;
            b.slainAt = round;
            for (uint8 s; s < 4; ++s) {
                bossEnd[bossId][s] = indices[s];
            }
            emit BossSlain(bossId, b.seasonId, round, b.damageUnits);
            ++bossId;
            _summon(round);
        } else {
            b.hpUnits -= damage;
        }
    }

    function _landMove(uint64 round) internal {
        uint8 target = _target();
        uint256 power = alivePower[target];
        // Cover counts real raiders, not equipment: levels boost damage only.
        bool blocked = _blocked(target);
        emit MoveLanded(round, bossId, napMove, blocked, power);
        if (power == 0 || blocked) return;
        uint256 oldWeight = partyWeight();
        uint64 epoch = koEpoch[target];
        knockouts[target][epoch] = Knockout(bossId, round, totalBurrowRounds, indices[target]);
        koEpoch[target] = epoch + 1;
        alivePower[target] = 0;
        aliveCount[target] = 0;
        nonDemoCount[target] = 0;
        emit KO(target, epoch, bossId, round, power);
        _rescale(oldWeight, round);
    }

    function _blocked(uint8 target) internal view returns (bool) {
        return nonDemoCount[target] != 0 && nonDemoCount[GUARD] * 2 >= nonDemoCount[target];
    }

    function _target() internal view returns (uint8) {
        return napMove == 0 ? STRIKER : napMove == 1 ? FORAGER : DREAMER;
    }

    function multiplier(uint8 stance) internal pure returns (uint256) {
        return
            stance == STRIKER
                ? 150
                : stance == GUARD ? 50 : stance == FORAGER ? 80 : stance == DREAMER ? 25 : 0;
    }

    function gearMult(uint8 level) internal pure returns (uint256) {
        return 100 + 10 * uint256(level);
    }

    function partyWeight() public view returns (uint256 w) {
        for (uint8 s; s < 4; ++s) {
            w += alivePower[s] * multiplier(s);
        }
        return w / 150;
    }

    function _rescale(uint256 oldWeight, uint64 round) internal {
        uint256 weight = partyWeight();
        if (weight == oldWeight) return;
        Boss storage b = _bosses[bossId];
        b.hpUnits = b.hpUnits * (100 + weight) / (100 + oldWeight);
        b.maxHpUnits = b.maxHpUnits * (100 + weight) / (100 + oldWeight);
        if (b.hpUnits == 0) b.hpUnits = 1;
        emit PowerChanged(round, oldWeight, weight, b.hpUnits);
    }

    function _summon(uint64 round) internal {
        uint8 tier = uint8((bossId - 1) % 3);
        uint64 previous = lastRunWork;
        uint256 clamped = previous < 1000 ? 1000 : previous > 12000 ? 12000 : previous;
        uint256 hp = 3 * clamped * (100 + partyWeight()) * 150 * (13 ** uint256(tier)) / (10 ** uint256(tier));
        uint64 seasonId = _seasonOf(bossId);
        _bosses[bossId] = Boss(bossId, seasonId, tier, round, 0, previous, hp, hp, 0);
        emit BossSummoned(bossId, seasonId, tier, hp, previous);
    }

    function _applyQueued(uint64 round) internal {
        uint256 oldWeight = partyWeight();
        Boundary storage boundary = _boundaries[round];
        boundary.bossId = bossId;
        for (uint8 s; s < 4; ++s) {
            boundary.idx[s] = indices[s];
            boundary.epochs[s] = koEpoch[s];
        }
        // A fixed 5x5 matrix. Stale source epochs are deliberately never applied.
        for (uint8 from; from <= NONE; ++from) {
            uint64 epoch = from == NONE ? 0 : koEpoch[from];
            for (uint8 to; to <= NONE; ++to) {
                Delta storage d = pendingDelta[round][from][to][epoch];
                if (d.count == 0) continue;
                if (from != NONE) {
                    alivePower[from] -= d.outPower;
                    nonDemoCount[from] -= d.outReal;
                    aliveCount[from] -= d.count;
                }
                if (to != NONE) {
                    alivePower[to] += d.inPower;
                    nonDemoCount[to] += d.inReal;
                    aliveCount[to] += d.count;
                }
            }
        }
        _rescale(oldWeight, round);
    }

    function enlist(uint256[] calldata ids, uint8 stance) external nonReentrant {
        _beforeAction();
        _batch(ids.length);
        _stance(stance);
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] >= DEMO_BIT) revert InvalidId();
            _controller(ids[i]);
            _enlist(ids[i], stance, false);
        }
    }

    function enlistDemo(uint8 stance) external nonReentrant returns (uint256 id) {
        _beforeAction();
        _stance(stance);
        id = demoId(msg.sender);
        _enlist(id, stance, true);
    }

    function _enlist(uint256 id, uint8 stance, bool demo) internal {
        Raider storage r = _raiders[id];
        if (r.enlisted) revert AlreadyEnlisted();
        r.enlisted = true;
        r.isDemo = demo;
        r.stance = NONE;
        r.lastStanceRound = effectiveRound();
        _queue(id, NONE, stance, 0, Change.Enlist);
        emit Enlisted(id, msg.sender, demo);
    }

    function setStance(uint256[] calldata ids, uint8 stance) external nonReentrant {
        _beforeAction();
        _batch(ids.length);
        _stance(stance);
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            _controller(id);
            _ready(id);
            Raider storage r = _raiders[id];
            if (_isKO(r)) revert KnockedOut();
            bool replacing = r.pending.kind == Change.Stance || r.pending.kind == Change.Enlist;
            if (r.pending.round != 0) {
                if (!replacing) revert PendingLocked();
                _cancel(id);
            } else if (effectiveRound() < r.lastStanceRound + 6) {
                revert Cooldown();
            }
            r.lastStanceRound = effectiveRound();
            _queue(id, r.stance, stance, r.level, r.stance == NONE ? Change.Enlist : Change.Stance);
        }
    }

    /// @notice Pays 10*2^level Scrap now; the level applies at E. A KO of the raider's stance processed
    ///         before E cancels the upgrade (a KO wins) and the paid Scrap is not refunded.
    function upgrade(uint256 id) external nonReentrant {
        _beforeAction();
        _controller(id);
        _ready(id);
        Raider storage r = _raiders[id];
        if (_isKO(r) || r.stance == NONE) revert KnockedOut();
        if (r.pending.round != 0) revert PendingExists();
        if (r.level >= (r.isDemo ? 3 : 5)) revert MaxLevel();
        _spend(id, 10 * (uint256(1) << r.level), Change.Upgrade);
        _queue(id, r.stance, r.stance, r.level + 1, Change.Upgrade);
    }

    function revive(uint256 id) external nonReentrant {
        _beforeAction();
        _controller(id);
        _ready(id);
        Raider storage r = _raiders[id];
        if (!_isKO(r)) revert NotKnockedOut();
        if (r.pending.round != 0) revert PendingExists();
        _spend(id, 20, Change.Revive);
        _queue(id, NONE, r.stance, r.level, Change.Revive);
    }

    function rest(uint256[] calldata ids) external nonReentrant {
        _beforeAction();
        _batch(ids.length);
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            _ready(id);
            Raider storage r = _raiders[id];
            if (!_isKO(r)) revert NotKnockedOut();
            if (r.pending.round != 0) revert PendingExists();
            if (totalBurrowRounds - knockouts[r.stance][r.epoch].burrow < 6) revert NotRested();
            _queue(id, NONE, r.stance, r.level, Change.Rest);
        }
    }

    function bury(uint256 id) external nonReentrant {
        _beforeAction();
        if (id >= DEMO_BIT) revert InvalidId();
        (bool ok,) = CoreReader.read(nft, abi.encodeCall(ISqueekNFT.ownerOf, (id)), 32);
        if (ok) revert NotBurned();
        _ready(id);
        Raider storage r = _raiders[id];
        if (r.pending.round != 0) _cancel(id);
        _queue(id, _isKO(r) ? NONE : r.stance, NONE, r.level, Change.Bury);
    }

    function poke(uint256[] calldata ids) external nonReentrant {
        _beforeAction();
        _batch(ids.length);
        for (uint256 i; i < ids.length; ++i) {
            if (!_raiders[ids[i]].enlisted) revert NotEnlisted();
            _checkpoint(ids[i]);
        }
    }

    function _beforeAction() internal {
        if (block.timestamp < GENESIS) revert BeforeGenesis();
        _advance(64);
        if (!anchored) revert SourceUnavailable();
    }

    function _batch(uint256 size) internal pure {
        if (size == 0 || size > MAX_BATCH) revert InvalidBatch();
    }

    function _stance(uint8 s) internal pure {
        if (s >= NONE) revert InvalidStance();
    }

    function _controller(uint256 id) internal view {
        if (controllerOf(id) != msg.sender) revert NotController();
    }

    function _ready(uint256 id) internal {
        if (!_raiders[id].enlisted) revert NotEnlisted();
        if (!_checkpoint(id)) revert NeedsPoke();
        if (_raiders[id].buried) revert NotEnlisted();
    }

    function _spend(uint256 id, uint256 amount, Change reason) internal {
        Raider storage r = _raiders[id];
        if (r.scrap < amount) revert InsufficientScrap();
        r.scrap -= amount;
        emit ScrapSpent(id, amount, reason);
    }

    function _queue(uint256 id, uint8 from, uint8 to, uint8 level, Change kind) internal {
        Raider storage r = _raiders[id];
        uint64 round = effectiveRound();
        uint64 epoch = from == NONE ? 0 : r.epoch;
        r.pending = Pending(round, epoch, from, to, level, kind);
        Delta storage d = pendingDelta[round][from][to][epoch];
        ++d.count;
        if (from != NONE) {
            d.outPower += gearMult(r.level);
            if (!r.isDemo) ++d.outReal;
        }
        if (to != NONE) {
            d.inPower += gearMult(level);
            if (!r.isDemo) ++d.inReal;
        }
        if (_queuedRounds.length == 0 || _queuedRounds[_queuedRounds.length - 1] < round) {
            _queuedRounds.push(round);
        }
        emit ChangeQueued(id, round, kind, to, level);
    }

    function _cancel(uint256 id) internal {
        Raider storage r = _raiders[id];
        Pending memory p = r.pending;
        // A submitted change freezes when its round starts, even if settlement is lagging.
        if (liveRound() >= p.round) revert PendingLocked();
        Delta storage d = pendingDelta[p.round][p.from][p.to][p.fromEpoch];
        --d.count;
        if (p.from != NONE) {
            d.outPower -= gearMult(r.level);
            if (!r.isDemo) --d.outReal;
        }
        if (p.to != NONE) {
            d.inPower -= gearMult(p.level);
            if (!r.isDemo) --d.inReal;
        }
        delete r.pending;
        emit ChangeCancelled(id, p.round, p.kind);
    }

    function _isKO(Raider memory r) internal view returns (bool) {
        return r.enlisted && !r.buried && r.stance < NONE && r.epoch != koEpoch[r.stance];
    }

    function _end(Raider memory r, uint64 boundaryRound) internal view returns (End memory e) {
        if (r.stance == NONE) return End(r.cursorBoss, r.checkpoint);
        if (boundaryRound != 0) {
            Boundary storage b = _boundaries[boundaryRound];
            e = End(b.bossId, b.idx[r.stance]);
        } else {
            e = End(bossId, indices[r.stance]);
        }
        if (_isKO(r)) {
            Knockout storage k = knockouts[r.stance][r.epoch];
            // At E, pending changes precede E's move. A KO in E cannot erase an escape in E.
            if (boundaryRound == 0 || k.round < boundaryRound) e = End(k.bossId, k.idx);
        }
    }

    function _preview(uint256 id) internal view returns (Preview memory p) {
        p.data = _raiders[id];
        Raider memory r = p.data;
        if (!r.enlisted) {
            p.complete = true;
            return p;
        }
        Pending memory change = r.pending;
        if (
            change.round > processedThrough && change.kind != Change.Bury && change.from < NONE
                && change.fromEpoch != koEpoch[change.from]
        ) {
            delete r.pending;
            p.cancelled = true;
            change = r.pending;
        }
        if (change.round != 0 && change.round <= processedThrough) {
            if (!_settle(id, p, _end(r, change.round))) return p;
            Boundary storage b = _boundaries[change.round];
            if (_applies(change, b)) {
                _transition(r, change, b);
                p.applied = true;
            } else {
                p.cancelled = true;
            }
            delete r.pending;
        }
        p.complete = _settle(id, p, _end(r, 0));
    }

    function _applies(Pending memory change, Boundary storage b) internal view returns (bool) {
        return change.kind == Change.Bury || change.from == NONE || change.fromEpoch == b.epochs[change.from];
    }

    function _transition(Raider memory r, Pending memory change, Boundary storage b) internal view {
        r.stance = change.to;
        r.level = change.level;
        r.cursorBoss = b.bossId;
        if (change.to < NONE) {
            r.epoch = b.epochs[change.to];
            r.checkpoint = b.idx[change.to];
        }
        if (change.kind == Change.Bury) r.buried = true;
    }

    function _settle(uint256 id, Preview memory p, End memory end) internal view returns (bool) {
        Raider memory r = p.data;
        if (r.stance == NONE && !r.buried) return true;
        while (p.count < MAX_CHECKPOINT) {
            uint64 b = r.cursorBoss;
            Index memory target = b < end.bossId ? bossEnd[b][r.stance] : end.idx;
            uint256 damage = gearMult(r.level) * (target.damage - r.checkpoint.damage);
            uint256 dreams = target.dreams - r.checkpoint.dreams;
            uint256 scrap = target.scrap - r.checkpoint.scrap;
            Credit memory old = credits[id][b];
            // A pending transition can split one boss into two segments in this checkpoint.
            for (uint256 i; i < p.count; ++i) {
                if (p.ops[i].bossId == b) {
                    old.damageUnits += p.ops[i].damageUnits;
                    old.dreams += p.ops[i].dreams;
                    old.trophy = old.trophy || p.ops[i].trophy;
                }
            }
            bool trophy = !old.trophy && _bosses[b].slainAt != 0
                && ((old.damageUnits + damage) / DAMAGE_SCALE != 0 || old.dreams + dreams != 0);
            r.damage += (old.damageUnits + damage) / DAMAGE_SCALE - old.damageUnits / DAMAGE_SCALE;
            r.dreams += dreams;
            r.scrap += scrap;
            if (trophy) ++r.bossesSlain;
            p.ops[p.count++] = CreditOp(b, damage, dreams, scrap, trophy);
            r.checkpoint = target;
            if (b == end.bossId) return true;
            ++r.cursorBoss;
        }
        return false;
    }

    function _checkpoint(uint256 id) internal returns (bool) {
        Pending memory beforeChange = _raiders[id].pending;
        Preview memory p = _preview(id);
        _raiders[id] = p.data;
        for (uint256 i; i < p.count; ++i) {
            CreditOp memory op = p.ops[i];
            Credit storage c = credits[id][op.bossId];
            uint256 beforeDamage = c.damageUnits / DAMAGE_SCALE;
            c.damageUnits += op.damageUnits;
            c.dreams += op.dreams;
            if (op.damageUnits != 0 || op.dreams != 0) {
                emit Credited(
                    id,
                    op.bossId,
                    _seasonOf(op.bossId),
                    c.damageUnits / DAMAGE_SCALE - beforeDamage,
                    op.dreams
                );
            }
            if (op.scrap != 0) emit ScrapCredited(id, op.scrap);
            if (op.trophy) {
                c.trophy = true;
                emit TrophyCredited(id, op.bossId);
            }
        }
        if (p.applied) emit ChangeApplied(id, beforeChange.round, beforeChange.kind);
        if (p.cancelled) emit ChangeCancelled(id, beforeChange.round, beforeChange.kind);
        emit Checkpointed(id, p.data.cursorBoss, _isKO(p.data), p.complete);
        return p.complete;
    }

    function raider(uint256 id) public view returns (RaiderView memory v) {
        Preview memory p = _preview(id);
        v = RaiderView(p.data, _isKO(p.data), p.complete);
    }

    function boss() external view returns (Boss memory) {
        return _bosses[bossId];
    }

    function bossAt(uint64 id) external view returns (Boss memory) {
        return _bosses[id];
    }

    function season() external view returns (uint64) {
        return _seasonOf(bossId);
    }

    function _seasonOf(uint64 id) internal pure returns (uint64) {
        return (id - 1) / 3 + 1;
    }

    function pendingMove() external view returns (uint8 move, uint64 napRounds, bool armed) {
        return (napMove, burrowStreak, burrowStreak >= 18 && wheelSeen);
    }

    function cover()
        external
        view
        returns (uint8 target, uint256 targetPower, uint256 realTarget, uint256 realGuards, bool blocked)
    {
        target = _target();
        targetPower = alivePower[target];
        realTarget = nonDemoCount[target];
        realGuards = nonDemoCount[GUARD];
        blocked = _blocked(target);
    }

    /// @notice Exact score for one boss, including lazy credits; constant work irrespective of backlog.
    function scoreOf(uint64 b, uint256 id) public view returns (uint256) {
        if (b == 0 || b > bossId) return 0;
        Credit memory c = credits[id][b];
        Raider memory r = _raiders[id];
        if (!r.enlisted) return 0;
        Pending memory change = r.pending;
        bool applied = change.round != 0 && change.round <= processedThrough;
        (uint256 damage, uint256 dreams) = _uncredited(r, b, _end(r, applied ? change.round : 0));
        c.damageUnits += damage;
        c.dreams += dreams;
        if (applied) {
            Boundary storage boundary = _boundaries[change.round];
            if (_applies(change, boundary)) {
                _transition(r, change, boundary);
                (damage, dreams) = _uncredited(r, b, _end(r, 0));
                c.damageUnits += damage;
                c.dreams += dreams;
            }
        }
        return c.damageUnits / DAMAGE_SCALE + 300 * c.dreams;
    }

    function _uncredited(Raider memory r, uint64 b, End memory end)
        internal
        view
        returns (uint256 damage, uint256 dreams)
    {
        if (r.stance == NONE || b < r.cursorBoss || b > end.bossId) return (0, 0);
        Index memory start = b == r.cursorBoss ? r.checkpoint : bossEnd[b - 1][r.stance];
        Index memory finish = b == end.bossId ? end.idx : bossEnd[b][r.stance];
        damage = gearMult(r.level) * (finish.damage - start.damage);
        dreams = finish.dreams - start.dreams;
    }

    function seasonScoreOf(uint64 seasonId, uint256 id) external view returns (uint256 score) {
        if (seasonId == 0 || seasonId > _seasonOf(bossId)) return 0;
        uint64 first = (seasonId - 1) * 3 + 1;
        for (uint64 i; i < 3; ++i) {
            score += scoreOf(first + i, id);
        }
    }

    function cardURI(uint256 id) external view returns (string memory) {
        RaiderView memory v = raider(id);
        Raider memory r = v.data;
        return renderer.cardURI(
            RaiderCard.Card(
                id,
                r.enlisted ? r.stance : NONE,
                r.level,
                v.ko,
                r.enlisted && !r.buried,
                burrowStreak != 0,
                id >= DEMO_BIT,
                r.bossesSlain,
                r.scrap,
                r.dreams,
                r.damage + 300 * r.dreams
            )
        );
    }

    function bossSVG(uint8 tier) external view returns (string memory) {
        return renderer.bossSVG(tier);
    }
}
