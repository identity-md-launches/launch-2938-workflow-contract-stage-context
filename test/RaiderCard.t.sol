// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RaiderCard} from "../src/RaiderCard.sol";
import {Text} from "../src/Text.sol";

contract RaiderCardTest is Test {
    RaiderCard internal card;

    function setUp() public {
        card = new RaiderCard();
    }

    function testRFC4648Base64Vectors() public pure {
        assertEq(Text.base64(bytes("")), "");
        assertEq(Text.base64(bytes("f")), "Zg==");
        assertEq(Text.base64(bytes("fo")), "Zm8=");
        assertEq(Text.base64(bytes("foo")), "Zm9v");
        assertEq(Text.base64(bytes("foob")), "Zm9vYg==");
        assertEq(Text.base64(bytes("fooba")), "Zm9vYmE=");
        assertEq(Text.base64(bytes("foobar")), "Zm9vYmFy");
    }

    function testCardURIStrictJSONAndNestedSVG() public view {
        RaiderCard.Card memory c = RaiderCard.Card(123, 2, 5, false, true, true, false, 12, 34, 56, 789);
        string memory uri = card.cardURI(c);
        bytes memory raw = _strip(uri, "data:application/json;base64,");
        string memory json = string(_decode(raw));
        assertEq(vm.parseJsonString(json, ".name"), "Squeek Raider #123");
        assertEq(
            vm.parseJsonString(json, ".description"),
            "Unofficial community game, Sepolia TEST NETWORK, not the Squeek mint"
        );
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "FORAGER");
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), 5);
        assertFalse(vm.parseJsonBool(json, ".attributes[2].value"));
        assertFalse(vm.parseJsonBool(json, ".attributes[3].value"));
        assertEq(vm.parseJsonUint(json, ".attributes[8].value"), 789);
        string memory svg =
            string(_decode(_strip(vm.parseJsonString(json, ".image"), "data:image/svg+xml;base64,")));
        assertEq(svg, card.cardSVG(c));
        assertTrue(_contains(svg, 'shape-rendering="crispEdges"'));
        assertTrue(_contains(svg, "#F08DB1"));
        assertTrue(_contains(svg, "TROPHIES 12"));
        assertTrue(_contains(svg, 'cx="25" cy="6"'));
    }

    function testKOClosedEyesGreyUnenlistedAndWheelBackdrop() public view {
        RaiderCard.Card memory c;
        c.ko = true;
        c.stance = 4;
        string memory svg = card.cardSVG(c);
        assertTrue(_contains(svg, 'height="0.35"'));
        assertTrue(_contains(svg, "#777781"));
        assertTrue(_contains(svg, "M5 15h22"));
        assertTrue(_contains(svg, " | KO"));
        c.enlisted = true;
        c.stance = 0;
        c.isDemo = true;
        string memory json = string(_decode(_strip(card.cardURI(c), "data:application/json;base64,")));
        assertTrue(vm.parseJsonBool(json, ".attributes[2].value"));
        assertTrue(vm.parseJsonBool(json, ".attributes[3].value"));
    }

    function testPendingRaiderWithNoStanceDrawsNoItem() public view {
        string memory dreamer = "M26 15h1v3h3v1h-3v3h-1v-3h-3v-1h3zM25 23h3v1h-3z";
        RaiderCard.Card memory c;
        c.id = 1;
        c.enlisted = true;
        c.stance = 4;
        string memory pending = card.cardSVG(c);
        assertFalse(_contains(pending, dreamer));
        assertFalse(_contains(pending, '<g fill="#A1A5B7">'));
        assertTrue(_contains(pending, "NONE"));
        c.stance = 3;
        assertTrue(_contains(card.cardSVG(c), dreamer));
    }

    function testOwlTintsAndInvalidTier() public {
        string memory a = card.bossSVG(0);
        string memory b = card.bossSVG(1);
        string memory c = card.bossSVG(2);
        assertTrue(_contains(a, "#8F7EA8"));
        assertTrue(_contains(b, "#B87957"));
        assertTrue(_contains(c, "#C35377"));
        assertTrue(_contains(a, 'viewBox="0 0 16 16"'));
        assertTrue(_contains(a, "</svg>"));
        vm.expectRevert(bytes("tier"));
        card.bossSVG(3);
    }

    function testFuzzBase64RoundTrip(bytes memory raw) public pure {
        vm.assume(raw.length <= 1024);
        assertEq(_decode(bytes(Text.base64(raw))), raw);
    }

    function _strip(string memory input, string memory prefix) internal pure returns (bytes memory out) {
        bytes memory a = bytes(input);
        bytes memory p = bytes(prefix);
        assertGe(a.length, p.length);
        out = new bytes(a.length - p.length);
        for (uint256 i; i < p.length; ++i) {
            assertEq(bytes1(a[i]), bytes1(p[i]));
        }
        for (uint256 i; i < out.length; ++i) {
            out[i] = a[p.length + i];
        }
    }

    function _decode(bytes memory input) internal pure returns (bytes memory out) {
        if (input.length == 0) return new bytes(0);
        assertEq(input.length % 4, 0);
        uint256 padding = input[input.length - 1] == "=" ? 1 : 0;
        if (input[input.length - 2] == "=") ++padding;
        out = new bytes(input.length / 4 * 3 - padding);
        uint256 at;
        for (uint256 i; i < input.length; i += 4) {
            uint256 v = (_six(input[i]) << 18) | (_six(input[i + 1]) << 12) | (_six(input[i + 2]) << 6)
                | _six(input[i + 3]);
            if (at < out.length) out[at++] = bytes1(uint8(v >> 16));
            if (at < out.length) out[at++] = bytes1(uint8(v >> 8));
            if (at < out.length) out[at++] = bytes1(uint8(v));
        }
    }

    function _six(bytes1 c) internal pure returns (uint256) {
        uint8 n = uint8(c);
        if (n >= 65 && n <= 90) return n - 65;
        if (n >= 97 && n <= 122) return n - 71;
        if (n >= 48 && n <= 57) return n + 4;
        if (c == "+") return 62;
        if (c == "/") return 63;
        assertEq(c, bytes1("="));
        return 0;
    }

    function _contains(string memory input, string memory needle) internal pure returns (bool) {
        bytes memory a = bytes(input);
        bytes memory b = bytes(needle);
        for (uint256 i; i + b.length <= a.length; ++i) {
            bool same = true;
            for (uint256 j; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        return false;
    }
}
