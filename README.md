# Morpheus BuildersV4 — retroactive withdraw-lock PoC (J2)

A Foundry mainnet-fork proof of concept showing that on the **deployed** BuildersV4 contract on Base
(`0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9`), a **permissionless** subnet admin can retroactively raise
`withdrawLockPeriodAfterDeposit` via `editSubnet` **after** a depositor has staked, permanently locking that
depositor's MOR principal (the depositor can no longer `withdraw`).

## Run it (one command, from a clean clone)

```bash
git clone --recursive https://github.com/gons66/morpheus-j2-poc && cd morpheus-j2-poc
BASE_ARCHIVE_RPC=https://mainnet.base.org forge test --match-path test/J2_capture.t.sol -vv
```

`BASE_ARCHIVE_RPC` can be any Base **archive** RPC (the test forks at a pinned historical block). If you
cloned without `--recursive`, run `git submodule update --init` first. No other setup is needed.

The test pins fork block **50970873** (Base mainnet, chainId 8453).


## Expected result: 3 passed / 0 failed

- `test_control_honestWithdrawSucceeds` — NEGATIVE CONTROL: with the honest (untampered) lock, the depositor
  deposits and, after the lock elapses, `withdraw` succeeds and their principal is returned.
- `test_exploit_designedLock_permanentRevert` — the attacker creates a subnet with a benign lock, the victim
  deposits, the attacker `editSubnet`s the lock up to `~2^127`, and the victim's `withdraw` reverts with the
  exact reason `"BU: user withdraw is locked"`. Asserts the principal is still escrowed in the proxy, the
  victim received nothing, and the **attacker's MOR balance is unchanged**.
- `test_exploit_overflowLock_panics` — incidental variant: a lock of `type(uint128).max` makes
  `lastDeposit + lock` overflow (Panic 0x11) before the timestamp comparison.

## Honest scope note

The test "victim" (`0xBEEF`) is a **synthetic funded address**; the test scripts both the attacker and the
victim — it is **not** a real third party. This PoC demonstrates the **mechanism** and a negative control on
the deployed bytecode; real-world magnitude depends on deposits an attacker manages to attract into its own
subnet. It is a **permanent-lock / griefing of depositor principal, not theft** — the attacker gains nothing.
This repository does not assert a severity; severity is assigned by the program.
