// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply launch token. It deliberately has no owner, mint, burn, tax or pause hook.
contract ForkPareToken is ERC20 {
    address public immutable factory;

    error NotFactory();

    constructor(string memory name_, string memory symbol_, uint256 supply_, address receiver_)
        ERC20(name_, symbol_)
    {
        factory = receiver_;
        _mint(receiver_, supply_);
    }

    /// @dev The non-upgradeable factory only calls this during launch to remove bounded V3
    /// rounding dust that never entered the position. It can burn only tokens it owns.
    function burnUnspent(uint256 amount) external {
        if (msg.sender != factory) revert NotFactory();
        _burn(msg.sender, amount);
    }
}
