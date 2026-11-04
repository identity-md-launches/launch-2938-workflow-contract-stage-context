// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqueekRaider} from "../src/SqueekRaider.sol";
import {ISqueekCore} from "../src/interfaces/ISqueekchain.sol";

contract RawCore {
    uint64 private _through;
    uint64 private _work;
    bytes private _page;

    function configure(uint64 through, uint64 work, bytes memory page) external {
        _through = through;
        _work = work;
        _page = page;
    }

    function state() external view returns (uint64, uint64, uint96, uint64, uint96, uint32, uint256, bool) {
        return (_through, _work, 0, 0, 0, 0, 0, false);
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return _page;
    }
}

contract CoreReaderTest is Test {
    RawCore internal core;
    SqueekRaider internal game;
    uint256 constant G = 1_793_022_600;

    function setUp() public {
        vm.warp(G);
        core = new RawCore();
        game = new SqueekRaider(address(core), address(0x123), address(0x456));
        game.advance(0);
        vm.warp(G + 100 * 600);
    }

    function page(uint64 certified, uint64 start, uint64 end, uint64 round, uint64 work)
        internal
        pure
        returns (ISqueekCore.RoundPage memory p)
    {
        ISqueekCore.Round[] memory rounds = new ISqueekCore.Round[](1);
        rounds[0] = ISqueekCore.Round(round, work, 0, 0, bytes32(uint256(1)));
        return ISqueekCore.RoundPage(
            certified, ISqueekCore.WorkState(start, 0, 0), ISqueekCore.WorkState(end, 0, 0), rounds
        );
    }

    function assertRejected(ISqueekCore.RoundPage memory p) internal {
        core.configure(100, 100, abi.encode(p));
        game.advance(type(uint256).max);
        assertEq(game.processedThrough(), 0);
    }

    function testMalformedPageBoundsAndNonMonotonicWorkAreNonThrowing() public {
        assertRejected(page(101, 0, 100, 100, 100));
        assertRejected(page(0, 0, 100, 100, 100));
        assertRejected(page(100, 1, 100, 100, 100));
        assertRejected(page(100, 0, 99, 100, 100));
        assertRejected(page(100, 0, 100, 101, 100));
        assertRejected(page(100, 0, 100, 0, 100));
        ISqueekCore.RoundPage memory p = page(100, 0, 100, 99, 100);
        p.rounds = new ISqueekCore.Round[](17);
        assertRejected(p);
        p.rounds = new ISqueekCore.Round[](2);
        p.rounds[0] = ISqueekCore.Round(99, 100, 0, 0, bytes32(0));
        p.rounds[1] = ISqueekCore.Round(98, 100, 0, 0, bytes32(0));
        assertRejected(p);
        p.rounds[1] = ISqueekCore.Round(100, 99, 0, 0, bytes32(0));
        assertRejected(p);
        core.configure(100, 100, hex"1234");
        game.advance(128);
        assertEq(game.processedThrough(), 0);
        core.configure(100, 100, new bytes(4000));
        game.advance(128);
        assertEq(game.processedThrough(), 0);
    }

    function testFlatTupleAndActualStructEnvelopeBothAccepted() public {
        ISqueekCore.RoundPage memory p = page(50, 0, 10, 50, 10);
        core.configure(100, 100, abi.encode(p.certifiedThroughRound, p.start, p.end, p.rounds));
        game.advance(128);
        assertEq(game.processedThrough(), 50);
        assertEq(game.processedWork(), 10);
        p = page(100, 10, 100, 100, 100);
        core.configure(100, 100, abi.encode(p));
        game.advance(128);
        assertEq(game.processedThrough(), 100);
        assertEq(game.processedWork(), 100);
    }

    function testFutureSettlementsRejectedWithoutLosingCursor() public {
        core.configure(101, 100, abi.encode(page(101, 0, 100, 100, 100)));
        game.advance(128);
        assertEq(game.processedThrough(), 0);
    }

    function testFuzzMalformedBytesNeverAdvanceOrRevert(bytes memory malformed) public {
        vm.assume(malformed.length < 288);
        core.configure(100, 100, malformed);
        game.advance(type(uint256).max);
        assertEq(game.processedThrough(), 0);
    }
}
