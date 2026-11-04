// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqueekRaider} from "../src/SqueekRaider.sol";
import {CoreReader} from "../src/CoreReader.sol";
import {ISqueekCore, ISqueekNFT, ISqueekStaking} from "../src/interfaces/ISqueekchain.sol";

/// @dev Opt-in via forge test --fork-url ... --fork-block-number 12059021 --match-contract SepoliaIntegrationTest.
///      The ordinary offline suite explicitly skips these network tests; it never creates a fork or reads env.
contract SepoliaIntegrationTest is Test {
    address constant CORE = 0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44;
    address constant NFT = 0xCB98349c134aB983dA5BfD80527dfe2552bDB70F;
    address constant STAKING = 0x4b67b739dFd832f4EAC67a7Aa3bc244fB74cea4F;

    function setUp() public {
        vm.skip(block.chainid != 11155111 || CORE.code.length == 0);
    }

    function testForkRealInterfacesAndConstructor() public {
        assertGt(NFT.code.length, 0);
        assertGt(STAKING.code.length, 0);
        SqueekRaider game = new SqueekRaider(CORE, NFT, STAKING);
        (uint64 settled, uint64 cumulative,,,,,,) = ISqueekCore(CORE).state();
        game.advance(128);
        assertTrue(game.anchored());
        assertEq(game.processedThrough(), settled);
        assertEq(game.processedWork(), cumulative);
        address holder = ISqueekNFT(NFT).ownerOf(1);
        address controller = holder == STAKING ? ISqueekStaking(STAKING).depositor(NFT, 1) : holder;
        assertEq(game.controllerOf(1), controller);
        vm.prank(controller);
        game.enlist(_ids(1), 1);
        assertTrue(game.raider(1).data.enlisted);
    }

    function testForkReplayRealHistoricalActiveAndIdleRounds() public {
        (uint64 settled, uint64 cumulative,,,,,,) = ISqueekCore(CORE).state();
        assertGt(settled, 48);
        uint64 anchor = settled - 48;
        ISqueekCore.RoundPage memory initial = ISqueekCore(CORE).roundPage(anchor, anchor, 1);
        (bool ok, CoreReader.Page memory first) =
            CoreReader.page(CORE, anchor, settled, initial.end.cumulativeWork);
        assertTrue(ok);
        assertGt(first.through, anchor);
        assertLe(first.rounds.length, 16);
        SqueekRaider game = new SqueekRaider(CORE, NFT, STAKING);
        vm.mockCall(
            CORE,
            abi.encodeCall(ISqueekCore.state, ()),
            abi.encode(
                anchor,
                initial.end.cumulativeWork,
                uint96(0),
                uint64(0),
                uint96(0),
                uint32(0),
                uint256(0),
                false
            )
        );
        game.advance(128);
        vm.clearMockedCalls();
        game.advance(128);
        assertEq(game.processedThrough(), settled);
        assertEq(game.processedWork(), cumulative);
        assertEq(game.totalDamageUnits(), 0);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = id;
    }
}
