// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import { IRewardBalanceChangeReceiver } from "./IRewardVault.sol";

/// @notice Fixed-supply QUOTE reward-mode launch token with reward-share notifications.
/// @dev The constructor is deterministic and mints the full supply to the initial receiver. There
///      are no owner, external mint, external burn, pause, blacklist, tax or admin entry points.
contract QuoteRewardToken is ERC20 {
    uint256 public constant MAX_NAME_LENGTH = 64;
    uint256 public constant MAX_SYMBOL_LENGTH = 16;
    uint256 public constant MAX_LOGO_LENGTH = 256;
    uint256 public constant MAX_DESCRIPTION_LENGTH = 1_024;
    uint256 public constant MAX_SOCIAL_LENGTH = 128;
    uint256 public constant MAX_WEBSITE_LENGTH = 256;

    bytes32 private constant FIELD_NAME = "name";
    bytes32 private constant FIELD_SYMBOL = "symbol";
    bytes32 private constant FIELD_LOGO = "logo";
    bytes32 private constant FIELD_DESCRIPTION = "description";
    bytes32 private constant FIELD_TWITTER = "twitter";
    bytes32 private constant FIELD_TELEGRAM = "telegram";
    bytes32 private constant FIELD_DISCORD = "discord";
    bytes32 private constant FIELD_WEBSITE = "website";
    bytes32 private constant FIELD_LAUNCHER = "launcher";
    bytes32 private constant FIELD_INITIAL_RECEIVER = "initialReceiver";
    bytes32 private constant FIELD_FACTORY = "factory";
    bytes32 private constant FIELD_VAULT = "vault";

    address public immutable launcher;
    address public immutable initialReceiver;
    address public immutable factory;
    address public immutable vault;
    uint256 public immutable fixedSupply;

    struct TokenMetadata {
        string logo;
        string description;
        string twitter;
        string telegram;
        string discord;
        string website;
    }

    struct TokenInfo {
        string name;
        string symbol;
        uint8 decimals;
        uint256 totalSupply;
        uint256 fixedSupply;
        address launcher;
        address initialReceiver;
        address factory;
        address vault;
        TokenMetadata metadata;
    }

    TokenMetadata private _metadata;

    error EmptyText(bytes32 field);
    error TextTooLong(bytes32 field, uint256 length, uint256 maxLength);
    error InvalidReference(bytes32 field);
    error InvalidFixedSupply();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 fixedSupply_,
        address launcher_,
        address initialReceiver_,
        address factory_,
        address vault_,
        TokenMetadata memory metadata_
    ) ERC20(name_, symbol_) {
        _validateRequiredText(FIELD_NAME, name_, MAX_NAME_LENGTH);
        _validateRequiredText(FIELD_SYMBOL, symbol_, MAX_SYMBOL_LENGTH);
        if (fixedSupply_ == 0) revert InvalidFixedSupply();
        if (launcher_ == address(0)) revert InvalidReference(FIELD_LAUNCHER);
        if (initialReceiver_ == address(0)) revert InvalidReference(FIELD_INITIAL_RECEIVER);
        if (factory_ == address(0)) revert InvalidReference(FIELD_FACTORY);
        if (vault_ == address(0) || vault_.code.length == 0) revert InvalidReference(FIELD_VAULT);

        _validateOptionalText(FIELD_LOGO, metadata_.logo, MAX_LOGO_LENGTH);
        _validateOptionalText(FIELD_DESCRIPTION, metadata_.description, MAX_DESCRIPTION_LENGTH);
        _validateOptionalText(FIELD_TWITTER, metadata_.twitter, MAX_SOCIAL_LENGTH);
        _validateOptionalText(FIELD_TELEGRAM, metadata_.telegram, MAX_SOCIAL_LENGTH);
        _validateOptionalText(FIELD_DISCORD, metadata_.discord, MAX_SOCIAL_LENGTH);
        _validateOptionalText(FIELD_WEBSITE, metadata_.website, MAX_WEBSITE_LENGTH);

        launcher = launcher_;
        initialReceiver = initialReceiver_;
        factory = factory_;
        vault = vault_;
        fixedSupply = fixedSupply_;
        _metadata = metadata_;

        _mint(initialReceiver_, fixedSupply_);
    }

    function getTokenInfo() external view returns (TokenInfo memory info) {
        info = TokenInfo({
            name: name(),
            symbol: symbol(),
            decimals: decimals(),
            totalSupply: totalSupply(),
            fixedSupply: fixedSupply,
            launcher: launcher,
            initialReceiver: initialReceiver,
            factory: factory,
            vault: vault,
            metadata: _metadata
        });
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 fromBefore = from == address(0) ? 0 : balanceOf(from);
        uint256 toBefore = to == address(0) ? 0 : balanceOf(to);

        super._update(from, to, value);

        IRewardBalanceChangeReceiver rewardVault = IRewardBalanceChangeReceiver(vault);
        if (from == to) {
            if (from != address(0)) {
                rewardVault.notifyBalanceChange(from, fromBefore, balanceOf(from));
            }
            return;
        }
        if (from != address(0)) rewardVault.notifyBalanceChange(from, fromBefore, balanceOf(from));
        if (to != address(0)) rewardVault.notifyBalanceChange(to, toBefore, balanceOf(to));
    }

    function _validateRequiredText(bytes32 field, string memory value, uint256 maxLength)
        private
        pure
    {
        uint256 length = bytes(value).length;
        if (length == 0) revert EmptyText(field);
        if (length > maxLength) revert TextTooLong(field, length, maxLength);
    }

    function _validateOptionalText(bytes32 field, string memory value, uint256 maxLength)
        private
        pure
    {
        uint256 length = bytes(value).length;
        if (length > maxLength) revert TextTooLong(field, length, maxLength);
    }
}
