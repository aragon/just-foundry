// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract Thing {
    uint256 public immutable id;

    constructor(uint256 _id) {
        id = _id;
    }
}

contract Other {
    function hello() external pure returns (uint256) {
        return 1;
    }
}

contract Parent {
    Other public child;

    constructor(uint256 _unused) {
        child = new Other();
        _unused;
    }
}
