// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISqueekCore} from "../../src/interfaces/ISqueekchain.sol";

contract MockCore is ISqueekCore {
    uint64 public settled;
    uint64 public work;
    Round[] private _rounds;
    bool public failState;
    bool public failPage;
    uint64 public certificationLimit = type(uint64).max;

    function setFailure(bool state_, bool page_) external {
        failState = state_;
        failPage = page_;
    }

    function setCertificationLimit(uint64 limit) external {
        certificationLimit = limit;
    }

    function settle(uint64 through) external {
        require(through >= settled);
        settled = through;
    }

    function wheel(uint64 round, uint64 amount, bytes32 hash) external {
        require(round > settled, "round order");
        work += amount;
        _rounds.push(Round(round, work, 0, 0, hash));
        settled = round;
    }

    function state() external view returns (uint64, uint64, uint96, uint64, uint96, uint32, uint256, bool) {
        require(!failState, "state unavailable");
        return (settled, work, 0, 0, 0, 0, 0, false);
    }

    function roundPage(uint64 afterRound, uint64 throughRound, uint256 maximum)
        external
        view
        returns (RoundPage memory result)
    {
        uint64 certified;
        WorkState memory start;
        WorkState memory end;
        Round[] memory rounds;
        require(!failPage, "page unavailable");
        require(
            throughRound <= settled && throughRound >= afterRound && maximum > 0 && maximum <= 16, "range"
        );
        uint256 lo;
        uint256 hi = _rounds.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_rounds[mid].roundId <= afterRound) lo = mid + 1;
            else hi = mid;
        }
        uint256 offset = lo;
        if (offset != 0) start.cumulativeWork = _rounds[offset - 1].cumulativeWork;
        certified = throughRound < certificationLimit ? throughRound : certificationLimit;
        uint256 count;
        while (
            offset + count < _rounds.length && _rounds[offset + count].roundId <= certified && count < maximum
        ) ++count;
        if (
            count == maximum && offset + count < _rounds.length
                && _rounds[offset + count].roundId <= certified
        ) {
            certified = _rounds[offset + count - 1].roundId;
        }
        rounds = new Round[](count);
        end = WorkState(start.cumulativeWork, 0, 0);
        for (uint256 i; i < count; ++i) {
            rounds[i] = _rounds[offset + i];
            end.cumulativeWork = rounds[i].cumulativeWork;
        }
        result = RoundPage(certified, start, end, rounds);
    }
}

contract MockNFT {
    mapping(uint256 => address) public holders;

    function mint(uint256 id, address holder) external {
        holders[id] = holder;
    }

    function burn(uint256 id) external {
        delete holders[id];
    }

    function ownerOf(uint256 id) external view returns (address) {
        require(holders[id] != address(0), "nonexistent");
        return holders[id];
    }
}

contract MockStaking {
    mapping(address => mapping(uint256 => address)) public depositor;

    function setDepositor(address collection, uint256 id, address who) external {
        depositor[collection][id] = who;
    }
}

contract BadCore {
    bytes public response;
    bool public fails;

    function configure(bytes calldata data, bool fail) external {
        response = data;
        fails = fail;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        require(!fails);
        return response;
    }
}
