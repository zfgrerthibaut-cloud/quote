// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply token used only by the QUOTE direct V3 engine.
contract QuoteDirectToken is ERC20 {
    address public immutable engine;

    error NotEngine();

    constructor(string memory name_, string memory symbol_, uint256 supply_, address engine_)
        ERC20(name_, symbol_)
    {
        engine = engine_;
        _mint(engine_, supply_);
    }

    /// @dev Removes only bounded launch dust still owned by the engine during atomic initialization.
    function burnLaunchDust(uint256 amount) external {
        if (msg.sender != engine) revert NotEngine();
        _burn(msg.sender, amount);
    }
}
