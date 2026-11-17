# Morpheus — BuildersV4 editSubnet unbounded withdraw lock (PoC)

Foundry proof of concept for a Morpheus bug bounty report. `editSubnet` lets
the subnet admin rewrite `withdrawLockPeriodAfterDeposit` with no upper bound
and no time gate; `withdraw` reads the CURRENT lock, so raising it after
deposits retroactively locks all stakers indefinitely. V3 gated edits to
pre-pool-start (`block.timestamp + editPoolDeadline < poolStart_`); V4 removed
the gate — a regression of an intended control. The subnet admin is a
permissionless role (`createSubnet` is public, anyone creates a subnet for
free), not protocol-owner privilege.

- **Target:** BuildersV4 `0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9`
  (Base proxy, Appendix A)
- **Fork:** Base mainnet, pinned to block **58650783**
- **Result:** victim locked even 100 years after the admin raises the lock to
  1,000 years; lock = `type(uint128).max` panics `withdraw` (arithmetic
  overflow, 0x11); the admin claims 1,832 MOR of rewards from the locked
  deposits. Live: $127k in the largest single subnet (180,512 MOR), $2.12M
  aggregate across subnets. No privileged accounts are used.

## Run (one command, from a clean clone)

```sh
forge test
```

Requires [Foundry](https://getfoundry.sh/) (forge 1.9+). `forge-std` is vendored
under `lib/`, so no install step is needed. The fork RPC is
`https://mainnet.base.org`.

## What the tests assert

- `test_AdminLockAttack` — control: after the 7-day lock expires the victim CAN
  withdraw; attack: after the admin raises the lock to 1,000 years the victim's
  withdrawal reverts even 100 years later, and at `type(uint128).max` it reverts
  with an arithmetic panic; the victim's 999 MOR stays in the contract,
  inaccessible, while the admin claims the accrued rewards.
- `test_SubnetDepositsEnumeration` — enumerates the 92 legacy subnets' live
  deposits (largest legacy subnet 130,422 MOR ≈ $92,000; the largest subnet
  overall is a V4 subnet holding 180,512 MOR ≈ $127,400 per the Morpheus
  Marketplace API).
