// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {SqueekRaider} from "../src/SqueekRaider.sol";
import {MockCore} from "./mocks/SqueekchainMocks.sol";
import {RaiderFixture} from "./SqueekRaider.t.sol";

contract RoundBoundariesTest is RaiderFixture {
    uint256 internal constant TX_GAS = (1 << 24) - 21_000;

    function _advanceCall(SqueekRaider g, uint256 gasLimit, uint256 rounds) internal returns (bool ok) {
        (ok,) = address(g).call{gas: gasLimit}(abi.encodeCall(g.advance, (rounds)));
    }

    /// @dev A settlement stall with a distinct queued change on every round, all then settling active.
    function _stall(SqueekRaider g, uint160 walletBase, uint64 rounds) internal {
        g.advance(1);
        for (uint64 r = 1; r <= rounds; ++r) {
            vm.warp(uint256(G) + uint256(r) * 600 + 1);
            vm.prank(address(walletBase + r));
            g.enlistDemo(uint8(r % 4));
        }
    }

    function _settleWheels(MockCore c, uint64 rounds) internal {
        for (uint64 r = 1; r <= rounds; ++r) {
            c.wheel(r, 1, bytes32(uint256(r)));
        }
    }

    function testQueuedBacklogDrainsUnderTransactionCapAndMatchesSingleSteps() public {
        MockCore otherCore = new MockCore();
        SqueekRaider stepped = new SqueekRaider(address(otherCore), address(nft), address(staking));
        game.advance(1);
        stepped.advance(1);
        for (uint64 r = 1; r <= 64; ++r) {
            vm.warp(uint256(G) + uint256(r) * 600 + 1);
            vm.prank(address(uint160(0x10000 + r)));
            game.enlistDemo(uint8(r % 4));
            vm.prank(address(uint160(0x10000 + r)));
            stepped.enlistDemo(uint8(r % 4));
        }
        _settleWheels(core, 64);
        _settleWheels(otherCore, 64);

        uint256 calls;
        while (game.processedThrough() < 64) {
            uint64 before = game.processedThrough();
            uint256 start = gasleft();
            assertTrue(_advanceCall(game, TX_GAS, 64));
            assertLt(start - gasleft(), TX_GAS);
            assertGt(game.processedThrough(), before);
            ++calls;
        }
        assertGt(calls, 1, "the backlog must not fit one call, or this test proves nothing");
        for (uint256 i; i < 64; ++i) {
            stepped.advance(1);
        }
        assertEq(stepped.processedThrough(), 64);
        assertEq(game.totalDamageUnits(), stepped.totalDamageUnits());
        assertEq(game.boss().hpUnits, stepped.boss().hpUnits);
        assertEq(game.boss().maxHpUnits, stepped.boss().maxHpUnits);
        for (uint256 s; s < 4; ++s) {
            assertEq(game.alivePower(s), stepped.alivePower(s));
            assertEq(game.aliveCount(s), stepped.aliveCount(s));
        }
    }

    function testGasBoundDoesNotDependOnTheCallersLimit() public {
        _stall(game, 0x10000, 64);
        _settleWheels(core, 64);
        uint256 snapshot = vm.snapshotState();
        assertTrue(_advanceCall(game, TX_GAS, 64));
        uint64 capped = game.processedThrough();
        vm.revertToState(snapshot);
        assertTrue(_advanceCall(game, 200_000_000, 64));
        assertEq(game.processedThrough(), capped);
        assertLt(capped, 64);
    }

    function testLowGasAdvanceStopsWithoutRevertingAndLaterResumes() public {
        _stall(game, 0x10000, 8);
        _settleWheels(core, 8);
        assertTrue(_advanceCall(game, 1_500_000, 64));
        assertEq(game.processedThrough(), 0);
        assertEq(game.totalDamageUnits(), 0);
        assertTrue(_advanceCall(game, 2_500_000, 64));
        uint64 partway = game.processedThrough();
        assertGt(partway, 0);
        assertLt(partway, 8);
        game.advance(64);
        assertEq(game.processedThrough(), 8);
    }

    function testFullBatchEnlistFitsTransactionCapDuringBacklog() public {
        _stall(game, 0x10000, 64);
        _settleWheels(core, 64);
        uint256[] memory batch = new uint256[](64);
        for (uint256 i; i < 64; ++i) {
            batch[i] = 1000 + i;
            nft.mint(batch[i], alice);
        }
        vm.prank(alice);
        (bool ok,) = address(game).call{gas: TX_GAS}(abi.encodeCall(game.enlist, (batch, uint8(0))));
        assertTrue(ok);
        assertTrue(raider(1063).data.enlisted);
        assertGt(game.processedThrough(), 0);
    }

    function testZeroWorkRunIsStoredAndSizesNextBossAtTheClamp() public {
        enlist(1, 0);
        wheel(1, 12_000, bytes32(0));
        idle(3);
        assertEq(game.lastRunWork(), 12_000);
        wheel(4, 0, bytes32(0));
        assertEq(game.lastRunWork(), 12_000, "stored only at the next nap start");
        idle(6);
        assertEq(game.lastRunWork(), 0);
        wheel(7, 50_000, bytes32(0));
        assertEq(game.bossId(), 2);
        assertEq(game.boss().previousRunWork, 0);
        assertEq(game.boss().maxHpUnits, 3 * 1000 * 200 * 150 * 13 / 10);
    }

    function testNapBeforeFirstProcessedWheelHasNoMoveAndKeepsDefaultRun() public {
        enlist(1, 0);
        vm.recordLogs();
        idle(30);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != SqueekRaider.NapStarted.selector, "no known hash, no NapStarted");
        }
        (, uint64 napRounds, bool armed) = game.pendingMove();
        assertEq(napRounds, 30);
        assertFalse(armed);
        assertEq(game.lastRunWork(), 1600);

        // Nap rewards do not depend on a move existing.
        enlist(2, 3);
        idle(33);
        assertEq(raider(2).data.dreams, 2); // Rounds 32 and 33: E is 32, nap positions below 37.

        // The Wheel ending that nap lands nothing, and supplies the hash for the next nap.
        wheel(34, 10, hashFor(0, 1));
        assertFalse(raider(1).ko);
        assertEq(game.koEpoch(0), 0);
        assertEq(game.lastRunWork(), 1600);

        idle(52);
        (uint8 move,, bool armedNow) = game.pendingMove();
        assertEq(move, 0);
        assertTrue(armedNow);
        assertEq(game.lastRunWork(), 10);
        wheel(53, 10, bytes32(0));
        assertTrue(raider(1).ko);
        assertEq(game.koEpoch(0), 1);
    }

    function testAnchorDuringNapIgnoresPreAnchorHashUntilAWheelIsProcessed() public {
        core.wheel(10, 500, hashFor(1, 1));
        core.settle(12);
        vm.warp(G + 12 * 600);
        game.advance(1);
        assertEq(game.processedThrough(), 12);
        idle(40);
        (,, bool armed) = game.pendingMove();
        assertFalse(armed);
        (uint8 target,,,,) = game.cover();
        assertEq(target, 0);
        wheel(41, 5, bytes32(0));
        assertEq(game.koEpoch(0), 0);
        assertEq(game.koEpoch(2), 0);
    }
}
