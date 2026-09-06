// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC721Receiver } from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";

import { INonfungiblePositionManager } from "../../../src/interfaces/IPancakeV3.sol";
import { PermanentPancakeV3Locker } from "../../../src/v2/locker/PermanentPancakeV3Locker.sol";

interface ILockerCollect {
    function collect() external returns (uint256 amount0, uint256 amount1);
}

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Taxed Token", "TAX") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value / 10;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

contract SenderPaysExtraToken is ERC20 {
    constructor() ERC20("Sender Pays Extra Token", "EXTRA") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        _burn(_msgSender(), amount / 10);
        return ok;
    }
}

contract FalseReturnToken is ERC20 {
    constructor() ERC20("False Token", "FALSE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

contract ToggleReturnToken is ERC20 {
    bool public returnsFalse;

    constructor() ERC20("Toggle Token", "TOGGLE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setReturnsFalse(bool returnsFalse_) external {
        returnsFalse = returnsFalse_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        return !returnsFalse;
    }
}

contract ReentrantToken is ERC20 {
    address public locker;
    bool public reenterOnTransfer;
    bool public reentryBlocked;

    constructor() ERC20("Reentrant Token", "REENTER") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setReentry(address locker_, bool reenterOnTransfer_) external {
        locker = locker_;
        reenterOnTransfer = reenterOnTransfer_;
        reentryBlocked = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (reenterOnTransfer) {
            reenterOnTransfer = false;
            try ILockerCollect(locker).collect() { }
            catch {
                reentryBlocked = true;
            }
        }

        return super.transfer(to, amount);
    }
}

contract MockPositionManager {
    struct PositionData {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    mapping(uint256 tokenId => address owner) public ownerOf;
    mapping(uint256 tokenId => PositionData position) public positionData;
    uint256 public collectAmount0;
    uint256 public collectAmount1;
    uint256 public collectCalls;

    function mintPosition(address recipient, uint256 tokenId, PositionData memory position)
        external
    {
        ownerOf[tokenId] = recipient;
        positionData[tokenId] = position;
        IERC721Receiver(recipient).onERC721Received(address(this), address(0), tokenId, bytes(""));
    }

    function deliver(address recipient, address from, uint256 tokenId) external {
        IERC721Receiver(recipient).onERC721Received(address(this), from, tokenId, bytes(""));
    }

    function setOwner(uint256 tokenId, address owner_) external {
        ownerOf[tokenId] = owner_;
    }

    function setPosition(uint256 tokenId, PositionData memory position) external {
        positionData[tokenId] = position;
    }

    function setCollectAmounts(uint256 amount0, uint256 amount1) external {
        collectAmount0 = amount0;
        collectAmount1 = amount1;
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        require(ownerOf[params.tokenId] == msg.sender, "not owner");
        ++collectCalls;

        amount0 = collectAmount0;
        amount1 = collectAmount1;
        collectAmount0 = 0;
        collectAmount1 = 0;

        PositionData memory position = positionData[params.tokenId];
        if (amount0 != 0) IERC20(position.token0).transfer(params.recipient, amount0);
        if (amount1 != 0) IERC20(position.token1).transfer(params.recipient, amount1);
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24,
            int24,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        PositionData memory position = positionData[tokenId];
        return (
            0,
            address(0),
            position.token0,
            position.token1,
            position.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            0,
            0,
            0,
            0
        );
    }
}

contract PermanentPancakeV3LockerTest is Test {
    uint256 internal constant TOKEN_ID = 77;
    uint16 internal constant CREATOR_FEE_BPS = 6_000;
    uint24 internal constant FEE = 500;
    int24 internal constant TICK_LOWER = 10;
    int24 internal constant TICK_UPPER = 100;

    address internal factory = makeAddr("factory");
    address internal creator = makeAddr("creator");
    address internal treasury = makeAddr("treasury");
    address internal attacker = makeAddr("attacker");

    MockPositionManager internal positionManager;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PermanentPancakeV3Locker internal locker;

    function setUp() external {
        positionManager = new MockPositionManager();
        token0 = new MockERC20("Token Zero", "TK0");
        token1 = new MockERC20("Token One", "TK1");
        locker = _newLocker(TOKEN_ID, CREATOR_FEE_BPS);
    }

    function testConstructorRejectsBadConfiguration() external {
        vm.expectRevert(PermanentPancakeV3Locker.InvalidConfiguration.selector);
        new PermanentPancakeV3Locker(
            INonfungiblePositionManager(address(0)),
            factory,
            creator,
            treasury,
            CREATOR_FEE_BPS,
            TOKEN_ID
        );

        vm.expectRevert(PermanentPancakeV3Locker.InvalidConfiguration.selector);
        new PermanentPancakeV3Locker(
            INonfungiblePositionManager(address(positionManager)),
            factory,
            creator,
            treasury,
            10_001,
            TOKEN_ID
        );

        vm.expectRevert(PermanentPancakeV3Locker.InvalidConfiguration.selector);
        new PermanentPancakeV3Locker(
            INonfungiblePositionManager(address(positionManager)),
            factory,
            creator,
            treasury,
            CREATOR_FEE_BPS,
            0
        );
    }

    function testAcceptsOnlyExpectedMintFromCanonicalPositionManager() external {
        vm.expectRevert(PermanentPancakeV3Locker.NotPositionManager.selector);
        locker.onERC721Received(address(this), address(0), TOKEN_ID, bytes(""));

        vm.expectRevert(PermanentPancakeV3Locker.UnexpectedNft.selector);
        positionManager.deliver(address(locker), address(0), TOKEN_ID + 1);

        vm.expectRevert(PermanentPancakeV3Locker.UnexpectedNft.selector);
        positionManager.deliver(address(locker), attacker, TOKEN_ID);

        positionManager.deliver(address(locker), factory, TOKEN_ID);
        assertTrue(locker.received());

        vm.expectRevert(PermanentPancakeV3Locker.AlreadyReceived.selector);
        positionManager.deliver(address(locker), address(0), TOKEN_ID);
    }

    function testAcceptsExpectedMintFromCanonicalPositionManager() external {
        PermanentPancakeV3Locker mintLocker = _newLocker(TOKEN_ID + 1, CREATOR_FEE_BPS);

        positionManager.mintPosition(
            address(mintLocker), TOKEN_ID + 1, _position(address(token0), address(token1))
        );
        assertTrue(mintLocker.received());

        vm.expectRevert(PermanentPancakeV3Locker.AlreadyReceived.selector);
        positionManager.deliver(address(mintLocker), address(0), TOKEN_ID + 2);
    }

    function testFinalizeIsFactoryOnlyAndVerifiesCleanPosition() external {
        vm.prank(factory);
        vm.expectRevert(PermanentPancakeV3Locker.NotReceived.selector);
        locker.finalize(address(token0), address(token1), FEE, TICK_LOWER, TICK_UPPER);

        positionManager.mintPosition(
            address(locker), TOKEN_ID, _position(address(token0), address(token1))
        );

        vm.prank(attacker);
        vm.expectRevert(PermanentPancakeV3Locker.NotFactory.selector);
        locker.finalize(address(token0), address(token1), FEE, TICK_LOWER, TICK_UPPER);

        positionManager.setOwner(TOKEN_ID, attacker);
        vm.prank(factory);
        vm.expectRevert(PermanentPancakeV3Locker.InvalidPosition.selector);
        locker.finalize(address(token0), address(token1), FEE, TICK_LOWER, TICK_UPPER);

        positionManager.setOwner(TOKEN_ID, address(locker));
        vm.prank(factory);
        vm.expectRevert(PermanentPancakeV3Locker.InvalidPosition.selector);
        locker.finalize(address(token1), address(token0), FEE, TICK_LOWER, TICK_UPPER);

        vm.prank(factory);
        locker.finalize(address(token0), address(token1), FEE, TICK_LOWER, TICK_UPPER);

        assertEq(locker.token0(), address(token0));
        assertEq(locker.token1(), address(token1));
        assertEq(locker.fee(), FEE);
        assertEq(locker.tickLower(), TICK_LOWER);
        assertEq(locker.tickUpper(), TICK_UPPER);
        assertTrue(locker.finalized());

        vm.prank(factory);
        vm.expectRevert(PermanentPancakeV3Locker.AlreadyFinalized.selector);
        locker.finalize(address(token0), address(token1), FEE, TICK_LOWER, TICK_UPPER);
    }

    function testCollectCreditsNetFeesAndClaimsArePullBased() external {
        _mintAndFinalize(address(token0), address(token1));
        token0.mint(address(positionManager), 100 ether);
        token1.mint(address(positionManager), 33 ether);
        positionManager.setCollectAmounts(100 ether, 33 ether);

        (uint256 amount0, uint256 amount1) = locker.collect();

        assertEq(amount0, 100 ether);
        assertEq(amount1, 33 ether);
        assertEq(locker.claimable(creator, address(token0)), 60 ether);
        assertEq(locker.claimable(treasury, address(token0)), 40 ether);
        assertEq(
            locker.claimable(creator, address(token1)),
            (33 ether * uint256(CREATOR_FEE_BPS)) / 10_000
        );
        assertEq(
            locker.claimable(creator, address(token1))
                + locker.claimable(treasury, address(token1)),
            amount1
        );

        vm.prank(attacker);
        vm.expectRevert(PermanentPancakeV3Locker.NotBeneficiary.selector);
        locker.claim(address(token0));

        vm.prank(creator);
        locker.claim(address(token0));
        vm.prank(treasury);
        locker.claim(address(token0));

        assertEq(token0.balanceOf(creator), 60 ether);
        assertEq(token0.balanceOf(treasury), 40 ether);
        assertEq(locker.claimable(creator, address(token0)), 0);
        assertEq(locker.claimable(treasury, address(token0)), 0);
    }

    function testCollectCarriesCreatorRemainderAcrossPermissionlessCollections() external {
        PermanentPancakeV3Locker roundingLocker = _newLocker(TOKEN_ID + 6, CREATOR_FEE_BPS);
        _mintAndFinalize(roundingLocker, TOKEN_ID + 6, address(token0), address(token1));

        token0.mint(address(positionManager), 1);
        token1.mint(address(positionManager), 1);
        positionManager.setCollectAmounts(1, 1);

        roundingLocker.collect();

        assertEq(roundingLocker.claimable(creator, address(token0)), 0);
        assertEq(roundingLocker.claimable(treasury, address(token0)), 1);
        assertEq(roundingLocker.creatorFeeRemainder(address(token0)), CREATOR_FEE_BPS);
        assertEq(roundingLocker.creatorFeeRemainder(address(token1)), CREATOR_FEE_BPS);

        token0.mint(address(positionManager), 1);
        positionManager.setCollectAmounts(1, 0);

        roundingLocker.collect();

        assertEq(roundingLocker.claimable(creator, address(token0)), 1);
        assertEq(roundingLocker.claimable(treasury, address(token0)), 1);
        assertEq(roundingLocker.creatorFeeRemainder(address(token0)), 2_000);
        assertEq(roundingLocker.claimable(creator, address(token1)), 0);
        assertEq(roundingLocker.claimable(treasury, address(token1)), 1);
        assertEq(roundingLocker.creatorFeeRemainder(address(token1)), CREATOR_FEE_BPS);
    }

    function testFuzzCollectConservesNetFees(
        uint128 rawAmount0,
        uint128 rawAmount1,
        uint16 rawFeeBps
    ) external {
        uint256 amount0 = bound(uint256(rawAmount0), 0, 1_000_000_000 ether);
        uint256 amount1 = bound(uint256(rawAmount1), 0, 1_000_000_000 ether);
        uint16 feeBps = uint16(bound(rawFeeBps, 0, locker.MAX_CREATOR_FEE_BPS()));
        PermanentPancakeV3Locker fuzzLocker = _newLocker(TOKEN_ID + 1, feeBps);

        positionManager.mintPosition(
            address(fuzzLocker), TOKEN_ID + 1, _position(address(token0), address(token1))
        );
        vm.prank(factory);
        fuzzLocker.finalize(address(token0), address(token1), FEE, TICK_LOWER, TICK_UPPER);

        token0.mint(address(positionManager), amount0);
        token1.mint(address(positionManager), amount1);
        positionManager.setCollectAmounts(amount0, amount1);

        (uint256 net0, uint256 net1) = fuzzLocker.collect();

        assertEq(net0, amount0);
        assertEq(net1, amount1);
        assertEq(
            fuzzLocker.claimable(creator, address(token0))
                + fuzzLocker.claimable(treasury, address(token0)),
            net0
        );
        assertEq(
            fuzzLocker.claimable(creator, address(token1))
                + fuzzLocker.claimable(treasury, address(token1)),
            net1
        );
        assertEq(fuzzLocker.claimable(creator, address(token0)), (net0 * feeBps) / 10_000);
        assertEq(fuzzLocker.claimable(creator, address(token1)), (net1 * feeBps) / 10_000);
    }

    function testCreatorFeeShareAllowsZeroAndFullRange() external {
        PermanentPancakeV3Locker zeroCreatorLocker = _newLocker(TOKEN_ID + 2, 0);
        _mintAndFinalize(zeroCreatorLocker, TOKEN_ID + 2, address(token0), address(token1));
        token0.mint(address(positionManager), 100 ether);
        positionManager.setCollectAmounts(100 ether, 0);

        zeroCreatorLocker.collect();

        assertEq(zeroCreatorLocker.claimable(creator, address(token0)), 0);
        assertEq(zeroCreatorLocker.claimable(treasury, address(token0)), 100 ether);

        PermanentPancakeV3Locker fullCreatorLocker = _newLocker(TOKEN_ID + 3, 10_000);
        _mintAndFinalize(fullCreatorLocker, TOKEN_ID + 3, address(token0), address(token1));
        token1.mint(address(positionManager), 100 ether);
        positionManager.setCollectAmounts(0, 100 ether);

        fullCreatorLocker.collect();

        assertEq(fullCreatorLocker.claimable(creator, address(token1)), 100 ether);
        assertEq(fullCreatorLocker.claimable(treasury, address(token1)), 0);
    }

    function testFeeOnTransferCollectCreditsOnlyNetReceived() external {
        FeeOnTransferToken taxedToken = new FeeOnTransferToken();
        PermanentPancakeV3Locker taxedLocker = _newLocker(TOKEN_ID + 2, CREATOR_FEE_BPS);
        _mintAndFinalize(taxedLocker, TOKEN_ID + 2, address(token0), address(taxedToken));

        taxedToken.mint(address(positionManager), 100 ether);
        positionManager.setCollectAmounts(0, 100 ether);

        (, uint256 netReceived) = taxedLocker.collect();

        assertEq(netReceived, 90 ether);
        assertEq(taxedLocker.claimable(creator, address(taxedToken)), 54 ether);
        assertEq(taxedLocker.claimable(treasury, address(taxedToken)), 36 ether);
    }

    function testClaimRejectsSenderPaysExtraTokenDebit() external {
        SenderPaysExtraToken extraToken = new SenderPaysExtraToken();
        PermanentPancakeV3Locker extraLocker = _newLocker(TOKEN_ID + 6, CREATOR_FEE_BPS);
        _mintAndFinalize(extraLocker, TOKEN_ID + 6, address(token0), address(extraToken));

        extraToken.mint(address(positionManager), 200 ether);
        positionManager.setCollectAmounts(0, 100 ether);
        extraLocker.collect();

        vm.expectRevert(
            abi.encodeWithSelector(
                PermanentPancakeV3Locker.BadClaimDebit.selector, 60 ether, 66 ether
            )
        );
        vm.prank(creator);
        extraLocker.claim(address(extraToken));

        assertEq(extraLocker.claimable(creator, address(extraToken)), 60 ether);
        assertEq(extraLocker.claimable(treasury, address(extraToken)), 40 ether);
        assertEq(extraToken.balanceOf(address(extraLocker)), 100 ether);
        assertEq(extraToken.balanceOf(creator), 0);
    }

    function testFalseReturnTokenCannotCreatePhantomClaims() external {
        FalseReturnToken falseToken = new FalseReturnToken();
        PermanentPancakeV3Locker falseLocker = _newLocker(TOKEN_ID + 3, CREATOR_FEE_BPS);
        _mintAndFinalize(falseLocker, TOKEN_ID + 3, address(token0), address(falseToken));

        falseToken.mint(address(positionManager), 100 ether);
        positionManager.setCollectAmounts(0, 100 ether);

        (, uint256 netReceived) = falseLocker.collect();

        assertEq(netReceived, 0);
        assertEq(falseLocker.claimable(creator, address(falseToken)), 0);
        assertEq(falseLocker.claimable(treasury, address(falseToken)), 0);
    }

    function testClaimUsesSafeTransfer() external {
        ToggleReturnToken toggleToken = new ToggleReturnToken();
        PermanentPancakeV3Locker toggleLocker = _newLocker(TOKEN_ID + 4, CREATOR_FEE_BPS);
        _mintAndFinalize(toggleLocker, TOKEN_ID + 4, address(token0), address(toggleToken));

        toggleToken.mint(address(positionManager), 100 ether);
        positionManager.setCollectAmounts(0, 100 ether);
        toggleLocker.collect();

        toggleToken.setReturnsFalse(true);
        vm.prank(creator);
        vm.expectRevert();
        toggleLocker.claim(address(toggleToken));

        assertEq(toggleToken.balanceOf(creator), 0);
        assertEq(toggleLocker.claimable(creator, address(toggleToken)), 60 ether);
    }

    function testClaimBlocksReentrantCollection() external {
        ReentrantToken reentrantToken = new ReentrantToken();
        PermanentPancakeV3Locker reentrantLocker = _newLocker(TOKEN_ID + 5, CREATOR_FEE_BPS);
        _mintAndFinalize(reentrantLocker, TOKEN_ID + 5, address(reentrantToken), address(token1));

        reentrantToken.mint(address(positionManager), 100 ether);
        positionManager.setCollectAmounts(100 ether, 0);
        reentrantLocker.collect();
        assertEq(positionManager.collectCalls(), 1);

        reentrantToken.setReentry(address(reentrantLocker), true);
        vm.prank(creator);
        reentrantLocker.claim(address(reentrantToken));

        assertTrue(reentrantToken.reentryBlocked());
        assertEq(positionManager.collectCalls(), 1);
        assertEq(reentrantToken.balanceOf(creator), 60 ether);
    }

    function testCollectAndClaimRequireFinalizedPosition() external {
        vm.expectRevert(PermanentPancakeV3Locker.InvalidPosition.selector);
        locker.collect();

        positionManager.mintPosition(
            address(locker), TOKEN_ID, _position(address(token0), address(token1))
        );

        vm.expectRevert(PermanentPancakeV3Locker.InvalidPosition.selector);
        locker.collect();

        vm.prank(creator);
        vm.expectRevert(PermanentPancakeV3Locker.InvalidPosition.selector);
        locker.claim(address(token0));
    }

    function testAbsentPrincipalApprovalAndArbitraryCallSelectors() external {
        _mintAndFinalize(address(token0), address(token1));

        _assertMissing(bytes4(keccak256("approve(address,uint256)")));
        _assertMissing(bytes4(keccak256("setApprovalForAll(address,bool)")));
        _assertMissing(bytes4(keccak256("transferFrom(address,address,uint256)")));
        _assertMissing(bytes4(keccak256("safeTransferFrom(address,address,uint256)")));
        _assertMissing(bytes4(keccak256("safeTransferFrom(address,address,uint256,bytes)")));
        _assertMissing(
            bytes4(keccak256("decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))"))
        );
        _assertMissing(bytes4(keccak256("burn(uint256)")));
        _assertMissing(bytes4(keccak256("execute(address,uint256,bytes)")));
        _assertMissing(bytes4(keccak256("multicall(bytes[])")));
    }

    function _newLocker(uint256 tokenId, uint16 creatorFeeBps)
        internal
        returns (PermanentPancakeV3Locker)
    {
        return new PermanentPancakeV3Locker(
            INonfungiblePositionManager(address(positionManager)),
            factory,
            creator,
            treasury,
            creatorFeeBps,
            tokenId
        );
    }

    function _mintAndFinalize(address token0_, address token1_) internal {
        _mintAndFinalize(locker, TOKEN_ID, token0_, token1_);
    }

    function _mintAndFinalize(
        PermanentPancakeV3Locker locker_,
        uint256 tokenId,
        address token0_,
        address token1_
    ) internal {
        positionManager.mintPosition(address(locker_), tokenId, _position(token0_, token1_));
        vm.prank(factory);
        locker_.finalize(token0_, token1_, FEE, TICK_LOWER, TICK_UPPER);
    }

    function _position(address token0_, address token1_)
        internal
        pure
        returns (MockPositionManager.PositionData memory)
    {
        return MockPositionManager.PositionData({
            token0: token0_,
            token1: token1_,
            fee: FEE,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidity: 1_000
        });
    }

    function _assertMissing(bytes4 selector) internal {
        (bool ok,) = address(locker).call(abi.encodeWithSelector(selector));
        assertFalse(ok);
    }
}
