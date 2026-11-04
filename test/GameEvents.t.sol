// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {RaiderFixture} from "./SqueekRaider.t.sol";
import {SqueekRaider} from "src/SqueekRaider.sol";

contract GameEventsTest is RaiderFixture {
    event ChangeQueued(
        uint256 indexed id, uint64 indexed round, SqueekRaider.Change kind, uint8 stance, uint8 level
    );
    event Enlisted(uint256 indexed id, address indexed controller, bool isDemo);
    event RoundApplied(
        uint64 indexed fromRound, uint64 indexed throughRound, bool wheel, uint64 work, uint64 bossId
    );
    event Credited(
        uint256 indexed id, uint64 indexed bossId, uint64 indexed seasonId, uint256 damage, uint256 dreams
    );

    function testEnlistmentAndDemoEventsIdentifyControllerAndFutureBoundary() public {
        game.advance(0);
        vm.expectEmit(true, true, false, true, address(game));
        emit ChangeQueued(1, 2, SqueekRaider.Change.Enlist, 2, 0);
        vm.expectEmit(true, true, false, true, address(game));
        emit Enlisted(1, alice, false);
        enlist(1, 2);
        uint256 demo = game.demoId(bob);
        vm.expectEmit(true, true, false, true, address(game));
        emit ChangeQueued(demo, 2, SqueekRaider.Change.Enlist, 3, 0);
        vm.expectEmit(true, true, false, true, address(game));
        emit Enlisted(demo, bob, true);
        vm.prank(bob);
        game.enlistDemo(3);
    }

    function testWheelAndCompressedIdleEventsDescribeAppliedRange() public {
        enlist(1, 1);
        core.wheel(2, 10, bytes32(0));
        vm.warp(G + 2 * 600);
        vm.expectEmit(true, true, false, true, address(game));
        emit RoundApplied(1, 1, false, 0, 1);
        vm.expectEmit(true, true, false, true, address(game));
        emit RoundApplied(2, 2, true, 10, 1);
        game.advance(128);
        core.settle(1_000_000);
        vm.warp(G + 1_000_000 * 600);
        vm.expectEmit(true, true, false, true, address(game));
        emit RoundApplied(3, 1_000_000, false, 0, 1);
        game.advance(128);
    }

    function testFractionalCreditEventsCarryOnlyNewWholeDamage() public {
        enlist(1, 1);
        wheel(2, 1, bytes32(0));
        vm.expectEmit(true, true, true, true, address(game));
        emit Credited(1, 1, 1, 0, 0); // First half point is retained, not rounded up.
        checkpoint(1);
        wheel(3, 1, bytes32(0));
        vm.expectEmit(true, true, true, true, address(game));
        emit Credited(1, 1, 1, 1, 0);
        checkpoint(1);
        vm.recordLogs();
        checkpoint(1);
        checkpoint(1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, keccak256("Credited(uint256,uint64,uint64,uint256,uint256)")), 0);
        assertEq(_count(logs, keccak256("ScrapCredited(uint256,uint256)")), 0);
        assertEq(raider(1).data.damage, 1);
    }

    function testKOEventPrecedesLandingRoundDamageAndTargetsCohortEpoch() public {
        enlist(1, 0);
        wheel(2, 1, hashFor(0, 1));
        idle(20);
        vm.recordLogs();
        wheel(21, 1, bytes32(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 moveIndex = type(uint256).max;
        uint256 koIndex = type(uint256).max;
        uint256 roundIndex = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(game)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == keccak256("MoveLanded(uint64,uint64,uint8,bool,uint256)")) moveIndex = i;
            if (topic == keccak256("KO(uint8,uint64,uint64,uint64,uint256)")) {
                koIndex = i;
                assertEq(logs[i].topics[1], bytes32(uint256(0))); // Striker.
                assertEq(logs[i].topics[2], bytes32(uint256(0))); // Previous cohort epoch.
                assertEq(logs[i].topics[3], bytes32(uint256(1))); // Boss.
                (uint64 round, uint256 power) = abi.decode(logs[i].data, (uint64, uint256));
                assertEq(round, 21);
                assertEq(power, 100);
            }
            if (topic == keccak256("RoundApplied(uint64,uint64,bool,uint64,uint64)")) roundIndex = i;
        }
        assertLt(moveIndex, koIndex);
        assertLt(koIndex, roundIndex);
        assertEq(_count(logs, keccak256("KO(uint8,uint64,uint64,uint64,uint256)")), 1);
        assertEq(game.totalDamageUnits(), 15_000, "KO'd raider earned landing-round damage");
    }

    function testLazyTrophyEventIsEmittedOncePerBoss() public {
        enlist(1, 0);
        wheel(2, 50_000, bytes32(0));
        vm.recordLogs();
        checkpoint(1);
        checkpoint(1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, keccak256("TrophyCredited(uint256,uint64)")), 1);
        assertEq(raider(1).data.bossesSlain, 1);
    }

    function _count(Vm.Log[] memory logs, bytes32 signature) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(game) && logs[i].topics.length != 0
                    && logs[i].topics[0] == signature
            ) ++count;
        }
    }
}
