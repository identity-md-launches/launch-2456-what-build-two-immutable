// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {HookListingRegistry} from "../src/store/HookListingRegistry.sol";

/// @dev Drives the registry with arbitrary callers and asserts each call succeeds exactly when the model
/// says it should. The model tracks owners, pending transfers, visibility, revisions, labels and the
/// (chain, hook, owner) identity index that purchases and duplicate protection depend on.
contract RegistryModelHandler is Test {
    HookListingRegistry public registry;
    address[3] public actors;
    address[2] public hooks;
    uint256[2] public chains = [uint256(1), 4663];

    struct ModelListing {
        uint256 chainId;
        address hook;
        address owner;
        address proposed;
        uint256 revision;
        bool active;
        uint256 labelSet;
    }

    mapping(uint256 => ModelListing) internal _m;
    mapping(bytes32 => uint256) public mIndex;
    uint256 public mCount;

    constructor(HookListingRegistry registry_, address[3] memory actors_, address[2] memory hooks_) {
        registry = registry_;
        actors = actors_;
        hooks = hooks_;
    }

    function listing(uint256 id) external view returns (ModelListing memory) {
        return _m[id];
    }

    function key(uint256 chainId, address hook, address owner) public pure returns (bytes32) {
        return keccak256(abi.encode(chainId, hook, owner));
    }

    function metadata(uint256 labelSet) public pure returns (HookListingRegistry.Metadata memory data) {
        data.name = "Fuzzed hook";
        data.callbackDisclosure = "afterSwap";
        data.feeDisclosure = "none";
        data.adminDisclosure = "none";
        data.labels = new string[](2);
        data.labels[0] = labelSet == 0 ? "alpha" : "beta";
        data.labels[1] = labelSet == 0 ? "beta" : "gamma";
    }

    function _id(uint256 seed) internal view returns (uint256) {
        return seed % (mCount + 2); // includes unknown 0 and one past the end
    }

    function create(uint256 actorSeed, uint256 chainSeed, uint256 hookSeed, uint256 labelSet) external {
        address actor = actors[actorSeed % 3];
        uint256 chainId = chains[chainSeed % 2];
        address hook = hooks[hookSeed % 2];
        labelSet %= 2;
        bool expected = mIndex[key(chainId, hook, actor)] == 0;
        vm.prank(actor);
        bool ok;
        uint256 id;
        try registry.createListing(chainId, hook, metadata(labelSet)) returns (uint256 newId) {
            ok = true;
            id = newId;
        } catch {}
        assertEq(ok, expected, "create");
        if (!ok) return;
        assertEq(id, ++mCount);
        _m[id] = ModelListing(chainId, hook, actor, address(0), 1, true, labelSet);
        mIndex[key(chainId, hook, actor)] = id;
    }

    function update(uint256 actorSeed, uint256 idSeed, uint256 labelSet) external {
        address actor = actors[actorSeed % 3];
        uint256 id = _id(idSeed);
        labelSet %= 2;
        vm.prank(actor);
        bool ok;
        try registry.updateListing(id, metadata(labelSet)) {
            ok = true;
        } catch {}
        assertEq(ok, _m[id].owner == actor && actor != address(0), "update");
        if (!ok) return;
        ++_m[id].revision;
        _m[id].labelSet = labelSet;
    }

    function setActive(uint256 actorSeed, uint256 idSeed, bool active) external {
        address actor = actors[actorSeed % 3];
        uint256 id = _id(idSeed);
        vm.prank(actor);
        bool ok;
        try registry.setListingActive(id, active) {
            ok = true;
        } catch {}
        assertEq(ok, _m[id].owner == actor, "setActive");
        if (ok) _m[id].active = active;
    }

    function propose(uint256 actorSeed, uint256 idSeed, uint256 toSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 id = _id(idSeed);
        uint256 pick = toSeed % 5;
        address to = pick < 3 ? actors[pick] : pick == 3 ? address(0) : address(registry);
        vm.prank(actor);
        bool ok;
        try registry.proposeListingOwner(id, to) {
            ok = true;
        } catch {}
        assertEq(ok, _m[id].owner == actor && pick < 3, "propose");
        if (ok) _m[id].proposed = to;
    }

    function cancelTransfer(uint256 actorSeed, uint256 idSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 id = _id(idSeed);
        vm.prank(actor);
        bool ok;
        try registry.cancelListingTransfer(id) {
            ok = true;
        } catch {}
        assertEq(ok, _m[id].owner == actor, "cancelTransfer");
        if (ok) _m[id].proposed = address(0);
    }

    function accept(uint256 actorSeed, uint256 idSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 id = _id(idSeed);
        ModelListing storage m = _m[id];
        uint256 existing = mIndex[key(m.chainId, m.hook, actor)];
        bool expected = m.owner != address(0) && m.proposed == actor && (existing == 0 || existing == id);
        vm.prank(actor);
        bool ok;
        try registry.acceptListingOwnership(id) {
            ok = true;
        } catch {}
        assertEq(ok, expected, "accept");
        if (!ok) return;
        delete mIndex[key(m.chainId, m.hook, m.owner)];
        mIndex[key(m.chainId, m.hook, actor)] = id;
        m.owner = actor;
        m.proposed = address(0);
    }
}

contract HookListingRegistryInvariantTest is StdInvariant, Test {
    HookListingRegistry internal registry;
    RegistryModelHandler internal handler;

    function setUp() public {
        registry = new HookListingRegistry();
        address[3] memory actors = [makeAddr("lister A"), makeAddr("lister B"), makeAddr("lister C")];
        handler = new RegistryModelHandler(registry, actors, [makeAddr("hook 1"), makeAddr("hook 2")]);
        handler.create(0, 0, 0, 0);
        handler.create(1, 0, 0, 1);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariantListingsAndIdentityIndexMatchModel() public view {
        uint256 count = registry.listingCount();
        assertEq(count, handler.mCount());
        uint256 active;
        for (uint256 id = 1; id <= count; ++id) {
            HookListingRegistry.Listing memory item = registry.getListing(id);
            RegistryModelHandler.ModelListing memory m = handler.listing(id);
            assertEq(item.owner, m.owner);
            assertTrue(item.owner != address(0));
            assertEq(item.proposedOwner, m.proposed);
            assertEq(item.chainId, m.chainId);
            assertEq(item.hook, m.hook);
            assertEq(item.revision, m.revision);
            assertEq(item.active, m.active);
            assertFalse(registry.isAudited(id));
            // The current owner's identity key always resolves to this listing.
            assertEq(registry.listingFor(registry.identityKey(item.chainId, item.hook, item.owner)), id);
            assertEq(registry.hasLabel(id, keccak256("alpha")), m.labelSet == 0);
            assertTrue(registry.hasLabel(id, keccak256("beta")));
            assertEq(registry.hasLabel(id, keccak256("gamma")), m.labelSet == 1);
            assertEq(abi.encode(registry.getMetadata(id, item.revision)), abi.encode(handler.metadata(m.labelSet)));
            if (item.active) ++active;
        }
        // No stale identity entries: every (chain, hook, owner) key matches the model, and points at a
        // listing that really is owned by that account.
        for (uint256 c; c < 2; ++c) {
            for (uint256 h; h < 2; ++h) {
                for (uint256 a; a < 3; ++a) {
                    bytes32 k = registry.identityKey(handler.chains(c), handler.hooks(h), handler.actors(a));
                    uint256 id = registry.listingFor(k);
                    assertEq(id, handler.mIndex(k));
                    if (id != 0) assertEq(registry.getListing(id).owner, handler.actors(a));
                }
            }
        }
        (uint256[] memory ids, uint256 next) = registry.search(1, registry.MAX_SCAN(), 0, address(0), bytes32(0));
        assertEq(next, count + 1);
        assertEq(ids.length, active);
        for (uint256 i = 1; i < ids.length; ++i) {
            assertGt(ids[i], ids[i - 1]);
        }
    }
}
