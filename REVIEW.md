# Implementation verification

This is the implementing contributor's review and local verification record, not an independent security audit. The network's separate independent adversarial review remains a release step. No transactions were broadcast. Revision-time Sepolia code queries returned `0x` for the fixed IMD and treasury addresses; no paired-token implementation or treasury control was verified.

## Source fidelity and dependencies

- The original submission preserved the supplied Solidity logic. This revision changes only the input-side fee denominator and removes the native balance from the sweep loop, after reproducing both supplied proofs. Token logic, callback permissions, constants, constructor arguments, fee timing, and administration remain unchanged.
- Compared every parsed `launch.json` field with the assignment, including a byte-for-byte comparison of the notes string.
- Used v4-core v4.0.0 rather than the newer local mirror because the supplied hook uses that release's `IPoolManager.SwapParams` interface.
- Vendored the imported dependency sources as ordinary files, with licenses and archive hashes in `docs/dependencies.json`. Solmate uses v4.0.0's pinned submodule commit, copied as files rather than a git submodule. No dependencies require a network at build/test time.

## Review observations and disposition

| Observation | Disposition / evidence |
| --- | --- |
| Hook construction requires exact address permissions | Real CREATE2 deployment and incorrect-flags rejection are tested. Salt preparation must use the actual CREATE2 deployer and final init code. |
| Initialization is permissionless and the price is not validated by the hook | Reproduced third-party initialization at a different price and subsequent factory lockout. Preserved as requested; README now requires atomic hook deployment, initialization at the manifest price, and initial liquidity seeding. Invalid pairs, fees, tick spacing, hook reference, unauthorized callbacks, repeat initialization, and failed-initialization rollback are tested. |
| Manager and token addresses are immutable; the supplied constructor does not check their code | Preserved. The network must resolve and verify the two manifest parameters. The optional standalone hook script checks that both have code. Tests use a real PoolManager and real WORK. |
| The standing-fee administrator can immediately change the ramp endpoint and post-ramp fee | Preserved, documented, and tested. The only accepted caller is the fixed treasury and the permitted range is 0–1000 bps. No recipient, owner, upgrade, or pause control was introduced. |
| Exact-output fees were a smaller effective fraction than exact-input fees | Corrected negative unspecified deltas to use `abs(a) * rate / (10000 - rate)`. Both directions and swap modes are checked against a real unhooked pool at launch, midpoint, standing, maximum standing, and zero fees, including partial fills and fuzzed amounts/rates. An independent assertion measures the fee fraction from actual trader deltas, allowing less than one smallest unit of rounding. Assertions also cover trader balances, manager balances, claims, and fixed WORK supply. |
| The hook holds claims until a keeper/user pays for sweeping | Preserved and documented. Permissionless, empty, repeated, donation, and subsequent-swap sweeps are tested. Both currencies reach the fixed treasury; the sweeper receives none. |
| Forced ETH could block all token payouts when the treasury rejected native transfers | Removed the unused native sweep leg. A regression forces one wei via constructor selfdestruct under Cancun and verifies both fee claims and direct token donations reach a rejecting treasury, including repeated sweeps. Forced ETH remains at the hook without a recovery path. |
| A paired-token transfer failure can still block both token payouts | Preserved within this bounded fix. Failure tests demonstrate complete transaction rollback, retaining claims and preventing partial payout. Both paired tokens must remain transferable to the fixed treasury. A nested manager unlock is rejected. |
| The ramp runs before liquidity exists | Reproduced initialization, a 900-second wait, then liquidity and the first trade at 2%. The requested initialization-based timer remains unchanged. README requires seeding in the atomic launch transaction; the hook does not enforce it or guarantee 15 minutes from the first trade. |
| Other WORK pools pay no hook fee | Reproduced a swap in a hookless WORK/IMD pool at fee 3000 with zero hook claims. README qualifies fees as applying only to this hooked pool. No restriction was added to WORK. |
| Dust fees round to zero | Reproduced a 50-wei exact-input trade yielding 48 wei with zero claims at 2%. Floor rounding is retained; README documents the output/input thresholds. |
| No `getHookPermissions()` getter; deployment prerequisites need verification | Confirmed getter absence with a failed staticcall, correct address flags, and wrong-flags constructor rejection. No getter is required by the supplied constructor/address-bit design. Sepolia `cast code` calls returned `0x` for IMD and the treasury. README makes live IMD code/behavior and treasury control explicit launch prerequisites. |
| Slippage and initial liquidity are external operational responsibilities | Documented. Test routers are upstream harnesses, not a production user router. No LP bootstrapping, frontend, MEV guarantee, or production router is added. |

## Re-run checks

Foundry **1.8.3**, Solidity **0.8.26**, Cancun EVM, optimizer 200, via IR, metadata hash disabled.

```
forge build
forge test
forge fmt
forge fmt --check
forge test --match-path 'test/scratch/Proof_*.t.sol' -vv
```

The permanent suite contains **47 tests** in two suites: 6 token tests and 41 hook tests. Five fuzz tests cover transfers, unauthorized administration, out-of-range fees, bounded/monotone fee schedules, and actual swap accounting. The default run uses 256 cases per fuzz test. Inputs are bounded and tests neither read nor mutate environment variables. No fork or mocked PoolManager is used. Only the fixed-address paired token and a rejecting native recipient use test runtime installation.

Before editing the hook, copied both supplied proofs unchanged into `test/scratch/` and ran them. The exact-output proof failed with `3334 !~= 5000`; the native sweep proof failed with `WrappedError` / `NativeTransferFailed` after forcing one wei. The five `testReview*` characterization tests passed against the original hook, reproducing the advisory behaviors. Scratch copies are verification inputs and are not part of the deliverable; permanent tests cover the corrected fee fraction and forced-ETH payout regression.

After the fixes, `forge test -vv` passed all **49 tests**, including both unchanged scratch proofs and all 47 permanent tests. The exact-output proof now reports 5000 bps for both routes and input of `100014813231403300540` for its exact-output purchase. Scratch proof copies were then moved outside the repository before formatting, leaving the supplied proof files untouched.

Final checks without scratch tests passed: `forge build`, `forge test` (47 passed, zero failed), and `forge fmt --check`, using the pinned Solidity 0.8.26 configuration. A byte comparison confirms `launch.json` is unchanged, including its notes string; all seven finding responses are present in `.imd-responses.json`.

The original submission's deployment smoke command succeeded offline and deployed one WORK token in simulation. The unchanged standalone script was not re-run for this revision. The network factory launch is separate; the smoke run does not demonstrate a live pool launch. CREATE2 hook construction is exercised by the integration tests and salts must be mined again for the changed hook bytecode.

Foundry lint emits advisory warnings about timestamp comparisons, `openedAt` changing without a dedicated hook event, explicit numeric casts, an unused unlock return value, and external calls in fixed-length loops. The forced-value test helper intentionally uses deprecated `selfdestruct` to reproduce the reported attack; production contracts do not. Initialization also emits the real PoolManager event. Fee arithmetic and rounding are exercised across bounded input ranges; both sweep loops now cover only the two pool currencies. Build success and these tests are not a proof for every possible external token behavior or integer boundary.

Slither, Mythril, a new independent audit, deployment, and explorer verification were not performed. Live RPC checks were limited to the two Sepolia `cast code` reads above; no mainnet or Base verification was repeated.
