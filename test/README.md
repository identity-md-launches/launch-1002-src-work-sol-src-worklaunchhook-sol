# WORK test suite

Run `forge build` and `forge test` from the repository root. No downloads, RPC,
environment variables, or additional dependencies are needed. The accepted unit
tests remain in `Work.t.sol` and `WorkLaunchHook.t.sol`; their fuzz campaigns use
1,000 cases through inline configuration.

## Stateful properties

Both invariant suites use 256 sequences of 128 handler calls, with unexpected
reverts treated as failures. Only explicitly selected handler functions are
fuzzed. Expected rejection paths use `expectRevert`; there are no discarded inputs
or swallowed failures. Deterministic sequences also exercise handler actions and
known boundaries.

| Suite | Random actions | Properties |
| --- | --- | --- |
| `WorkInvariant.t.sol` | Transfers, approvals, delegated transfers, allowance revocation, overspending, invalid recipients across three actors | Fixed supply; every actor balance matches an independent transfer ledger; allowances match approvals and finite/infinite spending rules |
| `WorkLaunchInvariant.t.sol` | All four swap modes, time advancement, authorized/unauthorized fee changes, donations, sweeps, blocked sweeps, unauthorized callbacks, attempted claim theft, liquidity round trips across three actors | Fees and donations are conserved; all claims are backed; only the treasury receives payouts; supply is conserved; initialization time stays fixed; fee bounds hold; manager accounting settles and locks |

The hook fee ledger uses the real PoolManager's `Swap` event (emitted before
`afterSwap`) and actual settled trader deltas. It does not compute expected fees
using a copy of the hook's formula. A separate assertion measures the charged
fraction of gross output or total input, allowing less than one base unit of
rounding. Pool balances must equal the pool's accumulated asset ledger plus
outstanding hook claims. Treasury balances must exactly equal cumulative payouts.

The handler seeds nonzero claims in both currencies and all four swap modes.
Every random sequence ends with two permissionless sweeps, checking withdrawal
liveness and idempotence. Failed sweeps must preserve balances and claims;
unblocking the paired token must restore payout availability. Immediate add/remove
liquidity cycles cannot produce a trader profit or hook fees.

Bounds keep swaps and liquidity cycles between 1 base unit and 1,000 tokens,
donations between zero and 100 tokens, and time steps between zero and 120 seconds.
The pool begins with 1,000,000 units of full-range liquidity; each actor starts
with 10,000,000 of each token. These budgets support the full configured sequence
without replenishing balances. The separate token campaign spans the full fixed
supply and arbitrary uint256 allowances; deterministic cases include zero, one,
self-transfers, the full supply and infinite approval.

## Failure and arithmetic checks

In addition to the accepted failure tests, regressions cover a failed exact-output
settlement after fees and donations already exist, failure of a direct donation
transfer after the unlock callback has paid claims, and swaps without liquidity.
The ramp's fuzz properties include boundedness, monotonicity and linear symmetry
at complementary timestamps. Existing tests cover constructor flags, pool-key
validation, initialization rollback, all callback permissions, administrator
bounds, partial fills, dust, sweep retries and forced native currency.

## Integration scope

PoolManager, WORK and the CREATE2 hook are real deployments. IMD uses the existing
test-only ERC-20 runtime at the required paired-currency address, including an
optional rejecting recipient for payout failure tests. No deployed IMD behavior,
live pool state or treasury control is verified here. A fork check against the
intended deployment remains outside this offline suite.

Tests build on the accepted hook revision, including its corrected input-fee
denominator and token-only sweep. No production logic, manifest, dependency or
configuration is changed by this contribution.
