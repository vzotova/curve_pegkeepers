# Curve PegKeeper V3

Foundry/Vyper workspace for Curve crvUSD PegKeeper research, V2 migration testing, and an unreleased direct-liquidity PegKeeperV3 candidate.

> **Status:** unreleased version `3.0.0` on branch `main` is not deployed. Nothing in this repository authorizes deployment, allocation, registration, activation, governance execution, or broadcast.

## What a PegKeeper does

A PegKeeper uses crvUSD allocated by the ControllerFactory to rebalance one two-coin Curve pool:

- when crvUSD is scarce, it deposits crvUSD and records the amount as debt;
- when crvUSD is abundant, it removes the canonical exact crvUSD amount and reduces debt;
- it retains the LP token as backing and pays callers only from realized accounting profit.

PegKeepers are not a hard peg guarantee. Their effectiveness depends on pool depth, oracle health, policy admission, available debt capacity, and executable economics.

## Standalone direct-only architecture

Each `PegKeeperV3` is one full, non-upgradeable deployment fixed to one pool containing crvUSD and one paired token. There is no implementation contract, proxy, clone factory, keeper factory, or factory-owned registry.

The constructor:

- reads crvUSD from the canonical ControllerFactory and binds it as a public immutable;
- derives the paired token from the pool;
- optionally derives an ERC-4626 backing asset through `asset()`;
- fixes the pool liquidity ABI mode, keeper index, backing oracle, cap, profit floors, keeper reward share, and execution buffer;
- stores the final `admin`, `emergency_admin`, and selected `policy` directly on that keeper;
- grants unlimited crvUSD allowance to the ControllerFactory and unlimited pool allowances for crvUSD and the paired token.

```text
expansion:
    crvUSD (+ optional matched paired-token donation)
        -> add_liquidity on the keeper's own AMM
        -> retained LP

contraction:
    retained LP
        -> remove_liquidity_imbalance([exact crvUSD, 0], max LP burn)
        -> idle crvUSD
```

The core has no swap router, target AMM, path storage, route adapter, or detached preview module. For ERC-4626 paired tokens, loose shares are normalized with `convertToAssets()`. Held LP is valued only with `get_virtual_price()`; applying the ERC-4626 rate again would double-count it.

Expansion, donation settlement, and contraction use measured token/LP deltas, constructor-set unlimited pool allowances, quote-derived slippage bounds, and gross-before-reward accounting. Profitable expansion and donation settlement may reduce a pre-existing deficit without curing it. Contraction preview values the expected `calc_token_amount(..., false) + 1 LP wei` burn; the larger buffered burn is execution-only, where actual burn and profit are rechecked.

Ordinary interventions do not accept a caller-selected amount. `expand_supply()` and `contract_supply()` execute the sole current crvUSD amount: the configured `20%` share of normalized local imbalance, bounded by balance, backing, and capacity. `update()` selects the local direction for V2 compatibility. `update(address beneficiary)` routes the physical reward to a selected nonzero beneficiary. Both forms return zero rather than reverting when another caller already consumed the shared `action_delay`.

## PegKeeperPolicy and Registry

Each keeper stores its selected Policy directly and asks it for global executable rulings:

```solidity
policy.can_expand();
policy.can_contract();
policy.expansion_regime();
```

The current `PegKeeperPolicy` owns the aggregate crvUSD oracle and global `fee_receiver`. It does not own a keeper list or reward setting and does not call keepers for local conditions. Its current rulings use only aggregate price. The no-argument selectors deliberately preserve a replaceable Policy boundary: a future Policy can add global or caller-aware rules, using `msg.sender` as the querying keeper, without changing keeper bytecode.

Every keeper independently enforces pauses, action delay, local imbalance, backing-oracle health, capacity, AMM economics, and reward accounting. Protocol-profit withdrawal remains bounded by backing surplus and rechecks final solvency. The current Policy does not inspect keeper-local state, so one keeper's local conditions cannot block another.

`PegKeeperRegistry` is a separate governance-owned discovery list:

```solidity
peg_keeper_count();
peg_keepers(index);
is_active(keeper);
add_peg_keepers(keepers);
remove_peg_keepers(keepers);
```

It is bounded to 32 entries. Addition rejects duplicates and non-contract addresses. Removal uses pop-and-swap and repairs the moved keeper's 1-based index. A removed keeper can be added again. Neither Policy nor keeper queries Registry during execution; Registry membership does not grant or revoke execution authority.

### Independent execution and soft priorities

Keeper-local AMM fees and gross-profit floors provide soft economic preference. frxUSD has a lower entry floor; USDC and USDT require more gross edge before exposure is created. This is not hard sequencing.

The aggregate direction boundary is exact:

```text
aggregate price < 1e18: expansion denied; contraction allowed
aggregate price = 1e18: expansion and contraction allowed
aggregate price > 1e18: expansion allowed; contraction denied
```

Policy and keeper oracle reads use the declared `price()` interface directly. Reverting calls or zero aggregate prices fail closed.

## Keeper-local governance

Each keeper directly exposes:

```solidity
admin();
future_admin();
new_admin_deadline();
emergency_admin();
policy();
keeper_profit_share_bps();
commit_new_admin(newAdmin);
apply_new_admin();
set_emergency_admin(admin);
set_policy_contract(newPolicy);
set_keeper_profit_share_bps(newKeeperProfitShareBps);
```

Only the current keeper admin may update these values. Admin replacement follows Curve's three-day `commit_new_admin` / `apply_new_admin` flow: the current admin remains active during the delay and can replace or cancel a pending commitment by recommitting. After the deadline, only `future_admin` may apply. Constructor roles are nonzero and distinct; `set_emergency_admin` can later replace or revoke the emergency role. A replacement Policy must contain code. Changing `policy` changes both the global-ruling contract and global fee receiver queried by that keeper. Registry enrollment is independent and requires no coordinated execution handoff.

The Policy admin controls the nonzero `fee_receiver` once for all keepers selecting that Policy. Policy and Registry use the same three-day Curve admin transfer flow; their current admins remain active while a commitment is pending.

`admin` may configure policy parameters, execute recovery calls, pause or unpause, and use the policy-gated external draw. `emergency_admin` may only pause.

## External execution modules

Routing and arbitrage remain outside the core. The keeper admin may call:

```solidity
borrow_crvusd(uint256 amount, address receiver)
```

The draw requires Policy expansion admission, open pauses, elapsed delay, healthy retained backing, a requested amount within local imbalance, sufficient idle crvUSD, and resulting debt within both the keeper cap and ControllerFactory ceiling. It records debt and updates the shared intervention timestamp before transferring exactly the requested amount.

The draw cannot prove that an external module returns LP backing. A production integration must make the draw, external execution, backing return, and postconditions atomic. `reduce_debt(amount)` is the keeper-admin inverse bookkeeping operation.

## Donations, profit, and surplus

Loose paired-token donations can be swept into LP. Positive crvUSD matching requires the selected Policy's global expansion ruling. Under the current price-only Policy, donations are fully matched at or above `$1` and deposited one-sided below `$1`; keeper-local oracle, capacity, balance, and profit checks remain binding. Donation value is excluded from caller-profit attribution, and settlement may partially repair a pre-existing deficit.

`withdraw_profit()` first settles loose paired-token donations, then transfers all claimable idle crvUSD to the selected Policy's current global `fee_receiver`. The bounded overload performs the same accounting with a caller-supplied transfer cap. Both remain callable in contraction regimes.

Entry and normal-contraction floors apply to gross realized profit before keeper compensation and are independent:

| Profile | `entryMinProfitPpm` | `normalExitMinProfitPpm` |
|---|---:|---:|
| frxUSD | `10` (`0.1 bp`) | `150` (`1.5 bp`) |
| USDC / USDT | `300` (`3 bp`) | `80` (`0.8 bp`) |

Every contraction requires strictly positive gross realized profit before compensation, even when the configured floor is zero. Break-even and loss-making withdrawals are never permitted.

At the initial keeper-local `3_000 bps` reward share, the `0.1 bp` frxUSD entry boundary splits into `0.03 bp` for the caller and `0.07 bp` retained by the protocol. The `3 bp` USDC/USDT boundary splits into `0.9 bp` and `2.1 bp`.

## Deployment

The environment-free deployment script performs eight monotonic CREATEs:

1. `PegKeeperPolicy` administered directly by the Curve Ownership Agent;
2. `PegKeeperRegistry` administered directly by the Curve Ownership Agent;
3. frxUSD/USD Chainlink adapter;
4. USDC/USD Chainlink adapter;
5. USDT/USD Chainlink adapter;
6. standalone frxUSD PegKeeperV3;
7. standalone USDC PegKeeperV3;
8. standalone USDT PegKeeperV3.

Each keeper is complete at construction with final roles, local reward share, and selected Policy. There is no temporary implementation, deployer-controlled configuration phase, pending admin commitment, or post-deploy keeper setup transaction. The Registry is intentionally empty after deployment. Every keeper is unpaused, debt-free, and has a zero ControllerFactory allocation until governance acts.

The deployment JSON records the Policy, Registry, three oracle adapters, and three keeper addresses.

## Canonical launch proposal

The proposal contains ten actions:

1. add all three keepers to `PegKeeperRegistry` in one batch;
2. register each keeper in the current aggregate monetary policy;
3. register each keeper in the legacy aggregate monetary policy;
4. assign each keeper its ControllerFactory ceiling.

That is one Registry action, six monetary-policy registrations, and three ceiling assignments.

| Paired token | AMM | Liquidity ABI | Retained oracle | Local cap | Initial ceiling | Entry floor | Contraction floor |
|---|---|---|---|---:|---:|---:|---:|
| frxUSD | `0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1` | dynamic | frxUSD/USD | 150m | 150m | 0.1 bp | 1.5 bp |
| USDC | `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E` | fixed | USDC/USD | 150m | 150m | 3 bp | 0.8 bp |
| USDT | `0x390f3595bCa2Df7d23783dFd126427CCeb997BF4` | fixed | USDT/USD | 150m | 150m | 3 bp | 0.8 bp |

## Runtime identity

Pinned Vyper `0.4.3`, `--optimize codesize`, Prague:

```text
PegKeeperV3 version:       3.0.0 (numeric tuple: 3, 0, 0)
standalone initcode:      18,056 bytes
keeper runtime core:       15,155 bytes
standalone runtime:      15,187 bytes
EIP-170 headroom:         9,389 bytes
runtime core hash:
0x692f8e37be588b2d441bda19025847aeb33097eb353231eb14a9777df0d0f20c
mainnet runtime hash (canonical crvUSD immutable suffix):
0x418be17ea754b8b279ff2ffa4c8574a26f999d5a506806fdcc349e5eab9f0279

PegKeeperPolicy runtime:   905 bytes
policy hash:
0xa11f74514ddad33cebd3ea933e1bf8d802b74107af7b3bc23b0bb6a0067a758c

PegKeeperRegistry runtime: 1,296 bytes
registry hash:
0xa8701fd3d6a78297bb59b5d1466c6e20e96e41959650282aa03b4e7b4015e8a8
```

## Verification

```bash
git submodule update --init --recursive
make setup
ETH_RPC_URL=https://an-archive-rpc.example make check
```

Coverage includes fixed- and dynamic-array liquidity dispatch, amountless expansion/contraction, V2-compatible update/profit views, ERC-4626 valuation, donations, surplus, keeper-local role and reward changes, replaceable Policy rulings, Registry lifecycle and pop-and-swap removal, independent execution, external draw accounting, preview/execution parity, runtime pins, ABI parity, stateful invariants, deployment JSON, and full Curve ownership-vote execution.

The pinned frxUSD canary uses the production `10 ppm` entry and `150 ppm` exit profile. It exercises canonical expansion and exact-output contraction under the `20%` rule without weakening the profit floor, and verifies Policy direction, measured deltas, debt reduction, final solvency, ControllerFactory funding, idle-allocation burning, residual rugging, and persistent ControllerFactory/pool allowances.

The existing `deployments/mainnet/PegKeeperV3-release.json`, `docs/pegkeeper-v3-release-checklist.md`, and `scripts/verify-release-manifest.py` predate this source candidate. They remain frozen and must be regenerated from the final committed source snapshot before release.

## Main files

```text
src/vyper/PegKeeperV3.vy
src/vyper/PegKeeperPolicy.vy
src/vyper/PegKeeperRegistry.vy
src/vyper/ChainlinkStablecoinOracle.vy
src/interfaces/IPegKeeperV3.sol
src/interfaces/IPegKeeperPolicy.sol
src/interfaces/IPegKeeperRegistry.sol
script/DeployPegKeeperV3.s.sol
script/PegKeeperV3ReleaseCanary.s.sol
script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol
docs/pegkeeper-v3-spec.md
docs/pegkeeper-v3-suggested-launch-parameters.md
```
