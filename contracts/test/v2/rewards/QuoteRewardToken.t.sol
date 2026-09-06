// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20Errors } from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import { QuoteRewardToken } from "../../../src/v2/rewards/QuoteRewardToken.sol";
import { RewardVault } from "../../../src/v2/rewards/RewardVault.sol";

contract QuoteRewardTestQuote is ERC20 {
    constructor() ERC20("Quote", "QUOTE") { }
}

contract QuoteRewardTokenTest is Test {
    uint256 internal constant SUPPLY = 100_000_000 ether;
    uint256 internal constant MIN_ELIGIBLE_BALANCE = 1 ether;

    address internal launcher = makeAddr("launcher");
    address internal factory = makeAddr("factory");
    address internal market = makeAddr("market");
    address internal rewardHook = makeAddr("rewardHook");
    address internal poolManager = makeAddr("poolManager");
    address internal locker = makeAddr("locker");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    QuoteRewardTestQuote internal quote;

    function setUp() external {
        quote = new QuoteRewardTestQuote();
    }

    function testPredeployedVaultTracksConstructorMintToExcludedMarket() external {
        bytes32 salt = keccak256("quote-reward-market-token");
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address predictedToken = _predictToken(salt, market, predictedVault, _metadata());

        RewardVault vault = new RewardVault(
            predictedToken, address(quote), rewardHook, MIN_ELIGIBLE_BALANCE, _exclusions(market)
        );
        assertEq(address(vault), predictedVault);

        QuoteRewardToken token = new QuoteRewardToken{ salt: salt }(
            "Quote Reward Market",
            "QRWD",
            SUPPLY,
            launcher,
            market,
            factory,
            address(vault),
            _metadata()
        );

        assertEq(address(token), predictedToken);
        assertEq(token.name(), "Quote Reward Market");
        assertEq(token.symbol(), "QRWD");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.fixedSupply(), SUPPLY);
        assertEq(token.launcher(), launcher);
        assertEq(token.initialReceiver(), market);
        assertEq(token.factory(), factory);
        assertEq(token.vault(), address(vault));
        assertEq(token.balanceOf(market), SUPPLY);

        assertTrue(vault.isExcluded(market));
        assertEq(vault.trackedBalanceOf(market), SUPPLY);
        assertEq(vault.eligibleSharesOf(market), 0);
        assertEq(vault.totalEligibleShares(), 0);
    }

    function testTransferNotifiesFromAndToWithPlainErc20Semantics() external {
        (QuoteRewardToken token, RewardVault vault) = _deployTokenAndVault(market);

        vm.prank(market);
        assertTrue(token.transfer(alice, 1_000 ether));

        assertEq(token.balanceOf(market), SUPPLY - 1_000 ether);
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(vault.trackedBalanceOf(market), SUPPLY - 1_000 ether);
        assertEq(vault.trackedBalanceOf(alice), 1_000 ether);
        assertEq(vault.eligibleSharesOf(market), 0);
        assertEq(vault.eligibleSharesOf(alice), 1_000 ether);
        assertEq(vault.totalEligibleShares(), 1_000 ether);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 250 ether));

        assertEq(token.balanceOf(alice), 750 ether);
        assertEq(token.balanceOf(bob), 250 ether);
        assertEq(vault.trackedBalanceOf(alice), 750 ether);
        assertEq(vault.trackedBalanceOf(bob), 250 ether);
        assertEq(vault.totalEligibleShares(), 1_000 ether);
    }

    function testGetTokenInfoReturnsMetadataAndImmutableRefs() external {
        (QuoteRewardToken token,) = _deployTokenAndVault(market);

        QuoteRewardToken.TokenMetadata memory metadata = _metadata();
        QuoteRewardToken.TokenInfo memory info = token.getTokenInfo();

        assertEq(info.name, "Quote Reward Market");
        assertEq(info.symbol, "QRWD");
        assertEq(info.decimals, 18);
        assertEq(info.totalSupply, SUPPLY);
        assertEq(info.fixedSupply, SUPPLY);
        assertEq(info.launcher, launcher);
        assertEq(info.initialReceiver, market);
        assertEq(info.factory, factory);
        assertEq(info.vault, token.vault());
        assertEq(info.metadata.logo, metadata.logo);
        assertEq(info.metadata.description, metadata.description);
        assertEq(info.metadata.twitter, metadata.twitter);
        assertEq(info.metadata.telegram, metadata.telegram);
        assertEq(info.metadata.discord, metadata.discord);
        assertEq(info.metadata.website, metadata.website);
    }

    function testRejectsInvalidConstructorInputs() external {
        RewardVault vault = new RewardVault(
            makeAddr("token"),
            address(quote),
            rewardHook,
            MIN_ELIGIBLE_BALANCE,
            _exclusions(address(0))
        );
        QuoteRewardToken.TokenMetadata memory metadata = _metadata();

        vm.expectRevert(
            abi.encodeWithSelector(QuoteRewardToken.EmptyText.selector, bytes32("name"))
        );
        new QuoteRewardToken(
            "", "QRWD", SUPPLY, launcher, market, factory, address(vault), metadata
        );

        vm.expectRevert(
            abi.encodeWithSelector(QuoteRewardToken.EmptyText.selector, bytes32("symbol"))
        );
        new QuoteRewardToken(
            "Quote Reward Market", "", SUPPLY, launcher, market, factory, address(vault), metadata
        );

        vm.expectRevert(QuoteRewardToken.InvalidFixedSupply.selector);
        new QuoteRewardToken(
            "Quote Reward Market", "QRWD", 0, launcher, market, factory, address(vault), metadata
        );

        vm.expectRevert(
            abi.encodeWithSelector(QuoteRewardToken.InvalidReference.selector, bytes32("launcher"))
        );
        new QuoteRewardToken(
            "Quote Reward Market",
            "QRWD",
            SUPPLY,
            address(0),
            market,
            factory,
            address(vault),
            metadata
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                QuoteRewardToken.InvalidReference.selector, bytes32("initialReceiver")
            )
        );
        new QuoteRewardToken(
            "Quote Reward Market",
            "QRWD",
            SUPPLY,
            launcher,
            address(0),
            factory,
            address(vault),
            metadata
        );

        vm.expectRevert(
            abi.encodeWithSelector(QuoteRewardToken.InvalidReference.selector, bytes32("factory"))
        );
        new QuoteRewardToken(
            "Quote Reward Market",
            "QRWD",
            SUPPLY,
            launcher,
            market,
            address(0),
            address(vault),
            metadata
        );

        vm.expectRevert(
            abi.encodeWithSelector(QuoteRewardToken.InvalidReference.selector, bytes32("vault"))
        );
        new QuoteRewardToken(
            "Quote Reward Market", "QRWD", SUPPLY, launcher, market, factory, address(0), metadata
        );

        vm.expectRevert(
            abi.encodeWithSelector(QuoteRewardToken.InvalidReference.selector, bytes32("vault"))
        );
        new QuoteRewardToken(
            "Quote Reward Market",
            "QRWD",
            SUPPLY,
            launcher,
            market,
            factory,
            makeAddr("emptyVault"),
            metadata
        );
    }

    function testConstructorRevertsWhenVaultIsNotBoundToPredictedToken() external {
        bytes32 salt = keccak256("quote-reward-wrong-vault");
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address predictedToken = _predictToken(salt, market, predictedVault, _metadata());

        RewardVault wrongVault = new RewardVault(
            makeAddr("wrongToken"),
            address(quote),
            rewardHook,
            MIN_ELIGIBLE_BALANCE,
            _exclusions(market)
        );
        assertEq(address(wrongVault), predictedVault);

        vm.expectRevert(abi.encodeWithSelector(RewardVault.NotLaunchToken.selector, predictedToken));
        new QuoteRewardToken{ salt: salt }(
            "Quote Reward Market",
            "QRWD",
            SUPPLY,
            launcher,
            market,
            factory,
            address(wrongVault),
            _metadata()
        );
    }

    function testNoAdminMintBurnTaxOrMutableVaultSurface() external {
        (QuoteRewardToken token,) = _deployTokenAndVault(market);

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
        _assertMissingSelector(address(token), "setTax(uint256)", abi.encode(1));
        _assertMissingSelector(address(token), "setVault(address)", abi.encode(address(this)));
    }

    function testRejectsTransferBeyondBalanceWithStandardErc20Error() external {
        (QuoteRewardToken token,) = _deployTokenAndVault(market);

        vm.prank(launcher);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, launcher, 0, 1)
        );
        token.transfer(alice, 1);
    }

    function _deployTokenAndVault(address receiver)
        internal
        returns (QuoteRewardToken token, RewardVault vault)
    {
        bytes32 salt = keccak256(
            abi.encode("quote-reward-token", receiver, vm.getNonce(address(this)))
        );
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        QuoteRewardToken.TokenMetadata memory metadata = _metadata();
        address predictedToken = _predictToken(salt, receiver, predictedVault, metadata);

        vault = new RewardVault(
            predictedToken, address(quote), rewardHook, MIN_ELIGIBLE_BALANCE, _exclusions(receiver)
        );
        token = new QuoteRewardToken{ salt: salt }(
            "Quote Reward Market",
            "QRWD",
            SUPPLY,
            launcher,
            receiver,
            factory,
            address(vault),
            metadata
        );
    }

    function _predictToken(
        bytes32 salt,
        address receiver,
        address predictedVault,
        QuoteRewardToken.TokenMetadata memory metadata
    ) internal view returns (address) {
        bytes memory constructorArgs = abi.encode(
            "Quote Reward Market",
            "QRWD",
            SUPPLY,
            launcher,
            receiver,
            factory,
            predictedVault,
            metadata
        );
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(QuoteRewardToken).creationCode, constructorArgs));
        return vm.computeCreate2Address(salt, initCodeHash, address(this));
    }

    function _exclusions(address receiver) internal view returns (address[] memory exclusions) {
        exclusions = new address[](4);
        exclusions[0] = poolManager;
        exclusions[1] = locker;
        exclusions[2] = treasury;
        exclusions[3] = receiver;
    }

    function _metadata() internal pure returns (QuoteRewardToken.TokenMetadata memory metadata) {
        metadata = QuoteRewardToken.TokenMetadata({
            logo: "ipfs://quote-reward-logo",
            description: "Fixed-supply QUOTE reward-mode launch token.",
            twitter: "https://x.com/quote",
            telegram: "https://t.me/quote",
            discord: "https://discord.gg/quote",
            website: "https://quote.example"
        });
    }

    function _assertMissingSelector(address target, string memory signature, bytes memory args)
        internal
    {
        (bool ok,) = target.call(bytes.concat(abi.encodeWithSignature(signature), args));
        assertFalse(ok, signature);
    }

    function _assertMissingSelector(address target, string memory signature) internal {
        (bool ok,) = target.call(abi.encodeWithSignature(signature));
        assertFalse(ok, signature);
    }
}
