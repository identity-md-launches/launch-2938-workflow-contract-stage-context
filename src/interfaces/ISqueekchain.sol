// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ISqueekCore {
    struct WorkState {
        uint64 cumulativeWork;
        uint96 accumulated;
        uint32 count;
    }

    struct Round {
        uint64 roundId;
        uint64 cumulativeWork;
        uint96 accumulated;
        uint32 count;
        bytes32 dataHash;
    }

    struct RoundPage {
        uint64 certifiedThroughRound;
        WorkState start;
        WorkState end;
        Round[] rounds;
    }

    function state() external view returns (uint64, uint64, uint96, uint64, uint96, uint32, uint256, bool);
    function roundPage(uint64 afterRound, uint64 throughRound, uint256 maxRecords)
        external
        view
        returns (RoundPage memory);
}

interface ISqueekNFT {
    function ownerOf(uint256 id) external view returns (address);
}

interface ISqueekStaking {
    function depositor(address collection, uint256 id) external view returns (address);
}
