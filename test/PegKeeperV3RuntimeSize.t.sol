// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {
    LpYieldAmm,
    LpYieldControllerAndPolicy,
    LpYieldOracle,
    LpYieldToken
} from "./PegKeeperV3LpYield.t.sol";

contract PegKeeperV3RuntimeSizeTest is Test {
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant EIP_3860_INITCODE_LIMIT = 49_152;
    uint256 internal constant RELEASE_KEEPER_INITCODE_SIZE = 18_056;
    uint256 internal constant RELEASE_KEEPER_CORE_SIZE = 15_155;
    bytes32 internal constant RELEASE_KEEPER_CORE_HASH =
        0x692f8e37be588b2d441bda19025847aeb33097eb353231eb14a9777df0d0f20c;
    uint256 internal constant RELEASE_KEEPER_RUNTIME_SIZE = 15_155 + 32;
    bytes32 internal constant RELEASE_KEEPER_RUNTIME_HASH =
        0x418be17ea754b8b279ff2ffa4c8574a26f999d5a506806fdcc349e5eab9f0279;

    function test_standaloneKeeperFitsProtocolLimits() public {
        LpYieldToken crvUsd = new LpYieldToken(18);
        LpYieldToken pairedToken = new LpYieldToken(18);
        LpYieldOracle oracle = new LpYieldOracle();
        LpYieldControllerAndPolicy controllerFactory = new LpYieldControllerAndPolicy(
            address(crvUsd), address(this), address(0xBEEF), address(0xFEE), address(oracle)
        );
        LpYieldAmm pool = new LpYieldAmm(address(crvUsd), address(pairedToken));

        bytes memory keeperInitCode = bytes.concat(
            vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json"),
            abi.encode(
                address(controllerFactory),
                address(pool),
                false,
                true,
                150_000_000e18,
                1,
                address(oracle)
            ),
            abi.encode(
                10, 150, 3, 3_000, address(this), address(0xBEEF), address(controllerFactory)
            )
        );
        assertEq(keeperInitCode.length, RELEASE_KEEPER_INITCODE_SIZE, "keeper initcode drift");
        assertLe(keeperInitCode.length, EIP_3860_INITCODE_LIMIT, "keeper exceeds EIP-3860");

        address keeperAddress;
        assembly ("memory-safe") {
            keeperAddress := create(0, add(keeperInitCode, 0x20), mload(keeperInitCode))
        }
        assertTrue(keeperAddress != address(0), "keeper deployment failed");
        bytes memory keeperCore = vm.getDeployedCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        assertEq(keeperCore.length, RELEASE_KEEPER_CORE_SIZE, "keeper core size drift");
        assertEq(keccak256(keeperCore), RELEASE_KEEPER_CORE_HASH, "keeper core hash drift");
        assertEq(
            keeperAddress.code,
            bytes.concat(keeperCore, abi.encode(address(crvUsd))),
            "Vyper immutable suffix drift"
        );
        assertEq(keeperAddress.code.length, RELEASE_KEEPER_RUNTIME_SIZE, "keeper runtime drift");
        assertEq(
            keccak256(bytes.concat(keeperCore, abi.encode(CRVUSD))),
            RELEASE_KEEPER_RUNTIME_HASH,
            "mainnet runtime hash drift"
        );
        assertLe(keeperAddress.code.length, EIP_170_RUNTIME_LIMIT, "keeper exceeds EIP-170");
        assertGt(keeperAddress.code.length, 45, "keeper unexpectedly uses a minimal proxy");
        assertEq(IPegKeeperV3(keeperAddress).policy(), address(controllerFactory));

        (bool factoryGetterExists,) = keeperAddress.staticcall(abi.encodeWithSignature("factory()"));
        assertFalse(factoryGetterExists);
        (bool initializedGetterExists,) =
            keeperAddress.staticcall(abi.encodeWithSignature("initialized()"));
        assertFalse(initializedGetterExists);
    }
}
