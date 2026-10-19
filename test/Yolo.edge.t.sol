// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Yolo} from "../src/Yolo.sol";

/// @dev Deploys the token and performs the launch allocation in one call, as the factory does in
/// one transaction, and records what the constructor left behind before anything moved.
contract OneCallLauncher {
    uint256 public supplyAfterConstructor;
    uint256 public balanceAfterConstructor;

    function launch(bytes32 salt, address distributor, address pool, address remainder) external returns (Yolo token) {
        token = new Yolo{salt: salt}();
        supplyAfterConstructor = token.totalSupply();
        balanceAfterConstructor = token.balanceOf(address(this));
        uint256 supply = supplyAfterConstructor;
        require(token.transfer(distributor, supply / 10), "swarm transfer");
        require(token.transfer(pool, supply * 6_000 / 10_000), "pool transfer");
        require(token.transfer(remainder, token.balanceOf(address(this))), "remainder transfer");
    }
}

/// @dev Edge cases and adversarial callers the main unit suite does not reach.
contract YoloEdgeTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    Yolo private token;
    address private alice;
    address private bob;
    address private spender;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        token = new Yolo();
        assertTrue(token.transfer(alice, 1_000 ether));
    }

    // ---------------------------------------------------------------- denomination

    function test_supplyIsExactlyTenToTheTwentySeven() public view {
        // Independent literal: 1e9 whole tokens * 1e18 units.
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.INITIAL_SUPPLY(), 1e27);
        assertEq(token.totalSupply() / 10 ** token.decimals(), 1_000_000_000);
        assertEq(token.totalSupply() % 10 ** token.decimals(), 0);
    }

    function test_eachDeploymentMintsItsOwnSupplyOnce() public {
        Yolo second = new Yolo();
        vm.prank(alice);
        Yolo third = new Yolo();
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(third.totalSupply(), SUPPLY);
        assertEq(third.balanceOf(alice), SUPPLY);
        assertEq(third.balanceOf(address(this)), 0);
        // The first token is untouched by later deployments.
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1_000 ether);
    }

    // ---------------------------------------------------------------- launch in one transaction

    function test_oneCallLaunchMintsToLauncherAndAllocatesExactly() public {
        OneCallLauncher launcher = new OneCallLauncher();
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        address remainder = makeAddr("remainder");
        vm.prank(alice, bob);
        Yolo launched = launcher.launch(bytes32(uint256(7)), distributor, pool, remainder);

        assertEq(launcher.supplyAfterConstructor(), SUPPLY);
        assertEq(launcher.balanceAfterConstructor(), SUPPLY);
        assertEq(launched.balanceOf(address(launcher)), 0);
        assertEq(launched.balanceOf(distributor), SUPPLY / 10);
        assertEq(launched.balanceOf(pool), SUPPLY * 6 / 10);
        assertEq(launched.balanceOf(remainder), SUPPLY * 3 / 10);
        assertEq(launched.balanceOf(alice), 0);
        assertEq(launched.balanceOf(bob), 0);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_create2RedeployWithSameSaltFails() public {
        OneCallLauncher launcher = new OneCallLauncher();
        address d = makeAddr("d");
        launcher.launch(bytes32(uint256(1)), d, d, d);
        // Same deployer, same salt, same code: a second supply cannot be minted at the same address.
        vm.expectRevert();
        launcher.launch(bytes32(uint256(1)), d, d, d);
    }

    // ---------------------------------------------------------------- authorization

    function test_ownerCannotUseTransferFromOnOwnTokensWithoutSelfApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 1_000 ether);
    }

    function test_selfApprovalIsConsumedLikeAnyOther() public {
        vm.startPrank(alice);
        assertTrue(token.approve(alice, 5 ether));
        assertTrue(token.transferFrom(alice, bob, 5 ether));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
        vm.stopPrank();
        assertEq(token.allowance(alice, alice), 0);
        assertEq(token.balanceOf(bob), 5 ether);
    }

    function test_allowanceAboveBalanceIsCappedByBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, 5_000 ether));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1_000 ether, 1_001 ether)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, 1_001 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 1_000 ether));
        assertEq(token.allowance(alice, spender), 4_000 ether);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_maxMinusOneAllowanceIsFiniteAndDecrements() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max - 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 1));
        assertEq(token.allowance(alice, spender), type(uint256).max - 2);
    }

    function test_infiniteAllowanceSurvivesSpendingWholeBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 1_000 ether));
        assertEq(token.allowance(alice, spender), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
    }

    function test_spenderCannotRedirectAllowanceOfAnotherOwner() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, 10 ether));
        // Allowance from alice does not authorize spending the deployer's much larger balance.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), spender, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1_000 ether);
    }

    function test_noIncreaseOrDecreaseAllowanceEntrypoints() public {
        vm.startPrank(alice);
        (bool inc,) = address(token).call(abi.encodeWithSignature("increaseAllowance(address,uint256)", spender, 1));
        (bool dec,) = address(token).call(abi.encodeWithSignature("decreaseAllowance(address,uint256)", spender, 1));
        (bool permit,) = address(token)
            .call(
                abi.encodeWithSignature(
                    "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
                    alice,
                    spender,
                    1,
                    block.timestamp,
                    uint8(27),
                    bytes32(0),
                    bytes32(0)
                )
            );
        vm.stopPrank();
        assertFalse(inc);
        assertFalse(dec);
        assertFalse(permit);
        assertEq(token.allowance(alice, spender), 0);
    }

    function test_burnLikeTransfersToTokenAddressDoNotReduceSupply() public {
        vm.prank(alice);
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
        // Tokens sent to the contract itself are stuck: there is no rescue entrypoint.
        (bool rescued,) =
            address(token).call(abi.encodeWithSignature("rescue(address,uint256)", address(this), 1 ether));
        assertFalse(rescued);
        assertEq(token.balanceOf(address(token)), 1 ether);
    }

    // ---------------------------------------------------------------- fuzz

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unknownSelectorRevertsWithoutStateChange(bytes4 selector, bytes calldata args) public {
        bytes4[10] memory known = [
            token.name.selector,
            token.symbol.selector,
            token.decimals.selector,
            token.totalSupply.selector,
            token.balanceOf.selector,
            token.transfer.selector,
            token.allowance.selector,
            token.approve.selector,
            token.transferFrom.selector,
            token.INITIAL_SUPPLY.selector
        ];
        uint256 i;
        while (i < known.length) {
            if (selector == known[i]) {
                // Remap a collision with the real ABI and rescan from the start.
                selector = bytes4(uint32(selector) + 1);
                i = 0;
            } else {
                ++i;
            }
        }
        vm.prank(bob);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_strangerWithoutAllowanceCannotMoveAnyAmount(address stranger, uint256 amount) public {
        if (stranger == alice) stranger = bob;
        amount = bound(amount, 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        vm.prank(stranger);
        token.transferFrom(alice, stranger, amount);
        assertEq(token.balanceOf(alice), 1_000 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferBetweenThirdPartiesTouchesOnlyThem(uint256 amount, address observer) public {
        amount = bound(amount, 0, 1_000 ether);
        uint256 observerBefore = token.balanceOf(observer);
        uint256 deployerBefore = token.balanceOf(address(this));
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(alice), 1_000 ether - amount);
        assertEq(token.balanceOf(bob), amount);
        if (observer != alice && observer != bob) assertEq(token.balanceOf(observer), observerBefore);
        assertEq(token.balanceOf(address(this)), deployerBefore);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromSplitIntoTwoEqualsOneShot(uint256 total, uint256 firstPart) public {
        total = bound(total, 0, 1_000 ether);
        firstPart = bound(firstPart, 0, total);
        vm.prank(alice);
        assertTrue(token.approve(spender, total));
        vm.startPrank(spender);
        assertTrue(token.transferFrom(alice, bob, firstPart));
        assertTrue(token.transferFrom(alice, bob, total - firstPart));
        vm.stopPrank();
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(bob), total);
        assertEq(token.balanceOf(alice), 1_000 ether - total);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_infiniteAllowanceNeverDecrements(uint256 amount) public {
        amount = bound(amount, 0, 1_000 ether);
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, amount));
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(bob), amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_roundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY - 1_000 ether);
        assertTrue(token.transfer(bob, amount));
        vm.prank(bob);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY - 1_000 ether);
        assertEq(token.balanceOf(bob), 0);
    }
}
