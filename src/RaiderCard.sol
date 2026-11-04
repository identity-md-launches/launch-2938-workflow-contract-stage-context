// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Text} from "./Text.sol";

/// @notice Stateless artwork and metadata. No collection, ownership or minting functionality.
contract RaiderCard {
    using Text for uint256;

    struct Card {
        uint256 id;
        uint8 stance;
        uint8 level;
        bool ko;
        bool enlisted;
        bool burrow;
        bool isDemo;
        uint256 trophies;
        uint256 scrap;
        uint256 dreams;
        uint256 score;
    }

    function cardURI(Card memory c) external pure returns (string memory) {
        string memory json = string.concat(
            '{"name":"Squeek Raider #',
            c.id.decimal(),
            '","description":"Unofficial community game, Sepolia TEST NETWORK, not the Squeek mint",',
            '"image":"data:image/svg+xml;base64,',
            Text.base64(bytes(cardSVG(c))),
            '","attributes":[',
            '{"trait_type":"Stance","value":"',
            stanceName(c.stance),
            '"},',
            '{"trait_type":"Level","value":',
            uint256(c.level).decimal(),
            "},",
            '{"trait_type":"KO","value":',
            c.ko ? "true" : "false",
            "},",
            '{"trait_type":"Demo","value":',
            c.isDemo ? "true" : "false",
            "},",
            '{"trait_type":"Enlisted","value":',
            c.enlisted ? "true" : "false",
            "},",
            '{"trait_type":"Trophies","value":',
            c.trophies.decimal(),
            "},",
            '{"trait_type":"Scrap","value":',
            c.scrap.decimal(),
            "},",
            '{"trait_type":"Dreams","value":',
            c.dreams.decimal(),
            "},",
            '{"trait_type":"Score","value":',
            c.score.decimal(),
            "}]}"
        );
        return string.concat("data:application/json;base64,", Text.base64(bytes(json)));
    }

    function cardSVG(Card memory c) public pure returns (string memory) {
        string memory backdrop = c.burrow
            ? '<circle cx="25" cy="6" r="3" fill="#DDD6B8"/><circle cx="26" cy="5" r="3" fill="#191B31"/>'
            : '<g stroke="#444B68" fill="none"><circle cx="16" cy="15" r="11"/><path d="M5 15h22M16 4v22M8 7l16 16M8 23L24 7"/></g>';
        string memory pixels = _hamster(c.id, c.ko, c.enlisted);
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 42" shape-rendering="crispEdges">',
            '<rect width="32" height="42" rx="2" fill="#333B5C"/><rect x="1" y="1" width="30" height="40" fill="#10121E"/>',
            '<rect x="2" y="3" width="28" height="25" fill="#191B31"/>',
            backdrop,
            '<g transform="translate(8 9)">',
            pixels,
            "</g>",
            _item(c.stance, c.level, c.enlisted),
            '<g fill="#F3DDBB" font-family="monospace" font-size="2" text-anchor="middle">',
            '<text x="16" y="31">',
            c.isDemo ? "DEMO " : "SQUEEK ",
            stanceName(c.stance),
            "</text>",
            '<text x="16" y="34">LV ',
            uint256(c.level).decimal(),
            c.ko ? " | KO" : "",
            "</text>",
            '<text x="16" y="37">TROPHIES ',
            c.trophies.decimal(),
            "</text>",
            '<text x="16" y="40" fill="#E9928F">SEPOLIA TEST NETWORK</text></g></svg>'
        );
    }

    function _hamster(uint256 id, bool ko, bool enlisted) internal pure returns (string memory output) {
        bytes memory rows = bytes(
            string.concat(
                "...oo......oo...",
                "..opfo....ofpo..",
                "..offooooooffo..",
                ".offffffffffffo.",
                ".offeffffffeffo.",
                "offffffffffffffo",
                "offcfffppfffcffo",
                "offfffbbbbfffffo",
                "offffbbbbbbffffo",
                ".offfbbbbbbfffo.",
                ".offbbbbbbbbffo.",
                "..offbbbbbbffo..",
                "...oooooooooo...",
                "...pp......pp..."
            )
        );
        string[4] memory furs = [string("#C98A4B"), "#E8C08A", "#8A6448", "#D9D2C4"];
        string memory fur = furs[uint256(keccak256(abi.encode(id))) % 4];
        // The supplied rows are sixteen pixels wide. Draw runs, preserving every source pixel.
        for (uint256 y; y < 14; ++y) {
            for (uint256 x; x < 16;) {
                bytes1 pixel = rows[y * 16 + x];
                uint256 width = 1;
                while (x + width < 16 && rows[y * 16 + x + width] == pixel) ++width;
                if (pixel != ".") {
                    string memory color = pixel == "o"
                        ? "#2A1E14"
                        : pixel == "f" ? fur : pixel == "e" ? "#0E0E12" : pixel == "b" ? "#F3DDBB" : "#E9928F";
                    if (!enlisted) color = pixel == "o" || pixel == "e" ? "#393941" : "#777781";
                    output = string.concat(
                        output,
                        '<rect x="',
                        x.decimal(),
                        '" y="',
                        y.decimal(),
                        '" width="',
                        width.decimal(),
                        '" height="',
                        ko && pixel == "e" ? "0.35" : "1",
                        '" fill="',
                        color,
                        '"/>'
                    );
                }
                x += width;
            }
        }
    }

    function _item(uint8 stance, uint8 level, bool enlisted) internal pure returns (string memory) {
        if (!enlisted || stance > 3) return "";
        string[6] memory colors = [string("#A1A5B7"), "#79C796", "#71BCE0", "#AA8BE3", "#E8BD62", "#F08DB1"];
        string memory shape = stance == 0
            ? '<path d="M26 15h1v9h-1zM24 21h5v1h-5z"/>'
            : stance == 1
                ? '<path d="M24 16h5v6l-2.5 3-2.5-3z"/>'
                : stance == 2
                    ? '<path d="M24 19h5v6h-5zM25 17h3v2h-1v-1h-1v1h-1z"/>'
                    : '<path d="M26 15h1v3h3v1h-3v3h-1v-3h-3v-1h3zM25 23h3v1h-3z"/>';
        return string.concat('<g fill="', colors[level > 5 ? 5 : level], '">', shape, "</g>");
    }

    function stanceName(uint8 stance) public pure returns (string memory) {
        return stance == 0
            ? "STRIKER"
            : stance == 1 ? "GUARD" : stance == 2 ? "FORAGER" : stance == 3 ? "DREAMER" : "NONE";
    }

    function bossSVG(uint8 tier) external pure returns (string memory output) {
        require(tier <= 2, "tier");
        bytes memory rows = bytes(
            string.concat(
                "................",
                "..oo........oo..",
                "..offo....offo..",
                "..offfoooofffo..",
                ".offffffffffffo.",
                ".offbbffffbbffo.",
                "offbeebffbeebffo",
                "offbeebffbeebffo",
                "offbbboppobbbffo",
                "offfffoppofffffo",
                ".offfffppfffffo.",
                ".offfbffffbfffo.",
                "..offbffffbffo..",
                "...offfffffo....",
                "....ooooooo.....",
                "....pp...pp....."
            )
        );
        string[3] memory colors = [string("#8F7EA8"), "#B87957", "#C35377"];
        output = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">';
        for (uint256 y; y < 16; ++y) {
            for (uint256 x; x < 16; ++x) {
                bytes1 p = rows[y * 16 + x];
                if (p == ".") continue;
                string memory color = p == "o"
                    ? "#2A1E14"
                    : p == "f" ? colors[tier] : p == "e" ? "#0E0E12" : p == "b" ? "#F3DDBB" : "#E9928F";
                output = string.concat(
                    output,
                    '<rect x="',
                    x.decimal(),
                    '" y="',
                    y.decimal(),
                    '" width="1" height="1" fill="',
                    color,
                    '"/>'
                );
            }
        }
        return string.concat(output, "</svg>");
    }
}
