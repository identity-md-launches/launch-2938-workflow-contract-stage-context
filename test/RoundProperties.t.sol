// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RaiderFixture} from "./SqueekRaider.t.sol";
import {SqueekRaider} from "src/SqueekRaider.sol";

/// forge-config: default.fuzz.runs = 256
contract RoundPropertiesTest is RaiderFixture {
    function testFuzzPartitioningAdvanceDoesNotChangeOutcomes(
        uint256 entropy,
        uint8 countSeed,
        uint8 budgetSeed
    ) public {
        SqueekRaider chunked = new SqueekRaider(address(core), address(nft), address(staking));
        for (uint256 id = 1; id <= 3; ++id) {
            uint8 stance = id == 1 ? 0 : id == 2 ? 2 : 3;
            enlist(id, stance);
            vm.prank(alice);
            chunked.enlist(ids(id), stance);
        }
        vm.warp(G + 5 * 600);
        enlist(4, 0); // A separate queued boundary inside an unsettled idle gap.
        vm.prank(alice);
        chunked.enlist(ids(4), 0);
        vm.warp(G + 11 * 600);
        vm.prank(bob);
        uint256 demo = game.enlistDemo(1);
        vm.prank(bob);
        chunked.enlistDemo(1);
        uint256 records = bound(countSeed, 20, 144);
        uint64 round;
        for (uint256 i; i < records; ++i) {
            entropy = uint256(keccak256(abi.encode(entropy, i)));
            round += uint64(1 + entropy % 24);
            core.wheel(round, uint64((entropy >> 64) % 60_001), bytes32(entropy));
        }
        core.settle(round + 40); // Include the trailing idle portion of the final page.
        vm.warp(uint256(G) + uint256(round + 40) * 600);
        while (game.processedThrough() < core.settled()) {
            uint64 beforeRound = game.processedThrough();
            game.advance(type(uint256).max);
            assertGt(game.processedThrough(), beforeRound, "bulk progress stalled");
        }
        uint256 budget = bound(budgetSeed, 1, 17);
        while (chunked.processedThrough() < core.settled()) {
            uint64 beforeRound = chunked.processedThrough();
            chunked.advance(budget);
            assertGt(chunked.processedThrough(), beforeRound, "chunked progress stalled");
        }
        assertEq(chunked.processedWork(), game.processedWork());
        assertEq(chunked.totalDamageUnits(), game.totalDamageUnits());
        assertEq(chunked.lastRunWork(), game.lastRunWork());
        assertEq(chunked.totalBurrowRounds(), game.totalBurrowRounds());
        assertEq(keccak256(abi.encode(chunked.boss())), keccak256(abi.encode(game.boss())));
        for (uint8 s; s < 4; ++s) {
            assertEq(chunked.alivePower(s), game.alivePower(s));
            assertEq(chunked.aliveCount(s), game.aliveCount(s));
            assertEq(chunked.nonDemoCount(s), game.nonDemoCount(s));
            assertEq(chunked.koEpoch(s), game.koEpoch(s));
        }
        uint256[5] memory party = [uint256(1), 2, 3, 4, demo];
        for (uint256 i; i < party.length; ++i) {
            assertEq(
                keccak256(abi.encode(chunked.raider(party[i]))), keccak256(abi.encode(game.raider(party[i])))
            );
            for (uint64 b = 1; b <= game.bossId(); ++b) {
                assertEq(
                    chunked.scoreOf(b, party[i]), game.scoreOf(b, party[i]), "partition changed boss credit"
                );
            }
        }
    }

    function testFuzzLaggedStanceChangeCannotRewriteEarlierRounds(uint64 submitSeed, uint64 workSeed) public {
        uint64 submit = uint64(bound(submitSeed, 8, 10_000));
        uint64 work = uint64(bound(workSeed, 0, 60_000));
        enlist(1, 1); // Guards cannot be KO'd by a long historical nap.
        wheel(2, 1, bytes32(0));
        vm.warp(uint256(G) + uint256(submit) * 600);
        vm.prank(alice);
        game.setStance(ids(1), 2);
        assertEq(raider(1).data.pending.round, submit + 2);
        core.wheel(3, work, bytes32(0));
        core.wheel(submit + 1, work, bytes32(0));
        vm.warp(uint256(G) + uint256(submit + 1) * 600);
        game.advance(128);
        assertEq(game.processedThrough(), submit + 1);
        assertEq(game.alivePower(1), 100);
        assertEq(game.alivePower(2), 0);
        assertEq(game.totalDamageUnits(), (uint256(1) + 2 * uint256(work)) * 50 * 100);
        assertEq(raider(1).data.scrap, 3);
        wheel(submit + 2, work, bytes32(0));
        assertEq(game.alivePower(1), 0);
        assertEq(game.alivePower(2), 100);
        assertEq(
            game.totalDamageUnits(), (uint256(1) + 2 * uint256(work)) * 50 * 100 + uint256(work) * 80 * 100
        );
    }

    function testMaximumAdvanceIsOneHundredTwentyEightActiveRounds() public {
        enlist(1, 1);
        for (uint64 r = 1; r <= 257; ++r) {
            core.wheel(r, 1, bytes32(uint256(r)));
        }
        vm.warp(G + 257 * 600);
        game.advance(type(uint256).max);
        assertEq(game.processedThrough(), 128);
        assertEq(raider(1).data.scrap, 127);
        game.advance(type(uint256).max);
        assertEq(game.processedThrough(), 256);
        game.advance(0);
        assertEq(game.processedThrough(), 256);
        game.advance(1);
        assertEq(game.processedThrough(), 257);
        assertEq(raider(1).data.scrap, 256);
    }

    function testPendingOnlyRoundConsumesBudgetButIdleGapsDoNot() public {
        enlist(1, 1); // E 2.
        vm.warp(G + 4 * 600);
        enlist(2, 1); // E 6.
        vm.warp(G + 8 * 600);
        enlist(3, 1); // E 10.
        core.settle(1000);
        vm.warp(G + 1000 * 600);
        game.advance(1);
        assertEq(game.processedThrough(), 2);
        assertEq(game.alivePower(1), 100);
        game.advance(1);
        assertEq(game.processedThrough(), 6);
        assertEq(game.alivePower(1), 200);
        game.advance(1);
        assertEq(game.processedThrough(), 10);
        assertEq(game.alivePower(1), 300);
        game.advance(1);
        assertEq(game.processedThrough(), 1000);
        assertEq(game.alivePower(1), 300);
        assertEq(game.totalDamageUnits(), 0);
    }

    function testZeroWorkActiveRecordStillGrantsWheelScrapAndResetsNap() public {
        enlist(1, 1);
        idle(17);
        wheel(18, 0, bytes32(uint256(1)));
        assertEq(game.burrowStreak(), 0);
        assertEq(raider(1).data.scrap, 1);
        assertEq(game.totalDamageUnits(), 0);
        assertEq(game.bossId(), 1);
        idle(35);
        (,, bool armed) = game.pendingMove();
        assertFalse(armed);
    }

    function testMaximumUint64WorkDoesNotOverflowDamageOrLeakOverkill() public {
        enlist(1, 0);
        wheel(2, type(uint64).max, bytes32(0));
        uint256 expected = uint256(type(uint64).max) * 150 * 100;
        assertEq(game.totalDamageUnits(), expected);
        assertEq(game.bossAt(1).damageUnits, expected);
        assertEq(game.scoreOf(1, 1), expected / 10_000);
        assertEq(game.bossId(), 2);
        assertEq(game.boss().damageUnits, 0);
        idle(4);
        assertEq(game.lastRunWork(), type(uint64).max);
        wheel(5, 0, bytes32(0));
        assertEq(game.totalDamageUnits(), expected);
    }

    function testPreviousRunClampLowHighAndAllTiers() public {
        for (uint256 scenario; scenario < 2; ++scenario) {
            if (scenario != 0) setUp();
            uint64 work = scenario == 0 ? 1 : 12_001;
            enlist(1, 0);
            wheel(2, work, bytes32(0));
            idle(4);
            assertEq(game.lastRunWork(), work);
            uint256 clamped = scenario == 0 ? 1000 : 12_000;
            for (uint256 kill; kill < 3; ++kill) {
                uint64 r = uint64(5 + kill);
                wheel(r, 1_000_000, bytes32(0));
                SqueekRaider.Boss memory b = game.boss();
                uint256 expected = 3 * clamped * (100 + game.partyWeight()) * 150 * (13 ** uint256(b.tier))
                    / (10 ** uint256(b.tier));
                assertEq(b.maxHpUnits, expected);
                assertEq(b.hpUnits, expected);
                assertEq(b.previousRunWork, work);
                assertEq(b.seasonId, (b.id - 1) / 3 + 1);
            }
        }
    }
}
