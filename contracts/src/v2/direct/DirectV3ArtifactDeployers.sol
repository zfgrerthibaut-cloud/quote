// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { INonfungiblePositionManager } from "../../interfaces/IPancakeV3.sol";
import { QuoteDirectToken } from "./QuoteDirectToken.sol";
import { PermanentPancakeV3Locker } from "../locker/PermanentPancakeV3Locker.sol";

contract DirectV3TokenDeployer {
    address public immutable engine;

    error NotEngine();

    constructor(address engine_) {
        engine = engine_;
    }

    function deploy(bytes32 salt, string calldata name, string calldata symbol, uint256 supply)
        external
        returns (QuoteDirectToken token)
    {
        if (msg.sender != engine) revert NotEngine();
        token = new QuoteDirectToken{ salt: salt }(name, symbol, supply, engine);
    }

    function predict(bytes32 salt, string calldata name, string calldata symbol, uint256 supply)
        external
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(QuoteDirectToken).creationCode, abi.encode(name, symbol, supply, engine)
            )
        );
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))
                )
            )
        );
    }
}

contract DirectV3LockerDeployer {
    address public immutable engine;

    error NotEngine();

    constructor(address engine_) {
        engine = engine_;
    }

    function deploy(
        INonfungiblePositionManager positionManager,
        address creator,
        address protocolTreasury,
        uint16 creatorFeeBps,
        uint256 expectedTokenId
    ) external returns (PermanentPancakeV3Locker locker) {
        if (msg.sender != engine) revert NotEngine();
        locker = new PermanentPancakeV3Locker(
            positionManager, engine, creator, protocolTreasury, creatorFeeBps, expectedTokenId
        );
    }
}
