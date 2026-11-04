// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RaiderFixture} from "./SqueekRaider.t.sol";
import {SqueekRaider} from "../src/SqueekRaider.sol";

contract CallbackCore {
    address private _target;
    bytes private _attack;

    function configure(address target, bytes calldata attack) external {
        _target = target;
        _attack = attack;
    }

    function state() external view returns (uint64, uint64, uint96, uint64, uint96, uint32, uint256, bool) {
        (bool success, bytes memory result) = _target.staticcall(_attack);
        require(
            !success && result.length == 4 && bytes4(result) == SqueekRaider.Reentrant.selector,
            "unguarded write"
        );
        return (0, 0, 0, 0, 0, 0, 0, false);
    }
}

contract ReentrancyTest is RaiderFixture {
    function testEveryWriteRejectsReentrantEntry() public {
        bytes[8] memory attempts = [
            abi.encodeCall(SqueekRaider.advance, (1)),
            abi.encodeCall(SqueekRaider.enlist, (ids(1), 0)),
            abi.encodeCall(SqueekRaider.enlistDemo, (0)),
            abi.encodeCall(SqueekRaider.setStance, (ids(1), 0)),
            abi.encodeCall(SqueekRaider.upgrade, (1)),
            abi.encodeCall(SqueekRaider.revive, (1)),
            abi.encodeCall(SqueekRaider.rest, (ids(1))),
            abi.encodeCall(SqueekRaider.bury, (1))
        ];
        for (uint256 i; i <= attempts.length; ++i) {
            CallbackCore callback = new CallbackCore();
            SqueekRaider target = new SqueekRaider(address(callback), address(nft), address(staking));
            callback.configure(
                address(target),
                i == attempts.length ? abi.encodeCall(SqueekRaider.poke, (ids(1))) : attempts[i]
            );
            target.advance(0);
            // Anchoring succeeds only if state() verified the exact reentrancy error.
            assertTrue(target.anchored());
        }
    }
}
