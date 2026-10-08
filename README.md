# Work (WORK)

This project implements the supplied contracts with two reviewed corrections: input-side hook fees are calculated as a fraction of the total input paid, and sweeping excludes native currency so forced ETH cannot block token fee payouts. `launch.json`, including its notes string, is preserved exactly. [REVIEW.md](REVIEW.md) and [.imd-responses.json](.imd-responses.json) record the revision evidence and dispositions.

## Token and pool

`Work()` is an OpenZeppelin ERC-20 named **Work**, symbol **WORK**, with 18 decimals. Its constructor mints exactly **1,000,000,000 WORK** (`10^27` minor units) to its immediate caller. In the network launch that caller is the launch factory, which is responsible for distribution and liquidity. The token has no external mint, owner, pause, tax, blocklist, or upgrade function.

`WorkLaunchHook(IPoolManager manager, address token)` stores both constructor arguments immutably. The hook accepts one pool containing WORK and IMD at `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`, with fee **12500** (1.25% LP fee) and tick spacing **60**. Sort the currencies by address. The manifest specifies `sqrtPriceX96 = 79228162514264337593543950336` (`2^96`), a 1:1 ratio of raw token units. Whether that is a 1:1 whole-token ratio depends on the paired token's decimals.

The hook requires these low 14 address bits:

```
uint160(hookAddress) & 0x3fff == 0x2044
0x2000 beforeInitialize
0x0040 afterSwap
0x0004 afterSwapReturnDelta
```

Its constructor validates these permissions. There is no `getHookPermissions()` function in the requested source; permissions are enforced by the constructor and the address bits.

## Hook fees and administration

The successful initialization records `openedAt = block.timestamp`. The fee starts at 5000 basis points (50%) and slides linearly over 900 seconds to the current standing fee, initially 200 basis points (2%). For elapsed seconds `e` below 900:

```
standingFee + floor((5000 - standingFee) * (900 - e) / 900)
```

At and after 900 seconds it equals `standingFee`. Before initialization, `feeNow()` also reports 5000. With the initial standing fee, rates at elapsed 0, 450, 899, and 900 seconds are 5000, 2600, 205, and 200 basis points.

Every swap **in this hooked pool** charges a fee on the unspecified side of the real PoolManager swap. Let `a` be that side's pre-hook delta and `r = feeNow()`:

```
a >= 0 (output): fee = floor(a * r / 10000)
a < 0  (input):  fee = floor(abs(a) * r / (10000 - r))
```

The output fee is the fraction `r / 10000` of the pool output. The input fee is the same fraction of the trader's total input (`pool input + fee`), subject to rounding. At 50%, a 100-unit pool output leaves 50 units for the trader; a 100-unit pool input costs the trader 200 units, with 100 going to the treasury. At 2%, input is multiplied by `10000 / 9800`. LP fees and price impact still affect the underlying pool amounts, so this does not promise identical quotes across swap modes.

| Swap | Currency charged | Effect on trader |
| --- | --- | --- |
| Exact input, currency0 to currency1 | currency1 output | Less currency1 received |
| Exact input, currency1 to currency0 | currency0 output | Less currency0 received |
| Exact output, currency0 to currency1 | currency0 input | More currency0 paid |
| Exact output, currency1 to currency0 | currency1 input | More currency1 paid |

Fees use the executed amounts, including partial fills, and round down by less than one smallest unit of the charged currency. Dust fees can round to zero: at 2%, an output below 50 units or a pool input below 49 units incurs no hook fee. The LP fee is separate; hook fees are not converted to ETH. They remain in the charged currency, either WORK or IMD.

WORK transfers and trades in other pools have no hook fee. Anyone holding WORK can supply a hookless WORK/IMD pool, including during the launch ramp. The manifest's phrase "Every swap" describes swaps in the accepted hooked pool; it is not a token-wide tax or protection against trading elsewhere.

Only `0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0` (the constant `B`) can call `setStandingFee(uint256)`. Values from 0 through 1000 basis points (0–10%) are accepted and emit `StandingFee(uint256)`. Changes are immediate, including during the launch ramp: they change its endpoint without resetting `openedAt`. There is no timelock, recipient change, administrator transfer, pause, or upgrade.

## Accrual and sweep

`afterSwap` mints ERC-6909 claims to the hook in the PoolManager. Anyone may call `sweep()` while the manager is locked (outside an existing unlock). The manager calls `unlockCallback`, which burns both currencies' claims and transfers their underlying tokens directly to `B`. The sweep also transfers any direct IMD or WORK donations to `B`. Native currency is excluded: forced ETH remains at the hook without a recovery path and cannot prevent token fee payouts, even if the treasury rejects ETH. The caller receives no reward.

Empty and repeated sweeps are valid. A failed IMD or WORK transfer still reverts the entire transaction, restoring all claims and earlier transfers; token payouts remain coupled. `sweep()` cannot be nested within a PoolManager unlock. Only the configured manager can invoke the three callbacks.

## Offline build and tests

Use Foundry 1.8.3 with Solidity **0.8.26** installed in its normal compiler cache. The repository pins Cancun, optimizer enabled with 200 runs, `via_ir = true`, and `bytecode_hash = "none"`. FFI and filesystem cheatcode access are disabled. All imported dependency sources are ordinary files under `lib/`; no install step, RPC, fork, environment variables in tests, compiler binary in the tree, or submodules are required.

```
forge build --offline
forge test --offline
forge fmt
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
forge test --offline --fuzz-seed 0x574f524b --fuzz-runs 1024
```

`forge build` and `forge test` also work directly; the default profile is offline. Tests deploy the real v4.0.0 PoolManager and real WORK, mine and execute CREATE2 for the actual hook, and use the upstream test routers to settle swaps. A test-only ERC-20 runtime is installed at the fixed IMD address; tests do not establish the behavior of the live IMD deployment. An otherwise identical pool without a hook supplies an independent baseline for swap deltas. Both currencies' trader balances, manager reserves, claims, and treasury payouts are checked.

Sources and archive hashes are recorded in [docs/dependencies.json](docs/dependencies.json). Vendored versions are Uniswap v4-core **v4.0.0**, OpenZeppelin Contracts **v5.0.2**, forge-std **v1.9.7**, and the Solmate commit pinned by v4.0.0. Upstream source/license files are retained; upstream CI, package-manager installations, and unrelated repository tooling are omitted.

## Deployment parameters and responsibilities

The network deployer consumes `launch.json`: it resolves `$poolManager` to the target chain's manager and `$token` to the newly deployed WORK. Neither is a guessed address. The default launch target is Sepolia, chain **11155111**; Cancun support is required. No transactions were submitted by this assignment.

The deployer must:

1. Verify the selected PoolManager and the brief's fixed IMD address have the expected code and token behavior on the launch chain; confirm IMD metadata/decimals and the intended initial price. The hook does not check manager or token bytecode in its constructor. Revision-time `cast code` calls to the Sepolia publicnode endpoint returned `0x` for both IMD and the treasury. This is not deployment approval: do not launch until IMD exists at the fixed address and its behavior is verified. A treasury EOA needs no code, but its control and token receipt must be confirmed by the operator. Offline tests install only a test IMD runtime and cannot establish live readiness.
2. Deploy WORK through the launch factory and ensure its full supply initially belongs to that factory.
3. Form the hook init code as `type(WorkLaunchHook).creationCode ++ abi.encode(manager, token)`. Mine a salt for the **actual address executing CREATE2**, using the final compiler settings and final constructor arguments. `script/HookMiner.sol` implements the standard `keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))` prediction and a bounded salt search.
4. Deploy at a vacant address with exactly flags `0x2044`, verify immutables, initialize the sorted pool at the manifest price, and seed its initial liquidity **in one atomic factory transaction**. Initialization is permissionless and the supplied hook does not restrict the caller or check the initial price. A deployment split across transactions lets another caller initialize first at a different price and start the timer; there is no reset. The factory must revert the entire launch if initialization or liquidity seeding fails.
5. Arrange liquidity amounts, ticks, custody, and approvals under the launch policy before that transaction. Initialization alone creates no liquidity: the 900-second ramp starts at initialization, not at first liquidity or first trade. If liquidity is delayed, the ramp can fully expire before trading starts. The hook does not enforce the factory's atomic seeding requirement, and idle time still consumes the ramp. Ensure the network's external review and source verification are complete before release.

Changing the manager, token, CREATE2 deployer, compiler version/settings, or dependency code changes the predicted address and requires mining again. Do not substitute a vanity address or bypass the constructor checks.

`script/Deploy.s.sol` is an optional standalone operator utility, separate from the network factory. Its no-argument `run()` deploys only WORK, making the documented offline command a token deployment smoke simulation; it does not launch a pool. Its `deployHook(address,address,bytes32)` entry point deploys one hook, after checking both constructor arguments have code. Each deployment entry point has exactly one deployment between broadcast markers. Only `EXPECTED_CHAIN_ID` is read: 0 or unset is restricted to local chain 31337; a nonzero value must match, and only 31337 and 11155111 are supported.

Operator-only token simulation command (add `--broadcast` only in the network's approved signing environment):

```
EXPECTED_CHAIN_ID=11155111 forge script script/Deploy.s.sol:Deploy --sig 'run()'
```

The operator's tooling must supply the connection and signing configuration; this repository contains neither. For the separate hook entry point, supply the real manager, already deployed WORK, and mined salt via `--sig 'deployHook(address,address,bytes32)'`. For a Foundry script CREATE2 deployment, mine for the CREATE2 deployer actually used by Foundry, which may differ from the script address or signer. The network factory must mine for its own CREATE2 execution address instead. The read-only `mine(address,address,address,uint256,uint256)` helper accepts that deployer explicitly and returns the predicted address and salt. The network launch should use its normal factory workflow rather than these standalone deployment entry points.

## After launch and assumptions

The treasury may leave the 2% standing fee unchanged, or call `setStandingFee` with an integer from 0 to 1000. Any keeper or user may pay gas to call `sweep()` periodically; there is no automatic scheduler or caller incentive. The treasury must accept both paired tokens; it need not accept ETH. A reverting paired token can prevent both token payouts, as covered by rollback tests. Unrelated ERC-20 tokens and forced ETH sent to the hook have no rescue path.

The supplied design assumes the authentic v4 PoolManager, a normally transferring paired ERC-20, nonzero and nondecreasing chain timestamps, and a working fixed treasury. It does not support fee-on-transfer/rebasing token accounting. The fee ramp is a launch charge, not a guarantee against MEV; routers must enforce user slippage/deadline limits. There is no on-chain oracle, upgrade path, or emergency administrator. Independent security review remains the network's release responsibility; [REVIEW.md](REVIEW.md) records the checks performed here and their limits.
