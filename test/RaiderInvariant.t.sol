// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SqueekRaider} from "src/SqueekRaider.sol";
import {MockCore, MockNFT, MockStaking} from "./mocks/SqueekchainMocks.sol";
import {RaiderHandler} from "./invariant/RaiderHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract RaiderInvariantTest is StdInvariant, Test {
    SqueekRaider internal game;
    RaiderHandler internal handler;

    function setUp() public {
        vm.warp(1_793_022_600);
        MockCore core = new MockCore();
        MockNFT nft = new MockNFT();
        MockStaking staking = new MockStaking();
        game = new SqueekRaider(address(core), address(nft), address(staking));
        handler = new RaiderHandler(game, core, nft, staking);
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.enlist.selector;
        selectors[1] = handler.changeStance.selector;
        selectors[2] = handler.upgrade.selector;
        selectors[3] = handler.recover.selector;
        selectors[4] = handler.burnAndBury.selector;
        selectors[5] = handler.transferOrStake.selector;
        selectors[6] = handler.elapseWithoutSettlement.selector;
        selectors[7] = handler.wheel.selector;
        selectors[8] = handler.idle.selector;
        selectors[9] = handler.checkpoint.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_rewardsAndPowerMatchIndependentRoundModel() public view {
        uint64 current = game.bossId();
        uint256[4] memory power;
        uint256[4] memory counts;
        uint256[4] memory realCounts;
        uint256 sumDamageUnits;
        uint256 sumFlooredDamage;
        for (uint256 i; i < handler.ACTORS(); ++i) {
            RaiderHandler.Model memory m = handler.model(i);
            SqueekRaider.RaiderView memory v = game.raider(m.id);
            assertTrue(v.caughtUp, "partial preview used as a full balance");
            assertEq(v.data.enlisted, m.enlisted, "enlistment");
            if (!m.enlisted) continue;
            assertEq(v.data.isDemo, m.demo, "demo identity");
            assertEq(v.data.buried, m.buried, "burial");
            assertEq(v.ko, m.ko, "KO state");
            assertEq(v.data.stance, m.stance, "stance activation");
            assertEq(v.data.level, m.level, "upgrade activation");
            assertEq(v.data.pending.round, m.pendingRound, "pending timing");
            assertEq(uint256(v.data.pending.kind), uint256(m.pendingKind), "pending cancellation");
            assertEq(v.data.scrap + m.spentScrap, m.earnedScrap, "Scrap conservation");
            assertEq(v.data.dreams, m.dreams, "Dream conservation");
            uint256 total;
            uint256 trophies;
            for (uint64 b = 1; b <= current; ++b) {
                uint256 units = handler.damageUnits(i, b);
                uint256 damage = units / 10_000;
                uint256 dreams = handler.dreamsByBoss(i, b);
                assertEq(game.scoreOf(b, m.id), damage + 300 * dreams, "credit assigned to wrong boss");
                total += damage;
                sumDamageUnits += units;
                if (b < current && (damage != 0 || dreams != 0)) ++trophies;
            }
            assertEq(v.data.damage, total, "checkpoint rounding or duplicate damage");
            assertEq(v.data.bossesSlain, trophies, "missing or duplicated trophy");
            sumFlooredDamage += total;
            if (!m.buried && !m.ko && m.stance < 4) {
                power[m.stance] += 100 + 10 * uint256(m.level);
                ++counts[m.stance];
                if (!m.demo) ++realCounts[m.stance];
            }
        }
        assertEq(sumDamageUnits, game.totalDamageUnits(), "damage lost or created");
        assertEq(sumDamageUnits, handler.totalDamage(), "oracle damage disagrees");
        assertLe(sumFlooredDamage, sumDamageUnits / 10_000, "flooring created damage");
        assertLt(sumDamageUnits / 10_000 - sumFlooredDamage, handler.ACTORS() * current, "unbounded dust");
        for (uint8 s; s < 4; ++s) {
            assertEq(game.alivePower(s), power[s], "cohort power differs from raiders");
            assertEq(game.aliveCount(s), counts[s], "phantom live raider");
            assertEq(game.nonDemoCount(s), realCounts[s], "demos counted for cover");
            assertEq(game.koEpoch(s), handler.epochs(s), "KO epoch");
        }
        assertEq(game.burrowStreak(), handler.burrow(), "Burrow streak");
        assertEq(game.totalBurrowRounds(), handler.totalBurrow(), "rest clock");
        assertEq(game.processedThrough(), handler.round(), "processing cursor");
        assertEq(game.boss().seasonId, (current - 1) / 3 + 1, "season");
        assertEq(game.boss().tier, (current - 1) % 3, "tier");
        uint256 bossDamage;
        for (uint64 b = 1; b <= current; ++b) {
            SqueekRaider.Boss memory boss = game.bossAt(b);
            bossDamage += boss.damageUnits;
            if (b < current) {
                assertEq(boss.hpUnits, 0, "slain boss regained HP");
                assertGt(boss.slainAt, 0, "slain boss reopened");
            }
        }
        assertEq(bossDamage, sumDamageUnits, "global/per-boss damage mismatch");
    }

    /// @dev Proves the guarded handler reaches its less frequent paths; random
    ///      dispatch alone could otherwise pass while recovery/upgrade are no-ops.
    function testHandlerExercisesEveryActionIncludingBothRecoveryMethods() public {
        handler.enlist(4, 0);
        handler.enlist(8, 3);
        handler.changeStance(6, 0);
        bytes32 frenzy;
        for (uint256 h;; ++h) {
            if (uint256(keccak256(abi.encode(bytes32(h), uint64(1)))) % 3 == 0) {
                frenzy = bytes32(h);
                break;
            }
        }
        handler.wheel(1, 2, frenzy);
        for (uint256 i; i < 20; ++i) {
            handler.wheel(1, 1, frenzy);
        }
        handler.upgrade(0);
        handler.transferOrStake(0, 2, true);
        handler.idle(2);
        handler.burnAndBury(1); // Remove the only real Guard before the attack.
        handler.idle(16);
        handler.wheel(1, 1, bytes32(0));
        assertTrue(handler.model(0).ko);
        assertTrue(handler.model(4).ko);
        handler.recover(4, true);
        handler.idle(6);
        handler.recover(0, false);
        handler.wheel(1, 2, bytes32(0));
        assertFalse(handler.model(0).ko);
        assertFalse(handler.model(4).ko);
        handler.checkpoint(0);
        handler.elapseWithoutSettlement(2);
        for (uint256 i; i < targetSelectors()[0].selectors.length; ++i) {
            assertGt(
                handler.successes(targetSelectors()[0].selectors[i]), 0, "handler action was never reached"
            );
        }
        assertEq(handler.successes(handler.recover.selector), 2, "both recovery paths must execute");
        invariant_rewardsAndPowerMatchIndependentRoundModel();
    }
}
