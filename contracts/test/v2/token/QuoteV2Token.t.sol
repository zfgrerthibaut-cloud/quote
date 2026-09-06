// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20Errors } from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

import { QuoteV2Token as ForkPareV2Token } from "../../../src/v2/token/QuoteV2Token.sol";

contract QuoteV2TokenTest is Test {
    uint256 internal constant SUPPLY = 100_000_000 ether;
    uint256 internal constant TOKEN_MAX_NAME_LENGTH = 64;
    uint256 internal constant TOKEN_MAX_SYMBOL_LENGTH = 16;
    uint256 internal constant TOKEN_MAX_LOGO_LENGTH = 256;
    uint256 internal constant TOKEN_MAX_DESCRIPTION_LENGTH = 1_024;
    uint256 internal constant TOKEN_MAX_SOCIAL_LENGTH = 128;
    uint256 internal constant TOKEN_MAX_WEBSITE_LENGTH = 256;

    address internal launcher = makeAddr("launcher");
    address internal initialReceiver = makeAddr("initialReceiver");
    address internal factory = makeAddr("factory");
    address internal vault = makeAddr("vault");

    function testConstructorMintsFixedSupplyToInitialReceiverAndStoresLaunchContext() external {
        ForkPareV2Token.TokenMetadata memory metadata = _metadata();
        ForkPareV2Token token = new ForkPareV2Token(
            "ForkPare V2 Market",
            "FPV2",
            SUPPLY,
            launcher,
            initialReceiver,
            factory,
            vault,
            metadata
        );

        assertEq(token.name(), "ForkPare V2 Market");
        assertEq(token.symbol(), "FPV2");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.fixedSupply(), SUPPLY);
        assertEq(token.balanceOf(launcher), 0);
        assertEq(token.balanceOf(initialReceiver), SUPPLY);
        assertEq(token.balanceOf(factory), 0);
        assertEq(token.balanceOf(vault), 0);
        assertEq(token.launcher(), launcher);
        assertEq(token.initialReceiver(), initialReceiver);
        assertEq(token.factory(), factory);
        assertEq(token.vault(), vault);
        assertEq(token.MAX_NAME_LENGTH(), TOKEN_MAX_NAME_LENGTH);
        assertEq(token.MAX_SYMBOL_LENGTH(), TOKEN_MAX_SYMBOL_LENGTH);
        assertEq(token.MAX_LOGO_LENGTH(), TOKEN_MAX_LOGO_LENGTH);
        assertEq(token.MAX_DESCRIPTION_LENGTH(), TOKEN_MAX_DESCRIPTION_LENGTH);
        assertEq(token.MAX_SOCIAL_LENGTH(), TOKEN_MAX_SOCIAL_LENGTH);
        assertEq(token.MAX_WEBSITE_LENGTH(), TOKEN_MAX_WEBSITE_LENGTH);
    }

    function testGetTokenInfoReturnsMetadataAndImmutableRefs() external {
        ForkPareV2Token.TokenMetadata memory metadata = _metadata();
        ForkPareV2Token token = new ForkPareV2Token(
            "ForkPare V2 Market",
            "FPV2",
            SUPPLY,
            launcher,
            initialReceiver,
            factory,
            vault,
            metadata
        );

        ForkPareV2Token.TokenInfo memory info = token.getTokenInfo();

        assertEq(info.name, "ForkPare V2 Market");
        assertEq(info.symbol, "FPV2");
        assertEq(info.decimals, 18);
        assertEq(info.totalSupply, SUPPLY);
        assertEq(info.fixedSupply, SUPPLY);
        assertEq(info.launcher, launcher);
        assertEq(info.initialReceiver, initialReceiver);
        assertEq(info.factory, factory);
        assertEq(info.vault, vault);
        _assertMetadataEq(info.metadata, metadata);
    }

    function testAcceptsEmptyOptionalMetadata() external {
        ForkPareV2Token.TokenMetadata memory metadata;
        ForkPareV2Token token = new ForkPareV2Token(
            "No Metadata", "NOMETA", SUPPLY, launcher, initialReceiver, factory, vault, metadata
        );

        ForkPareV2Token.TokenInfo memory info = token.getTokenInfo();
        _assertMetadataEq(info.metadata, metadata);
    }

    function testAcceptsExactMaximumTextLengths() external {
        ForkPareV2Token.TokenMetadata memory metadata = ForkPareV2Token.TokenMetadata({
            logo: _repeat("l", tokenMaxLogo()),
            description: _repeat("d", tokenMaxDescription()),
            twitter: _repeat("t", tokenMaxSocial()),
            telegram: _repeat("g", tokenMaxSocial()),
            discord: _repeat("c", tokenMaxSocial()),
            website: _repeat("w", tokenMaxWebsite())
        });

        ForkPareV2Token token = new ForkPareV2Token(
            _repeat("n", tokenMaxName()),
            _repeat("s", tokenMaxSymbol()),
            SUPPLY,
            launcher,
            initialReceiver,
            factory,
            vault,
            metadata
        );

        ForkPareV2Token.TokenInfo memory info = token.getTokenInfo();
        assertEq(bytes(info.name).length, tokenMaxName());
        assertEq(bytes(info.symbol).length, tokenMaxSymbol());
        _assertMetadataEq(info.metadata, metadata);
    }

    function testRejectsEmptyNameAndSymbol() external {
        ForkPareV2Token.TokenMetadata memory metadata = _metadata();

        vm.expectRevert(abi.encodeWithSelector(ForkPareV2Token.EmptyText.selector, bytes32("name")));
        new ForkPareV2Token("", "FPV2", SUPPLY, launcher, initialReceiver, factory, vault, metadata);

        vm.expectRevert(
            abi.encodeWithSelector(ForkPareV2Token.EmptyText.selector, bytes32("symbol"))
        );
        new ForkPareV2Token(
            "ForkPare V2 Market", "", SUPPLY, launcher, initialReceiver, factory, vault, metadata
        );
    }

    function testRejectsZeroFixedSupply() external {
        vm.expectRevert(ForkPareV2Token.InvalidFixedSupply.selector);
        new ForkPareV2Token(
            "ForkPare V2 Market", "FPV2", 0, launcher, initialReceiver, factory, vault, _metadata()
        );
    }

    function testRejectsZeroRequiredLaunchReferences() external {
        ForkPareV2Token.TokenMetadata memory metadata = _metadata();

        vm.expectRevert(
            abi.encodeWithSelector(ForkPareV2Token.InvalidReference.selector, bytes32("launcher"))
        );
        new ForkPareV2Token(
            "ForkPare V2 Market",
            "FPV2",
            SUPPLY,
            address(0),
            initialReceiver,
            factory,
            vault,
            metadata
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ForkPareV2Token.InvalidReference.selector, bytes32("initialReceiver")
            )
        );
        new ForkPareV2Token(
            "ForkPare V2 Market", "FPV2", SUPPLY, launcher, address(0), factory, vault, metadata
        );

        vm.expectRevert(
            abi.encodeWithSelector(ForkPareV2Token.InvalidReference.selector, bytes32("factory"))
        );
        new ForkPareV2Token(
            "ForkPare V2 Market",
            "FPV2",
            SUPPLY,
            launcher,
            initialReceiver,
            address(0),
            vault,
            metadata
        );
    }

    function testAllowsZeroVaultForStandardMode() external {
        ForkPareV2Token token = new ForkPareV2Token(
            "ForkPare V2 Market",
            "FPV2",
            SUPPLY,
            launcher,
            initialReceiver,
            factory,
            address(0),
            _metadata()
        );

        assertEq(token.vault(), address(0));
        assertEq(token.balanceOf(initialReceiver), SUPPLY);
        ForkPareV2Token.TokenInfo memory info = token.getTokenInfo();
        assertEq(info.vault, address(0));
        assertEq(info.initialReceiver, initialReceiver);
    }

    function testRejectsTextOverMaximumLengths() external {
        _expectTextTooLong(
            bytes32("name"),
            tokenMaxName() + 1,
            tokenMaxName(),
            _overrideName(_repeat("n", tokenMaxName() + 1))
        );
        _expectTextTooLong(
            bytes32("symbol"),
            tokenMaxSymbol() + 1,
            tokenMaxSymbol(),
            _overrideSymbol(_repeat("s", tokenMaxSymbol() + 1))
        );
        _expectTextTooLong(
            bytes32("logo"),
            tokenMaxLogo() + 1,
            tokenMaxLogo(),
            _overrideLogo(_repeat("l", tokenMaxLogo() + 1))
        );
        _expectTextTooLong(
            bytes32("description"),
            tokenMaxDescription() + 1,
            tokenMaxDescription(),
            _overrideDescription(_repeat("d", tokenMaxDescription() + 1))
        );
        _expectTextTooLong(
            bytes32("twitter"),
            tokenMaxSocial() + 1,
            tokenMaxSocial(),
            _overrideTwitter(_repeat("t", tokenMaxSocial() + 1))
        );
        _expectTextTooLong(
            bytes32("telegram"),
            tokenMaxSocial() + 1,
            tokenMaxSocial(),
            _overrideTelegram(_repeat("g", tokenMaxSocial() + 1))
        );
        _expectTextTooLong(
            bytes32("discord"),
            tokenMaxSocial() + 1,
            tokenMaxSocial(),
            _overrideDiscord(_repeat("c", tokenMaxSocial() + 1))
        );
        _expectTextTooLong(
            bytes32("website"),
            tokenMaxWebsite() + 1,
            tokenMaxWebsite(),
            _overrideWebsite(_repeat("w", tokenMaxWebsite() + 1))
        );
    }

    function testTransferAndAllowanceArePlainErc20AndSupplyStaysFixed() external {
        ForkPareV2Token token = new ForkPareV2Token(
            "ForkPare V2 Market",
            "FPV2",
            SUPPLY,
            launcher,
            initialReceiver,
            factory,
            vault,
            _metadata()
        );
        address buyer = makeAddr("buyer");
        address spender = makeAddr("spender");

        vm.prank(initialReceiver);
        assertTrue(token.transfer(buyer, 1_000 ether));
        assertEq(token.balanceOf(launcher), 0);
        assertEq(token.balanceOf(initialReceiver), SUPPLY - 1_000 ether);
        assertEq(token.balanceOf(buyer), 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.fixedSupply(), SUPPLY);

        vm.prank(buyer);
        assertTrue(token.approve(spender, 400 ether));
        vm.prank(spender);
        assertTrue(token.transferFrom(buyer, vault, 250 ether));

        assertEq(token.allowance(buyer, spender), 150 ether);
        assertEq(token.balanceOf(vault), 250 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzPlainTransfersConserveFixedSupply(uint96 rawAmount, address receiver)
        external
    {
        vm.assume(receiver != address(0));
        vm.assume(receiver != initialReceiver);

        uint256 amount = bound(uint256(rawAmount), 0, SUPPLY);
        ForkPareV2Token token = new ForkPareV2Token(
            "ForkPare V2 Market",
            "FPV2",
            SUPPLY,
            launcher,
            initialReceiver,
            factory,
            vault,
            _metadata()
        );

        vm.prank(initialReceiver);
        token.transfer(receiver, amount);

        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.fixedSupply(), SUPPLY);
        assertEq(token.balanceOf(initialReceiver) + token.balanceOf(receiver), SUPPLY);
    }

    function testFuzzValidConstructorInputsAreStored(
        uint96 rawSupply,
        uint8 nameLengthSeed,
        uint8 symbolLengthSeed,
        uint16 logoLengthSeed,
        uint16 descriptionLengthSeed,
        uint16 twitterLengthSeed,
        uint16 telegramLengthSeed,
        uint16 discordLengthSeed,
        uint16 websiteLengthSeed
    ) external {
        uint256 supply = bound(uint256(rawSupply), 1, type(uint96).max);
        string memory name_ = _repeat("n", bound(nameLengthSeed, 1, tokenMaxName()));
        string memory symbol_ = _repeat("s", bound(symbolLengthSeed, 1, tokenMaxSymbol()));
        ForkPareV2Token.TokenMetadata memory metadata = ForkPareV2Token.TokenMetadata({
            logo: _repeat("l", bound(logoLengthSeed, 0, tokenMaxLogo())),
            description: _repeat("d", bound(descriptionLengthSeed, 0, tokenMaxDescription())),
            twitter: _repeat("t", bound(twitterLengthSeed, 0, tokenMaxSocial())),
            telegram: _repeat("g", bound(telegramLengthSeed, 0, tokenMaxSocial())),
            discord: _repeat("c", bound(discordLengthSeed, 0, tokenMaxSocial())),
            website: _repeat("w", bound(websiteLengthSeed, 0, tokenMaxWebsite()))
        });

        ForkPareV2Token token = new ForkPareV2Token(
            name_, symbol_, supply, launcher, initialReceiver, factory, vault, metadata
        );
        ForkPareV2Token.TokenInfo memory info = token.getTokenInfo();

        assertEq(info.name, name_);
        assertEq(info.symbol, symbol_);
        assertEq(info.totalSupply, supply);
        assertEq(info.fixedSupply, supply);
        assertEq(info.initialReceiver, initialReceiver);
        assertEq(token.balanceOf(launcher), 0);
        assertEq(token.balanceOf(initialReceiver), supply);
        _assertMetadataEq(info.metadata, metadata);
    }

    function testDeterministicCreate2AddressDependsOnlyOnSaltAndConstructorArgs() external {
        bytes32 salt = keccak256("forkpare-v2-token");
        ForkPareV2Token.TokenMetadata memory metadata = _metadata();
        bytes memory constructorArgs = abi.encode(
            "ForkPare V2 Market",
            "FPV2",
            SUPPLY,
            launcher,
            initialReceiver,
            factory,
            vault,
            metadata
        );
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(ForkPareV2Token).creationCode, constructorArgs));
        address predicted = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))
                )
            )
        );

        ForkPareV2Token token = new ForkPareV2Token{ salt: salt }(
            "ForkPare V2 Market",
            "FPV2",
            SUPPLY,
            launcher,
            initialReceiver,
            factory,
            vault,
            metadata
        );

        assertEq(address(token), predicted);
    }

    function testNoOwnerMintPauseBlacklistTaxAdminOrVaultCallbackSurface() external {
        ForkPareV2Token token = new ForkPareV2Token(
            "ForkPare V2 Market",
            "FPV2",
            SUPPLY,
            launcher,
            initialReceiver,
            factory,
            vault,
            _metadata()
        );

        _assertMissingSelector(address(token), "owner()");
        _assertMissingSelector(
            address(token), "mint(address,uint256)", abi.encode(address(this), 1)
        );
        _assertMissingSelector(address(token), "burn(uint256)", abi.encode(1));
        _assertMissingSelector(address(token), "pause()");
        _assertMissingSelector(address(token), "unpause()");
        _assertMissingSelector(
            address(token), "setBlacklist(address,bool)", abi.encode(address(this), true)
        );
        _assertMissingSelector(address(token), "blacklist(address)", abi.encode(address(this)));
        _assertMissingSelector(address(token), "setTax(uint256)", abi.encode(1));
        _assertMissingSelector(address(token), "setVault(address)", abi.encode(address(this)));
        _assertMissingSelector(
            address(token), "setInitialReceiver(address)", abi.encode(address(this))
        );
        _assertMissingSelector(
            address(token),
            "onVaultTransfer(address,address,uint256)",
            abi.encode(address(this), initialReceiver, 1)
        );
    }

    function testRejectsTransferBeyondBalanceWithStandardErc20Error() external {
        ForkPareV2Token token = new ForkPareV2Token(
            "ForkPare V2 Market",
            "FPV2",
            SUPPLY,
            launcher,
            initialReceiver,
            factory,
            vault,
            _metadata()
        );

        vm.prank(launcher);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, launcher, 0, 1)
        );
        token.transfer(vault, 1);
    }

    function _metadata() internal pure returns (ForkPareV2Token.TokenMetadata memory metadata) {
        metadata = ForkPareV2Token.TokenMetadata({
            logo: "ipfs://bafybeigdyrzt",
            description: "Fixed-supply direct-pool launch token.",
            twitter: "https://x.com/forkpare",
            telegram: "https://t.me/forkpare",
            discord: "https://discord.gg/forkpare",
            website: "https://forkpare.example"
        });
    }

    struct Overrides {
        string name;
        string symbol;
        string logo;
        string description;
        string twitter;
        string telegram;
        string discord;
        string website;
    }

    function _overrideName(string memory name_)
        internal
        pure
        returns (Overrides memory overrides_)
    {
        overrides_.name = name_;
    }

    function _overrideSymbol(string memory symbol_)
        internal
        pure
        returns (Overrides memory overrides_)
    {
        overrides_.symbol = symbol_;
    }

    function _overrideLogo(string memory logo_)
        internal
        pure
        returns (Overrides memory overrides_)
    {
        overrides_.logo = logo_;
    }

    function _overrideDescription(string memory description_)
        internal
        pure
        returns (Overrides memory overrides_)
    {
        overrides_.description = description_;
    }

    function _overrideTwitter(string memory twitter_)
        internal
        pure
        returns (Overrides memory overrides_)
    {
        overrides_.twitter = twitter_;
    }

    function _overrideTelegram(string memory telegram_)
        internal
        pure
        returns (Overrides memory overrides_)
    {
        overrides_.telegram = telegram_;
    }

    function _overrideDiscord(string memory discord_)
        internal
        pure
        returns (Overrides memory overrides_)
    {
        overrides_.discord = discord_;
    }

    function _overrideWebsite(string memory website_)
        internal
        pure
        returns (Overrides memory overrides_)
    {
        overrides_.website = website_;
    }

    function _expectTextTooLong(
        bytes32 field,
        uint256 length,
        uint256 maxLength,
        Overrides memory overrides_
    ) internal {
        ForkPareV2Token.TokenMetadata memory metadata = _metadata();
        string memory name_ = "ForkPare V2 Market";
        string memory symbol_ = "FPV2";
        if (bytes(overrides_.name).length != 0) name_ = overrides_.name;
        if (bytes(overrides_.symbol).length != 0) symbol_ = overrides_.symbol;
        if (bytes(overrides_.logo).length != 0) metadata.logo = overrides_.logo;
        if (bytes(overrides_.description).length != 0) {
            metadata.description = overrides_.description;
        }
        if (bytes(overrides_.twitter).length != 0) metadata.twitter = overrides_.twitter;
        if (bytes(overrides_.telegram).length != 0) metadata.telegram = overrides_.telegram;
        if (bytes(overrides_.discord).length != 0) metadata.discord = overrides_.discord;
        if (bytes(overrides_.website).length != 0) metadata.website = overrides_.website;

        vm.expectRevert(
            abi.encodeWithSelector(ForkPareV2Token.TextTooLong.selector, field, length, maxLength)
        );
        new ForkPareV2Token(
            name_, symbol_, SUPPLY, launcher, initialReceiver, factory, vault, metadata
        );
    }

    function _assertMetadataEq(
        ForkPareV2Token.TokenMetadata memory actual,
        ForkPareV2Token.TokenMetadata memory expected
    ) internal pure {
        assertEq(actual.logo, expected.logo);
        assertEq(actual.description, expected.description);
        assertEq(actual.twitter, expected.twitter);
        assertEq(actual.telegram, expected.telegram);
        assertEq(actual.discord, expected.discord);
        assertEq(actual.website, expected.website);
    }

    function _assertMissingSelector(address target, string memory signature) internal {
        (bool ok,) = target.call(abi.encodeWithSignature(signature));
        assertFalse(ok, signature);
    }

    function _assertMissingSelector(address target, string memory signature, bytes memory args)
        internal
    {
        (bool ok,) = target.call(bytes.concat(abi.encodeWithSignature(signature), args));
        assertFalse(ok, signature);
    }

    function _repeat(string memory char, uint256 length) internal pure returns (string memory) {
        bytes memory charBytes = bytes(char);
        assertEq(charBytes.length, 1);

        bytes memory output = new bytes(length);
        bytes1 value = charBytes[0];
        for (uint256 i; i < length; ++i) {
            output[i] = value;
        }
        return string(output);
    }

    function tokenMaxName() internal pure returns (uint256) {
        return TOKEN_MAX_NAME_LENGTH;
    }

    function tokenMaxSymbol() internal pure returns (uint256) {
        return TOKEN_MAX_SYMBOL_LENGTH;
    }

    function tokenMaxLogo() internal pure returns (uint256) {
        return TOKEN_MAX_LOGO_LENGTH;
    }

    function tokenMaxDescription() internal pure returns (uint256) {
        return TOKEN_MAX_DESCRIPTION_LENGTH;
    }

    function tokenMaxSocial() internal pure returns (uint256) {
        return TOKEN_MAX_SOCIAL_LENGTH;
    }

    function tokenMaxWebsite() internal pure returns (uint256) {
        return TOKEN_MAX_WEBSITE_LENGTH;
    }
}
