// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookListingRegistry} from "../src/store/HookListingRegistry.sol";
import {FeaturedPlacementsV2} from "../src/store/FeaturedPlacementsV2.sol";
import {StoreAdmin} from "../src/store/StoreAdmin.sol";
import {TestToken} from "./helpers/TestToken.sol";

/// @dev Local factory simulation only; not an application to launch.
contract StoreDeploymentProbe {
    function deploy(address owner) external returns (HookListingRegistry registry, FeaturedPlacementsV2 ads) {
        registry = new HookListingRegistry();
        ads = new FeaturedPlacementsV2(owner, registry);
    }

    function attemptRecipientChange(FeaturedPlacementsV2 ads, address recipient) external {
        ads.setProceedsRecipient(recipient);
    }
}

contract StoreDeploymentTest is Test {
    address internal constant LAUNCH_OWNER = address(bytes20(hex"5bff2a2fecd1d6152676813b21346238733beab1"));

    function testFactoryDeploymentAssignsExplicitOwnerAndMakesNoPayments() public {
        vm.chainId(1);
        StoreDeploymentProbe factory = new StoreDeploymentProbe();
        (HookListingRegistry registry, FeaturedPlacementsV2 ads) = factory.deploy(LAUNCH_OWNER);
        assertEq(ads.owner(), LAUNCH_OWNER);
        assertNotEq(ads.owner(), address(factory));
        assertNotEq(ads.owner(), address(this));
        assertEq(address(ads.registry()), address(registry));
        assertEq(ads.imd(), address(0), "configured only after deployment");
        assertEq(ads.proceedsRecipient(), address(0));
        assertEq(ads.accountedBalance(), 0);
        assertEq(ads.placementCount(), 0);
        assertEq(registry.listingCount(), 0);
        assertEq(address(ads).balance, 0);
        assertEq(address(registry).balance, 0);

        vm.expectRevert(StoreAdmin.NotOwner.selector);
        factory.attemptRecipientChange(ads, address(factory));
        TestToken token = new TestToken("Local IMD fixture", 18);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        ads.configureToken(address(token));
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        ads.transferOwnership(address(this));
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        ads.cancelOwnershipTransfer();
        vm.startPrank(LAUNCH_OWNER);
        ads.configureToken(address(token));
        ads.setProceedsRecipient(LAUNCH_OWNER);
        vm.stopPrank();
        assertEq(ads.imd(), address(token));
        assertEq(ads.proceedsRecipient(), LAUNCH_OWNER);
    }

    function testConstructionRequiresNoRegistryOrTokenCode() public {
        address futureRegistry = makeAddr("not yet deployed registry");
        assertEq(futureRegistry.code.length, 0);
        FeaturedPlacementsV2 ads = new FeaturedPlacementsV2(LAUNCH_OWNER, HookListingRegistry(futureRegistry));
        assertEq(address(ads.registry()), futureRegistry);
        assertEq(ads.owner(), LAUNCH_OWNER);
        assertEq(ads.imd(), address(0));
        vm.expectRevert(FeaturedPlacementsV2.TokenNotConfigured.selector);
        ads.deposit(1);
    }

    function testApplicationBytecodeIsBoundedAndHasNoForbiddenRuntimeOpcodes() public {
        StoreDeploymentProbe factory = new StoreDeploymentProbe();
        (HookListingRegistry registry, FeaturedPlacementsV2 ads) = factory.deploy(LAUNCH_OWNER);
        assertLe(type(HookListingRegistry).creationCode.length, 49_152);
        assertLe(type(FeaturedPlacementsV2).creationCode.length + 64, 49_152);
        _checkRuntime(address(registry).code);
        _checkRuntime(address(ads).code);
    }

    function _checkRuntime(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}
