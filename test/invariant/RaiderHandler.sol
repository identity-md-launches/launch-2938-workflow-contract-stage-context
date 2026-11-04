// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqueekRaider} from "src/SqueekRaider.sol";
import {MockCore, MockNFT, MockStaking} from "../mocks/SqueekchainMocks.sol";

/// @dev An eager, per-raider oracle. It has no indices, checkpoints, deltas, or
///      cohort epochs: rewards are assigned individually as each round happens.
contract RaiderHandler is Test {
    uint256 public constant ACTORS = 9;
    uint64 private constant GENESIS = 1_793_022_600;
    uint8 private constant NONE = 4;

    struct Model {
        uint256 id;
        address controller;
        bool demo;
        bool enlisted;
        bool buried;
        bool ko;
        uint8 stance;
        uint8 level;
        uint64 lastStance;
        uint64 koBurrow;
        uint64 pendingRound;
        SqueekRaider.Change pendingKind;
        uint8 pendingStance;
        uint8 pendingLevel;
        uint256 earnedScrap;
        uint256 spentScrap;
        uint256 dreams;
    }

    SqueekRaider public immutable game;
    MockCore public immutable core;
    MockNFT public immutable nft;
    MockStaking public immutable staking;
    Model[9] private models;
    mapping(uint256 => mapping(uint64 => uint256)) public damageUnits;
    mapping(uint256 => mapping(uint64 => uint256)) public dreamsByBoss;
    mapping(uint8 => uint64) public epochs;
    mapping(bytes4 => uint256) public successes;
    uint256 public totalDamage;
    uint64 public round;
    uint64 public burrow;
    uint64 public totalBurrow;
    bytes32 private lastHash;
    uint8 private move;
    /// @dev The core pages forward only, so a nap before the first processed Wheel has no known
    ///      last dataHash: it keeps the default previous run and arms no move.
    bool public wheelSeen;
    uint64 public runWork;
    uint64 public lastRunWork = 1600;

    constructor(SqueekRaider game_, MockCore core_, MockNFT nft_, MockStaking staking_) {
        game = game_;
        core = core_;
        nft = nft_;
        staking = staking_;
        game.advance(0);
        for (uint256 i; i < ACTORS; ++i) {
            Model storage m = models[i];
            m.controller = address(uint160(0xA1100 + i));
            m.demo = i >= 6;
            m.id = m.demo ? game.demoId(m.controller) : i + 1;
            m.stance = NONE;
            if (!m.demo) nft.mint(m.id, m.controller);
            // Start with all four stances, two demos, and three possible late entrants.
            if (i < 4 || i == 6 || i == 7) _enlist(i, uint8(i % 4));
        }
    }

    function model(uint256 i) external view returns (Model memory) {
        return models[i];
    }

    function enlist(uint256 actorSeed, uint256 stanceSeed) external {
        uint256 i = actorSeed % ACTORS;
        if (models[i].enlisted) return;
        _enlist(i, uint8(stanceSeed % 4));
        ++successes[msg.sig];
    }

    function _enlist(uint256 i, uint8 stance) internal {
        Model storage m = models[i];
        vm.prank(m.controller);
        if (m.demo) game.enlistDemo(stance);
        else game.enlist(_one(m.id), stance);
        m.enlisted = true;
        m.lastStance = _effective();
        _queue(m, SqueekRaider.Change.Enlist, stance, 0);
    }

    function changeStance(uint256 actorSeed, uint256 stanceSeed) external {
        Model storage m = models[actorSeed % ACTORS];
        if (!m.enlisted || m.buried || m.ko) return;
        if (m.pendingRound != 0) {
            if (
                (m.pendingKind != SqueekRaider.Change.Enlist && m.pendingKind != SqueekRaider.Change.Stance)
                    || _live() >= m.pendingRound
            ) return;
        } else if (_effective() < m.lastStance + 6) {
            return;
        }
        uint8 stance = uint8(stanceSeed % 4);
        vm.prank(m.controller);
        game.setStance(_one(m.id), stance);
        m.lastStance = _effective();
        _queue(m, m.stance == NONE ? SqueekRaider.Change.Enlist : SqueekRaider.Change.Stance, stance, m.level);
        ++successes[msg.sig];
    }

    function upgrade(uint256 actorSeed) external {
        Model storage m = models[actorSeed % ACTORS];
        if (!m.enlisted || m.buried || m.ko || m.stance == NONE || m.pendingRound != 0) return;
        uint256 cost = uint256(10) << m.level;
        if (m.level == (m.demo ? 3 : 5) || m.earnedScrap - m.spentScrap < cost) return;
        vm.prank(m.controller);
        game.upgrade(m.id);
        m.spentScrap += cost;
        _queue(m, SqueekRaider.Change.Upgrade, m.stance, m.level + 1);
        ++successes[msg.sig];
    }

    function recover(uint256 actorSeed, bool paid) external {
        Model storage m = models[actorSeed % ACTORS];
        if (!m.enlisted || m.buried || !m.ko || m.pendingRound != 0) return;
        if (paid) {
            if (m.earnedScrap - m.spentScrap < 20) return;
            vm.prank(m.controller);
            game.revive(m.id);
            m.spentScrap += 20;
        } else {
            if (totalBurrow - m.koBurrow < 6) return;
            // An unrelated caller must be able to rest another wallet's raider.
            vm.prank(address(0xCA11));
            game.rest(_one(m.id));
        }
        _queue(m, paid ? SqueekRaider.Change.Revive : SqueekRaider.Change.Rest, m.stance, m.level);
        ++successes[msg.sig];
    }

    function burnAndBury(uint256 actorSeed) external {
        Model storage m = models[actorSeed % 6];
        if (!m.enlisted || m.buried) return;
        if (m.pendingRound != 0 && _live() >= m.pendingRound) return;
        nft.burn(m.id);
        vm.prank(address(0xCA11));
        game.bury(m.id);
        _queue(m, SqueekRaider.Change.Bury, NONE, m.level);
        ++successes[msg.sig];
    }

    function transferOrStake(uint256 actorSeed, uint256 ownerSeed, bool staked) external {
        Model storage m = models[actorSeed % 6];
        if (m.buried || m.pendingKind == SqueekRaider.Change.Bury) return;
        address nextOwner = address(uint160(0xB2200 + ownerSeed % ACTORS));
        nft.mint(m.id, staked ? address(staking) : nextOwner);
        if (staked) staking.setDepositor(address(nft), m.id, nextOwner);
        m.controller = nextOwner;
        assertEq(game.controllerOf(m.id), nextOwner, "controller did not follow ownership");
        ++successes[msg.sig];
    }

    function elapseWithoutSettlement(uint256 roundsSeed) external {
        vm.warp(block.timestamp + bound(roundsSeed, 1, 24) * 600);
        ++successes[msg.sig];
    }

    function wheel(uint256 workSeed, uint256 gapSeed, bytes32 dataHash) external {
        uint64 work = uint64(bound(workSeed, 0, 60_000));
        uint64 next = round + uint64(bound(gapSeed, 1, 40));
        uint64 bossBefore = game.bossId();
        while (round + 1 < next) _idleRound(bossBefore);
        ++round;
        _applyChanges();
        if (burrow >= 18 && wheelSeen) _knockOut();
        wheelSeen = true;
        burrow = 0;
        runWork += work;
        lastHash = dataHash;
        for (uint256 i; i < ACTORS; ++i) {
            Model storage m = models[i];
            if (!_alive(m)) continue;
            uint256 damage = uint256(work) * _multiplier(m.stance) * (100 + 10 * uint256(m.level));
            damageUnits[i][bossBefore] += damage;
            totalDamage += damage;
            ++m.earnedScrap;
        }
        core.wheel(round, work, dataHash);
        _settle();
        assertLe(game.bossId(), bossBefore + 1, "overkill killed multiple bosses");
        assertGe(game.bossId(), bossBefore, "boss reopened");
        ++successes[msg.sig];
    }

    function idle(uint256 roundsSeed) external {
        uint64 count = uint64(bound(roundsSeed, 1, 48));
        uint64 b = game.bossId();
        for (uint64 j; j < count; ++j) {
            _idleRound(b);
        }
        core.settle(round);
        _settle();
        assertEq(game.bossId(), b, "idle rounds killed a boss");
        ++successes[msg.sig];
    }

    function checkpoint(uint256 actorSeed) external {
        Model storage m = models[actorSeed % ACTORS];
        if (!m.enlisted) return;
        bytes32 beforeView = keccak256(abi.encode(game.raider(m.id)));
        uint64 b = game.bossId();
        uint256 score = game.scoreOf(b, m.id);
        game.poke(_one(m.id));
        game.poke(_one(m.id));
        assertEq(keccak256(abi.encode(game.raider(m.id))), beforeView, "checkpoint changed projected balance");
        assertEq(game.scoreOf(b, m.id), score, "checkpoint changed score");
        ++successes[msg.sig];
    }

    function _idleRound(uint64 b) internal {
        ++round;
        _applyChanges();
        ++burrow;
        ++totalBurrow;
        if (burrow == 2 && wheelSeen) {
            move = uint8(uint256(keccak256(abi.encode(lastHash, b))) % 3);
            lastRunWork = runWork;
            runWork = 0;
        }
        if (burrow < 2 || burrow > 37) return;
        for (uint256 i; i < ACTORS; ++i) {
            Model storage m = models[i];
            if (!_alive(m)) continue;
            if (m.stance == 2) ++m.earnedScrap;
            if (m.stance == 3) {
                ++m.dreams;
                ++dreamsByBoss[i][b];
            }
        }
    }

    function _applyChanges() internal {
        for (uint256 i; i < ACTORS; ++i) {
            Model storage m = models[i];
            if (m.pendingRound != round) continue;
            m.stance = m.pendingStance;
            m.level = m.pendingLevel;
            m.ko = false;
            if (m.pendingKind == SqueekRaider.Change.Bury) m.buried = true;
            m.pendingRound = 0;
            m.pendingKind = SqueekRaider.Change.None;
        }
    }

    function _knockOut() internal {
        uint8 target = move == 0 ? 0 : move == 1 ? 2 : 3;
        uint256 realTarget;
        uint256 guards;
        bool anyTarget;
        for (uint256 i; i < ACTORS; ++i) {
            Model storage m = models[i];
            if (!_alive(m)) continue;
            if (m.stance == target) {
                anyTarget = true;
                if (!m.demo) ++realTarget;
            }
            if (!m.demo && m.stance == 1) ++guards;
        }
        if (!anyTarget || (realTarget != 0 && guards * 2 >= realTarget)) return;
        ++epochs[target];
        for (uint256 i; i < ACTORS; ++i) {
            Model storage m = models[i];
            if (!_alive(m) || m.stance != target) continue;
            m.ko = true;
            m.koBurrow = totalBurrow;
            if (m.pendingRound != 0 && m.pendingKind != SqueekRaider.Change.Bury) {
                m.pendingRound = 0;
                m.pendingKind = SqueekRaider.Change.None;
            }
        }
    }

    function _settle() internal {
        uint256 timestamp = uint256(GENESIS) + uint256(round) * 600;
        if (block.timestamp < timestamp) vm.warp(timestamp);
        uint256 oldDamage = game.totalDamageUnits();
        game.advance(128);
        assertEq(game.processedThrough(), round, "bounded source was not fully applied");
        assertGe(game.totalDamageUnits(), oldDamage, "damage decreased");
        // Do not let a bounded preview make the invariant vacuous. Catch up only
        // raiders whose view has actually reached the eight-boss work limit.
        for (uint256 i; i < ACTORS; ++i) {
            if (!models[i].enlisted) continue;
            for (uint256 j; j < 16 && !game.raider(models[i].id).caughtUp; ++j) {
                game.poke(_one(models[i].id));
            }
            assertTrue(game.raider(models[i].id).caughtUp, "checkpoint failed to converge");
        }
    }

    function _queue(Model storage m, SqueekRaider.Change kind, uint8 stance, uint8 level) internal {
        m.pendingRound = _effective();
        m.pendingKind = kind;
        m.pendingStance = stance;
        m.pendingLevel = level;
    }

    function _live() internal view returns (uint64) {
        return uint64((block.timestamp - GENESIS) / 600 + 1);
    }

    function _effective() internal view returns (uint64) {
        return _live() + 1;
    }

    function _alive(Model storage m) internal view returns (bool) {
        return m.enlisted && !m.buried && !m.ko && m.stance < NONE;
    }

    function _multiplier(uint8 stance) internal pure returns (uint256) {
        uint256[4] memory multipliers = [uint256(150), 50, 80, 25];
        return multipliers[stance];
    }

    function _one(uint256 id) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = id;
    }
}
