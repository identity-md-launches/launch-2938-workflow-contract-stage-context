// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SqueekRaider} from "src/SqueekRaider.sol";
import {RaiderFixture} from "./SqueekRaider.t.sol";

/// @dev The gas bound inside `advance` (ADVANCE_GAS / GAS_RESERVE) must only decide *where* a call
///      stops, never *what* the processed rounds produce. Every stopping point must be resumable.
/// forge-config: default.fuzz.runs = 48
contract GasPartitionTest is RaiderFixture {
    uint256 internal constant TX_GAS = (1 << 24) - 21_000;

    function _call(SqueekRaider g, uint256 gasLimit, bytes memory data) internal returns (bool ok) {
        (ok,) = address(g).call{gas: gasLimit}(data);
    }

    /// @dev Same party, same queued boundaries (one per stalled round) and same source on both games.
    function _setup(SqueekRaider a, SqueekRaider b, uint256 entropy, uint64 stall)
        internal
        returns (uint64 last)
    {
        a.advance(1);
        b.advance(1);
        for (uint256 id = 1; id <= 4; ++id) {
            vm.prank(alice);
            a.enlist(ids(id), uint8(id % 4));
            vm.prank(alice);
            b.enlist(ids(id), uint8(id % 4));
        }
        for (uint64 r = 1; r <= stall; ++r) {
            vm.warp(uint256(G) + uint256(r) * 600 + 1);
            address w = address(uint160(0x20000 + r));
            vm.prank(w);
            a.enlistDemo(uint8((entropy >> r) % 4));
            vm.prank(w);
            b.enlistDemo(uint8((entropy >> r) % 4));
        }
        for (uint64 r = 1; r <= stall + 30; ++r) {
            entropy = uint256(keccak256(abi.encode(entropy, r)));
            // Roughly a third of rounds are idle, so queued, active and idle steps interleave.
            if (entropy % 3 != 0) core.wheel(r, uint64((entropy >> 8) % 20_000), bytes32(entropy));
            last = r;
        }
        core.settle(last);
        vm.warp(uint256(G) + uint256(last + 1) * 600 + 1);
    }

    function _assertSame(SqueekRaider a, SqueekRaider b, uint64 stall) internal {
        assertEq(a.processedThrough(), b.processedThrough(), "cursor");
        assertEq(a.processedWork(), b.processedWork(), "work cursor");
        assertEq(a.totalDamageUnits(), b.totalDamageUnits(), "damage");
        assertEq(a.lastRunWork(), b.lastRunWork(), "previous run");
        assertEq(a.burrowStreak(), b.burrowStreak(), "streak");
        assertEq(a.totalBurrowRounds(), b.totalBurrowRounds(), "burrow clock");
        assertEq(keccak256(abi.encode(a.boss())), keccak256(abi.encode(b.boss())), "boss");
        for (uint8 s; s < 4; ++s) {
            assertEq(a.alivePower(s), b.alivePower(s), "power");
            assertEq(a.aliveCount(s), b.aliveCount(s), "count");
            assertEq(a.koEpoch(s), b.koEpoch(s), "epoch");
        }
        for (uint256 id = 1; id <= 4; ++id) {
            _sameRaider(a, b, id);
        }
        for (uint64 r = 1; r <= stall; ++r) {
            _sameRaider(a, b, a.demoId(address(uint160(0x20000 + r))));
        }
    }

    /// @dev Compares what a raider owns and is, not where its lazy checkpoint happens to sit: a poked
    ///      raider legitimately has a later persisted checkpoint than an unpoked one.
    function _sameRaider(SqueekRaider a, SqueekRaider b, uint256 id) internal {
        for (uint256 i; i < 8 && !a.raider(id).caughtUp; ++i) {
            a.poke(ids(id));
        }
        for (uint256 i; i < 8 && !b.raider(id).caughtUp; ++i) {
            b.poke(ids(id));
        }
        SqueekRaider.RaiderView memory x = a.raider(id);
        SqueekRaider.RaiderView memory y = b.raider(id);
        assertTrue(x.caughtUp && y.caughtUp, "views did not converge");
        assertEq(x.ko, y.ko, "ko");
        assertEq(x.data.stance, y.data.stance, "stance");
        assertEq(x.data.level, y.data.level, "level");
        assertEq(x.data.epoch, y.data.epoch, "raider epoch");
        assertEq(x.data.scrap, y.data.scrap, "scrap");
        assertEq(x.data.dreams, y.data.dreams, "dreams");
        assertEq(x.data.damage, y.data.damage, "damage credit");
        assertEq(x.data.bossesSlain, y.data.bossesSlain, "trophies");
        assertEq(keccak256(abi.encode(x.data.pending)), keccak256(abi.encode(y.data.pending)), "pending");
        for (uint64 boss = 1; boss <= a.bossId(); ++boss) {
            assertEq(a.scoreOf(boss, id), b.scoreOf(boss, id), "boss score");
        }
    }

    /// @dev Drain a backlog with random per-call gas limits between the reserve and the transaction
    ///      cap; the outcome must equal one-step-at-a-time processing with unlimited gas.
    function testFuzzRandomGasLimitsDoNotChangeOutcomes(uint256 entropy, uint8 stallSeed) public {
        uint64 stall = uint64(bound(stallSeed, 8, 48));
        SqueekRaider stepped = new SqueekRaider(address(core), address(nft), address(staking));
        uint64 last = _setup(game, stepped, entropy, stall);

        uint256 calls;
        while (game.processedThrough() < last) {
            entropy = uint256(keccak256(abi.encode(entropy, "gas")));
            uint256 limit = bound(entropy, 2_100_000, TX_GAS);
            uint64 before = game.processedThrough();
            assertTrue(_call(game, limit, abi.encodeCall(game.advance, (128))), "advance reverted");
            // A limit below the reserve plus one step may legitimately do nothing; retry with the cap.
            if (game.processedThrough() == before) {
                assertTrue(_call(game, TX_GAS, abi.encodeCall(game.advance, (128))));
                assertGt(game.processedThrough(), before, "a capped call made no progress");
            }
            assertLt(++calls, 400, "drain did not converge");
        }
        while (stepped.processedThrough() < last) {
            stepped.advance(1);
        }
        _assertSame(game, stepped, stall);
    }

    /// @dev Same property when the gas-bounded advance runs inside actions rather than `advance`.
    function testFuzzActionsUnderBacklogStopSafelyAndResume(uint256 entropy) public {
        uint64 stall = 40;
        SqueekRaider stepped = new SqueekRaider(address(core), address(nft), address(staking));
        uint64 last = _setup(game, stepped, entropy, stall);
        uint256 calls;
        while (game.processedThrough() < last) {
            entropy = uint256(keccak256(abi.encode(entropy, "action")));
            uint256 limit = bound(entropy, 2_400_000, TX_GAS);
            // A permissionless no-op-on-state action (poke) still drives the bounded advance.
            assertTrue(_call(game, limit, abi.encodeCall(game.poke, (ids(1 + entropy % 4)))), "poke reverted");
            assertLt(++calls, 400, "drain did not converge");
        }
        while (stepped.processedThrough() < last) {
            stepped.advance(1);
        }
        _assertSame(game, stepped, stall);
    }

    /// @dev A single-ID action is the "small action" GAS_RESERVE is meant to cover: it must succeed at
    ///      every gas limit during a backlog, and its effective round must not depend on how far the
    ///      inner advance got.
    function testSingleActionSucceedsAtEveryGasLimitDuringBacklog() public {
        SqueekRaider stepped = new SqueekRaider(address(core), address(nft), address(staking));
        _setup(game, stepped, 7, 48);
        uint256 snap = vm.snapshotState();
        uint64 expectedRound = game.liveRound() + 1;
        uint64 lowest = type(uint64).max;
        uint64 highest;
        for (uint256 limit = 400_000; limit <= TX_GAS; limit += 700_000) {
            vm.revertToState(snap);
            vm.prank(alice);
            assertTrue(_call(game, limit, abi.encodeCall(game.enlist, (ids(8), uint8(1)))), "enlist reverted");
            SqueekRaider.RaiderView memory v = raider(8);
            assertTrue(v.data.enlisted);
            assertEq(v.data.pending.round, expectedRound, "E depends on processing progress");
            uint64 p = game.processedThrough();
            if (p < lowest) lowest = p;
            if (p > highest) highest = p;
        }
        assertEq(lowest, 0, "the low-gas case must process nothing, or the test proves nothing");
        assertGt(highest, 0, "the high-gas case must make progress");
    }

    /// @dev An advance starved below the reserve must leave all state untouched, including the
    ///      anchoring step, and must not revert.
    function testStarvedAdvanceIsANoOp() public {
        game.advance(1);
        enlist(1, 0);
        for (uint64 r = 1; r <= 5; ++r) {
            core.wheel(r, 100, bytes32(uint256(r)));
        }
        vm.warp(G + 6 * 600 + 1);
        uint256 damage = game.totalDamageUnits();
        assertTrue(_call(game, 1_900_000, abi.encodeCall(game.advance, (128))));
        assertEq(game.processedThrough(), 0);
        assertEq(game.totalDamageUnits(), damage);
        game.advance(128);
        assertEq(game.processedThrough(), 5);
    }
}
