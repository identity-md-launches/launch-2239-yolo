// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Yolo} from "../src/Yolo.sol";

/// @dev Unlike the closed four-holder model, recipients here are arbitrary fuzzed addresses, the
/// deployer starts with most of the supply, and calls that must fail (zero receiver, zero spender,
/// zero sender, overspend, unauthorized spend) are attempted on purpose. Every address that may
/// hold tokens is recorded so the invariants can sum the whole ledger.
contract YoloOpenHandler is Test {
    Yolo public immutable token;
    address[] public holders;
    mapping(address => bool) public known;
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostMoved;
    uint256 public successfulCalls;
    uint256 public rejectedCalls;
    uint256 public unexpectedResults;

    constructor(Yolo token_, address[] memory seeded) {
        token = token_;
        for (uint256 i; i < seeded.length; ++i) {
            _track(seeded[i]);
            ghostBalance[seeded[i]] = token_.balanceOf(seeded[i]);
        }
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function _track(address account) private {
        if (!known[account]) {
            known[account] = true;
            holders.push(account);
        }
    }

    function _pick(uint256 seed) private view returns (address) {
        return holders[seed % holders.length];
    }

    /// @dev Recipient is either a known holder or a brand new fuzzed address (zero included).
    function _recipient(uint256 seed, address fresh, bool useFresh) private view returns (address) {
        return useFresh ? fresh : _pick(seed);
    }

    function _record(bool success, bool shouldSucceed) private {
        if (success != shouldSucceed) ++unexpectedResults;
        if (success) ++successfulCalls;
        else ++rejectedCalls;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, address fresh, bool useFresh, uint256 amount, uint8 mode)
        external
    {
        address from = _pick(fromSeed);
        address to = _recipient(toSeed, fresh, useFresh);
        uint256 balance = ghostBalance[from];
        // mode: 0 exact balance, 1 zero, 2 over by one, otherwise bounded random.
        if (mode % 4 == 0) amount = balance;
        else if (mode % 4 == 1) amount = 0;
        else if (mode % 4 == 2) amount = balance == type(uint256).max ? balance : balance + 1;
        else amount = bound(amount, 0, balance);
        bool shouldSucceed = to != address(0) && amount <= balance;

        vm.prank(from);
        (bool success, bytes memory ret) = address(token).call(abi.encodeCall(token.transfer, (to, amount)));
        _record(success, shouldSucceed);
        if (success) {
            if (ret.length != 32 || !abi.decode(ret, (bool))) ++unexpectedResults;
            _track(to);
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            ghostMoved += amount;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, address fresh, bool useFresh, uint256 amount, uint8 mode)
        external
    {
        address owner = _pick(ownerSeed);
        address spender = _recipient(spenderSeed, fresh, useFresh);
        if (mode % 3 == 0) amount = 0;
        else if (mode % 3 == 1) amount = type(uint256).max;
        bool shouldSucceed = spender != address(0);

        vm.prank(owner);
        (bool success,) = address(token).call(abi.encodeCall(token.approve, (spender, amount)));
        _record(success, shouldSucceed);
        if (success) {
            _track(spender);
            ghostAllowance[owner][spender] = amount;
        }
    }

    function transferFrom(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        address fresh,
        bool useFresh,
        uint256 amount,
        uint8 mode
    ) external {
        address owner = _pick(ownerSeed);
        address spender = _pick(spenderSeed);
        address to = _recipient(toSeed, fresh, useFresh);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 balance = ghostBalance[owner];
        uint256 available = allowed < balance ? allowed : balance;
        // mode: 0 exactly available, 1 one past available, otherwise any amount up to balance + 1.
        if (mode % 3 == 0) amount = available;
        else if (mode % 3 == 1) amount = available == type(uint256).max ? available : available + 1;
        else amount = bound(amount, 0, balance + 1);
        bool shouldSucceed = to != address(0) && amount <= allowed && amount <= balance;

        vm.prank(spender);
        (bool success, bytes memory ret) = address(token).call(abi.encodeCall(token.transferFrom, (owner, to, amount)));
        _record(success, shouldSucceed);
        if (success) {
            if (ret.length != 32 || !abi.decode(ret, (bool))) ++unexpectedResults;
            _track(to);
            ghostBalance[owner] -= amount;
            ghostBalance[to] += amount;
            if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
            ghostMoved += amount;
        }
    }

    /// @dev The zero address can never act as a sender, even with a zero amount.
    function transferFromZeroAddress(uint256 toSeed, uint256 amount) external {
        address to = _pick(toSeed);
        amount = bound(amount, 0, type(uint256).max);
        vm.prank(_pick(amount));
        (bool success,) = address(token).call(abi.encodeCall(token.transferFrom, (address(0), to, amount)));
        _record(success, false);
    }
}

contract YoloOpenInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    Yolo private token;
    YoloOpenHandler private handler;
    address private deployer;

    function setUp() public {
        deployer = makeAddr("deployer");
        vm.prank(deployer);
        token = new Yolo();

        address[] memory seeded = new address[](4);
        seeded[0] = deployer;
        seeded[1] = makeAddr("distributor");
        seeded[2] = makeAddr("pool");
        seeded[3] = makeAddr("trader");
        vm.startPrank(deployer);
        assertTrue(token.transfer(seeded[1], SUPPLY / 10));
        assertTrue(token.transfer(seeded[2], SUPPLY / 2));
        vm.stopPrank();

        handler = new YoloOpenHandler(token, seeded);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.transferFromZeroAddress.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_everyHolderMatchesModelAndLedgerSumsToSupply() public view {
        uint256 n = handler.holderCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address holder = handler.holders(i);
            uint256 balance = token.balanceOf(holder);
            assertEq(balance, handler.ghostBalance(holder), "balance diverged from model");
            sum += balance;
        }
        assertEq(sum, SUPPLY, "tokens exist outside the tracked holders");
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesMatchModel() public view {
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.holders(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.holders(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender));
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_everyCallSucceededOrFailedAsSpecified() public view {
        assertEq(handler.unexpectedResults(), 0, "a call succeeded that should fail, or the reverse");
    }

    /// @dev Guards against a vacuous campaign: across a sequence, both outcomes must be exercised.
    function afterInvariant() public view {
        uint256 total = handler.successfulCalls() + handler.rejectedCalls();
        if (total >= 32) {
            assertGt(handler.successfulCalls(), 0, "no call ever succeeded");
            assertGt(handler.rejectedCalls(), 0, "no failure path was ever exercised");
        }
    }
}
