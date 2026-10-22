// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StoreFixture, HookListingRegistry, FeaturedPlacementsV2, TestToken} from "./helpers/StoreFixture.sol";
import {StoreAdmin} from "../src/store/StoreAdmin.sol";

contract FeaturedPlacementsV2Test is StoreFixture {
    function testDepositWithdrawBelongsToDepositorAndCannotBeSwept() public {
        _deposit(alice, 3 * PRICE);
        _deposit(bob, PRICE);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.withdraw(PRICE, address(this));
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.withdrawProceeds(PRICE, address(this));
        vm.prank(alice);
        ads.withdraw(2 * PRICE, alice);
        assertEq(token.balanceOf(alice), 2 * PRICE);
        assertEq(ads.available(alice), PRICE);
        assertEq(ads.available(bob), PRICE);
        _assertSolvent();
    }

    function testPurchaseCostsExactlyPointOneImdAndHasTwentyFourHourAdLabel() public {
        (uint256 id, uint256 listingId) = _fundedAd();
        FeaturedPlacementsV2.Placement memory item = ads.getPlacement(id);
        assertEq(item.id, 1);
        assertEq(item.listingId, listingId);
        assertEq(item.revision, 1);
        assertEq(item.payer, alice);
        assertEq(item.recipient, treasury);
        assertEq(item.startsAt, START);
        assertEq(item.endsAt, START + 24 hours);
        assertEq(item.label, bytes3("#ad"));
        assertEq(ads.PRICE(), PRICE);
        assertEq(ads.DURATION(), DURATION);
        assertEq(ads.available(alice), 0);
        assertEq(ads.totalEscrowed(), PRICE);
        assertEq(ads.proceeds(treasury), 0);
        assertTrue(ads.isActive(id));
        vm.warp(START + DURATION - 1);
        assertTrue(ads.isActive(id));
        vm.warp(START + DURATION);
        assertFalse(ads.isActive(id));
        _assertSolvent();
    }

    function testImmediateCancellationFullyRefundsThenOwnerCanWithdraw() public {
        (uint256 id,) = _fundedAd();
        vm.prank(alice);
        assertEq(ads.cancel(id), PRICE);
        assertFalse(ads.isActive(id));
        assertEq(ads.totalEscrowed(), 0);
        assertEq(ads.totalProceeds(), 0);
        vm.prank(alice);
        ads.withdraw(PRICE, alice);
        assertEq(token.balanceOf(alice), PRICE);
        assertEq(ads.getPlacement(id).refund, PRICE);
        _assertSolvent();
    }

    function testHalfDurationCancellationSplitsFeeAndProceedsArePullBased() public {
        (uint256 id,) = _fundedAd();
        vm.warp(START + DURATION / 2);
        vm.prank(alice);
        assertEq(ads.cancel(id), PRICE / 2);
        assertEq(ads.proceeds(treasury), PRICE / 2);
        assertEq(token.balanceOf(treasury), 0);
        vm.prank(treasury);
        ads.withdrawProceeds(PRICE / 2, treasury);
        vm.prank(alice);
        ads.withdraw(PRICE / 2, alice);
        assertEq(token.balanceOf(treasury) + token.balanceOf(alice), PRICE);
        _assertSolvent();
    }

    function testFuzzCancellationConservesFundsAndRoundsInPayersFavor(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, DURATION - 1);
        (uint256 id,) = _fundedAd();
        vm.warp(START + elapsed);
        vm.prank(alice);
        uint256 refund = ads.cancel(id);
        uint256 earned = ads.proceeds(treasury);
        assertEq(refund + earned, PRICE);
        assertEq(earned, PRICE * elapsed / DURATION);
        assertGe(refund * DURATION, PRICE * (DURATION - elapsed));
        assertLt(refund * DURATION - PRICE * (DURATION - elapsed), DURATION);
        assertEq(ads.available(alice), refund);
        assertEq(ads.getPlacement(id).closedAt, START + elapsed);
        _assertSolvent();
    }

    function testExpirySettlementIsPermissionlessAndCannotBeRepeatedOrRefunded() public {
        (uint256 id,) = _fundedAd();
        vm.expectRevert(FeaturedPlacementsV2.PlacementNotExpired.selector);
        ads.settle(id);
        vm.warp(START + DURATION);
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.PlacementExpired.selector);
        ads.cancel(id);
        vm.prank(bob);
        ads.settle(id);
        assertEq(ads.totalEscrowed(), 0);
        assertEq(ads.proceeds(treasury), PRICE);
        assertEq(ads.available(alice), 0);
        vm.expectRevert(FeaturedPlacementsV2.PlacementClosed.selector);
        ads.settle(id);
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.PlacementClosed.selector);
        ads.cancel(id);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.withdrawProceeds(PRICE, bob);
        vm.prank(treasury);
        ads.withdrawProceeds(PRICE, treasury);
        _assertSolvent();
    }

    function testCancelledPlacementCannotSettleOrCancelTwice() public {
        (uint256 id,) = _fundedAd();
        vm.prank(alice);
        ads.cancel(id);
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.PlacementClosed.selector);
        ads.cancel(id);
        vm.warp(START + DURATION);
        vm.expectRevert(FeaturedPlacementsV2.PlacementClosed.selector);
        ads.settle(id);
        _assertSolvent();
    }

    function testRecipientsAreSnapshottedAndChangingThemCannotTakeOldFunds() public {
        (uint256 id, uint256 listingId) = _fundedAd();
        ads.setProceedsRecipient(nextTreasury);
        vm.warp(START + DURATION / 2);
        vm.prank(alice);
        ads.cancel(id);
        assertEq(ads.proceeds(treasury), PRICE / 2);
        assertEq(ads.proceeds(nextTreasury), 0);
        _deposit(alice, PRICE / 2);
        uint256 second = _purchase(alice, listingId);
        assertEq(ads.getPlacement(second).recipient, nextTreasury);
        vm.warp(START + 2 * DURATION);
        ads.settle(second);
        assertEq(ads.proceeds(nextTreasury), PRICE);
        vm.prank(nextTreasury);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.withdrawProceeds(PRICE + 1, nextTreasury);
        vm.prank(treasury);
        ads.withdrawProceeds(PRICE / 2, treasury);
        vm.prank(nextTreasury);
        ads.withdrawProceeds(PRICE, nextTreasury);
        _assertSolvent();
    }

    function testRecipientRotationInvalidatesStalePurchaseBeforeFundsAreLocked() public {
        uint256 listingId = _create(alice);
        _deposit(alice, PRICE);
        ads.setProceedsRecipient(nextTreasury);
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.TermsChanged.selector);
        ads.purchase(listingId, 1, treasury, START);
        assertEq(ads.available(alice), PRICE);
        assertEq(ads.totalEscrowed(), 0);
        uint256 id = _purchase(alice, listingId);
        assertEq(ads.getPlacement(id).recipient, nextTreasury);
    }

    function testEditingInvalidatesStalePurchaseAndFeeDisclosuresAreSnapshotted() public {
        uint256 listingId = _create(alice);
        _deposit(alice, PRICE);
        HookListingRegistry.Metadata memory data = _metadata();
        data.feeDisclosure = "Different fee claim";
        vm.prank(alice);
        registry.updateListing(listingId, data);
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.TermsChanged.selector);
        ads.purchase(listingId, 1, treasury, START);
        assertEq(ads.available(alice), PRICE);
        uint256 id = _purchase(alice, listingId);
        assertEq(ads.getPlacement(id).revision, 2);
        assertEq(registry.getMetadata(listingId, ads.getPlacement(id).revision).feeDisclosure, data.feeDisclosure);
    }

    function testSnapshotSurvivesEditingArchivingTransferAndRefundStaysWithPayer() public {
        (uint256 id, uint256 listingId) = _fundedAd();
        HookListingRegistry.Metadata memory changed = _metadata();
        changed.name = "Changed name";
        vm.startPrank(alice);
        registry.updateListing(listingId, changed);
        registry.setListingActive(listingId, false);
        registry.proposeListingOwner(listingId, bob);
        vm.stopPrank();
        vm.prank(bob);
        registry.acceptListingOwnership(listingId);
        FeaturedPlacementsV2.Placement memory item = ads.getPlacement(id);
        assertEq(item.revision, 1);
        assertEq(item.payer, alice);
        assertTrue(ads.isActive(id));
        assertEq(registry.getMetadata(listingId, item.revision).name, "Bounded swap hook");
        assertEq(registry.getMetadata(listingId, 2).name, "Changed name");
        vm.prank(bob);
        ads.cancel(id);
        assertEq(ads.available(alice), PRICE);
        assertEq(ads.available(bob), 0);
        _assertSolvent();
    }

    function testOnlyListingOwnerCanBuyAndUnrelatedAccountsCannotCancelIncludingAdmin() public {
        uint256 listingId = _create(alice);
        _deposit(bob, PRICE);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacementsV2.NotListingOwner.selector);
        ads.purchase(listingId, 1, treasury, START);
        _deposit(alice, PRICE);
        uint256 id = _purchase(alice, listingId);
        vm.expectRevert(FeaturedPlacementsV2.NotPayer.selector);
        ads.cancel(id);
        vm.prank(bob);
        vm.expectRevert(FeaturedPlacementsV2.NotPayer.selector);
        ads.cancel(id);
        assertTrue(ads.isActive(id));
        _assertSolvent();
    }

    function testStaleTermsInactiveListingInsufficientBalanceAndDeadlineFailBeforeDebit() public {
        uint256 listingId = _create(alice);
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.purchase(listingId, 1, treasury, START);
        _deposit(alice, PRICE);
        vm.startPrank(alice);
        vm.expectRevert(FeaturedPlacementsV2.TermsChanged.selector);
        ads.purchase(listingId, 2, treasury, START);
        vm.expectRevert(FeaturedPlacementsV2.TermsChanged.selector);
        ads.purchase(listingId, 1, nextTreasury, START);
        vm.expectRevert(FeaturedPlacementsV2.DeadlineExpired.selector);
        ads.purchase(listingId, 1, treasury, START - 1);
        registry.setListingActive(listingId, false);
        vm.expectRevert(FeaturedPlacementsV2.ListingInactive.selector);
        ads.purchase(listingId, 1, treasury, START);
        vm.stopPrank();
        assertEq(ads.available(alice), PRICE);
        assertEq(ads.placementCount(), 0);
        _assertSolvent();
    }

    function testSingleLivePlacementButCanRenewUnsettledExpiredOrCancelledPlacement() public {
        (uint256 id, uint256 listingId) = _fundedAd();
        _deposit(alice, 2 * PRICE);
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.AlreadyFeatured.selector);
        ads.purchase(listingId, 1, treasury, START);
        vm.warp(START + DURATION);
        uint256 second = _purchase(alice, listingId);
        assertTrue(ads.isActive(second));
        assertEq(ads.totalEscrowed(), 2 * PRICE);
        ads.settle(id);
        assertEq(ads.latestPlacement(listingId), second);
        vm.prank(alice);
        ads.cancel(second);
        uint256 third = _purchase(alice, listingId);
        assertGt(third, second);
        assertEq(ads.latestPlacement(listingId), third);
        _assertSolvent();
    }

    function testFeaturedOrderingPaginationAndLabelsSkipCancelledAndExpired() public {
        (uint256 first, uint256 firstListing) = _fundedAd();
        uint256 otherListing = _create(bob);
        _deposit(bob, 2 * PRICE);
        uint256 second = _purchase(bob, otherListing);
        (FeaturedPlacementsV2.Placement[] memory page,, uint256 next) = ads.featured(1, 100);
        assertEq(page.length, 2);
        assertEq(page[0].id, first);
        assertEq(page[1].id, second);
        assertEq(page[0].label, bytes3("#ad"));
        assertEq(page[1].label, bytes3("#ad"));
        assertEq(next, 3);
        vm.prank(alice);
        ads.cancel(first);
        (page,, next) = ads.featured(1, 1);
        assertEq(page.length, 0);
        assertEq(next, 2);
        (page,, next) = ads.featured(next, 1);
        assertEq(page.length, 1);
        assertEq(page[0].id, second);
        assertEq(next, 3);
        vm.warp(START + DURATION / 2);
        uint256 third = _purchase(alice, firstListing);
        vm.warp(START + DURATION);
        (page,, next) = ads.featured(1, 100);
        assertEq(page.length, 1);
        assertEq(page[0].id, third);
        assertEq(next, 4);
        (page,, next) = ads.featured(next, 100);
        assertEq(page.length, 0);
        assertEq(next, 4);
    }

    function testUnknownIdsAndInvalidPagesFail() public {
        assertFalse(ads.isActive(1));
        vm.expectRevert(FeaturedPlacementsV2.UnknownPlacement.selector);
        ads.cancel(1);
        vm.expectRevert(FeaturedPlacementsV2.UnknownPlacement.selector);
        ads.settle(1);
        vm.expectRevert(FeaturedPlacementsV2.UnknownPlacement.selector);
        ads.getPlacement(1);
        vm.expectRevert(abi.encodeWithSelector(HookListingRegistry.UnknownListing.selector, 1));
        ads.purchase(1, 1, treasury, START);
        vm.expectRevert(FeaturedPlacementsV2.InvalidPage.selector);
        ads.featured(0, 100);
        vm.expectRevert(FeaturedPlacementsV2.InvalidPage.selector);
        ads.featured(1, 101);
        vm.expectRevert(FeaturedPlacementsV2.InvalidPage.selector);
        ads.featured(1, 0);
        vm.expectRevert(FeaturedPlacementsV2.InvalidPage.selector);
        ads.featured(type(uint256).max, 1);
    }

    function testZeroAmountsInvalidRecipientsAndExcessWithdrawalsFail() public {
        _deposit(alice, PRICE);
        vm.startPrank(alice);
        vm.expectRevert(FeaturedPlacementsV2.InvalidAmount.selector);
        ads.deposit(0);
        vm.expectRevert(FeaturedPlacementsV2.InvalidAmount.selector);
        ads.withdraw(0, alice);
        vm.expectRevert(StoreAdmin.InvalidAddress.selector);
        ads.withdraw(1, address(0));
        vm.expectRevert(StoreAdmin.InvalidAddress.selector);
        ads.withdraw(1, address(ads));
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.withdraw(PRICE + 1, alice);
        vm.expectRevert(FeaturedPlacementsV2.InvalidAmount.selector);
        ads.withdrawProceeds(0, alice);
        vm.stopPrank();
        vm.expectRevert(StoreAdmin.InvalidAddress.selector);
        ads.setProceedsRecipient(address(ads));
        vm.expectRevert(StoreAdmin.InvalidAddress.selector);
        ads.setProceedsRecipient(address(0));
        _assertSolvent();
    }

    function testUnsetConfigurationAndTokenCanOnlyBeChosenOnce() public {
        FeaturedPlacementsV2 unconfigured = new FeaturedPlacementsV2(alice, registry);
        vm.expectRevert(FeaturedPlacementsV2.TokenNotConfigured.selector);
        unconfigured.deposit(PRICE);
        vm.expectRevert(FeaturedPlacementsV2.TokenNotConfigured.selector);
        unconfigured.withdraw(PRICE, alice);
        vm.expectRevert(FeaturedPlacementsV2.TokenNotConfigured.selector);
        unconfigured.purchase(1, 1, treasury, START);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        unconfigured.configureToken(address(token));
        vm.prank(alice);
        unconfigured.configureToken(address(token));
        vm.prank(alice);
        vm.expectRevert(FeaturedPlacementsV2.RecipientNotConfigured.selector);
        unconfigured.purchase(1, 1, treasury, START);
        // Deposit ownership/withdrawal do not depend on the recipient being configured.
        token.mint(alice, PRICE);
        vm.startPrank(alice);
        token.approve(address(unconfigured), PRICE);
        unconfigured.deposit(PRICE);
        unconfigured.withdraw(PRICE, alice);
        vm.expectRevert(FeaturedPlacementsV2.TokenAlreadyConfigured.selector);
        unconfigured.configureToken(address(token));
        unconfigured.setProceedsRecipient(treasury);
        vm.stopPrank();
        assertEq(unconfigured.proceedsRecipient(), treasury);
    }

    function testBadTokenConfigurationAndConstructorArguments() public {
        vm.expectRevert(StoreAdmin.InvalidAddress.selector);
        this.deployForConstructorCheck(address(0), registry);
        vm.expectRevert(StoreAdmin.InvalidAddress.selector);
        this.deployForConstructorCheck(alice, HookListingRegistry(address(0)));
        // Construction does not call a registry or require it to have code.
        FeaturedPlacementsV2 emptyChain = new FeaturedPlacementsV2(alice, HookListingRegistry(hook));
        assertEq(address(emptyChain.registry()), hook);
        FeaturedPlacementsV2 unconfigured = new FeaturedPlacementsV2(address(this), registry);
        vm.expectRevert(FeaturedPlacementsV2.InvalidToken.selector);
        unconfigured.configureToken(address(0));
        vm.expectRevert(FeaturedPlacementsV2.InvalidToken.selector);
        unconfigured.configureToken(alice);
        vm.expectRevert(FeaturedPlacementsV2.InvalidToken.selector);
        unconfigured.configureToken(address(unconfigured));
        TestToken sixDecimals = new TestToken("wrong decimals", 6);
        vm.expectRevert(FeaturedPlacementsV2.InvalidToken.selector);
        unconfigured.configureToken(address(sixDecimals));
        assertEq(unconfigured.imd(), address(0));
    }

    // Keep each expected constructor revert inside its own external call boundary.
    function deployForConstructorCheck(address owner_, HookListingRegistry registry_) external {
        new FeaturedPlacementsV2(owner_, registry_);
    }

    function testAdminRotationIsTwoStepAndDoesNotControlCustody() public {
        _deposit(alice, PRICE);
        vm.prank(bob);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        ads.setProceedsRecipient(bob);
        ads.transferOwnership(bob);
        assertEq(ads.owner(), address(this));
        vm.prank(alice);
        vm.expectRevert(StoreAdmin.NotPendingOwner.selector);
        ads.acceptOwnership();
        ads.cancelOwnershipTransfer();
        vm.prank(bob);
        vm.expectRevert(StoreAdmin.NotPendingOwner.selector);
        ads.acceptOwnership();
        ads.transferOwnership(bob);
        vm.prank(bob);
        ads.acceptOwnership();
        assertEq(ads.owner(), bob);
        assertEq(ads.pendingOwner(), address(0));
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        ads.setProceedsRecipient(alice);
        vm.startPrank(bob);
        ads.setProceedsRecipient(nextTreasury);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.withdraw(PRICE, bob);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.withdrawProceeds(PRICE, bob);
        vm.stopPrank();
        vm.prank(alice);
        ads.withdraw(PRICE, alice);
        _assertSolvent();
    }

    function testDirectTransfersAreNotCreditsAndCannotBeSwept() public {
        token.mint(bob, PRICE);
        vm.prank(bob);
        token.transfer(address(ads), PRICE);
        assertEq(ads.accountedBalance(), 0);
        vm.expectRevert(FeaturedPlacementsV2.InsufficientBalance.selector);
        ads.withdrawProceeds(PRICE, address(this));
        _deposit(alice, PRICE);
        vm.prank(alice);
        ads.withdraw(PRICE, alice);
        assertEq(token.balanceOf(address(ads)), PRICE);
        assertEq(ads.accountedBalance(), 0);
    }
}
