// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqueekRaider} from "../src/SqueekRaider.sol";

contract DeploymentProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
        require(deployed != address(0), "deployment failed");
    }
}

contract DeploymentTest is Test {
    function testFactoryDeploymentWithCanonicalArgumentsAndNoPrivilegedFactory() public {
        DeploymentProbe factory = new DeploymentProbe();
        bytes memory code = bytes.concat(
            type(SqueekRaider).creationCode,
            abi.encode(
                0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44,
                0xCB98349c134aB983dA5BfD80527dfe2552bDB70F,
                0x4b67b739dFd832f4EAC67a7Aa3bc244fB74cea4F
            )
        );
        SqueekRaider game =
            SqueekRaider(factory.deploy(code, keccak256("SqueekRaider constructor rehearsal")));
        assertEq(game.core(), 0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44);
        assertGt(address(game.renderer()).code.length, 0);
        (bool ownerExists,) = address(game).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ownerExists);
        _checkRuntime(address(game).code);
        _checkRuntime(address(game.renderer()).code);
        assertLe(type(SqueekRaider).creationCode.length + 96, 49_152);
    }

    function _checkRuntime(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }
}
