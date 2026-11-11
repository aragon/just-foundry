// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {Thing, Other, Parent} from "../src/Thing.sol";

contract DeployScript is Script {
    function run() external {
        vm.startBroadcast();
        new Thing(1);
        new Other();
        new Thing(2);
        new Thing{salt: bytes32(uint256(3))}(3);
        new Parent(7);
        new Parent{salt: bytes32(uint256(8))}(8);
        vm.stopBroadcast();
    }
}
