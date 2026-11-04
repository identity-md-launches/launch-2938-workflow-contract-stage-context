// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RaiderFixture} from "./SqueekRaider.t.sol";
import {SqueekRaider} from "src/SqueekRaider.sol";
import {BadCore} from "./mocks/SqueekchainMocks.sol";

contract ActionFailuresTest is RaiderFixture {
    function testEveryActionRejectsBeforeGenesisAndAdvanceIsHarmless() public {
        vm.warp(G - 1);
        bytes[] memory actions = _actions(1);
        for (uint256 i; i < actions.length; ++i) {
            vm.prank(alice);
            (bool ok, bytes memory reason) = address(game).call(actions[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(SqueekRaider.BeforeGenesis.selector));
        }
        game.advance(type(uint256).max);
        assertEq(game.liveRound(), 0);
        assertFalse(game.anchored());
        vm.expectRevert(SqueekRaider.BeforeGenesis.selector);
        game.effectiveRound();
        vm.warp(G);
        enlist(1, 0); // The failed calls must not leave the reentrancy lock set.
    }

    function testUnavailableInitialSourceRejectsAllActionsThenRecovers() public {
        core.setFailure(true, true);
        bytes[] memory actions = _actions(1);
        for (uint256 i; i < actions.length; ++i) {
            vm.prank(alice);
            (bool ok, bytes memory reason) = address(game).call(actions[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(SqueekRaider.SourceUnavailable.selector));
        }
        assertFalse(game.anchored());
        core.setFailure(false, false);
        enlist(1, 0);
        wheel(2, 1, bytes32(0));
        assertEq(game.alivePower(0), 100);
    }

    function testAllBatchActionsRejectZeroAndSixtyFiveEntries() public {
        for (uint256 which; which < 2; ++which) {
            uint256[] memory batch = new uint256[](which == 0 ? 0 : 65);
            bytes[4] memory actions = [
                abi.encodeCall(SqueekRaider.enlist, (batch, 0)),
                abi.encodeCall(SqueekRaider.setStance, (batch, 0)),
                abi.encodeCall(SqueekRaider.rest, (batch)),
                abi.encodeCall(SqueekRaider.poke, (batch))
            ];
            for (uint256 i; i < actions.length; ++i) {
                vm.prank(alice);
                (bool ok, bytes memory reason) = address(game).call(actions[i]);
                assertFalse(ok);
                assertEq(reason, abi.encodeWithSelector(SqueekRaider.InvalidBatch.selector));
            }
        }
        assertFalse(raider(1).data.enlisted);
    }

    function testMaximumBatchCanEnlistCheckpointAndChangeStance() public {
        uint256[] memory batch = new uint256[](64);
        for (uint256 i; i < batch.length; ++i) {
            batch[i] = i + 1;
            nft.mint(i + 1, alice);
        }
        vm.prank(alice);
        game.enlist(batch, 3);
        idle(2);
        assertEq(game.alivePower(3), 6400);
        assertEq(game.aliveCount(3), 64);
        game.poke(batch);
        for (uint256 i; i < batch.length; ++i) {
            assertEq(raider(batch[i]).data.dreams, 1);
        }
        idle(6);
        vm.prank(alice);
        game.setStance(batch, 1);
        idle(8);
        assertEq(game.alivePower(3), 0);
        assertEq(game.alivePower(1), 6400);
        assertEq(game.nonDemoCount(1), 64);
    }

    function testMixedControllerBatchRollsBackEarlierQueuedChange() public {
        enlist(1, 0);
        enlist(2, 0);
        idle(6);
        nft.mint(2, bob);
        uint256[] memory batch = new uint256[](2);
        batch[0] = 1;
        batch[1] = 2;
        bytes32 beforeState = keccak256(abi.encode(raider(1)));
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.NotController.selector);
        game.setStance(batch, 3);
        assertEq(keccak256(abi.encode(raider(1))), beforeState);
        idle(8);
        assertEq(game.alivePower(0), 200);
        assertEq(game.alivePower(3), 0);
    }

    function testDuplicateStanceReplacementHasNoPhantomDelta() public {
        enlist(1, 0);
        idle(6);
        uint256[] memory batch = new uint256[](2);
        batch[0] = 1;
        batch[1] = 1;
        vm.prank(alice);
        game.setStance(batch, 2);
        idle(8);
        assertEq(game.alivePower(0), 0);
        assertEq(game.alivePower(2), 100);
        assertEq(game.aliveCount(2), 1);
        assertEq(game.nonDemoCount(2), 1);
    }

    function testRestBatchFailureRollsBackPreviouslyEligibleRaider() public {
        enlist(1, 0);
        vm.prank(bob);
        uint256 guard = game.enlistDemo(1);
        wheel(2, 1, hashFor(0, 1));
        idle(20);
        wheel(21, 1, bytes32(0));
        idle(27);
        uint256[] memory batch = new uint256[](2);
        batch[0] = 1;
        batch[1] = guard;
        vm.expectRevert(SqueekRaider.NotKnockedOut.selector);
        game.rest(batch);
        assertEq(raider(1).data.pending.round, 0);
        batch[1] = 1;
        vm.expectRevert(SqueekRaider.PendingExists.selector);
        game.rest(batch);
        assertEq(raider(1).data.pending.round, 0);
        game.rest(ids(1));
        idle(29);
        assertFalse(raider(1).ko);
        assertEq(game.alivePower(0), 100);
    }

    function testUnauthorizedActionsCannotSpendOrReplacePendingUpgrade() public {
        enlist(1, 1);
        for (uint64 r = 2; r <= 11; ++r) {
            wheel(r, 1, bytes32(0));
        }
        bytes32 beforeState = keccak256(abi.encode(raider(1)));
        bytes[3] memory attempts = [
            abi.encodeCall(SqueekRaider.setStance, (ids(1), 0)),
            abi.encodeCall(SqueekRaider.upgrade, (1)),
            abi.encodeCall(SqueekRaider.revive, (1))
        ];
        for (uint256 i; i < attempts.length; ++i) {
            vm.prank(bob);
            (bool ok, bytes memory reason) = address(game).call(attempts[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(SqueekRaider.NotController.selector));
            assertEq(keccak256(abi.encode(raider(1))), beforeState);
        }
        vm.prank(alice);
        game.upgrade(1);
        nft.mint(1, bob);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.NotController.selector);
        game.setStance(ids(1), 0);
        idle(13);
        assertEq(raider(1).data.level, 1);
        assertEq(game.controllerOf(1), bob);
        assertEq(raider(1).data.scrap, 0);
    }

    function testStakedTokenWithNoDepositorHasNoController() public {
        nft.mint(1, address(staking));
        assertEq(game.controllerOf(1), address(0));
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.NotController.selector);
        game.enlist(ids(1), 0);
        staking.setDepositor(address(nft), 1, alice);
        enlist(1, 0);
        staking.setDepositor(address(nft), 1, bob);
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.NotController.selector);
        game.setStance(ids(1), 1);
        vm.prank(bob);
        game.setStance(ids(1), 1);
        idle(2);
        assertEq(game.alivePower(0), 0);
        assertEq(game.alivePower(1), 100);
    }

    function testMalformedOwnershipAndDepositorResponsesFailClosed() public {
        BadCore rawNFT = new BadCore();
        BadCore rawStaking = new BadCore();
        SqueekRaider target = new SqueekRaider(address(core), address(rawNFT), address(rawStaking));
        bytes[5] memory bad =
            [bytes(""), hex"00", new bytes(31), new bytes(33), abi.encode(uint256(1) << 160)];
        for (uint256 i; i < bad.length; ++i) {
            rawNFT.configure(bad[i], false);
            assertEq(target.controllerOf(1), address(0));
            vm.prank(alice);
            vm.expectRevert(SqueekRaider.NotController.selector);
            target.enlist(ids(1), 0);
        }
        rawNFT.configure(abi.encode(address(rawStaking)), false);
        for (uint256 i; i < bad.length; ++i) {
            rawStaking.configure(bad[i], false);
            assertEq(target.controllerOf(1), address(0));
        }
        rawStaking.configure(abi.encode(alice), true);
        assertEq(target.controllerOf(1), address(0));
        rawStaking.configure(abi.encode(alice), false);
        assertEq(target.controllerOf(1), alice);
        vm.prank(alice);
        target.enlist(ids(1), 0);
    }

    function testFuzzHighestRealIdsAndDemoNamespace(uint256 lowBits, address wallet) public {
        // The entire lower half is valid NFT namespace, including 0 and 2^255-1.
        uint256 id = lowBits & ((uint256(1) << 255) - 1);
        nft.mint(id, alice);
        vm.prank(alice);
        game.enlist(ids(id), 1);
        assertFalse(raider(id).data.isDemo);
        uint256 demo = game.demoId(wallet);
        assertEq(game.controllerOf(demo), wallet);
        assertEq(game.controllerOf(demo | (uint256(1) << 200)), address(0));
        vm.prank(alice);
        vm.expectRevert(SqueekRaider.InvalidId.selector);
        game.enlist(ids(demo), 1);
    }

    function testZeroAndMaximumRealIdAreUsable() public {
        nft.mint(0, alice);
        nft.mint((uint256(1) << 255) - 1, alice);
        enlist(0, 1);
        enlist((uint256(1) << 255) - 1, 1);
        wheel(2, 1, bytes32(0));
        assertEq(game.alivePower(1), 200);
        assertEq(raider(0).data.scrap, 1);
        assertEq(raider((uint256(1) << 255) - 1).data.scrap, 1);
    }

    function testNoActionOrFallbackAcceptsETH() public {
        bytes[] memory actions = _actions(1);
        vm.deal(alice, actions.length + 1);
        for (uint256 i; i < actions.length; ++i) {
            vm.prank(alice);
            (bool ok,) = address(game).call{value: 1}(actions[i]);
            assertFalse(ok, "nonpayable action accepted ETH");
        }
        vm.prank(alice);
        (bool accepted,) = address(game).call{value: 1}("");
        assertFalse(accepted);
        assertEq(address(game).balance, 0);
        assertEq(alice.balance, actions.length + 1);
    }

    function _actions(uint256 id) internal pure returns (bytes[] memory actions) {
        actions = new bytes[](8);
        actions[0] = abi.encodeCall(SqueekRaider.enlist, (ids(id), 0));
        actions[1] = abi.encodeCall(SqueekRaider.enlistDemo, (0));
        actions[2] = abi.encodeCall(SqueekRaider.setStance, (ids(id), 0));
        actions[3] = abi.encodeCall(SqueekRaider.upgrade, (id));
        actions[4] = abi.encodeCall(SqueekRaider.revive, (id));
        actions[5] = abi.encodeCall(SqueekRaider.rest, (ids(id)));
        actions[6] = abi.encodeCall(SqueekRaider.bury, (id));
        actions[7] = abi.encodeCall(SqueekRaider.poke, (ids(id)));
    }
}
