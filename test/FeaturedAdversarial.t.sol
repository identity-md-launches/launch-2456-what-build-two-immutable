// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StoreFixture, FeaturedPlacementsV2} from "./helpers/StoreFixture.sol";
import {StoreTokenMock} from "./helpers/StoreTokenMock.sol";
import {ExactStoreToken} from "../src/store/ExactStoreToken.sol";

contract FeaturedAdversarialTest is StoreFixture {
    StoreTokenMock internal hostile;

    function setUp() public override {
        super.setUp();
        hostile = new StoreTokenMock();
        ads = new FeaturedPlacementsV2(address(this), registry);
        ads.configureToken(address(hostile));
        ads.setProceedsRecipient(treasury);
        hostile.mint(alice, 10 * PRICE);
        vm.prank(alice);
        hostile.approve(address(ads), 10 * PRICE);
    }

    function testFalseRevertingMalformedAndNoMovementTokensCannotCreateCredit() public {
        for (uint256 mode = 1; mode <= uint256(StoreTokenMock.Mode.NoMovement); ++mode) {
            if (mode == uint256(StoreTokenMock.Mode.NoReturn)) continue;
            hostile.setMode(StoreTokenMock.Mode(mode));
            vm.prank(alice);
            vm.expectRevert(
                mode >= uint256(StoreTokenMock.Mode.RecipientFee)
                    ? ExactStoreToken.InexactTransfer.selector
                    : ExactStoreToken.TokenCallFailed.selector
            );
            ads.deposit(PRICE);
            assertEq(ads.available(alice), 0);
            assertEq(ads.accountedBalance(), 0);
            assertEq(hostile.balanceOf(address(ads)), 0);
            assertEq(hostile.balanceOf(alice), 10 * PRICE);
        }
    }

    function testNoReturnTokenWorksForDepositsAndWithdrawals() public {
        hostile.setMode(StoreTokenMock.Mode.NoReturn);
        vm.startPrank(alice);
        ads.deposit(PRICE);
        ads.withdraw(PRICE, alice);
        vm.stopPrank();
        assertEq(hostile.balanceOf(alice), 10 * PRICE);
        assertEq(ads.accountedBalance(), 0);
    }

    function testTaxedOrFailedWithdrawalRollsBackAndRemainsRetryable() public {
        vm.prank(alice);
        ads.deposit(2 * PRICE);
        for (uint256 mode = 1; mode <= uint256(StoreTokenMock.Mode.NoMovement); ++mode) {
            if (mode == uint256(StoreTokenMock.Mode.NoReturn)) continue;
            hostile.setMode(StoreTokenMock.Mode(mode));
            vm.prank(alice);
            vm.expectRevert(
                mode >= uint256(StoreTokenMock.Mode.RecipientFee)
                    ? ExactStoreToken.InexactTransfer.selector
                    : ExactStoreToken.TokenCallFailed.selector
            );
            ads.withdraw(PRICE, alice);
            assertEq(ads.available(alice), 2 * PRICE);
            assertEq(hostile.balanceOf(address(ads)), 2 * PRICE);
        }
        hostile.setMode(StoreTokenMock.Mode.Good);
        vm.prank(alice);
        ads.withdraw(2 * PRICE, alice);
        assertEq(ads.accountedBalance(), 0);
    }

    function testRecipientCannotBlockCancellationOrSettlementAndFailedClaimRollsBack() public {
        uint256 listingId = _create(alice);
        vm.prank(alice);
        ads.deposit(2 * PRICE);
        uint256 first = _purchase(alice, listingId);
        vm.warp(START + DURATION / 2);
        hostile.setMode(StoreTokenMock.Mode.RevertCall);
        vm.prank(alice);
        ads.cancel(first);
        assertEq(ads.available(alice), 3 * PRICE / 2);
        assertEq(ads.proceeds(treasury), PRICE / 2);
        uint256 second = _purchase(alice, listingId);
        vm.warp(START + 2 * DURATION);
        ads.settle(second);
        vm.prank(treasury);
        vm.expectRevert(ExactStoreToken.TokenCallFailed.selector);
        ads.withdrawProceeds(3 * PRICE / 2, treasury);
        assertEq(ads.proceeds(treasury), 3 * PRICE / 2);
        assertEq(ads.totalProceeds(), 3 * PRICE / 2);
        hostile.setMode(StoreTokenMock.Mode.Good);
        vm.prank(treasury);
        ads.withdrawProceeds(3 * PRICE / 2, treasury);
        vm.prank(alice);
        ads.withdraw(PRICE / 2, alice);
        assertEq(ads.accountedBalance(), 0);
        assertEq(hostile.balanceOf(address(ads)), 0);
    }

    function testTokenCallbacksCannotReenterAnyCustodyMutation() public {
        uint256 listingId = _create(alice);
        bytes[] memory attacks = new bytes[](7);
        attacks[0] = abi.encodeCall(FeaturedPlacementsV2.deposit, (1));
        attacks[1] = abi.encodeCall(FeaturedPlacementsV2.withdraw, (1, alice));
        attacks[2] = abi.encodeCall(FeaturedPlacementsV2.withdrawProceeds, (1, treasury));
        attacks[3] = abi.encodeCall(FeaturedPlacementsV2.purchase, (listingId, 1, treasury, START));
        attacks[4] = abi.encodeCall(FeaturedPlacementsV2.cancel, (1));
        attacks[5] = abi.encodeCall(FeaturedPlacementsV2.settle, (1));
        attacks[6] = abi.encodeCall(FeaturedPlacementsV2.boost, (1, 1));
        for (uint256 i; i < attacks.length; ++i) {
            hostile.setCallback(address(ads), attacks[i]);
            vm.prank(alice);
            ads.deposit(PRICE);
            _assertReentryBlocked();
            vm.prank(alice);
            ads.withdraw(PRICE, alice);
            _assertReentryBlocked();
            assertEq(ads.available(alice), 0);
            assertEq(hostile.balanceOf(address(ads)), 0);
        }
    }

    function testProceedsWithdrawalAlsoGuardsReentrancy() public {
        uint256 listingId = _create(alice);
        vm.prank(alice);
        ads.deposit(PRICE);
        uint256 id = _purchase(alice, listingId);
        vm.warp(START + DURATION);
        ads.settle(id);
        hostile.setCallback(address(ads), abi.encodeCall(FeaturedPlacementsV2.withdrawProceeds, (PRICE, treasury)));
        vm.prank(treasury);
        ads.withdrawProceeds(PRICE, treasury);
        _assertReentryBlocked();
        assertEq(ads.totalProceeds(), 0);
        assertEq(hostile.balanceOf(treasury), PRICE);
        assertEq(hostile.balanceOf(address(ads)), 0);
    }

    function testMissingTokenCodeAfterConfigurationCannotFakeTransfer() public {
        vm.etch(address(hostile), bytes(""));
        vm.prank(alice);
        vm.expectRevert(ExactStoreToken.TokenCallFailed.selector);
        ads.deposit(PRICE);
        assertEq(ads.available(alice), 0);
    }

    function testBoostAndCloseNeedNoTransferAndFailedBoostProceedsWithdrawalIsAtomic() public {
        uint256 listingId = _create(alice);
        vm.prank(alice);
        ads.deposit(2 * PRICE);
        uint256 id = _purchase(alice, listingId);
        hostile.mint(bob, 2 * PRICE);
        vm.startPrank(bob);
        hostile.approve(address(ads), 2 * PRICE);
        ads.deposit(2 * PRICE);
        vm.stopPrank();
        // Token failure must not prevent moving already deposited credits or closing an ad.
        hostile.setMode(StoreTokenMock.Mode.RevertCall);
        vm.prank(bob);
        ads.boost(id, 2 * PRICE);
        vm.prank(alice);
        ads.boost(id, PRICE);
        vm.warp(START + DURATION / 2);
        vm.prank(alice);
        ads.cancel(id);
        assertEq(ads.proceeds(treasury), 3 * PRICE + PRICE / 2);
        assertEq(ads.available(alice), PRICE / 2);
        assertEq(ads.available(bob), 0);
        assertEq(ads.totalEscrowed(), 0);

        for (uint256 mode = 1; mode <= uint256(StoreTokenMock.Mode.NoMovement); ++mode) {
            if (mode == uint256(StoreTokenMock.Mode.NoReturn)) continue;
            hostile.setMode(StoreTokenMock.Mode(mode));
            vm.prank(treasury);
            vm.expectRevert(
                mode >= uint256(StoreTokenMock.Mode.RecipientFee)
                    ? ExactStoreToken.InexactTransfer.selector
                    : ExactStoreToken.TokenCallFailed.selector
            );
            ads.withdrawProceeds(3 * PRICE + PRICE / 2, treasury);
            assertEq(ads.totalProceeds(), 3 * PRICE + PRICE / 2);
            assertEq(ads.proceeds(treasury), 3 * PRICE + PRICE / 2);
            assertEq(hostile.balanceOf(address(ads)), 4 * PRICE);
            assertEq(hostile.balanceOf(treasury), 0);
        }
        hostile.setMode(StoreTokenMock.Mode.Good);
        hostile.setCallback(address(ads), abi.encodeCall(FeaturedPlacementsV2.boost, (id, 1)));
        vm.prank(treasury);
        ads.withdrawProceeds(3 * PRICE + PRICE / 2, treasury);
        _assertReentryBlocked();
        vm.prank(alice);
        ads.withdraw(PRICE / 2, alice);
        assertEq(ads.accountedBalance(), 0);
        assertEq(hostile.balanceOf(address(ads)), 0);
    }

    function _assertReentryBlocked() internal view {
        assertGt(hostile.callbackCount(), 0);
        assertFalse(hostile.callbackSucceeded());
        assertEq(hostile.callbackResult(), abi.encodeWithSelector(FeaturedPlacementsV2.Reentrancy.selector));
    }
}
