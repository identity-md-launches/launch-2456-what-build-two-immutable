// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StoreFixture, FeaturedPlacementsV2, HookListingRegistry} from "./helpers/StoreFixture.sol";

contract FeaturedBoostTest is StoreFixture {
    function _boost(address actor, uint256 id, uint256 amount) internal {
        vm.prank(actor);
        ads.boost(id, amount);
    }

    function testThirdPartyBoostUsesOnlyItsOwnDepositAndDoesNotChangeTerms() public {
        (uint256 id,) = _fundedAd();
        _deposit(bob, 3 * PRICE);
        FeaturedPlacementsV2.Placement memory beforeBoost = ads.getPlacement(id);
        uint256 backing = token.balanceOf(address(ads));
        // There is no remaining allowance after deposit, and boost must not pull from a wallet.
        assertEq(token.allowance(bob, address(ads)), 0);
        vm.expectEmit(true, true, false, true, address(ads));
        emit FeaturedPlacementsV2.PlacementBoosted(id, bob, 2 * PRICE, 3 * PRICE, bytes3("#ad"));
        _boost(bob, id, 2 * PRICE);
        assertEq(ads.available(bob), PRICE);
        assertEq(ads.available(alice), 0);
        assertEq(ads.totalAvailable(), PRICE);
        assertEq(ads.totalEscrowed(), 3 * PRICE);
        assertEq(ads.totalBoost(id), 2 * PRICE);
        assertEq(ads.rankOf(id), 3 * PRICE);
        assertEq(token.balanceOf(address(ads)), backing);
        assertEq(abi.encode(ads.getPlacement(id)), abi.encode(beforeBoost));
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacementsV2.NotPayer.selector);
        ads.cancel(id);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.withdraw(PRICE + 1, bob);
        _assertSolvent();
    }

    function testRepeatedBoostsFromPayerAndThirdPartyAccumulateWithoutExtendingExpiry() public {
        (uint256 id,) = _fundedAd();
        _deposit(alice, 2 * PRICE);
        _deposit(bob, 4 * PRICE);
        _boost(alice, id, PRICE);
        vm.warp(START + DURATION / 2);
        _boost(bob, id, PRICE);
        _boost(bob, id, 3 * PRICE);
        _boost(alice, id, PRICE);
        assertEq(ads.totalBoost(id), 6 * PRICE);
        assertEq(ads.rankOf(id), 7 * PRICE);
        assertEq(ads.getPlacement(id).endsAt, START + DURATION);
        assertEq(ads.totalAvailable(), 0);
        assertEq(ads.totalEscrowed(), 7 * PRICE);
        assertEq(ads.totalProceeds(), 0);
        _assertSolvent();
    }

    function testImmediateCancellationRefundsOnlyBaseAndForfeitsAllBoostToPinnedRecipient() public {
        (uint256 id,) = _fundedAd();
        // Rotation before a boost must not redirect either component of an existing placement.
        ads.setProceedsRecipient(nextTreasury);
        _deposit(bob, 2 * PRICE);
        _boost(bob, id, 2 * PRICE);
        vm.expectEmit(true, false, false, true, address(ads));
        emit FeaturedPlacementsV2.PlacementCancelled(id, PRICE, 2 * PRICE, bytes3("#ad"));
        vm.prank(alice);
        assertEq(ads.cancel(id), PRICE);
        assertEq(ads.available(alice), PRICE);
        assertEq(ads.available(bob), 0);
        assertEq(ads.proceeds(treasury), 2 * PRICE);
        assertEq(ads.proceeds(nextTreasury), 0);
        assertEq(ads.totalEscrowed(), 0);
        assertEq(ads.totalBoost(id), 2 * PRICE);
        assertEq(ads.rankOf(id), 3 * PRICE, "historical total is retained");
        vm.prank(treasury);
        ads.withdrawProceeds(2 * PRICE, treasury);
        vm.prank(alice);
        ads.withdraw(PRICE, alice);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(treasury), 2 * PRICE);
        assertEq(ads.accountedBalance(), 0);
        _assertSolvent();
    }

    function testNewListingOwnerCancelsBoostedAdButRefundStillBelongsToOriginalPayer() public {
        (uint256 id, uint256 listingId) = _fundedAd();
        _deposit(bob, PRICE);
        _boost(bob, id, PRICE);
        vm.prank(alice);
        registry.proposeListingOwner(listingId, bob);
        vm.prank(bob);
        registry.acceptListingOwnership(listingId);
        vm.warp(START + DURATION / 2);
        vm.prank(bob);
        assertEq(ads.cancel(id), PRICE / 2);
        assertEq(ads.available(alice), PRICE / 2);
        assertEq(ads.available(bob), 0);
        assertEq(ads.proceeds(treasury), PRICE + PRICE / 2);
        _assertSolvent();
    }

    function testFuzzCancellationConservesMultipleBoostsAndPreservesBaseRounding(
        uint256 payerBoost,
        uint256 thirdPartyBoost,
        uint256 elapsed
    ) public {
        payerBoost = bound(payerBoost, 1, 1e30);
        thirdPartyBoost = bound(thirdPartyBoost, 1, 1e30);
        elapsed = bound(elapsed, 0, DURATION - 1);
        (uint256 id,) = _fundedAd();
        _deposit(alice, payerBoost);
        _deposit(bob, thirdPartyBoost);
        _boost(alice, id, payerBoost);
        _boost(bob, id, thirdPartyBoost);
        uint256 boostTotal = payerBoost + thirdPartyBoost;
        assertEq(ads.totalEscrowed(), PRICE + boostTotal);
        _assertSolvent();
        vm.warp(START + elapsed);
        vm.prank(alice);
        uint256 refund = ads.cancel(id);
        uint256 baseEarned = PRICE * elapsed / DURATION;
        assertEq(refund, PRICE - baseEarned);
        assertEq(ads.proceeds(treasury), baseEarned + boostTotal);
        assertEq(refund + ads.proceeds(treasury), PRICE + boostTotal);
        assertEq(ads.available(bob), 0);
        assertEq(ads.totalEscrowed(), 0);
        assertEq(ads.getPlacement(id).refund, refund);
        assertEq(ads.getPlacement(id).closedAt, START + elapsed);
        vm.prank(alice);
        ads.withdraw(refund, alice);
        vm.prank(treasury);
        ads.withdrawProceeds(baseEarned + boostTotal, treasury);
        assertEq(ads.accountedBalance(), 0);
        _assertSolvent();
    }

    function testPermissionlessSettlementAtExpiryPaysBaseAndBoostToPinnedRecipient() public {
        (uint256 id,) = _fundedAd();
        _deposit(bob, 7 * PRICE);
        _boost(bob, id, 7 * PRICE);
        ads.setProceedsRecipient(nextTreasury);
        vm.prank(treasury);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.withdrawProceeds(1, treasury);
        vm.warp(START + DURATION);
        vm.expectEmit(true, true, false, true, address(ads));
        emit FeaturedPlacementsV2.PlacementSettled(id, treasury, 8 * PRICE, bytes3("#ad"));
        vm.prank(bob);
        ads.settle(id);
        assertEq(ads.proceeds(treasury), 8 * PRICE);
        assertEq(ads.proceeds(nextTreasury), 0);
        assertEq(ads.totalEscrowed(), 0);
        assertEq(ads.available(alice), 0);
        assertEq(ads.available(bob), 0);
        assertEq(ads.getPlacement(id).refund, 0);
        assertEq(ads.rankOf(id), 8 * PRICE);
        vm.prank(treasury);
        ads.withdrawProceeds(8 * PRICE, treasury);
        _assertSolvent();
    }

    function testBoostRejectsUnknownZeroAndInsufficientWithoutChangingCredits() public {
        _deposit(bob, PRICE);
        vm.startPrank(bob);
        vm.expectRevert(FeaturedPlacementsV2.UnknownPlacement.selector);
        ads.boost(0, 1);
        vm.expectRevert(FeaturedPlacementsV2.UnknownPlacement.selector);
        ads.boost(1, 1);
        vm.expectRevert(FeaturedPlacementsV2.UnknownPlacement.selector);
        ads.rankOf(0);
        vm.expectRevert(FeaturedPlacementsV2.UnknownPlacement.selector);
        ads.rankOf(type(uint256).max);
        vm.stopPrank();
        (uint256 id,) = _fundedAd();
        vm.startPrank(bob);
        vm.expectRevert(FeaturedPlacementsV2.InvalidAmount.selector);
        ads.boost(id, 0);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.boost(id, PRICE + 1);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.boost(id, 1);
        assertEq(ads.available(bob), PRICE);
        assertEq(ads.available(alice), 0);
        assertEq(ads.totalBoost(id), 0);
        assertEq(ads.rankOf(id), PRICE);
        assertEq(ads.totalEscrowed(), PRICE);
        _assertSolvent();
    }

    function testBoostLastSecondSucceedsButAtExpiryAndAfterSettlementFails() public {
        (uint256 id,) = _fundedAd();
        _deposit(bob, PRICE);
        vm.warp(START + DURATION - 1);
        _boost(bob, id, 1);
        vm.warp(START + DURATION);
        vm.startPrank(bob);
        vm.expectRevert(FeaturedPlacementsV2.PlacementExpired.selector);
        ads.boost(id, 1);
        vm.stopPrank();
        assertEq(uint256(ads.getPlacement(id).status), uint256(FeaturedPlacementsV2.Status.Open));
        assertFalse(ads.isActive(id));
        assertEq(ads.totalEscrowed(), PRICE + 1);
        (FeaturedPlacementsV2.Placement[] memory page, uint256[] memory totals,) = ads.featured(1, 100);
        assertEq(page.length, 0);
        assertEq(totals.length, 0);
        ads.settle(id);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacementsV2.PlacementClosed.selector);
        ads.boost(id, 1);
        assertEq(ads.totalBoost(id), 1);
        assertEq(ads.available(bob), PRICE - 1);
        _assertSolvent();
    }

    function testCancelledBoostCannotBeRepeatedRefundedOrMovedToReplacement() public {
        (uint256 first, uint256 listingId) = _fundedAd();
        _deposit(bob, 2 * PRICE);
        _boost(bob, first, PRICE);
        vm.prank(alice);
        ads.cancel(first);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacementsV2.PlacementClosed.selector);
        ads.boost(first, 1);
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.PlacementClosed.selector);
        ads.cancel(first);
        vm.expectRevert(FeaturedPlacementsV2.PlacementClosed.selector);
        ads.settle(first);
        uint256 second = _purchase(alice, listingId);
        assertEq(ads.totalBoost(second), 0);
        assertEq(ads.rankOf(second), PRICE);
        _boost(bob, second, PRICE);
        assertEq(ads.totalBoost(first), PRICE);
        assertEq(ads.totalBoost(second), PRICE);
        assertEq(ads.totalEscrowed(), 2 * PRICE);
        assertEq(ads.proceeds(treasury), PRICE);
        _assertSolvent();
    }

    function testRenewalBeforeOldSettlementKeepsBoostsAndRecipientsSeparate() public {
        (uint256 first, uint256 listingId) = _fundedAd();
        _deposit(bob, 4 * PRICE);
        _boost(bob, first, 3 * PRICE);
        _deposit(alice, PRICE);
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.AlreadyFeatured.selector);
        ads.purchase(listingId, 1, treasury, START);
        vm.warp(START + DURATION);
        ads.setProceedsRecipient(nextTreasury);
        uint256 second = _purchase(alice, listingId);
        _boost(bob, second, PRICE);
        assertEq(ads.totalEscrowed(), 6 * PRICE);
        ads.settle(first);
        assertTrue(ads.isActive(second));
        assertEq(ads.latestPlacement(listingId), second);
        assertEq(ads.totalEscrowed(), 2 * PRICE);
        assertEq(ads.proceeds(treasury), 4 * PRICE);
        vm.prank(alice);
        ads.cancel(second);
        assertEq(ads.proceeds(nextTreasury), PRICE);
        assertEq(ads.available(alice), PRICE);
        _assertSolvent();
    }

    function testBoostUsesPurchasedSnapshotAfterListingEditArchiveAndTransfer() public {
        (uint256 id, uint256 listingId) = _fundedAd();
        HookListingRegistry.Metadata memory changed = _metadata();
        changed.name = "Changed after purchase";
        vm.startPrank(alice);
        registry.updateListing(listingId, changed);
        registry.setListingActive(listingId, false);
        registry.proposeListingOwner(listingId, bob);
        vm.stopPrank();
        vm.prank(bob);
        registry.acceptListingOwnership(listingId);
        _deposit(bob, PRICE);
        _boost(bob, id, PRICE);
        (FeaturedPlacementsV2.Placement[] memory page, uint256[] memory totals,) = ads.featured(1, 1);
        assertEq(page.length, 1);
        assertEq(page[0].revision, 1);
        assertEq(page[0].payer, alice);
        assertEq(page[0].label, bytes3("#ad"));
        assertEq(totals[0], 2 * PRICE);
        _assertSolvent();
    }

    function testRankingTotalsSupportDescendingSortAndLowerIdWinsBothKindsOfTie() public {
        (uint256 first,) = _fundedAd();
        uint256 secondListing = _create(bob);
        _deposit(bob, 2 * PRICE);
        uint256 second = _purchase(bob, secondListing);
        address carol = makeAddr("third listing for ranking");
        uint256 thirdListing = _create(carol);
        _deposit(carol, 3 * PRICE);
        uint256 third = _purchase(carol, thirdListing);
        _boost(carol, third, 2 * PRICE);
        (FeaturedPlacementsV2.Placement[] memory page, uint256[] memory totals, uint256 next) = ads.featured(1, 100);
        assertEq(next, 4);
        assertEq(page.length, totals.length);
        assertEq(page[0].id, first, "scanning remains in ID order");
        assertEq(page[1].id, second);
        assertEq(page[2].id, third);
        assertEq(totals[0], PRICE);
        assertEq(totals[1], PRICE);
        assertEq(totals[2], 3 * PRICE);
        uint256[] memory sorted = _rankedIds(page, totals);
        assertEq(sorted[0], third);
        assertEq(sorted[1], first);
        assertEq(sorted[2], second);
        _deposit(alice, PRICE);
        _boost(alice, first, PRICE);
        _boost(bob, second, PRICE);
        (page, totals,) = ads.featured(1, 100);
        assertEq(totals[0], 2 * PRICE);
        assertEq(totals[1], 2 * PRICE);
        sorted = _rankedIds(page, totals);
        assertEq(sorted[0], third);
        assertEq(sorted[1], first);
        assertEq(sorted[2], second);
        _assertSolvent();
    }

    function testFeaturedPaginationKeepsTotalsAlignedAcrossGapsAndTerminalPages() public {
        (uint256 first,) = _fundedAd();
        uint256 listingId = _create(bob);
        _deposit(bob, 4 * PRICE);
        uint256 second = _purchase(bob, listingId);
        _boost(bob, first, PRICE);
        _boost(bob, second, 2 * PRICE);
        vm.prank(alice);
        ads.cancel(first);
        (FeaturedPlacementsV2.Placement[] memory page, uint256[] memory totals, uint256 next) = ads.featured(1, 1);
        assertEq(page.length, 0);
        assertEq(totals.length, 0);
        assertEq(next, 2);
        (page, totals, next) = ads.featured(next, 1);
        assertEq(page.length, 1);
        assertEq(totals.length, 1);
        assertEq(page[0].id, second);
        assertEq(totals[0], 3 * PRICE);
        assertEq(totals[0], ads.rankOf(second));
        assertEq(next, 3);
        (page, totals, next) = ads.featured(next, 100);
        assertEq(page.length, 0);
        assertEq(totals.length, 0);
        assertEq(next, 3);
        vm.warp(START + DURATION);
        (page, totals, next) = ads.featured(1, 100);
        assertEq(page.length, 0);
        assertEq(totals.length, 0);
        assertEq(next, 3);
        _assertSolvent();
    }

    function testEmptyRegistryFeaturedReturnsTwoEmptyArrays() public view {
        (FeaturedPlacementsV2.Placement[] memory page, uint256[] memory totals, uint256 next) = ads.featured(1, 100);
        assertEq(page.length, 0);
        assertEq(totals.length, 0);
        assertEq(next, 1);
    }

    function testMaxFundedBoostCanCloseWithoutOverflow() public {
        (uint256 id,) = _fundedAd();
        uint256 amount = type(uint256).max - PRICE;
        _deposit(bob, amount);
        _boost(bob, id, amount);
        assertEq(ads.rankOf(id), type(uint256).max);
        _assertSolvent();
        vm.warp(START + DURATION / 2);
        vm.prank(alice);
        ads.cancel(id);
        assertEq(ads.proceeds(treasury), amount + PRICE / 2);
        assertEq(ads.available(alice), PRICE / 2);
        _assertSolvent();
    }

    // Example of the documented website comparator; the contract supplies bounded, unsorted pages.
    function _rankedIds(FeaturedPlacementsV2.Placement[] memory page, uint256[] memory totals)
        internal
        pure
        returns (uint256[] memory ids)
    {
        ids = new uint256[](page.length);
        for (uint256 i; i < page.length; ++i) {
            ids[i] = page[i].id;
        }
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j = i + 1; j < ids.length; ++j) {
                if (totals[j] > totals[i] || (totals[j] == totals[i] && ids[j] < ids[i])) {
                    (totals[i], totals[j]) = (totals[j], totals[i]);
                    (ids[i], ids[j]) = (ids[j], ids[i]);
                }
            }
        }
    }
}
