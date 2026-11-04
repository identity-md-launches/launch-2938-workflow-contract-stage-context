// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISqueekCore} from "./interfaces/ISqueekchain.sol";

/// @dev Bounded, non-throwing reads. Invalid / unavailable pages leave the cursor unchanged.
library CoreReader {
    uint256 internal constant READ_GAS = 500_000;

    struct Page {
        uint64 through;
        ISqueekCore.Round[] rounds;
    }

    function readState(address core) internal view returns (bool ok, uint64 through, uint64 work) {
        bytes memory data;
        (ok, data) = read(core, abi.encodeCall(ISqueekCore.state, ()), 256);
        if (
            !ok || data.length != 256 || word(data, 0) > type(uint64).max || word(data, 32) > type(uint64).max
        ) {
            return (false, 0, 0);
        }
        return (true, uint64(word(data, 0)), uint64(word(data, 32)));
    }

    function page(address core, uint64 afterRound, uint64 throughRound, uint64 expectedWork)
        internal
        view
        returns (bool ok, Page memory p)
    {
        bytes memory data;
        (ok, data) = read(core, abi.encodeCall(ISqueekCore.roundPage, (afterRound, throughRound, 16)), 2880);
        // Sepolia returns one dynamic Page struct (outer offset 32). Also accept the
        // equivalent flat tuple described by the interface brief; both have a fixed inner head.
        uint256 base = data.length % 160 == 0 ? 32 : 0;
        if (
            !ok || data.length < 288 + base || (base != 0 && word(data, 0) != 32)
                || word(data, base + 224) != 256
        ) return (false, p);
        uint256 count = word(data, base + 256);
        uint256 certified = word(data, base);
        if (
            count > 16 || data.length != 288 + base + count * 160 || certified <= afterRound
                || certified > throughRound || word(data, base + 32) != expectedWork
                || word(data, base + 128) > type(uint64).max
        ) return (false, p);
        p.through = uint64(certified);
        p.rounds = new ISqueekCore.Round[](count);
        uint64 previousRound = afterRound;
        uint64 previousWork = expectedWork;
        for (uint256 i; i < count; ++i) {
            uint256 offset = base + 288 + i * 160;
            uint256 r = word(data, offset);
            uint256 w = word(data, offset + 32);
            if (
                r <= previousRound || r > certified || w < previousWork || w > type(uint64).max
                    || word(data, offset + 64) > type(uint96).max
                    || word(data, offset + 96) > type(uint32).max
            ) return (false, p);
            p.rounds[i] = ISqueekCore.Round(
                uint64(r),
                uint64(w),
                uint96(word(data, offset + 64)),
                uint32(word(data, offset + 96)),
                bytes32(word(data, offset + 128))
            );
            previousRound = uint64(r);
            previousWork = uint64(w);
        }
        if (word(data, base + 128) != previousWork) return (false, p);
        return (true, p);
    }

    function read(address target, bytes memory input, uint256 cap)
        internal
        view
        returns (bool ok, bytes memory result)
    {
        uint256 gasLimit = READ_GAS;
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(input, 32), mload(input), 0, 0)
            let size := returndatasize()
            if gt(size, cap) {
                ok := 0
                size := 0
            }
            result := mload(0x40)
            mstore(result, size)
            returndatacopy(add(result, 32), 0, size)
            mstore(0x40, and(add(add(result, 63), size), not(31)))
        }
    }

    function word(bytes memory data, uint256 offset) internal pure returns (uint256 value) {
        assembly ("memory-safe") { value := mload(add(add(data, 32), offset)) }
    }
}
