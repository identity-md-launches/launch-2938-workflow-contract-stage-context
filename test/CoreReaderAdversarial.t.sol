// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CoreReader} from "src/CoreReader.sol";
import {ISqueekCore} from "src/interfaces/ISqueekchain.sol";
import {BadCore} from "./mocks/SqueekchainMocks.sol";

contract ReaderProbe {
    function state(address source) external view returns (bool, uint64, uint64) {
        return CoreReader.readState(source);
    }

    function page(address source, uint64 afterRound, uint64 throughRound, uint64 work)
        external
        view
        returns (bool, CoreReader.Page memory)
    {
        return CoreReader.page(source, afterRound, throughRound, work);
    }

    function read(address source, uint256 cap) external view returns (bool, bytes memory) {
        return CoreReader.read(source, hex"12345678", cap);
    }
}

contract ReaderReturnBomb {
    fallback() external {
        assembly ("memory-safe") { return(0, 65536) }
    }
}

contract ReaderGasBomb {
    fallback() external {
        assembly ("memory-safe") { for {} 1 {} {} }
    }
}

/// forge-config: default.fuzz.runs = 512
contract CoreReaderAdversarialTest is Test {
    ReaderProbe internal probe;
    BadCore internal raw;

    function setUp() public {
        probe = new ReaderProbe();
        raw = new BadCore();
    }

    function testFuzzValidPagesDecodeBothEnvelopes(uint256 countSeed, uint64 start, bool wrapped) public {
        uint256 count = bound(countSeed, 0, 16);
        start = uint64(bound(start, 0, type(uint64).max - 16));
        ISqueekCore.RoundPage memory p = _page(count, start);
        raw.configure(_encode(p, wrapped), false);
        (bool ok, CoreReader.Page memory decoded) = probe.page(address(raw), 0, 100, start);
        assertTrue(ok, "canonical page was rejected");
        assertEq(decoded.through, 100);
        assertEq(keccak256(abi.encode(decoded.rounds)), keccak256(abi.encode(p.rounds)));
    }

    function testFuzzMalformedWordsAreRejected(uint256 fieldSeed, uint256 noise, bool wrapped) public {
        ISqueekCore.RoundPage memory p = _page(1, 0);
        bytes memory encoded = _encode(p, wrapped);
        uint256 base = wrapped ? 32 : 0;
        uint256 field = fieldSeed % 10;
        uint256 offset;
        uint256 value;
        if (field == 0) {
            offset = 0; // Certification cannot stagnate.
            value = 0;
        }
        if (field == 1) {
            offset = 0; // Or exceed requested settlement.
            value = 101;
        }
        if (field == 2) {
            offset = 32; // Wrong starting work.
            value = noise | 1;
        }
        if (field == 3) {
            offset = 128; // End work != final record.
            value = 2;
        }
        if (field == 4) {
            offset = 224; // Wrong array offset.
            value = noise == 256 ? 0 : noise;
        }
        if (field == 5) {
            offset = 256;
            value = bound(noise, 17, type(uint256).max);
        }
        if (field == 6) {
            offset = 288;
            value = noise | (uint256(1) << 64);
        }
        if (field == 7) {
            offset = 320;
            value = noise | (uint256(1) << 64);
        }
        if (field == 8) {
            offset = 352;
            value = noise | (uint256(1) << 96);
        }
        if (field == 9) {
            offset = 384;
            value = noise | (uint256(1) << 32);
        }
        _write(encoded, base + offset, value);
        raw.configure(encoded, false);
        (bool ok,) = probe.page(address(raw), 0, 100, 0);
        assertFalse(ok, "invalid record or ABI word accepted");
    }

    function testStructOuterOffsetAndUnexpectedTrailingDataAreRejected() public {
        bytes memory encoded = abi.encode(_page(1, 0));
        _write(encoded, 0, 64);
        raw.configure(encoded, false);
        (bool ok,) = probe.page(address(raw), 0, 100, 0);
        assertFalse(ok);
        encoded = bytes.concat(abi.encode(_page(1, 0)), hex"00");
        raw.configure(encoded, false);
        (ok,) = probe.page(address(raw), 0, 100, 0);
        assertFalse(ok);
    }

    function testFuzzTruncatedPageNeverThrows(bytes memory arbitrary, uint256 lengthSeed) public {
        // Generate a short response directly, rather than rejecting fuzz cases with assume().
        uint256 size = bound(lengthSeed, 0, 287);
        bytes memory truncated = new bytes(size);
        for (uint256 i; i < size && i < arbitrary.length; ++i) {
            truncated[i] = arbitrary[i];
        }
        raw.configure(truncated, false);
        (bool ok,) = probe.page(address(raw), 0, 100, 0);
        assertFalse(ok);
    }

    function testFuzzStateRejectsTruncationAndNonCanonicalIntegers(uint256 noise, uint256 fieldSeed) public {
        bytes memory encoded =
            abi.encode(uint64(10), uint64(20), uint96(0), uint64(0), uint96(0), uint32(0), uint256(0), false);
        _write(encoded, (fieldSeed % 2) * 32, noise | (uint256(1) << 64));
        raw.configure(encoded, false);
        (bool ok, uint64 through, uint64 work) = probe.state(address(raw));
        assertFalse(ok);
        assertEq(through, 0);
        assertEq(work, 0);
        raw.configure(new bytes(bound(fieldSeed, 0, 255)), false);
        (ok,,) = probe.state(address(raw));
        assertFalse(ok);
    }

    function testStateAcceptsUint64MaximumAndSourcePauseFlag() public {
        // Paused is source metadata; already settled records remain readable.
        raw.configure(
            abi.encode(
                type(uint64).max,
                type(uint64).max,
                uint96(0),
                uint64(0),
                uint96(0),
                uint32(0),
                uint256(0),
                true
            ),
            false
        );
        (bool ok, uint64 through, uint64 work) = probe.state(address(raw));
        assertTrue(ok);
        assertEq(through, type(uint64).max);
        assertEq(work, type(uint64).max);
    }

    function testExactReadCapAndFailuresAreBounded() public {
        raw.configure(new bytes(32), false);
        (bool ok, bytes memory data) = probe.read(address(raw), 32);
        assertTrue(ok);
        assertEq(data.length, 32);
        (ok, data) = probe.read(address(raw), 31);
        assertFalse(ok);
        assertEq(data.length, 0);
        raw.configure(hex"aabbccdd", true);
        (ok,) = probe.read(address(raw), 32);
        assertFalse(ok);
        ReaderReturnBomb returnBomb = new ReaderReturnBomb();
        (ok, data) = probe.read(address(returnBomb), 2880);
        assertFalse(ok);
        assertEq(data.length, 0, "oversized response was copied");
        ReaderGasBomb gasBomb = new ReaderGasBomb();
        uint256 beforeGas = gasleft();
        (ok,) = probe.read(address(gasBomb), 2880);
        assertLt(beforeGas - gasleft(), 550_000, "dependency consumed unbounded gas");
        assertFalse(ok);
        raw.configure(hex"12", false);
        (ok, data) = probe.read(address(raw), 32);
        assertTrue(ok, "a failed dependency read poisoned subsequent reads");
        assertEq(data, hex"12");
    }

    function _page(uint256 count, uint64 start) internal pure returns (ISqueekCore.RoundPage memory p) {
        p.certifiedThroughRound = 100;
        p.start.cumulativeWork = start;
        p.end.cumulativeWork = start + uint64(count);
        p.rounds = new ISqueekCore.Round[](count);
        for (uint256 i; i < count; ++i) {
            p.rounds[i] = ISqueekCore.Round(
                uint64(i + 1), start + uint64(i + 1), type(uint96).max, type(uint32).max, bytes32(i)
            );
        }
    }

    function _encode(ISqueekCore.RoundPage memory p, bool wrapped) internal pure returns (bytes memory) {
        return wrapped ? abi.encode(p) : abi.encode(p.certifiedThroughRound, p.start, p.end, p.rounds);
    }

    function _write(bytes memory data, uint256 offset, uint256 value) internal pure {
        require(offset + 32 <= data.length, "test offset");
        assembly ("memory-safe") { mstore(add(add(data, 32), offset), value) }
    }
}
