// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StoreFixture, FeaturedPlacementsV2, HookListingRegistry} from "./helpers/StoreFixture.sol";
import {StoreAdmin} from "../src/store/StoreAdmin.sol";

contract FeaturedBoostEdgesTest is StoreFixture {
    address internal carol;

    function setUp() public override {
        super.setUp();
        carol = makeAddr("third-party booster Carol");
    }

    function testProceedsCannotFundBoostsAndDepositsCannotBeClaimedAsProceeds() public {
        (uint256 id,) = _fundedAd();
        vm.warp(START + DURATION);
        ads.settle(id);
        assertEq(ads.proceeds(treasury), PRICE);
        uint256 second = _purchaseFresh(bob);
        vm.prank(treasury);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.boost(second, 1);
        // A booster's unspent deposit is not a proceeds credit.
        _deposit(carol, PRICE);
        vm.prank(carol);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.withdrawProceeds(1, carol);
        assertEq(ads.totalBoost(second), 0);
        assertEq(ads.proceeds(treasury), PRICE);
        _assertSolvent();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzBoostSpendsUpToExactlyTheAvailableBalance(uint256 deposited, uint256 amount) public {
        (uint256 id,) = _fundedAd();
        deposited = bound(deposited, 1, 1_000_000 ether);
        amount = bound(amount, 1, deposited + 1);
        _deposit(carol, deposited);
        vm.prank(carol);
        if (amount > deposited) {
            vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
            ads.boost(id, amount);
            assertEq(ads.totalBoost(id), 0);
            assertEq(ads.available(carol), deposited);
        } else {
            ads.boost(id, amount);
            assertEq(ads.totalBoost(id), amount);
            assertEq(ads.available(carol), deposited - amount);
            assertEq(ads.rankOf(id), PRICE + amount);
        }
        assertEq(ads.totalEscrowed(), PRICE + ads.totalBoost(id));
        _assertSolvent();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzNewListingOwnerCancelForfeitsThirdPartyBoostAndRefundsSellerBase(
        uint256 elapsed,
        uint256 boostAmount
    ) public {
        (uint256 id, uint256 listingId) = _fundedAd();
        elapsed = bound(elapsed, 0, DURATION - 1);
        boostAmount = bound(boostAmount, 1, 1_000_000 ether);
        _deposit(carol, boostAmount);
        vm.prank(carol);
        ads.boost(id, boostAmount);
        vm.prank(alice);
        registry.proposeListingOwner(listingId, bob);
        vm.prank(bob);
        registry.acceptListingOwnership(listingId);
        vm.warp(START + elapsed);
        vm.prank(bob);
        uint256 refund = ads.cancel(id);
        uint256 earnedBase = PRICE * elapsed / DURATION;
        assertEq(refund, PRICE - earnedBase);
        assertEq(ads.available(alice), refund, "refund goes to the original payer");
        assertEq(ads.available(bob), 0);
        assertEq(ads.available(carol), 0, "boost is never refunded");
        assertEq(ads.proceeds(treasury), earnedBase + boostAmount);
        assertEq(ads.totalEscrowed(), 0);
        assertEq(ads.rankOf(id), PRICE + boostAmount, "historical total stays readable");
        _assertSolvent();
    }

    function testCarolCannotCancelOrSettleEarlyAfterBoostingAndOwnerHasNoPlacementPowers() public {
        (uint256 id,) = _fundedAd();
        _deposit(carol, PRICE);
        vm.prank(carol);
        ads.boost(id, PRICE);
        vm.prank(carol);
        vm.expectRevert(FeaturedPlacementsV2.NotPayer.selector);
        ads.cancel(id);
        vm.expectRevert(FeaturedPlacementsV2.NotPayer.selector);
        ads.cancel(id); // the contract owner is not a payer or listing owner
        vm.warp(START + DURATION - 1);
        vm.prank(carol);
        vm.expectRevert(FeaturedPlacementsV2.PlacementNotExpired.selector);
        ads.settle(id);
        vm.warp(START + DURATION);
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.PlacementExpired.selector);
        ads.cancel(id);
        vm.prank(carol);
        ads.settle(id);
        assertEq(ads.proceeds(treasury), 2 * PRICE);
        assertEq(ads.available(carol), 0);
        _assertSolvent();
    }

    function testPendingAndFormerOwnersCannotUseOwnerPowers() public {
        FeaturedPlacementsV2 fresh = new FeaturedPlacementsV2(alice, registry);
        assertEq(fresh.owner(), alice);
        vm.prank(alice);
        fresh.transferOwnership(bob);
        vm.startPrank(bob);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        fresh.configureToken(address(token));
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        fresh.setProceedsRecipient(bob);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        fresh.transferOwnership(carol);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        fresh.cancelOwnershipTransfer();
        fresh.acceptOwnership();
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        fresh.configureToken(address(token));
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        fresh.setProceedsRecipient(alice);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        fresh.transferOwnership(alice);
        vm.expectRevert(StoreAdmin.NotPendingOwner.selector);
        fresh.acceptOwnership();
        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert(StoreAdmin.InvalidAddress.selector);
        fresh.transferOwnership(address(0));
        vm.expectRevert(StoreAdmin.InvalidAddress.selector);
        fresh.transferOwnership(address(fresh));
        vm.expectRevert(StoreAdmin.InvalidAddress.selector);
        fresh.setProceedsRecipient(address(fresh));
        fresh.configureToken(address(token));
        fresh.setProceedsRecipient(bob);
        vm.stopPrank();
        assertEq(fresh.imd(), address(token));
        assertEq(fresh.proceedsRecipient(), bob);
    }

    function testBoostAfterListingArchivedStillCountsAndFeaturedShowsTotal() public {
        (uint256 id, uint256 listingId) = _fundedAd();
        vm.prank(alice);
        registry.setListingActive(listingId, false);
        _deposit(carol, PRICE);
        vm.expectEmit(true, true, false, true, address(ads));
        emit FeaturedPlacementsV2.PlacementBoosted(id, carol, PRICE, 2 * PRICE, bytes3("#ad"));
        vm.prank(carol);
        ads.boost(id, PRICE);
        (FeaturedPlacementsV2.Placement[] memory page, uint256[] memory totals,) = ads.featured(1, 100);
        assertEq(page.length, 1);
        assertEq(totals[0], 2 * PRICE);
        assertEq(page[0].label, bytes3("#ad"));
        // A deactivated listing cannot be renewed after this placement closes.
        vm.warp(START + DURATION);
        _deposit(alice, PRICE);
        uint256 revision = registry.getListing(listingId).revision;
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.ListingInactive.selector);
        ads.purchase(listingId, revision, treasury, START + DURATION);
        _assertSolvent();
    }

    function _purchaseFresh(address actor) internal returns (uint256) {
        vm.prank(actor);
        uint256 listingId = registry.createListing(4663, hook, _metadata());
        _deposit(actor, PRICE);
        return _purchase(actor, listingId);
    }
}
