"""PegKeeperV3 against a StableSwap-NG pool that bounds oracle rate moves.

Such a pool carries two virtual prices. get_virtual_price() values LP at what it redeems
for, reading the rate sources directly; virtual_price_bounded() values it at the rates
quotes, mints and burns are priced at. They differ while a rate catches up, one bound per
block. A keeper that values LP with the first and transacts at the second measures the gap
between them as profit - an entry profit that exists only at the sources' price, and an
exit loss that blocks unwinding - so the patch puts both sides of an action on the lower of
the two. A pool that halts on a reading it will not accept quotes nothing at all, which is
a liveness problem rather than an accounting one, so the money-moving paths close for the
duration and poke_pool walks the pool back.

Every test runs BOTH the current keeper and the patched one against the real pool, so each
assertion is a difference in behaviour rather than a claim about one of them. The pool is
compiled with its own 0.3.10 compiler and deployed from bytecode, because the keeper needs
0.4.3.

    pip install titanoboa                       # vyper 0.4.3, for the keeper
    STABLESWAP_NG=<path to the stableswap-ng checkout>   # defaults in build_ng.py
    python test/boa/build_ng.py                 # compiles the pool stack beside this file
    pytest test/boa/test_bounded_rate_pool.py -s
"""

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import boa
import pytest
from eth_abi import encode
from eth_utils import function_signature_to_4byte_selector

REPO = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BUILD = HERE / "ng_build.json"

ORACLE_METHOD_ID = function_signature_to_4byte_selector("exchangeRate()")
ZERO = "0x" + "00" * 20
OFFPEG = 20_000_000_000
TVL = 10**6 * 10**18
PRINCIPAL = 100_000 * 10**18

# One rate bound is one fee at N=2, so a 4 bp fee bounds a rate move to 4 bp per block.
FEE = 4_000_000
# A=200 with a tilted pool: where the keeper's own 20% action share clears the entry floor
# on its merits. The gap between sum(xp) and D is ~14 bp here, which is what made a
# pro-rata stand-in for the bounded price inert; the pool publishes the price instead.
AMP = 200
ENTRY_PPM, EXIT_PPM, BUFFER_BPS, SHARE_BPS = 10, 150, 3, 3_000  # the launch profile

MOCKS = """
# pragma version 0.4.3

stablecoin: public(address)
ceiling: public(uint256)
can_expand: public(bool)
can_contract: public(bool)
expansion_regime: public(bool)
fee_receiver: public(address)

@deploy
def __init__(_stablecoin: address, _receiver: address):
    self.stablecoin = _stablecoin
    self.fee_receiver = _receiver
    self.ceiling = max_value(uint256) // 2
    self.can_expand = True
    self.can_contract = True

@external
@view
def debt_ceiling(_account: address) -> uint256:
    return self.ceiling

@external
@view
def price() -> uint256:
    return 10 ** 18
"""


# <---------------------   the pool, from its own compiler   --------------------->


@pytest.fixture(scope="module")
def ng():
    """The compiled pool stack, rebuilt whenever the pool sources it came from change."""
    for attempt in (1, 2):
        if BUILD.exists():
            build = json.loads(BUILD.read_text())
            if build.get("_sources_sha256") == _pool_sources_digest():
                return build
        if attempt == 2:
            raise AssertionError("ng_build.json does not match the pool sources it was built from")
        subprocess.run([sys.executable, str(HERE / "build_ng.py")], check=True)


def _pool_sources_digest():
    """Hash the pool sources exactly as build_ng.py does, to catch a stale fixture."""
    ng_path = os.environ.get("STABLESWAP_NG", str(REPO.parent / "stableswap-ng"))
    # build_ng.py hashes its TARGETS in key order; this must match it exactly
    sources = [
        "contracts/main/CurveStableSwapNG.vy",  # amm
        "contracts/main/CurveStableSwapNG.vy",  # amm_blueprint
        "contracts/mocks/ERC20.vy",
        "contracts/mocks/ERC20Oracle.vy",
        "contracts/mocks/ERC4626.vy",
        "contracts/main/CurveStableSwapFactoryNG.vy",
        "contracts/main/CurveStableSwapNGMath.vy",
        "contracts/main/CurveStableSwapNGViews.vy",
    ]
    digest = hashlib.sha256()
    for name in sources:
        digest.update(Path(ng_path, name).read_bytes())
    return digest.hexdigest()


def _deploy(ng, name, types=(), args=()):
    code = bytes.fromhex(ng[name]["bytecode"][2:])
    if types:
        code += encode(list(types), list(args))
    address, _ = boa.env.deploy_code(bytecode=code)
    return boa.loads_abi(json.dumps(ng[name]["abi"]), name=name).at(address)


def _factory(ng, owner):
    factory = _deploy(ng, "factory", ["address", "address"], [owner, owner])
    math = _deploy(ng, "math")
    views = _deploy(ng, "views")
    blueprint, _ = boa.env.deploy_code(bytecode=bytes.fromhex(ng["amm_blueprint"]["bytecode"][2:]))
    with boa.env.prank(owner):
        factory.set_math_implementation(math.address)
        factory.set_views_implementation(views.address)
        factory.set_pool_implementations(0, blueprint)
    return factory


class Pool:
    """A deployed crvUSD/paired pool, plus whatever moves its paired coin's rate.

    rated: 'none' (no rate source at all, like every launch pool), 'vault' (ERC4626, a
    rate that only ever rises and cannot revert), or 'oracle' (asset type 1, a rate that
    can rise, fall and be retracted - the configuration a yield-token test cannot reach).
    """

    def __init__(self, ng, owner, rated, amp):
        self.rated = rated
        self.crvusd = _deploy(ng, "erc20", ["string", "string", "uint256"], ["crvUSD", "crvUSD", 18])
        self.asset = _deploy(ng, "erc20", ["string", "string", "uint256"], ["USD", "USD", 18])
        self.oracle = None
        if rated == "vault":
            self.paired = _deploy(
                ng, "erc4626", ["string", "string", "uint8", "address"], ["V", "V", 18, self.asset.address]
            )
        else:
            self.paired = _deploy(ng, "erc20", ["string", "string", "uint256"], ["P", "P", 18])
            if rated == "oracle":
                self.oracle = _deploy(
                    ng, "erc20oracle", ["string", "string", "uint256", "uint256"], ["O", "O", 18, 10**18]
                )

        asset_types = {"none": [0, 0], "vault": [0, 3], "oracle": [0, 1]}[rated]
        method_ids = [b"", ORACLE_METHOD_ID if rated == "oracle" else b""]
        oracles = [ZERO, self.oracle.address if rated == "oracle" else ZERO]
        factory = _factory(ng, owner)
        address = factory.deploy_plain_pool(
            "pk", "pk", [self.crvusd.address, self.paired.address], amp, FEE, OFFPEG, 866, 0,
            asset_types, method_ids, oracles,
        )
        self.pool = boa.loads_abi(json.dumps(ng["amm"]["abi"]), name="pool").at(address)

        self.lp = boa.env.generate_address()
        self.crvusd._mint_for_testing(self.lp, 20 * TVL)
        self.crvusd.approve(address, 2**256 - 1, sender=self.lp)
        self._mint_paired(self.lp, TVL)
        self.paired.approve(address, 2**256 - 1, sender=self.lp)
        self.pool.add_liquidity([TVL, self.paired.balanceOf(self.lp)], 0, sender=self.lp)
        boa.env.time_travel(blocks=1)

    def _mint_paired(self, who, amount):
        if self.rated == "vault":
            self.asset._mint_for_testing(who, amount)
            self.asset.approve(self.paired.address, 2**256 - 1, sender=who)
            self.paired.deposit(amount, who, sender=who)
        else:
            self.paired._mint_for_testing(who, amount)

    def tilt_paired(self, multiple=1.0):
        """Add paired liquidity, so crvUSD is the scarce coin and expansion is on offer."""
        self._mint_paired(self.lp, int(TVL * multiple))
        self.pool.add_liquidity([0, self.paired.balanceOf(self.lp)], 0, sender=self.lp)
        boa.env.time_travel(blocks=5)

    def tilt_crvusd(self, multiple=2.0):
        """Add crvUSD liquidity, so contraction is the direction on offer."""
        self.pool.add_liquidity([int(TVL * multiple), 0], 0, sender=self.lp)
        boa.env.time_travel(blocks=5)

    def step_rate(self, pct):
        """Move the paired coin's reported rate by pct, and let a block pass."""
        if self.rated == "vault":
            assert pct > 0, "a vault share price cannot be walked back down"
            donation = self.paired.totalSupply() * int(pct * 1000) // 100_000
            self.asset._mint_for_testing(self.lp, donation)
            self.asset.transfer(self.paired.address, donation, sender=self.lp)
        elif self.rated == "oracle":
            rate = self.oracle.exchangeRate()
            self.oracle.set_exchange_rate(rate * (100_000 + int(pct * 1000)) // 100_000)
        boa.env.time_travel(blocks=1)

    @property
    def lag_bp(self):
        """How far the price the pool quotes sits below what the LP redeems for."""
        bounded = self.pool.virtual_price_bounded()
        return (self.pool.get_virtual_price() - bounded) / bounded * 1e4


# <---------------------   the two keepers   --------------------->


@pytest.fixture(scope="module")
def keeper_sources(tmp_path_factory):
    """The patched keeper from the working tree, and the one it replaces from the merge base."""
    base_ref = subprocess.run(
        ["git", "merge-base", "HEAD", "main"], cwd=REPO, capture_output=True, text=True, check=True
    ).stdout.strip()
    base = subprocess.run(
        ["git", "show", f"{base_ref}:src/vyper/PegKeeperV3.vy"], cwd=REPO, capture_output=True, text=True, check=True
    ).stdout
    path = tmp_path_factory.mktemp("baseline") / "PegKeeperV3Baseline.vy"
    path.write_text(base, encoding="utf8")
    return {
        "patched": boa.load_partial(str(REPO / "src" / "vyper" / "PegKeeperV3.vy")),
        "baseline": boa.load_partial(str(path)),
    }


@pytest.fixture
def build(ng, keeper_sources):
    def _build(which, rated="vault", amp=AMP, funded=True):
        owner, emergency = boa.env.generate_address(), boa.env.generate_address()
        p = Pool(ng, owner, rated, amp)
        mocks = boa.loads(MOCKS, p.crvusd.address, owner)
        keeper = keeper_sources[which].deploy(
            mocks.address, p.pool.address, rated == "vault", True, 10**9 * 10**18, 1, mocks.address,
            ENTRY_PPM, EXIT_PPM, BUFFER_BPS, SHARE_BPS, owner, emergency, mocks.address,
        )
        if funded:
            p.crvusd._mint_for_testing(keeper.address, 10 * PRINCIPAL)
        return keeper, p, mocks

    return _build


def _reverts(fn):
    try:
        fn()
        return False
    except Exception:  # noqa: BLE001 - boa raises its own error type
        return True


def _entry_profit_bp(keeper):
    """The entry profit preview_expansion measures, in bp of the crvUSD it would deploy."""
    deployed, gross_profit, _, _ = keeper.preview_expansion()
    return gross_profit / deployed * 1e4


def _expanded(build, which, rated="vault", amp=AMP):
    """A keeper already holding LP, on a pool tilted so the expansion was worth taking."""
    keeper, p, mocks = build(which, rated=rated, amp=amp)
    p.tilt_paired()
    keeper.expand_supply(sender=boa.env.generate_address())
    boa.env.time_travel(blocks=5)
    return keeper, p, mocks


# <---------------------   1. the lag must not read as entry profit   --------------------->


@pytest.mark.parametrize("rated", ["vault", "oracle"])
@pytest.mark.parametrize("step_pct", [0.2, 1.0, 4.0])
def test_a_lagging_rate_is_not_measured_as_entry_profit(build, rated, step_pct, capsys):
    """A rate step must not create entry profit the pool's own prices do not support.

    The keeper deploys crvUSD and receives LP priced at the bounded rates. Valuing that LP
    at the sources' price books the gap, which is not earnings: it comes out of the pool's
    other LPs, and 30% of it goes to whoever called. Measured against the same pool with no
    step, the patched keeper's entry profit must be the one the imbalance pays - not that
    plus the lag. The 0.2% step matters most: it is smaller than the gap between pro-rata
    reserves and D at this amplification, which is where an approximated bounded price was
    inert and this one is not.
    """
    no_step, p_no_step, _ = build("patched", rated=rated)
    p_no_step.tilt_paired()
    honest_bp = _entry_profit_bp(no_step)

    base, p_base, _ = build("baseline", rated=rated)
    p_base.tilt_paired()
    p_base.step_rate(step_pct)
    base_bp = _entry_profit_bp(base)

    patched, p_patched, _ = build("patched", rated=rated)
    p_patched.tilt_paired()
    p_patched.step_rate(step_pct)
    patched_bp = _entry_profit_bp(patched)

    with capsys.disabled():
        print(
            f"\n  {rated} +{step_pct}% (lag {p_patched.lag_bp:.2f} bp): honest {honest_bp:.3f} bp, "
            f"baseline books {base_bp:.3f} bp, patched books {patched_bp:.3f} bp"
        )
    assert base_bp > honest_bp + 0.5, "baseline should book the lag on top of the honest profit"
    assert patched_bp <= honest_bp + 0.05, (
        f"patched booked {patched_bp:.3f} bp against an honest {honest_bp:.3f} bp - "
        f"{patched_bp - honest_bp:.3f} bp of the {p_patched.lag_bp:.2f} bp lag survived"
    )


def _valued_at(keeper, unit_price):
    """What trusted_backing_value would read if the keeper valued at this unit price.

    The keeper's own arithmetic is lp_balance * unit // 1e18, so rebuilding it that way
    round-trips exactly - inverting the division instead lands a wei low.
    """
    lp = keeper.lp_balance()
    assert lp > 0
    return lp * unit_price // 10**18


@pytest.mark.parametrize("direction", ["rising", "falling"])
def test_the_keeper_values_its_position_at_the_lower_of_the_two_prices(build, direction, capsys):
    """Whichever way a rate is catching up, the keeper must use the lower price.

    Rising: the pool quotes below what the LP redeems for, so the bounded price is the
    lower one and the one a mint or burn settles at. Falling: the pool is still quoting
    the old, higher rate, so the sources are lower and the pool's price would book value
    the sources have already taken away. The patch takes the lower in both cases, which
    means it is deliberately a no-op in the falling direction - and that is what makes a
    patched-versus-baseline comparison there prove nothing. This asserts the price
    instead.

    Only an asset-type-1 oracle can fall, so this cannot be tested on a vault.
    """
    keeper, p, _ = _expanded(build, "patched", rated="oracle")
    p.step_rate(1.0 if direction == "rising" else -1.0)

    bounded = p.pool.virtual_price_bounded()
    redeems_for = p.pool.get_virtual_price()
    reads = keeper.trusted_backing_value()
    lower, higher = min(bounded, redeems_for), max(bounded, redeems_for)

    with capsys.disabled():
        print("")
        print(
            f"  {direction:8}: bounded {bounded / 1e18:.9f}, redemption {redeems_for / 1e18:.9f}, "
            f"keeper read {reads / 1e18:,.2f} against {_valued_at(keeper, lower) / 1e18:,.2f} at the "
            f"lower and {_valued_at(keeper, higher) / 1e18:,.2f} at the higher"
        )
    assert bounded != redeems_for, "the two prices did not diverge, so this test proves nothing"
    assert reads == _valued_at(keeper, lower), "the keeper valued its position at the higher price"
    assert reads != _valued_at(keeper, higher)
    expected = bounded if direction == "rising" else redeems_for
    assert lower == expected, (
        f"a {direction} rate should leave the lower price as "
        f"{'the pool quote' if direction == 'rising' else 'the sources'}"
    )


def test_an_executed_expansion_books_what_the_preview_promised(build, capsys):
    """A money path must run under a lag, not just a preview.

    expand_supply is where the measured profit turns into a caller reward in LP, so the
    settlement site has to be exercised with a rate catching up - otherwise a valuation
    that reverts to the sources' price at settlement only, and not in the preview, would
    pass unnoticed.
    """
    out = {}
    for which, step in (("patched", 0.0), ("patched", 1.0), ("baseline", 1.0)):
        keeper, p, _ = build(which, rated="oracle")
        p.tilt_paired()
        if step:
            p.step_rate(step)
        deployed, previewed_profit, previewed_reward, previewed_lp = keeper.preview_expansion()
        caller = boa.env.generate_address()
        got_deployed, got_lp, got_reward = keeper.expand_supply(sender=caller)
        out[(which, step)] = dict(
            deployed=got_deployed,
            profit_bp=previewed_profit / deployed * 1e4,
            reward=got_reward,
            # preview_expansion's own docstring calls itself an estimate, so this is a
            # closeness check: what it must not do is promise a different order of size
            reward_drift=abs(got_reward - previewed_reward) / max(previewed_reward, 1),
            lp_drift=abs(got_lp - previewed_lp) / max(previewed_lp, 1),
            paid=p.pool.balanceOf(caller),
        )

    with capsys.disabled():
        print("")
        for (which, step), r in out.items():
            print(
                f"  {which:8} +{step}%: booked {r['profit_bp']:.3f} bp, caller paid "
                f"{r['paid'] / 1e18:,.4f} LP, execution within "
                f"{max(r['reward_drift'], r['lp_drift']) * 1e4:.2f} bp of its preview"
            )
    honest, lagged, baseline = out[("patched", 0.0)], out[("patched", 1.0)], out[("baseline", 1.0)]
    for r in out.values():
        assert r["paid"] > 0, "the caller was promised a reward and paid nothing"
    # the keeper's own deposit is the block's first write, so it advances the anchor one
    # bound and settles a little away from the preview either way; what matters is how far
    for key in (("patched", 0.0), ("patched", 1.0)):
        assert out[key]["reward_drift"] < 0.01, (
            f"patched execution drifted {out[key]['reward_drift'] * 1e4:.1f} bp from its preview"
        )
    assert baseline["reward_drift"] > lagged["reward_drift"] * 5, (
        f"the baseline's preview should be the unreliable one: it drifted "
        f"{baseline['reward_drift'] * 1e4:.1f} bp against the patch's {lagged['reward_drift'] * 1e4:.1f} bp"
    )
    assert abs(lagged["profit_bp"] - honest["profit_bp"]) < 0.05, (
        f"the executed expansion booked {lagged['profit_bp']:.3f} bp against an honest "
        f"{honest['profit_bp']:.3f} bp"
    )
    assert baseline["paid"] > lagged["paid"] * 15 // 10, (
        f"the baseline paid its caller {baseline['paid'] / 1e18:,.4f} LP and the patch "
        f"{lagged['paid'] / 1e18:,.4f} LP - the lag is still reaching the caller"
    )


# <---------------------   2. the lag must not block the exit   --------------------->


@pytest.mark.parametrize("rated", ["vault", "oracle"])
def test_a_lagging_rate_does_not_block_contraction(build, rated, capsys):
    """Unwinding must stay available when the pool itself prices it as profitable.

    Valuing LP at the sources' price while the pool burns it at the bounded price makes the
    exit look like it destroys backing, so the floor rejects it - exactly when crvUSD may
    need the keeper to contract. Priced one way, the same withdrawal is the ordinary
    imbalance trade it always was, and it executes.
    """
    out = {}
    for which in ("baseline", "patched"):
        keeper, p, _ = _expanded(build, which, rated=rated)
        p.tilt_crvusd()
        p.step_rate(1.0)
        available = keeper.available_contraction()
        blocked = _reverts(keeper.preview_contraction)
        executed = None
        if not blocked:
            lp_before = keeper.lp_balance()
            keeper.contract_supply(sender=boa.env.generate_address())
            executed = lp_before - keeper.lp_balance()
        out[which] = (available, blocked, executed, p.lag_bp)

    with capsys.disabled():
        for which, (avail, blocked, executed, lag) in out.items():
            print(
                f"\n  {rated} {which:9}: lag {lag:.2f} bp, available {avail / 1e18:,.2f} crvUSD, "
                f"preview {'reverts' if blocked else 'passes'}"
                + ("" if executed is None else f", contract_supply burned {executed / 1e18:,.2f} LP")
            )
    assert out["baseline"][1], "baseline should be blocked by the lag"
    assert not out["patched"][1], "patched keeper is still blocked from unwinding"
    assert out["patched"][2] and out["patched"][2] > 0, "contract_supply did not execute on the patched keeper"


# <---------------------   3. a halt closes the money, not the books   --------------------->


def test_a_halted_pool_cannot_pay_out_its_surplus(build, capsys):
    """The payout path must close while the pool is halted.

    withdraw_profit is the one money-moving path that prices against no quote, so a halted
    pool does not stop it by itself - and the keeper's own fallback reads the sources, the
    very reading the pool just refused. Without a liveness gate, a rate move large enough
    to halt the pool pays out the whole gap the bound exists to withhold: the protection
    would be switched off by making the manipulation bigger.
    """
    out = {}
    for which in ("baseline", "patched"):
        keeper, p, mocks = _expanded(build, which, rated="oracle")
        p.step_rate(10.0)  # past HALT_THRESHOLD: the pool stops quoting
        halted = _reverts(p.pool.stored_rates)
        paid = None
        if not _reverts(lambda: keeper.withdraw_profit()):
            paid = p.crvusd.balanceOf(mocks.fee_receiver())
        out[which] = (halted, paid, keeper.debt(), keeper.trusted_backing_value())

    with capsys.disabled():
        for which, (halted, paid, debt, backing) in out.items():
            print(
                f"\n  {which:9}: pool halted {halted}, withdraw_profit "
                + ("REVERTS" if paid is None else f"paid {paid / 1e18:,.2f} crvUSD")
                + f", debt {debt / 1e18:,.2f}, backing reads {backing / 1e18:,.2f}"
            )
    assert out["baseline"][0] and out["patched"][0], "the pool did not halt"
    assert out["baseline"][1] is not None, "baseline should pay out through a halt (the hole)"
    assert out["patched"][1] is None, "patched keeper still paid out a surplus priced at a refused reading"
    assert out["patched"][3] > 0, "a halted pool took the backing read with it"


def test_a_halted_pool_reads_as_halted_and_poking_reopens_it(build, capsys):
    """A halt must read as 'nothing to do', and the keeper must offer the way back.

    Every quote reverts until poke_rates has walked the anchor back within two bounds, one
    bound per block. Nothing in the keeper can do that for itself, so a bot cannot tell a
    halted pool from a broken one, and its view calls revert instead of answering.
    """
    base, p_base, _ = _expanded(build, "baseline", rated="oracle")
    p_base.step_rate(10.0)
    baseline_views_revert = _reverts(base.available_contraction)
    baseline_update_reverts = _reverts(base.update)

    keeper, p, _ = _expanded(build, "patched", rated="oracle")
    p.step_rate(10.0)
    assert not keeper.pool_rates_live()
    assert keeper.available_contraction() == 0
    assert keeper.update() == 0

    poker, pokes = boa.env.generate_address(), 0
    while not keeper.pool_rates_live() and pokes < 400:
        keeper.poke_pool(sender=poker)  # permissionless
        boa.env.time_travel(blocks=1)
        pokes += 1

    with capsys.disabled():
        print(
            f"\n  baseline: views revert {baseline_views_revert}, update reverts {baseline_update_reverts}, "
            f"no poke of its own"
            f"\n  patched : halt read as zero availability, reopened after {pokes} pokes, "
            f"lag now {p.lag_bp:.2f} bp"
        )
    assert baseline_views_revert and baseline_update_reverts, "baseline should be stuck on a halted pool"
    assert keeper.pool_rates_live(), f"poking {pokes} times did not reopen the pool"
    assert pokes > 1, "the pool reopened without poking, so this proves nothing about poke_pool"
    assert not _reverts(keeper.estimate_caller_profit), "a reopened pool left the keeper unreadable"


# <---------------------   4. pools with no rate source must not change   --------------------->


def test_an_unrated_pool_behaves_exactly_as_before(build, capsys):
    """The launch pools have no rate source: the patch must not move a single number.

    With nothing bounding the rates there is only one price, the pool returns it for both
    virtual prices, and every quantity is the one the current keeper computes - through an
    expansion and a contraction, not just a preview.
    """
    numbers = {}
    for which in ("baseline", "patched"):
        keeper, p, _ = build(which, rated="none")
        p.tilt_paired()
        numbers[which] = {
            "available_expansion": keeper.available_expansion(),
            "preview_expansion": tuple(keeper.preview_expansion()),
            "trusted_backing_value": keeper.trusted_backing_value(),
            "estimate_caller_profit": keeper.estimate_caller_profit(),
        }
        keeper.expand_supply(sender=boa.env.generate_address())
        boa.env.time_travel(blocks=5)
        p.tilt_crvusd()
        numbers[which].update(
            lp_after_expansion=keeper.lp_balance(),
            debt=keeper.debt(),
            available_contraction=keeper.available_contraction(),
            preview_contraction=tuple(keeper.preview_contraction()),
        )
        keeper.contract_supply(sender=boa.env.generate_address())
        numbers[which].update(
            lp_after_contraction=keeper.lp_balance(),
            debt_after_contraction=keeper.debt(),
            protocol_surplus=keeper.protocol_surplus(),
        )

    for key, expected in numbers["baseline"].items():
        assert numbers["patched"][key] == expected, (
            f"{key} changed on an unrated pool: {numbers['patched'][key]} != {expected}"
        )
    with capsys.disabled():
        print(f"\n  identical on an unrated pool, through both directions: {sorted(numbers['baseline'])}")


def test_the_two_prices_agree_when_no_rate_is_catching_up(build):
    """The patch can only ever differ from the baseline while a rate lags.

    Both virtual prices come off the same rates whenever the last update absorbed the whole
    move, which is every pool that is not mid-catch-up.
    """
    for rated in ("none", "vault", "oracle"):
        _, p, _ = build("patched", rated=rated)
        p.tilt_paired()
        assert p.pool.virtual_price_bounded() == p.pool.get_virtual_price(), rated


def test_a_donation_carried_through_a_lag_is_deferred_not_settled_wrong(build, capsys):
    """A donation is valued at its source rate, so a lag can defer an expansion.

    Loose paired tokens are valued with convertToAssets, which tracks the vault, while the
    LP they turn into is valued at what the pool quotes. While a rate catches up the two
    disagree, so an expansion carrying a donation can fail its own baseline check. What
    must not happen is that it settles anyway at the higher price; what must happen is
    that it becomes possible again as the anchor catches up, one bound per block.
    """
    keeper, p, _ = build("patched", rated="vault")
    p.tilt_paired()
    p.step_rate(4.0)
    # a donation lands while the rate is still catching up
    p._mint_paired(keeper.address, 20_000 * 10**18)

    during = _reverts(keeper.preview_expansion)
    poker, pokes = boa.env.generate_address(), 0
    while _reverts(keeper.preview_expansion) and pokes < 400:
        p.pool.poke_rates(sender=poker)
        boa.env.time_travel(blocks=1)
        pokes += 1
    after = _reverts(keeper.preview_expansion)

    with capsys.disabled():
        print("")
        print(
            f"  donation + 4% step: expansion {'deferred' if during else 'went through'} during the lag, "
            f"available again after {pokes} blocks of catch-up, lag now {p.lag_bp:.2f} bp"
        )
    assert during, "the expansion settled while its donation was valued above the LP it becomes"
    assert not after, f"the expansion never became available again ({pokes} pokes)"
    deployed, profit, _, _ = keeper.preview_expansion()
    assert profit / deployed * 1e4 < 25, (
        f"once the lag closed the expansion still booked {profit / deployed * 1e4:.2f} bp"
    )
