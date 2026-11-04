// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqueekRaider} from "../src/SqueekRaider.sol";
import {RaiderCard} from "../src/RaiderCard.sol";
import {MockCore, MockNFT, MockStaking, BadCore} from "./mocks/SqueekchainMocks.sol";

abstract contract RaiderFixture is Test {
    MockCore internal core;
    MockNFT internal nft;
    MockStaking internal staking;
    SqueekRaider internal game;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    uint64 internal constant G = 1_793_022_600;

    function setUp() public {
        vm.warp(G);
        core = new MockCore();
        nft = new MockNFT();
        staking = new MockStaking();
        game = new SqueekRaider(address(core), address(nft), address(staking));
        for (uint256 i = 1; i <= 8; ++i) {
            nft.mint(i, alice);
        }
    }

    function ids(uint256 id) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = id;
    }

    function enlist(uint256 id, uint8 stance) internal {
        vm.prank(alice);
        game.enlist(ids(id), stance);
    }

    function idle(uint64 through) internal {
        core.settle(through);
        vm.warp(uint256(G) + uint256(through) * 600);
        game.advance(128);
    }

    function wheel(uint64 round, uint64 work, bytes32 hash) internal {
        core.wheel(round, work, hash);
        vm.warp(uint256(G) + uint256(round) * 600);
        game.advance(128);
    }

    function hashFor(uint8 move, uint64 boss) internal pure returns (bytes32) {
        for (uint256 i;; ++i) {
            if (uint256(keccak256(abi.encode(bytes32(i), boss))) % 3 == move) return bytes32(i);
        }
        return bytes32(0);
    }

    function raider(uint256 id) internal view returns (SqueekRaider.RaiderView memory) {
        return game.raider(id);
    }

    function checkpoint(uint256 id) internal {
        game.poke(ids(id));
    }
}

contract SqueekRaiderTest is RaiderFixture {
    function testConstructorUsesNoExternalStateAndDeploysRenderer() public {
        SqueekRaider empty = new SqueekRaider(address(0x111), address(0x222), address(0x333));
        assertEq(empty.core(), address(0x111));
        assertGt(address(empty.renderer()).code.length, 0);
        assertFalse(empty.anchored());
        assertEq(empty.lastRunWork(), 1600);
        assertEq(empty.boss().hpUnits, 7200 * 10_000);
        assertLe(address(empty).code.length, 24_576);
        assertLe(type(SqueekRaider).creationCode.length + 96, 49_152);
        assertLe(address(empty.renderer()).code.length, 24_576);
        vm.expectRevert(SqueekRaider.InvalidAddress.selector);
        new SqueekRaider(address(0), address(nft), address(staking));
    }

    function testFirstCallAnchorsWithoutHistoricRewards() public {
        core.wheel(100, 2000, bytes32(uint256(1)));
        vm.warp(G + 100 * 600);
        enlist(1, 0);
        assertEq(game.processedThrough(), 100);
        assertEq(game.processedWork(), 2000);
        assertEq(raider(1).data.scrap, 0);
        assertEq(raider(1).data.pending.round, 102);
        assertEq(game.totalDamageUnits(), 0);
    }

    function testEntryFutureRoundAndAtomicDuplicateBatch() public {
        enlist(1, 0);
        assertEq(game.alivePower(0), 0);
        wheel(1, 100, bytes32(uint256(1)));
        assertEq(game.scoreOf(1, 1), 0);
        wheel(2, 100, bytes32(uint256(2)));
        assertEq(game.alivePower(0), 100);
        assertEq(game.scoreOf(1, 1), 150);
        assertEq(raider(1).data.scrap, 1);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.AlreadyEnlisted.selector);
        game.enlist(ids(1), 0);
        uint256[] memory duplicate = new uint256[](2);
        duplicate[0] = 2;
        duplicate[1] = 2;
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.AlreadyEnlisted.selector);
        game.enlist(duplicate, 0);
        assertFalse(raider(2).data.enlisted);
    }

    function testStakedControllerAndTransferFollowToken() public {
        nft.mint(1, address(staking));
        staking.setDepositor(address(nft), 1, bob);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.NotController.selector);
        game.enlist(ids(1), 1);
        vm.prank(bob);
        game.enlist(ids(1), 1);
        wheel(2, 100, bytes32(0));
        assertEq(game.controllerOf(1), bob);
        nft.mint(1, alice);
        idle(8);
        vm.prank(bob);
        vm.expectRevert(SqueekRaider.NotController.selector);
        game.setStance(ids(1), 2);
        vm.prank(alice);
        game.setStance(ids(1), 2);
        assertEq(game.scoreOf(1, 1), 50);
    }

    function testEnlistReplacementAndStanceCooldown() public {
        enlist(1, 0);
        vm.prank(alice);
        game.setStance(ids(1), 2);
        idle(2);
        assertEq(game.alivePower(0), 0);
        assertEq(game.alivePower(2), 100);
        assertEq(raider(1).data.stance, 2);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.Cooldown.selector);
        game.setStance(ids(1), 1);
        idle(6); // live 7, E 8, six rounds after enlist E 2.
        vm.prank(alice);
        game.setStance(ids(1), 1);
        vm.prank(alice);
        game.setStance(ids(1), 3);
        idle(8);
        assertEq(game.alivePower(2), 0);
        assertEq(game.alivePower(1), 0);
        assertEq(game.alivePower(3), 100);
    }

    function testPendingFreezesAtRoundStartUnderSettlementLag() public {
        enlist(1, 0);
        vm.warp(G + 600); // E 2 started, but core is still at zero.
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.PendingLocked.selector);
        game.setStance(ids(1), 1);
        assertEq(raider(1).data.pending.to, 0);
    }

    function testNoActionAffectsRoundsAtOrBeforeSubmissionWithLag() public {
        game.advance(1);
        vm.warp(G + 100 * 600); // live 101, E 102.
        enlist(1, 0);
        for (uint64 r = 1; r <= 101; ++r) {
            core.wheel(r, 1, bytes32(uint256(r)));
        }
        vm.warp(G + 101 * 600);
        game.advance(128);
        assertEq(game.processedThrough(), 101);
        assertEq(game.totalDamageUnits(), 0);
        assertEq(game.alivePower(0), 0);
        wheel(102, 100, bytes32(0));
        assertEq(game.scoreOf(1, 1), 150);
    }

    function testIdleGapConstantCostAndRewardWindow() public {
        enlist(1, 2);
        enlist(2, 3);
        idle(2);
        assertEq(raider(1).data.scrap, 1); // round 2 is nap round 2.
        uint256 before = gasleft();
        idle(1_000_000);
        assertLt(before - gasleft(), 700_000);
        assertEq(game.processedThrough(), 1_000_000);
        assertEq(raider(1).data.scrap, 36);
        assertEq(raider(2).data.dreams, 36);
        assertEq(game.scoreOf(1, 2), 10_800);
    }

    function testMoveDoesNotLandAfterSeventeenIdleRounds() public {
        enlist(1, 0);
        wheel(2, 1, hashFor(0, 1));
        idle(19);
        (,, bool armed) = game.pendingMove();
        assertFalse(armed);
        wheel(20, 1, bytes32(0));
        assertFalse(raider(1).ko);
        assertEq(game.koEpoch(0), 0);
        assertEq(raider(1).data.scrap, 2);
    }

    function testAllThreeMovesLandAfterEighteenAndGuardNeverKO() public {
        for (uint8 move; move < 3; ++move) {
            MockCore c = new MockCore();
            SqueekRaider g = new SqueekRaider(address(c), address(nft), address(staking));
            vm.warp(G);
            uint8 target = move == 0 ? 0 : move == 1 ? 2 : 3;
            vm.prank(alice);
            g.enlist(ids(1), target);
            // A demo guard must not cover a real raider.
            vm.prank(bob);
            uint256 demo = g.enlistDemo(1);
            c.wheel(2, 1, hashFor(move, 1));
            vm.warp(G + 2 * 600);
            g.advance(128);
            c.settle(20);
            vm.warp(G + 20 * 600);
            g.advance(128);
            (uint8 actual,, bool armed) = g.pendingMove();
            assertEq(actual, move);
            assertTrue(armed);
            c.wheel(21, 1, bytes32(0));
            vm.warp(G + 21 * 600);
            g.advance(128);
            assertTrue(g.raider(1).ko);
            assertFalse(g.raider(demo).ko);
            assertEq(g.alivePower(target), 0);
            assertEq(g.koEpoch(target), 1);
            assertEq(g.raider(1).data.scrap, target == 2 ? 18 : 1);
        }
    }

    function testRealGuardCoversTwoRealRaidersIncludingDemos() public {
        enlist(1, 0);
        enlist(2, 0);
        enlist(3, 1);
        vm.prank(bob);
        uint256 demo = game.enlistDemo(0);
        wheel(2, 1, hashFor(0, 1));
        idle(20);
        (,,, uint256 guards, bool blocked) = game.cover();
        assertEq(guards, 1);
        assertTrue(blocked);
        wheel(21, 1, bytes32(0));
        assertFalse(raider(1).ko);
        assertFalse(raider(2).ko);
        assertFalse(raider(demo).ko);
    }

    function testDemoOnlyTargetCannotUseRealGuardCover() public {
        enlist(1, 1);
        vm.prank(bob);
        uint256 demo = game.enlistDemo(0);
        wheel(2, 1, hashFor(0, 1));
        idle(20);
        wheel(21, 1, bytes32(0));
        assertTrue(raider(demo).ko);
        assertFalse(raider(1).ko);
    }

    function testKOBetweenSubmitAndEffectiveRoundCancelsEscape() public {
        enlist(1, 0);
        wheel(2, 10, hashFor(0, 1));
        vm.warp(G + 23 * 600);
        vm.prank(alice); // E 25, settled 2.
        game.setStance(ids(1), 1);
        core.wheel(21, 10, bytes32(0));
        game.advance(128);
        assertTrue(raider(1).ko);
        assertEq(uint256(raider(1).data.pending.kind), uint256(SqueekRaider.Change.None));
        core.settle(25);
        vm.warp(G + 25 * 600);
        game.advance(128);
        checkpoint(1);
        assertEq(game.alivePower(0), 0);
        assertEq(game.alivePower(1), 0);
        assertEq(raider(1).data.stance, 0);
        assertEq(game.scoreOf(1, 1), 15);
    }

    function testChangeAtMoveRoundAppliesBeforeKOAndDamage() public {
        enlist(1, 0);
        wheel(2, 10, hashFor(0, 1));
        idle(19);
        vm.prank(alice); // E 21.
        game.setStance(ids(1), 1);
        wheel(21, 100, bytes32(0));
        assertFalse(raider(1).ko);
        assertEq(raider(1).data.stance, 1);
        assertEq(game.scoreOf(1, 1), 65);
        assertEq(game.koEpoch(0), 0);
    }

    function testKOStopsRewardsAndFreeRestNeedsSixLaterBurrows() public {
        enlist(1, 0);
        wheel(2, 10, hashFor(0, 1));
        idle(20);
        wheel(21, 10, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.KnockedOut.selector);
        game.upgrade(1);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.KnockedOut.selector);
        game.setStance(ids(1), 2);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.InsufficientScrap.selector);
        game.revive(1);
        vm.expectRevert(SqueekRaider.NotRested.selector);
        game.rest(ids(1));
        idle(26);
        vm.expectRevert(SqueekRaider.NotRested.selector);
        game.rest(ids(1));
        idle(27);
        vm.prank(bob);
        game.rest(ids(1));
        assertEq(raider(1).data.pending.round, 29);
        assertEq(raider(1).data.scrap, 1);
        wheel(29, 100, bytes32(0));
        assertFalse(raider(1).ko);
        assertEq(raider(1).data.scrap, 2);
        assertEq(game.scoreOf(1, 1), 165);
    }

    function testBossHpRescalesOnEntryUpgradeStanceAndBury() public {
        enlist(1, 0);
        idle(2);
        assertEq(game.boss().hpUnits, 14_400 * 10_000);
        for (uint64 r = 3; r <= 12; ++r) {
            wheel(r, 1, bytes32(0));
        }
        uint256 previous = game.boss().hpUnits;
        vm.prank(alice);
        game.upgrade(1);
        assertEq(raider(1).data.scrap, 0);
        idle(14);
        assertEq(game.boss().hpUnits, previous * 210 / 200);
        assertEq(raider(1).data.level, 1);
        previous = game.boss().hpUnits;
        vm.prank(alice);
        game.setStance(ids(1), 1);
        idle(16);
        assertEq(game.boss().hpUnits, previous * 136 / 210);
        nft.burn(1);
        vm.prank(bob);
        game.bury(1);
        idle(18);
        assertEq(game.alivePower(1), 0);
        assertTrue(raider(1).data.buried);
    }

    function testUpgradeIsNotReplaceableAndDoesNotBoostRewards() public {
        enlist(1, 2);
        for (uint64 r = 2; r <= 11; ++r) {
            wheel(r, 1, bytes32(0));
        }
        vm.prank(alice);
        game.upgrade(1);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.PendingLocked.selector);
        game.setStance(ids(1), 1);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.PendingExists.selector);
        game.upgrade(1);
        wheel(13, 100, bytes32(0));
        assertEq(raider(1).data.scrap, 1);
        assertEq(raider(1).data.level, 1);
        uint256 damage = raider(1).data.damage;
        wheel(14, 100, bytes32(0));
        assertEq(raider(1).data.damage - damage, 88);
        assertEq(raider(1).data.scrap, 2);
        idle(51);
        assertEq(raider(1).data.scrap, 38);
    }

    function testDemoOnceAndMaxLevelThreeRealMaxFive() public {
        vm.prank(alice);
        uint256 demo = game.enlistDemo(1);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.AlreadyEnlisted.selector);
        game.enlistDemo(0);
        assertEq(demo, (uint256(1) << 255) | uint160(alice));
        assertEq(game.controllerOf(demo), alice);
        assertEq(game.controllerOf(demo | (uint256(1) << 200)), address(0));
        enlist(1, 1);
        for (uint64 r = 2; r <= 401; ++r) {
            core.wheel(r, 1, bytes32(0));
        }
        vm.warp(G + 401 * 600);
        for (uint256 i; i < 4; ++i) {
            game.advance(128);
        }
        for (uint64 level = 1; level <= 5; ++level) {
            vm.prank(alice);
            game.upgrade(1);
            if (level <= 3) {
                vm.prank(alice);
                game.upgrade(demo);
            }
            idle(401 + 2 * level);
        }
        assertEq(raider(1).data.level, 5);
        assertEq(raider(demo).data.level, 3);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.MaxLevel.selector);
        game.upgrade(demo);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.MaxLevel.selector);
        game.upgrade(1);
        assertEq(raider(demo).data.scrap, 330);
        assertEq(raider(1).data.scrap, 90);
    }

    function testOverkillStaysOnKilledBossAndLazyTrophies() public {
        enlist(1, 0);
        enlist(2, 3);
        wheel(2, 50_000, bytes32(0));
        assertEq(game.bossId(), 2);
        assertEq(game.scoreOf(1, 1), 75_000);
        assertEq(game.scoreOf(1, 2), 12_500);
        assertEq(game.scoreOf(2, 1), 0);
        assertEq(game.boss().damageUnits, 0);
        assertEq(raider(1).data.bossesSlain, 1);
        assertEq(raider(2).data.bossesSlain, 1);
        checkpoint(1);
        checkpoint(1);
        assertEq(raider(1).data.bossesSlain, 1);
        assertEq(game.bossAt(1).damageUnits, 87_500 * 10_000);
    }

    function testEightBossCheckpointBoundAndSeasonViews() public {
        enlist(1, 0);
        for (uint64 r = 2; r <= 21; ++r) {
            wheel(r, 50_000, bytes32(0));
        }
        assertEq(game.bossId(), 21);
        assertFalse(raider(1).caughtUp);
        assertEq(game.scoreOf(20, 1), 75_000);
        assertEq(game.seasonScoreOf(1, 1), 225_000);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.NeedsPoke.selector);
        game.upgrade(1);
        checkpoint(1);
        checkpoint(1);
        checkpoint(1);
        assertTrue(raider(1).caughtUp);
        assertEq(raider(1).data.bossesSlain, 20);
        assertEq(raider(1).data.damage, 1_500_000);
        assertEq(game.season(), 7);
        assertEq(game.boss().tier, 2);
    }

    function testPreviousRunSizingAndTierSeason() public {
        enlist(1, 0);
        wheel(2, 100, bytes32(0));
        wheel(3, 200, bytes32(0));
        idle(4);
        wheel(5, 300, bytes32(0));
        idle(7); // One idle round did not split the run.
        assertEq(game.lastRunWork(), 600);
        wheel(8, 50_000, bytes32(0));
        assertEq(game.bossId(), 2);
        assertEq(game.boss().previousRunWork, 600);
        assertEq(game.boss().maxHpUnits, 3 * 1000 * 200 * 150 * 13 / 10);
    }

    function testBoundedAdvanceAcrossPagesAndPendingIdleRounds() public {
        enlist(1, 1);
        for (uint64 r = 1; r <= 50; ++r) {
            core.wheel(r, 1, bytes32(uint256(r)));
        }
        vm.warp(G + 50 * 600);
        game.advance(3);
        assertEq(game.processedThrough(), 3);
        game.advance(16);
        assertEq(game.processedThrough(), 19);
        game.advance(0);
        assertEq(game.processedThrough(), 19);
        game.advance(type(uint256).max);
        assertEq(game.processedThrough(), 50);
        assertEq(raider(1).data.scrap, 49);
    }

    function testSourceOutagesMalformedResponsesAndCertifiedCursor() public {
        core.setFailure(true, true);
        game.advance(type(uint256).max);
        assertFalse(game.anchored());
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.SourceUnavailable.selector);
        game.enlist(ids(1), 0);
        core.setFailure(false, false);
        enlist(1, 0);
        core.wheel(10, 10, bytes32(0));
        vm.warp(G + 10 * 600);
        core.setFailure(false, true);
        game.advance(128);
        assertEq(game.processedThrough(), 0);
        core.setFailure(false, false);
        core.setCertificationLimit(5);
        game.advance(128);
        assertEq(game.processedThrough(), 5);
        core.setCertificationLimit(type(uint64).max);
        game.advance(128);
        assertEq(game.processedThrough(), 10);
        BadCore broken = new BadCore();
        SqueekRaider bad = new SqueekRaider(address(broken), address(nft), address(staking));
        broken.configure(hex"aa", false);
        bad.advance(128);
        assertFalse(bad.anchored());
        broken.configure(new bytes(3000), false);
        bad.advance(128);
        assertFalse(bad.anchored());
    }

    function testValidationAndBuryOnlyBurnedRealNFT() public {
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.InvalidStance.selector);
        game.enlist(ids(1), 4);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.InvalidId.selector);
        game.enlist(ids(1 << 255), 0);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.InvalidBatch.selector);
        game.enlist(new uint256[](0), 0);
        vm.expectRevert(SqueekRaider.NotEnlisted.selector);
        game.poke(ids(1));
        enlist(1, 0);
        vm.expectRevert(SqueekRaider.NotBurned.selector);
        game.bury(1);
        uint256 demo = game.demoId(alice);
        vm.expectRevert(SqueekRaider.InvalidId.selector);
        game.bury(demo);
        nft.burn(1);
        game.bury(1);
        idle(2);
        assertEq(game.alivePower(0), 0);
        assertTrue(raider(1).data.buried);
        vm.expectRevert(SqueekRaider.NotEnlisted.selector);
        game.bury(1);
    }
}
