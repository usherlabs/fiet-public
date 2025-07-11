// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";

abstract contract ScriptHelper is Script {
    string constant FILE_START = "script/deployments/";
    string constant FILE_END = "_deployments.json";

    string memory file = "";

    function _setFilename(string memory name) internal {
        file = string.concat(FILE_START, name, FILE_END);
    }

    function writeAddress(string memory name, address contractAddress) internal {
        string memory contents;
        try vm.readFile(file) returns (string memory data) {
            contents = data;
        } catch {
            contents = "{}";
        }

        string memory tempNS = "temp";
        string memory newData = vm.serializeAddress(tempNS, name, contractAddress);

        string memory merged = _mergeJson(contents, newData);
        vm.writeJson(merged, file);
    }

    function writeString(string memory name, string memory value) internal {
        string memory contents;
        try vm.readFile(file) returns (string memory data) {
            contents = data;
        } catch {
            contents = "{}";
        }

        string memory tempNS = "temp";
        string memory newData = vm.serializeString(tempNS, name, value);

        string memory merged = _mergeJson(contents, newData);
        vm.writeJson(merged, file);
    }

    function writeBytes(string memory name, bytes memory data) internal {
        string memory contents;
        try vm.readFile(file) returns (string memory fileData) {
            contents = fileData;
        } catch {
            contents = "{}";
        }

        string memory tempNS = "temp";
        string memory newData = vm.serializeBytes(tempNS, name, data);

        string memory merged = _mergeJson(contents, newData);
        vm.writeJson(merged, file);
    }

    function _mergeJson(string memory a, string memory b) private pure returns (string memory) {
        bytes memory ba = bytes(a);
        bytes memory bb = bytes(b);

        if (ba.length <= 2) return b;
        if (bb.length <= 2) return a;

        // Prepare output with room for: ba - '}', ',', bb - '{'
        bytes memory result = new bytes(ba.length + bb.length - 2 + 1);

        uint256 k = 0;

        // Copy all of `ba` except the last byte ('}')
        for (uint256 i = 0; i < ba.length - 1; i++) {
            result[k++] = ba[i];
        }

        // Insert comma
        result[k++] = bytes1(",");

        // Copy all of `bb` except the first byte ('{')
        for (uint256 i = 1; i < bb.length; i++) {
            result[k++] = bb[i];
        }

        return string(result);
    }

    function readAddress(string memory name) internal view returns (address) {
        string memory path = string.concat(".", name);
        string memory contents = vm.readFile(file);
        return vm.parseJsonAddress(contents, path);
    }

    function readBytes(string memory name) internal view returns (bytes memory) {
        string memory path = string.concat(".", name);
        string memory contents = vm.readFile(file);
        return vm.parseJsonBytes(contents, path);
    }

    function readString(string memory name) internal view returns (string memory) {
        string memory path = string.concat(".", name);
        string memory contents = vm.readFile(file);
        return vm.parseJsonString(contents, path);
    }
}
