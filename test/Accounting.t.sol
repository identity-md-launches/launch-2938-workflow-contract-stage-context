// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RaiderFixture} from "./SqueekRaider.t.sol";
import {SqueekRaider} from "../src/SqueekRaider.sol";

contract AccountingTest is RaiderFixture {
    function testBossKillWhileReviveQueuedKeepsOldCreditsAndJoinsNewBoss() public {
        enlist(1, 0);
        vm.prank(bob);
        game.enlistDemo(1);
        for (uint64 r = 2; r <= 21; ++r) {
            wheel(r, 1, hashFor(0, 1));
        }
        idle(39);
        wheel(40, 1, bytes32(0));
        assertTrue(raider(1).ko);
        assertEq(raider(1).data.scrap, 20);
        vm.prank(bob);
        vm.expectRevert(SqueekRaider.NotController.selector);
        game.revive(1);
        vm.prank(alice);
        game.revive(1);
        assertEq(raider(1).data.pending.round, 42);
        assertEq(raider(1).data.scrap, 0);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.PendingExists.selector);
        game.revive(1);
        wheel(41, 50_000, bytes32(0));
        assertEq(game.bossId(), 2);
        assertTrue(raider(1).ko);
        assertEq(game.scoreOf(1, 1), 30);
        assertEq(raider(1).data.bossesSlain, 1);
        wheel(42, 10, bytes32(0));
        assertFalse(raider(1).ko);
        assertEq(game.scoreOf(2, 1), 15);
        checkpoint(1);
        assertEq(raider(1).data.damage, 45);
        assertEq(raider(1).data.bossesSlain, 1);
    }

    function testPaidUpgradeCanceledByEarlierKOHasNoPhantomPower() public {
        enlist(1, 0);
        for (uint64 r = 2; r <= 11; ++r) {
            wheel(r, 1, hashFor(0, 1));
        }
        vm.warp(G + 31 * 600); // Live 32, E 33; core lags at 11.
        vm.prank(alice);
        game.upgrade(1);
        assertEq(raider(1).data.scrap, 0);
        core.wheel(30, 1, bytes32(0)); // 18 idle rounds then KO.
        game.advance(128);
        assertTrue(raider(1).ko);
        assertEq(raider(1).data.level, 0);
        assertEq(uint256(raider(1).data.pending.kind), 0);
        core.settle(33);
        vm.warp(G + 33 * 600);
        game.advance(128);
        checkpoint(1);
        assertEq(game.alivePower(0), 0);
        assertEq(raider(1).data.scrap, 0);
        assertEq(game.scoreOf(1, 1), 15);
    }

    function testEquipmentDoesNotChangeGuardCover() public {
        enlist(1, 0);
        enlist(2, 0);
        enlist(3, 1);
        for (uint64 r = 2; r <= 11; ++r) {
            wheel(r, 1, bytes32(0));
        }
        vm.prank(alice);
        game.upgrade(1);
        vm.prank(alice);
        game.upgrade(2);
        wheel(13, 1, hashFor(0, 1));
        assertEq(game.alivePower(0), 220);
        idle(31);
        wheel(32, 1, bytes32(0));
        assertFalse(raider(1).ko);
        assertFalse(raider(2).ko);
        assertEq(game.nonDemoCount(0), 2);
        assertEq(game.nonDemoCount(1), 1);
    }

    function testBurnedParticipantStillGetsTrophyForEarlierContribution() public {
        enlist(1, 0);
        enlist(2, 1);
        wheel(2, 100, bytes32(0));
        nft.burn(1);
        game.bury(1);
        idle(4);
        assertTrue(raider(1).data.buried);
        wheel(5, 50_000, bytes32(0));
        assertEq(game.scoreOf(1, 1), 150);
        assertEq(raider(1).data.bossesSlain, 1);
        checkpoint(1);
        checkpoint(1);
        assertEq(raider(1).data.bossesSlain, 1);
    }

    function testRepeatedEpochsCancelOnlyOldPendingGroups() public {
        enlist(1, 0);
        wheel(2, 10, hashFor(0, 1));
        idle(20);
        wheel(21, 10, bytes32(0));
        idle(27);
        game.rest(ids(1));
        // A new entrant and the revived old epoch both join epoch 1.
        vm.prank(alice);
        game.enlist(ids(2), 0);
        wheel(29, 1, hashFor(0, 1));
        assertEq(game.alivePower(0), 200);
        assertEq(raider(1).data.epoch, 1);
        idle(47);
        wheel(48, 1, bytes32(0));
        assertEq(game.koEpoch(0), 2);
        assertTrue(raider(1).ko);
        assertTrue(raider(2).ko);
        checkpoint(1);
        checkpoint(2);
        assertEq(game.scoreOf(1, 1), 16);
        assertEq(game.scoreOf(1, 2), 1);
        assertEq(raider(1).data.scrap, 2);
        assertEq(raider(2).data.scrap, 1);
    }

    function testBurnCleanupSurvivesAnInterveningKO() public {
        enlist(1, 0);
        wheel(2, 10, hashFor(0, 1));
        vm.warp(G + 23 * 600);
        nft.burn(1); // E 25, source still at 2.
        game.bury(1);
        core.wheel(21, 10, bytes32(0));
        game.advance(128);
        assertTrue(raider(1).ko);
        assertEq(uint256(raider(1).data.pending.kind), uint256(SqueekRaider.Change.Bury));
        core.settle(27);
        vm.warp(G + 27 * 600);
        game.advance(128);
        assertTrue(raider(1).data.buried);
        assertEq(game.alivePower(0), 0);
        vm.expectRevert(SqueekRaider.NotEnlisted.selector);
        game.rest(ids(1));
    }

    function testCheckpointFrequencyDoesNotChangeFractionalCredits() public {
        enlist(1, 1);
        enlist(2, 1);
        for (uint64 r = 2; r <= 24; ++r) {
            wheel(r, 1, bytes32(0));
            checkpoint(1);
        }
        assertEq(game.scoreOf(1, 1), 11);
        assertEq(game.scoreOf(1, 2), 11);
        checkpoint(2);
        assertEq(raider(1).data.damage, raider(2).data.damage);
        assertEq(game.bossAt(1).damageUnits, 230_000);
    }

    function testFuzzCreditConservationAcrossBossesKOsAndPendingChanges(uint256 entropy, uint8 steps_)
        public
    {
        uint256 count = 7;
        uint256[] memory party = new uint256[](count);
        for (uint256 i; i < 6; ++i) {
            party[i] = i + 1;
            enlist(i + 1, uint8((entropy >> (i * 3)) % 3));
        }
        vm.prank(alice);
        party[6] = game.enlistDemo(uint8((entropy >> 20) % 3));
        uint256 steps = bound(steps_, 12, 48);
        uint64 round;
        for (uint256 step; step < steps; ++step) {
            entropy = uint256(keccak256(abi.encode(entropy, step)));
            uint256 id = party[entropy % count];
            SqueekRaider.RaiderView memory v = raider(id);
            if (v.caughtUp && v.data.pending.round == 0 && v.data.stance < 4) {
                if (v.ko) {
                    if (v.data.scrap >= 20) {
                        vm.prank(alice);
                        game.revive(id);
                    } else {
                        try game.rest(ids(id)) {} catch {}
                    }
                } else if (
                    entropy % 7 == 0 && v.data.level < (v.data.isDemo ? 3 : 5)
                        && v.data.scrap >= (uint256(10) << v.data.level)
                ) {
                    vm.prank(alice);
                    game.upgrade(id);
                } else if (entropy % 5 == 0 && game.effectiveRound() >= v.data.lastStanceRound + 6) {
                    vm.prank(alice);
                    game.setStance(ids(id), uint8((entropy >> 32) % 3));
                }
            }
            uint64 gap = entropy % 4 == 0 ? uint64(2 + (entropy >> 40) % 38) : 1;
            round += gap;
            wheel(round, uint64(1 + (entropy >> 64) % 24_000), bytes32(entropy));
            if (entropy % 3 == 0) checkpoint(id);
            _assertPower(party);
        }
        for (uint256 i; i < count; ++i) {
            for (uint256 attempt; attempt < 8 && !raider(party[i]).caughtUp; ++attempt) {
                checkpoint(party[i]);
            }
            checkpoint(party[i]);
            assertTrue(raider(party[i]).caughtUp);
        }
        uint256 aggregateUnits;
        uint256 aggregateScore;
        for (uint64 b = 1; b <= game.bossId(); ++b) {
            uint256 credited;
            for (uint256 i; i < count; ++i) {
                credited += game.scoreOf(b, party[i]);
            }
            uint256 dealt = game.bossAt(b).damageUnits;
            // No Dreamers in this fuzz scenario: score is pure damage. Every raider loses
            // strictly less than one damage unit per boss to flooring, never per checkpoint.
            assertLe(credited, dealt / 10_000, "credit exceeds damage");
            assertLt(dealt / 10_000 - credited, count, "lost or misattributed credit");
            aggregateUnits += dealt;
            aggregateScore += credited;
        }
        assertEq(aggregateUnits, game.totalDamageUnits());
        uint256 creditedTotals;
        for (uint256 i; i < count; ++i) {
            creditedTotals += raider(party[i]).data.damage;
        }
        assertEq(creditedTotals, aggregateScore);
    }

    function testFuzzDreamsAndDamageStayInTheirBoss(uint256 entropy, uint8 steps_) public {
        enlist(1, 3);
        enlist(2, 3);
        uint256[40] memory dreamsByBoss;
        uint256 expectedDreams;
        uint64 round = 2;
        wheel(round, 50_000, bytes32(entropy));
        uint256 steps = bound(steps_, 12, 36);
        for (uint256 step; step < steps; ++step) {
            entropy = uint256(keccak256(abi.encode(entropy, step)));
            uint64 gap = uint64(entropy % 18); // No 18-round attack in this scenario.
            uint256 reward = gap >= 2 ? gap - 1 : 0;
            dreamsByBoss[game.bossId()] += 2 * reward;
            expectedDreams += reward;
            if (step == 10) {
                vm.prank(alice);
                game.upgrade(1);
            }
            round += gap + 1;
            wheel(round, uint64(1 + (entropy >> 16) % 60_000), bytes32(entropy));
            checkpoint(1);
        }
        while (!raider(2).caughtUp) checkpoint(2);
        checkpoint(2);
        assertEq(raider(1).data.dreams, expectedDreams);
        assertEq(raider(2).data.dreams, expectedDreams);
        uint256 totalDreams;
        for (uint64 b = 1; b <= game.bossId(); ++b) {
            uint256 damage = game.scoreOf(b, 1) + game.scoreOf(b, 2) - 300 * dreamsByBoss[b];
            uint256 dealt = game.bossAt(b).damageUnits / 10_000;
            assertLe(damage, dealt);
            assertLt(dealt - damage, 2);
            totalDreams += dreamsByBoss[b];
        }
        assertEq(totalDreams, 2 * expectedDreams);
    }

    function _assertPower(uint256[] memory party) internal view {
        uint256[4] memory expected;
        uint256[4] memory real;
        uint256[4] memory counts;
        for (uint256 i; i < party.length; ++i) {
            SqueekRaider.RaiderView memory v = raider(party[i]);
            // A bounded view may still be catching up through old bosses. Check aggregate
            // power whenever every participant's projection reaches the present.
            if (!v.caughtUp) return;
            if (!v.ko && v.data.stance < 4 && !v.data.buried) {
                uint256 weight = 100 + 10 * uint256(v.data.level);
                expected[v.data.stance] += weight;
                ++counts[v.data.stance];
                if (!v.data.isDemo) ++real[v.data.stance];
            }
        }
        for (uint8 s; s < 4; ++s) {
            assertEq(game.alivePower(s), expected[s], "cohort power");
            assertEq(game.nonDemoCount(s), real[s], "real cohort power");
            assertEq(game.aliveCount(s), counts[s], "cohort count");
        }
    }
}
