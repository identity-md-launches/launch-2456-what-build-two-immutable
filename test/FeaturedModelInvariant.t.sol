// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {StoreFixture, HookListingRegistry, FeaturedPlacementsV2, TestToken} from "./helpers/StoreFixture.sol";
import {StoreAdmin} from "../src/store/StoreAdmin.sol";

/// @dev Model-based handler. Unlike FeaturedHandler it does not filter out invalid calls: every action is
/// attempted with arbitrary actors (including a pure third-party booster and an outsider), ids and amounts,
/// and the handler asserts the call succeeds exactly when an independent model says it should. Failed calls
/// leave the model untouched, so the invariants also prove that rejected calls change nothing.
contract FeaturedModelHandler is Test {
    FeaturedPlacementsV2 public ads;
    HookListingRegistry public registry;
    TestToken public token;

    uint256 internal constant PRICE = 0.1 ether;
    uint256 internal constant DURATION = 24 hours;
    uint256 internal constant MAX_PLACEMENTS = 30;

    // alice and bob own the two listings (and may trade them); carol never owns one; mallory is an outsider.
    address[4] public actors;
    address[2] public recipients;
    uint256[2] public listings;

    struct ModelPlacement {
        uint256 listingId;
        address payer;
        address recipient;
        uint256 startsAt;
        uint256 boost;
        uint256 refund;
        uint256 closedAt;
        FeaturedPlacementsV2.Status status;
    }

    mapping(address => uint256) public mAvailable;
    mapping(address => uint256) public mProceeds;
    mapping(uint256 => ModelPlacement) internal _m;
    uint256 public mEscrowed;
    uint256 public mCount;
    uint256 public donated;
    uint256 public minted;

    uint256 public thirdPartyBoosts;
    uint256 public forfeitedOnCancel;
    uint256 public expectedFailures;

    constructor(FeaturedPlacementsV2 ads_, TestToken token_, address[4] memory actors_, address[2] memory recipients_) {
        ads = ads_;
        registry = ads_.registry();
        token = token_;
        actors = actors_;
        recipients = recipients_;
        listings = [uint256(1), 2];
    }

    function placement(uint256 id) external view returns (ModelPlacement memory) {
        return _m[id];
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _live(uint256 id) internal view returns (bool) {
        return _m[id].status == FeaturedPlacementsV2.Status.Open && _now() < _m[id].startsAt + DURATION;
    }

    function _check(bool ok, bool expected, string memory what) internal {
        assertEq(ok, expected, what);
        if (!expected) ++expectedFailures;
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 4];
        amount = bound(amount, 0, 3 * PRICE);
        token.mint(actor, amount);
        minted += amount;
        vm.prank(actor);
        token.approve(address(ads), amount);
        vm.prank(actor);
        bool ok;
        try ads.deposit(amount) {
            ok = true;
        } catch {}
        _check(ok, amount != 0, "deposit");
        if (ok) mAvailable[actor] += amount;
    }

    function withdraw(uint256 actorSeed, uint256 amount, uint256 toSeed) external {
        address actor = actors[actorSeed % 4];
        amount = bound(amount, 0, mAvailable[actor] + 1);
        uint256 pick = toSeed % 8;
        address to = pick == 0 ? address(0) : pick == 1 ? address(ads) : actor;
        vm.prank(actor);
        bool ok;
        try ads.withdraw(amount, to) {
            ok = true;
        } catch {}
        _check(ok, amount != 0 && amount <= mAvailable[actor] && pick > 1, "withdraw");
        if (ok) mAvailable[actor] -= amount;
    }

    function purchase(uint256 actorSeed, uint256 listingSeed, uint256 termsSeed) external {
        if (mCount >= MAX_PLACEMENTS) return;
        address actor = actors[actorSeed % 4];
        uint256 listingId = 1 + listingSeed % 3; // 3 does not exist
        uint256 revision = listingId <= 2 ? registry.getListing(listingId).revision : 1;
        address recipient = ads.proceedsRecipient();
        uint256 deadline = _now();
        uint256 terms = termsSeed % 8;
        if (terms == 0) ++revision; // stale or future revision
        if (terms == 1) recipient = recipient == recipients[0] ? recipients[1] : recipients[0];
        if (terms == 2) --deadline;

        bool expected = terms > 2 && listingId <= 2 && mAvailable[actor] >= PRICE;
        if (expected) {
            HookListingRegistry.Listing memory item = registry.getListing(listingId);
            expected = item.owner == actor && item.active && !_live(ads.latestPlacement(listingId));
        }
        vm.prank(actor);
        bool ok;
        uint256 id;
        try ads.purchase(listingId, revision, recipient, deadline) returns (uint256 newId) {
            ok = true;
            id = newId;
        } catch {}
        _check(ok, expected, "purchase");
        if (!ok) return;
        assertEq(id, ++mCount, "sequential id");
        mAvailable[actor] -= PRICE;
        mEscrowed += PRICE;
        _m[id] = ModelPlacement(listingId, actor, recipient, _now(), 0, 0, 0, FeaturedPlacementsV2.Status.Open);
    }

    function boost(uint256 actorSeed, uint256 idSeed, uint256 amount) external {
        address actor = actors[actorSeed % 4];
        uint256 id = idSeed % (mCount + 2); // includes 0 and one past the end
        amount = bound(amount, 0, mAvailable[actor] + 1);
        vm.prank(actor);
        bool ok;
        try ads.boost(id, amount) {
            ok = true;
        } catch {}
        _check(ok, _live(id) && amount != 0 && amount <= mAvailable[actor], "boost");
        if (!ok) return;
        mAvailable[actor] -= amount;
        mEscrowed += amount;
        _m[id].boost += amount;
        if (actor != _m[id].payer) thirdPartyBoosts += amount;
    }

    function cancel(uint256 actorSeed, uint256 idSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 id = idSeed % (mCount + 2);
        bool expected = _live(id);
        if (expected) expected = actor == _m[id].payer || actor == registry.getListing(_m[id].listingId).owner;
        vm.prank(actor);
        bool ok;
        uint256 refund;
        try ads.cancel(id) returns (uint256 r) {
            ok = true;
            refund = r;
        } catch {}
        _check(ok, expected, "cancel");
        if (!ok) return;
        ModelPlacement storage p = _m[id];
        uint256 earnedBase = PRICE * (_now() - p.startsAt) / DURATION;
        assertEq(refund, PRICE - earnedBase, "pro-rata base refund");
        p.status = FeaturedPlacementsV2.Status.Cancelled;
        p.refund = refund;
        p.closedAt = _now();
        mEscrowed -= PRICE + p.boost;
        mAvailable[p.payer] += refund;
        mProceeds[p.recipient] += earnedBase + p.boost;
        forfeitedOnCancel += p.boost;
    }

    function settle(uint256 actorSeed, uint256 idSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 id = idSeed % (mCount + 2);
        ModelPlacement storage p = _m[id];
        bool expected = p.status == FeaturedPlacementsV2.Status.Open && _now() >= p.startsAt + DURATION;
        vm.prank(actor);
        bool ok;
        try ads.settle(id) {
            ok = true;
        } catch {}
        _check(ok, expected, "settle");
        if (!ok) return;
        p.status = FeaturedPlacementsV2.Status.Settled;
        p.closedAt = _now();
        mEscrowed -= PRICE + p.boost;
        mProceeds[p.recipient] += PRICE + p.boost;
    }

    function withdrawProceeds(uint256 whoSeed, uint256 amount) external {
        // Recipients claim their own earnings; actors (including payers and boosters) hold none.
        uint256 pick = whoSeed % 6;
        address who = pick < 2 ? recipients[pick] : actors[pick - 2];
        amount = bound(amount, 0, mProceeds[who] + 1);
        vm.prank(who);
        bool ok;
        try ads.withdrawProceeds(amount, who) {
            ok = true;
        } catch {}
        _check(ok, amount != 0 && amount <= mProceeds[who], "withdrawProceeds");
        if (ok) mProceeds[who] -= amount;
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(_now() + bound(secondsSeed, 0, 30 hours));
    }

    function warpToExpiryEdge(uint256 idSeed, uint256 offsetSeed) external {
        if (mCount == 0) return;
        uint256 endsAt = _m[1 + idSeed % mCount].startsAt + DURATION;
        uint256 target = endsAt - 1 + offsetSeed % 2; // exactly the last live second or exactly expiry
        if (target > _now()) vm.warp(target);
    }

    function rotateRecipient(uint256 recipientSeed) external {
        ads.setProceedsRecipient(recipients[recipientSeed % 2]);
    }

    function transferListing(uint256 listingSeed) external {
        uint256 listingId = listings[listingSeed % 2];
        address current = registry.getListing(listingId).owner;
        address next = current == actors[0] ? actors[1] : actors[0];
        vm.prank(current);
        registry.proposeListingOwner(listingId, next);
        vm.prank(next);
        registry.acceptListingOwnership(listingId);
    }

    function toggleListing(uint256 listingSeed, bool active) external {
        uint256 listingId = listings[listingSeed % 2];
        vm.prank(registry.getListing(listingId).owner);
        registry.setListingActive(listingId, active);
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, PRICE);
        token.mint(actors[3], amount);
        minted += amount;
        vm.prank(actors[3]);
        token.transfer(address(ads), amount);
        donated += amount;
    }

    /// @dev Owner powers are never available to anyone but the owner, including payers and recipients.
    function outsiderTriesOwnerPowers(uint256 whoSeed, uint256 which) external {
        uint256 pick = whoSeed % 6;
        address who = pick < 2 ? recipients[pick] : actors[pick - 2];
        vm.prank(who);
        bool ok;
        uint256 w = which % 4;
        if (w == 0) {
            try ads.setProceedsRecipient(who) {
                ok = true;
            } catch {}
        } else if (w == 1) {
            try ads.transferOwnership(who) {
                ok = true;
            } catch {}
        } else if (w == 2) {
            try ads.configureToken(address(token)) {
                ok = true;
            } catch {}
        } else {
            try ads.acceptOwnership() {
                ok = true;
            } catch {}
        }
        _check(ok, false, "owner power used by outsider");
    }
}

contract FeaturedModelInvariantTest is StdInvariant, StoreFixture {
    FeaturedModelHandler internal handler;
    address internal carol;
    address internal mallory;

    function setUp() public override {
        super.setUp();
        carol = makeAddr("third-party booster Carol");
        mallory = makeAddr("outsider Mallory");
        _create(alice);
        vm.prank(bob);
        registry.createListing(4663, hook, _metadata());
        handler = new FeaturedModelHandler(ads, token, [alice, bob, carol, mallory], [treasury, nextTreasury]);
        ads.transferOwnership(address(handler));
        vm.prank(address(handler));
        ads.acceptOwnership();

        // Every sequence starts with a live, third-party-boosted ad on each listing.
        handler.deposit(0, PRICE);
        handler.deposit(1, PRICE);
        handler.deposit(2, 3 * PRICE);
        handler.purchase(0, 0, 3);
        handler.purchase(1, 1, 3);
        handler.boost(2, 1, PRICE / 3);
        handler.boost(2, 2, PRICE);
        require(handler.thirdPartyBoosts() == PRICE / 3 + PRICE, "seed");

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = FeaturedModelHandler.deposit.selector;
        selectors[1] = FeaturedModelHandler.withdraw.selector;
        selectors[2] = FeaturedModelHandler.purchase.selector;
        selectors[3] = FeaturedModelHandler.boost.selector;
        selectors[4] = FeaturedModelHandler.boost.selector; // weighted: boosts are the new surface
        selectors[5] = FeaturedModelHandler.cancel.selector;
        selectors[6] = FeaturedModelHandler.settle.selector;
        selectors[7] = FeaturedModelHandler.withdrawProceeds.selector;
        selectors[8] = FeaturedModelHandler.advanceTime.selector;
        selectors[9] = FeaturedModelHandler.warpToExpiryEdge.selector;
        selectors[10] = FeaturedModelHandler.rotateRecipient.selector;
        selectors[11] = FeaturedModelHandler.transferListing.selector;
        selectors[12] = FeaturedModelHandler.toggleListing.selector;
        selectors[13] = FeaturedModelHandler.donate.selector;
        selectors[14] = FeaturedModelHandler.outsiderTriesOwnerPowers.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 128
    function invariantConservationWithBoostsMatchesModel() public view {
        uint256 balance = token.balanceOf(address(ads));
        // Conservation rule from the brief; boosts sit in totalEscrowed until their placement closes.
        assertEq(ads.accountedBalance(), ads.totalAvailable() + ads.totalEscrowed() + ads.totalProceeds());
        // Donations are held but never credited, so the contract is always solvent for what it owes.
        assertEq(balance, ads.accountedBalance() + handler.donated());
        assertEq(ads.totalEscrowed(), handler.mEscrowed());

        address[6] memory accounts = [alice, bob, carol, mallory, treasury, nextTreasury];
        uint256 sumAvailable;
        uint256 sumProceeds;
        uint256 outside;
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(ads.available(accounts[i]), handler.mAvailable(accounts[i]), "available");
            assertEq(ads.proceeds(accounts[i]), handler.mProceeds(accounts[i]), "proceeds");
            sumAvailable += ads.available(accounts[i]);
            sumProceeds += ads.proceeds(accounts[i]);
            outside += token.balanceOf(accounts[i]);
        }
        assertEq(ads.totalAvailable(), sumAvailable);
        assertEq(ads.totalProceeds(), sumProceeds);
        // No token is created or destroyed by the contract.
        assertEq(outside + balance, handler.minted());
        // Payers, boosters and outsiders never hold proceeds; only pinned recipients earn.
        assertEq(ads.proceeds(alice) + ads.proceeds(bob) + ads.proceeds(carol) + ads.proceeds(mallory), 0);
        assertEq(ads.owner(), address(handler));
        assertEq(ads.pendingOwner(), address(0));
    }

    function invariantPlacementsMatchModelAndClosedNeverReopen() public view {
        uint256 count = ads.placementCount();
        assertEq(count, handler.mCount());
        uint256[3] memory livePerListing;
        uint256 escrowed;
        for (uint256 id = 1; id <= count; ++id) {
            FeaturedPlacementsV2.Placement memory p = ads.getPlacement(id);
            FeaturedModelHandler.ModelPlacement memory m = handler.placement(id);
            assertEq(uint256(p.status), uint256(m.status), "status");
            assertEq(p.payer, m.payer);
            assertEq(p.recipient, m.recipient);
            assertEq(p.listingId, m.listingId);
            assertEq(p.startsAt, m.startsAt);
            assertEq(p.endsAt, m.startsAt + DURATION);
            assertEq(p.refund, m.refund);
            assertEq(p.closedAt, m.closedAt);
            assertEq(p.label, bytes3("#ad"));
            assertEq(ads.totalBoost(id), m.boost, "boost");
            assertEq(ads.rankOf(id), PRICE + m.boost, "rank");
            if (m.status == FeaturedPlacementsV2.Status.Open) escrowed += PRICE + m.boost;
            if (ads.isActive(id)) ++livePerListing[p.listingId];
        }
        assertEq(escrowed, ads.totalEscrowed());
        assertLe(livePerListing[1], 1, "one live placement per listing");
        assertLe(livePerListing[2], 1, "one live placement per listing");
    }

    function invariantFeaturedTotalsAreSortableByTotalThenId() public view {
        uint256 count = ads.placementCount();
        (FeaturedPlacementsV2.Placement[] memory page, uint256[] memory totals, uint256 next) =
            ads.featured(1, ads.MAX_SCAN());
        assertEq(next, count + 1);
        assertEq(page.length, totals.length);
        uint256 live;
        for (uint256 id = 1; id <= count; ++id) {
            if (ads.isActive(id)) ++live;
        }
        assertEq(page.length, live);
        for (uint256 i; i < page.length; ++i) {
            assertEq(totals[i], ads.rankOf(page[i].id));
            assertEq(totals[i], PRICE + handler.placement(page[i].id).boost);
            assertEq(page[i].label, bytes3("#ad"));
            if (i != 0) assertGt(page[i].id, page[i - 1].id, "ids ascend so ties resolve to lower id");
        }
    }

    /// @dev Wind-down without admin help: every credit is withdrawable and only donations remain.
    function afterInvariant() public {
        vm.warp(vm.getBlockTimestamp() + DURATION);
        for (uint256 id = 1; id <= ads.placementCount(); ++id) {
            if (ads.getPlacement(id).status == FeaturedPlacementsV2.Status.Open) ads.settle(id);
        }
        address[6] memory accounts = [alice, bob, carol, mallory, treasury, nextTreasury];
        for (uint256 i; i < accounts.length; ++i) {
            uint256 credit = ads.available(accounts[i]);
            uint256 earned = ads.proceeds(accounts[i]);
            vm.startPrank(accounts[i]);
            if (credit != 0) ads.withdraw(credit, accounts[i]);
            if (earned != 0) ads.withdrawProceeds(earned, accounts[i]);
            vm.stopPrank();
        }
        assertEq(ads.accountedBalance(), 0);
        assertEq(token.balanceOf(address(ads)), handler.donated());
        // Boosts paid by carol are never returned to her: she can only have withdrawn unspent deposits.
        assertGe(handler.thirdPartyBoosts(), PRICE / 3 + PRICE);
    }
}
