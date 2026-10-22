// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {StoreFixture, HookListingRegistry, FeaturedPlacementsV2, TestToken} from "./helpers/StoreFixture.sol";

/// @dev Generates valid interleavings so failures are meaningful, not a stream of authorization reverts.
contract FeaturedHandler is Test {
    FeaturedPlacementsV2 public ads;
    HookListingRegistry public registry;
    TestToken public token;
    address[2] public actors;
    address[2] public recipients;
    uint256[2] public listings;
    uint256 public deposited;
    uint256 public withdrawn;
    uint256 public claimed;
    uint256 public boosted;
    mapping(uint256 => uint256) public recordedBoost;
    uint256 internal constant PRICE = 0.1 ether;

    constructor(FeaturedPlacementsV2 ads_, TestToken token_, address[2] memory actors_, address[2] memory recipients_) {
        ads = ads_;
        registry = ads_.registry();
        token = token_;
        actors = actors_;
        recipients = recipients_;
        listings = [uint256(1), 2];
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 2];
        amount = bound(amount, 1, 3 * PRICE);
        token.mint(actor, amount);
        vm.startPrank(actor);
        token.approve(address(ads), amount);
        ads.deposit(amount);
        vm.stopPrank();
        deposited += amount;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 2];
        uint256 credit = ads.available(actor);
        if (credit == 0) return;
        amount = bound(amount, 1, credit);
        vm.prank(actor);
        ads.withdraw(amount, actor);
        withdrawn += amount;
    }

    function purchase(uint256 actorSeed) external {
        // Bound history size so all records can be checked after every action without quadratic test cost.
        if (ads.placementCount() >= 30) return;
        uint256 index = actorSeed % 2;
        address actor = actors[index];
        uint256 listingId = listings[index];
        if (ads.available(actor) < PRICE || ads.isActive(ads.latestPlacement(listingId))) return;
        HookListingRegistry.Listing memory listing = registry.getListing(listingId);
        if (!listing.active) return;
        address recipient = ads.proceedsRecipient();
        vm.prank(actor);
        ads.purchase(listingId, listing.revision, recipient, vm.getBlockTimestamp());
    }

    function cancel(uint256 idSeed) external {
        uint256 count = ads.placementCount();
        if (count == 0) return;
        uint256 id = 1 + idSeed % count;
        FeaturedPlacementsV2.Placement memory item = ads.getPlacement(id);
        if (!ads.isActive(id)) return;
        vm.prank(item.payer);
        ads.cancel(id);
    }

    function boost(uint256 actorSeed, uint256 idSeed, uint256 amount) external {
        uint256 count = ads.placementCount();
        if (count == 0) return;
        uint256 id = 1 + idSeed % count;
        address actor = actors[actorSeed % 2];
        uint256 credit = ads.available(actor);
        if (!ads.isActive(id) || credit == 0) return;
        amount = bound(amount, 1, credit);
        vm.prank(actor);
        ads.boost(id, amount);
        // Independent record of successful input amounts, including boosts from non-payers.
        recordedBoost[id] += amount;
        boosted += amount;
    }

    function settle(uint256 idSeed) external {
        uint256 count = ads.placementCount();
        if (count == 0) return;
        uint256 id = 1 + idSeed % count;
        FeaturedPlacementsV2.Placement memory item = ads.getPlacement(id);
        if (item.status != FeaturedPlacementsV2.Status.Open || vm.getBlockTimestamp() < item.endsAt) return;
        ads.settle(id);
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 2 days));
    }

    function rotateRecipient(uint256 recipientSeed) external {
        ads.setProceedsRecipient(recipients[recipientSeed % 2]);
    }

    function claim(uint256 recipientSeed, uint256 amount) external {
        address recipient = recipients[recipientSeed % 2];
        uint256 credit = ads.proceeds(recipient);
        if (credit == 0) return;
        amount = bound(amount, 1, credit);
        vm.prank(recipient);
        ads.withdrawProceeds(amount, recipient);
        claimed += amount;
    }

    function toggleListing(uint256 actorSeed, bool active) external {
        uint256 index = actorSeed % 2;
        vm.prank(actors[index]);
        registry.setListingActive(listings[index], active);
    }
}

contract FeaturedInvariantTest is StdInvariant, StoreFixture {
    FeaturedHandler internal handler;

    function setUp() public virtual override {
        super.setUp();
        _create(alice);
        _create(bob);
        handler = new FeaturedHandler(ads, token, [alice, bob], [treasury, nextTreasury]);
        ads.transferOwnership(address(handler));
        vm.prank(address(handler));
        ads.acceptOwnership();
        _seedBoosts();
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = FeaturedHandler.deposit.selector;
        selectors[1] = FeaturedHandler.withdraw.selector;
        selectors[2] = FeaturedHandler.purchase.selector;
        selectors[3] = FeaturedHandler.cancel.selector;
        selectors[4] = FeaturedHandler.settle.selector;
        selectors[5] = FeaturedHandler.advanceTime.selector;
        selectors[6] = FeaturedHandler.rotateRecipient.selector;
        selectors[7] = FeaturedHandler.claim.selector;
        selectors[8] = FeaturedHandler.toggleListing.selector;
        selectors[9] = FeaturedHandler.boost.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function _seedBoosts() internal {
        // Every generated sequence starts with both active ads and third-party boosts.
        handler.deposit(0, 3 * PRICE);
        handler.deposit(1, 3 * PRICE);
        handler.purchase(0);
        handler.purchase(1);
        handler.boost(1, 0, PRICE / 2);
        handler.boost(0, 1, PRICE / 2);
    }

    function invariantEveryTokenIsAccountedForAndEveryCreditHasBacking() public view {
        _assertSolvent();
        assertEq(ads.totalAvailable(), ads.available(alice) + ads.available(bob));
        assertEq(ads.totalProceeds(), ads.proceeds(treasury) + ads.proceeds(nextTreasury));
        assertEq(handler.deposited(), token.balanceOf(address(ads)) + handler.withdrawn() + handler.claimed());
        assertEq(handler.claimed(), token.balanceOf(treasury) + token.balanceOf(nextTreasury));
        uint256 locked;
        uint256 earned;
        uint256 boosts;
        uint256[2] memory livePerListing;
        for (uint256 id = 1; id <= ads.placementCount(); ++id) {
            FeaturedPlacementsV2.Placement memory item = ads.getPlacement(id);
            uint256 boostTotal = handler.recordedBoost(id);
            boosts += boostTotal;
            assertEq(ads.totalBoost(id), boostTotal);
            assertEq(ads.rankOf(id), PRICE + boostTotal);
            assertEq(item.label, bytes3("#ad"));
            assertEq(item.endsAt - item.startsAt, DURATION);
            assertTrue(item.recipient == treasury || item.recipient == nextTreasury);
            if (item.status == FeaturedPlacementsV2.Status.Open) {
                locked += PRICE + boostTotal;
                assertEq(item.refund, 0);
                if (ads.isActive(id)) ++livePerListing[item.listingId - 1];
            } else if (item.status == FeaturedPlacementsV2.Status.Cancelled) {
                assertLt(item.closedAt, item.endsAt);
                assertEq(item.refund, PRICE - PRICE * (item.closedAt - item.startsAt) / DURATION);
                earned += PRICE - item.refund + boostTotal;
                assertFalse(ads.isActive(id));
            } else {
                assertEq(uint256(item.status), uint256(FeaturedPlacementsV2.Status.Settled));
                assertGe(item.closedAt, item.endsAt);
                assertEq(item.refund, 0);
                earned += PRICE + boostTotal;
                assertFalse(ads.isActive(id));
            }
        }
        assertEq(locked, ads.totalEscrowed());
        assertEq(earned, ads.totalProceeds() + handler.claimed());
        assertEq(boosts, handler.boosted());
        assertGt(boosts, 0, "boost accounting is exercised in every sequence");
        assertLe(livePerListing[0], 1);
        assertLe(livePerListing[1], 1);

        (FeaturedPlacementsV2.Placement[] memory page, uint256[] memory totals, uint256 next) = ads.featured(1, 100);
        assertEq(next, ads.placementCount() + 1);
        assertEq(page.length, livePerListing[0] + livePerListing[1]);
        assertEq(totals.length, page.length);
        for (uint256 i; i < page.length; ++i) {
            assertTrue(ads.isActive(page[i].id));
            assertEq(page[i].label, bytes3("#ad"));
            assertEq(totals[i], PRICE + handler.recordedBoost(page[i].id));
            if (i != 0) assertGt(page[i].id, page[i - 1].id);
        }
    }

    /// @dev Every generated sequence can wind down without admin cooperation or any remaining locked funds.
    function afterInvariant() public {
        vm.warp(vm.getBlockTimestamp() + DURATION);
        for (uint256 id = 1; id <= ads.placementCount(); ++id) {
            if (ads.getPlacement(id).status == FeaturedPlacementsV2.Status.Open) ads.settle(id);
        }
        address[4] memory accounts = [alice, bob, treasury, nextTreasury];
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            uint256 credit = ads.available(account);
            uint256 earned = ads.proceeds(account);
            vm.startPrank(account);
            if (credit != 0) ads.withdraw(credit, account);
            if (earned != 0) ads.withdrawProceeds(earned, account);
            vm.stopPrank();
        }
        assertEq(ads.accountedBalance(), 0);
        assertEq(token.balanceOf(address(ads)), 0);
    }
}
