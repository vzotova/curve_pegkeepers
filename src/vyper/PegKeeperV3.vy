# pragma version 0.4.3
"""
@title PegKeeper V3
@license MIT
@notice Adds and removes direct Curve liquidity to help keep crvUSD near its target price.
@dev Holds LP backing, accounts crvUSD debt, and delegates admission to a selected policy.
"""

interface ERC20:
    def balanceOf(_owner: address) -> uint256: view
    def decimals() -> uint256: view
    def approve(_spender: address, _amount: uint256): nonpayable
    def transfer(_recipient: address, _amount: uint256): nonpayable

interface ControllerFactory:
    def stablecoin() -> address: view
    def debt_ceiling(_account: address) -> uint256: view

interface PegKeeperPolicy:
    def expansion_regime() -> bool: view
    def can_expand() -> bool: view
    def can_contract() -> bool: view
    def fee_receiver() -> address: view

interface Pool:
    def coins(_index: uint256) -> address: view
    def balances(_index: uint256) -> uint256: view
    def balanceOf(_owner: address) -> uint256: view
    def get_virtual_price() -> uint256: view
    def calc_withdraw_one_coin(_lp_tokens: uint256, _index: int128) -> uint256: view
    def remove_liquidity_one_coin(
        _lp_tokens: uint256,
        _index: int128,
        _min_amount: uint256,
    ): nonpayable

interface DynamicLiquidityPool:
    def calc_token_amount(_amounts: DynArray[uint256, 2], _is_deposit: bool) -> uint256: view
    def add_liquidity(_amounts: DynArray[uint256, 2], _min_mint_amount: uint256) -> uint256: nonpayable
    def remove_liquidity_imbalance(
        _amounts: DynArray[uint256, 2],
        _max_burn_amount: uint256,
    ) -> uint256: nonpayable

interface FixedLiquidityPool:
    def calc_token_amount(_amounts: uint256[2], _is_deposit: bool) -> uint256: view
    def add_liquidity(_amounts: uint256[2], _min_mint_amount: uint256) -> uint256: nonpayable
    def remove_liquidity_imbalance(
        _amounts: uint256[2],
        _max_burn_amount: uint256,
    ) -> uint256: nonpayable

interface PairedToken:
    def asset() -> address: view
    def balanceOf(_owner: address) -> uint256: view
    def decimals() -> uint256: view
    def convertToAssets(_paired_token_amount: uint256) -> uint256: view
    def convertToShares(_assets: uint256) -> uint256: view

interface PriceOracle:
    def price() -> uint256: view

interface BoundedRatePool:
    def virtual_price_bounded() -> uint256: view
    def max_rate_bump() -> uint256: view
    def poke_rates(): nonpayable


event DirectionPaused:
    direction: indexed(uint256)
    paused: bool

event Executed:
    target: indexed(address)
    value: uint256
    selector: indexed(bytes4)
    data_hash: bytes32

event AmmExecutionBufferUpdated:
    execution_buffer_bps: uint256

event Expanded:
    keeper: indexed(address)
    crv_usd_deployed: uint256
    lp_tokens_received: uint256
    gross_profit: uint256
    keeper_reward: uint256

event DonatedPairedTokenSwept:
    keeper: indexed(address)
    paired_token_swept: uint256
    crv_usd_matched: uint256
    lp_tokens_received: uint256
    gross_profit: uint256
    keeper_reward: uint256

event Contracted:
    keeper: indexed(address)
    lp_tokens_burned: uint256
    crv_usd_received: uint256
    gross_profit: uint256
    keeper_reward: uint256

event ProfitWithdrawn:
    caller: indexed(address)
    receiver: indexed(address)
    crv_usd_transferred: uint256
    debt_after: uint256

event DebtReduced:
    caller: indexed(address)
    requested_reduction: uint256
    actual_reduction: uint256
    debt_after: uint256

event CrvUsdBorrowed:
    caller: indexed(address)
    receiver: indexed(address)
    amount: uint256
    debt_after: uint256


event PolicyUpdated:
    entry_min_profit_ppm: uint256
    normal_exit_min_profit_ppm: uint256
    max_debt: uint256


event KeeperProfitShareUpdated:
    old_keeper_profit_share_bps: uint256
    new_keeper_profit_share_bps: uint256


event InterventionPolicyUpdated:
    action_imbalance_bps: uint256
    action_delay: uint256

event BackingOraclePolicyUpdated:
    backing_oracle: indexed(address)
    min_backing_price: uint256


event CommitNewAdmin:
    admin: address


event ApplyNewAdmin:
    admin: address


event SetEmergencyAdmin:
    admin: address


event PolicyContractUpdated:
    old_policy: indexed(address)
    new_policy: indexed(address)



name: public(String[88])
keeper_index: public(uint256)

BPS: constant(uint256) = 10_000
PPM: constant(uint256) = 1_000_000
PRECISION: constant(uint256) = 10 ** 18
DEFAULT_MIN_BACKING_ORACLE_PRICE: constant(uint256) = 999_000_000_000_000_000
DEFAULT_ACTION_IMBALANCE_BPS: constant(uint256) = 2_000
DEFAULT_ACTION_DELAY: constant(uint256) = 12
ADMIN_ACTIONS_DELAY: constant(uint256) = 3 * 86400

DIRECTION_EXPANSION: constant(uint256) = 0
DIRECTION_CONTRACTION: constant(uint256) = 1
DIRECTION_ALL: constant(uint256) = 2

crv_usd: public(immutable(ERC20))

_controller_factory: ControllerFactory
_backing_asset: ERC20
_paired_token: PairedToken
pool: public(Pool)
pool_uses_dynamic_arrays: public(bool)
pool_prices_at_bounded_rates: public(bool)
paired_token_is_erc4626: public(bool)
backing_multiplier: uint256
backing_oracle: public(PriceOracle)
min_backing_oracle_price: public(uint256)

admin: public(address)
future_admin: public(address)
new_admin_deadline: public(uint256)
emergency_admin: public(address)
policy: public(address)

pool_crvusd_index: public(uint256)
pool_paired_token_index: public(uint256)

entry_min_profit_ppm: public(uint256)
normal_exit_min_profit_ppm: public(uint256)
max_debt: public(uint256)
keeper_profit_share_bps: public(uint256)
action_imbalance_bps: public(uint256)
action_delay: public(uint256)
last_intervention_at: public(uint256)
amm_execution_buffer_bps: public(uint256)

debt: public(uint256)

expansion_paused: public(bool)
contraction_paused: public(bool)
all_execution_paused: public(bool)


@deploy
def __init__(
    _controller_factory: ControllerFactory,
    _pool: Pool,
    _paired_token_is_erc4626: bool,
    _pool_uses_dynamic_arrays: bool,
    _max_debt: uint256,
    _keeper_index: uint256,
    _backing_oracle: PriceOracle,
    _entry_min_profit_ppm: uint256,
    _normal_exit_min_profit_ppm: uint256,
    _amm_execution_buffer_bps: uint256,
    _keeper_profit_share_bps: uint256,
    _admin: address,
    _emergency_admin: address,
    _policy: address,
):
    """
    @notice Deploys one fully configured standalone keeper for one direct pool.
    """
    assert _controller_factory.address != empty(address)
    assert _controller_factory.address.codesize > 0
    assert _pool.address != empty(address)
    assert _pool.address.codesize > 0
    assert _max_debt > 0
    assert _keeper_index > 0
    assert _backing_oracle.address != empty(address)
    assert _backing_oracle.address.codesize > 0
    assert _normal_exit_min_profit_ppm <= PPM
    assert _amm_execution_buffer_bps <= BPS
    assert _keeper_profit_share_bps <= BPS
    assert _admin != empty(address)
    assert _emergency_admin != empty(address)
    assert _admin != _emergency_admin
    assert _policy != empty(address) and _policy.codesize > 0

    crv_usd_address: address = staticcall _controller_factory.stablecoin()
    assert crv_usd_address != empty(address) and crv_usd_address.codesize > 0
    crv_usd = ERC20(crv_usd_address)

    coin_0: address = staticcall _pool.coins(0)
    coin_1: address = staticcall _pool.coins(1)
    paired_token_address: address = empty(address)
    if coin_0 == crv_usd_address and coin_1 != crv_usd_address:
        self.pool_crvusd_index = 0
        self.pool_paired_token_index = 1
        paired_token_address = coin_1
    elif coin_1 == crv_usd_address and coin_0 != crv_usd_address:
        self.pool_crvusd_index = 1
        self.pool_paired_token_index = 0
        paired_token_address = coin_0
    else:
        raise

    paired_token: PairedToken = PairedToken(paired_token_address)
    backing_asset_address: address = paired_token_address
    if _paired_token_is_erc4626:
        backing_asset_address = staticcall paired_token.asset()
        assert backing_asset_address != empty(address)
        assert staticcall paired_token.convertToAssets(0) == 0
        assert staticcall paired_token.convertToShares(0) == 0
    backing_asset: ERC20 = ERC20(backing_asset_address)

    crv_decimals: uint256 = staticcall ERC20(crv_usd_address).decimals()
    backing_decimals: uint256 = staticcall backing_asset.decimals()
    assert crv_decimals == 18
    assert backing_decimals <= 18
    assert staticcall ERC20(_pool.address).decimals() == 18
    assert staticcall _pool.get_virtual_price() > 0

    self._controller_factory = _controller_factory
    extcall ERC20(crv_usd_address).approve(_controller_factory.address, max_value(uint256))
    extcall ERC20(crv_usd_address).approve(_pool.address, max_value(uint256))
    extcall ERC20(paired_token_address).approve(_pool.address, max_value(uint256))
    self._backing_asset = backing_asset
    self._paired_token = paired_token
    self.pool = _pool
    self.pool_uses_dynamic_arrays = _pool_uses_dynamic_arrays
    bound_probe: bool = False
    bound_response: Bytes[32] = b""
    bound_probe, bound_response = raw_call(
        _pool.address,
        method_id("max_rate_bump()"),
        max_outsize=32,
        is_static_call=True,
        revert_on_failure=False,
    )
    self.pool_prices_at_bounded_rates = bound_probe and len(bound_response) == 32
    self.paired_token_is_erc4626 = _paired_token_is_erc4626
    self.backing_multiplier = 10 ** (18 - backing_decimals)
    self.backing_oracle = _backing_oracle
    self.min_backing_oracle_price = DEFAULT_MIN_BACKING_ORACLE_PRICE

    self.admin = _admin
    self.emergency_admin = _emergency_admin
    self.policy = _policy

    self.keeper_index = _keeper_index
    self.name = concat("Pegkeeper ", uint2str(_keeper_index))
    self.entry_min_profit_ppm = _entry_min_profit_ppm
    self.normal_exit_min_profit_ppm = _normal_exit_min_profit_ppm
    self.max_debt = _max_debt
    self.keeper_profit_share_bps = _keeper_profit_share_bps
    self.action_imbalance_bps = DEFAULT_ACTION_IMBALANCE_BPS
    self.action_delay = DEFAULT_ACTION_DELAY
    self.amm_execution_buffer_bps = _amm_execution_buffer_bps

    self.expansion_paused = False
    self.contraction_paused = False
    self.all_execution_paused = False

    log ApplyNewAdmin(admin=_admin)
    log SetEmergencyAdmin(admin=_emergency_admin)
    log PolicyContractUpdated(old_policy=empty(address), new_policy=_policy)
    log KeeperProfitShareUpdated(
        old_keeper_profit_share_bps=0,
        new_keeper_profit_share_bps=_keeper_profit_share_bps,
    )


@external
@pure
def version() -> (uint256, uint256, uint256):
    """
    @notice Returns the semantic version as major, minor, and patch integers.
    """
    return 3, 0, 0


@external
@view
def controller_factory() -> address:
    """
    @notice Returns the shared contract that provides crvUSD and debt limits.
    """
    return self._controller_factory.address


@internal
@view
def _is_admin(_account: address) -> bool:
    return _account == self.admin


@external
@view
def backing_asset() -> address:
    """
    @notice Returns the asset denomination used to match loose paired tokens with crvUSD.
    """
    return self._backing_asset.address


@external
@view
def paired_token() -> address:
    """
    @notice Returns the non-crvUSD token in the configured pool.
    """
    return self._paired_token.address


@internal
@view
def _paired_token_assets(_units: uint256) -> uint256:
    if self.paired_token_is_erc4626:
        return staticcall self._paired_token.convertToAssets(_units)
    return _units


@external
@view
def paired_token_assets(_units: uint256) -> uint256:
    """
    @notice Returns the backing-asset amount represented by a paired-token amount.
    """
    return self._paired_token_assets(_units)


@external
@view
def paired_token_units(_assets: uint256) -> uint256:
    """
    @notice Returns the paired-token amount represented by a backing-asset amount.
    """
    if self.paired_token_is_erc4626:
        return staticcall self._paired_token.convertToShares(_assets)
    return _assets


@internal
@view
def _paired_token_balance() -> uint256:
    return staticcall self._paired_token.balanceOf(self)


@internal
@view
def _lp_balance() -> uint256:
    return staticcall self.pool.balanceOf(self)


@internal
@view
def _bounded_lp_unit_value() -> uint256:
    quoting: bool = False
    response: Bytes[32] = b""
    quoting, response = raw_call(
        self.pool.address,
        method_id("virtual_price_bounded()"),
        max_outsize=32,
        is_static_call=True,
        revert_on_failure=False,
    )
    if not quoting or len(response) != 32:
        return 0
    return abi_decode(response, uint256)


@internal
@view
def _lp_unit_value() -> uint256:
    virtual_price: uint256 = staticcall self.pool.get_virtual_price()
    if not self.pool_prices_at_bounded_rates:
        return virtual_price
    bounded: uint256 = self._bounded_lp_unit_value()
    if bounded == 0:
        return virtual_price
    return min(virtual_price, bounded)


@internal
@view
def _lp_value(_lp_tokens: uint256) -> uint256:
    return _lp_tokens * self._lp_unit_value() // PRECISION


@internal
@view
def _pool_rates_live() -> bool:
    if not self.pool_prices_at_bounded_rates:
        return True
    return self._bounded_lp_unit_value() != 0


@external
@view
def lp_balance() -> uint256:
    """
    @notice Returns the complete held balance of pool LP tokens.
    """
    return self._lp_balance()


@external
@view
def coins(_index: uint256) -> address:
    """
    @notice Returns crvUSD for index 0 and the held pool LP token for index 1.
    """
    if _index == 0:
        return crv_usd.address
    assert _index == 1
    return self.pool.address


@internal
@pure
def _oracle_value(_value: uint256, _price: uint256) -> uint256:
    price: uint256 = min(_price, PRECISION)
    return _value * price // PRECISION


@internal
@view
def _backing_price() -> uint256:
    price: uint256 = staticcall self.backing_oracle.price()
    assert price >= self.min_backing_oracle_price
    return price


@internal
@view
def _policy_address() -> address:
    policy: address = self.policy
    assert policy != empty(address) and policy.codesize > 0
    return policy


@internal
@view
def _fee_receiver() -> address:
    receiver: address = staticcall PegKeeperPolicy(self._policy_address()).fee_receiver()
    assert receiver != empty(address)
    return receiver


@internal
@view
def _keeper_reward(_gross_profit: uint256) -> uint256:
    return _gross_profit * self.keeper_profit_share_bps // BPS


@internal
@view
def _require_expansion_policy():
    assert staticcall PegKeeperPolicy(self._policy_address()).can_expand()


@internal
@view
def _require_contraction_policy():
    assert staticcall PegKeeperPolicy(self._policy_address()).can_contract()


@internal
@view
def _meets_entry_floor(_gross_profit: uint256, _principal: uint256) -> bool:
    required_profit: uint256 = _principal * self.entry_min_profit_ppm // PPM
    return _gross_profit >= required_profit


@internal
@view
def _trusted_backing_value() -> uint256:
    return self._lp_value(self._lp_balance())


@internal
@view
def _trusted_paired_token_value(_paired_token_units: uint256) -> uint256:
    return self._paired_token_assets(_paired_token_units) * self.backing_multiplier


@external
@view
def trusted_backing_value() -> uint256:
    """
    @notice Returns the held pool LP balance valued at the lower of the pool's two virtual prices.
    """
    return self._trusted_backing_value()


@external
@view
def protocol_surplus() -> uint256:
    """
    @notice Returns backing value above the crvUSD amount this keeper must cover.
    """
    trusted_value: uint256 = self._trusted_backing_value()
    if trusted_value > self.debt:
        return trusted_value - self.debt
    return 0


@external
@view
def calc_profit() -> uint256:
    """
    @notice Returns current protocol surplus in crvUSD-value terms for V2 tooling compatibility.
    """
    trusted_value: uint256 = self._trusted_backing_value()
    if trusted_value > self.debt:
        return trusted_value - self.debt
    return 0


@internal
@view
def _remaining_exposure_capacity() -> uint256:
    current_debt: uint256 = self.debt
    if self.max_debt <= current_debt:
        return 0
    local_capacity: uint256 = self.max_debt - current_debt

    factory_allocation: uint256 = staticcall self._controller_factory.debt_ceiling(self)
    if factory_allocation <= current_debt:
        return 0
    return min(local_capacity, factory_allocation - current_debt)


@internal
@view
def _local_expansion_limit() -> uint256:
    crv_usd_balance: uint256 = staticcall self.pool.balances(self.pool_crvusd_index)
    paired_token_balance: uint256 = self._trusted_paired_token_value(
        staticcall self.pool.balances(self.pool_paired_token_index)
    )
    if paired_token_balance <= crv_usd_balance:
        return 0
    return (paired_token_balance - crv_usd_balance) * self.action_imbalance_bps // BPS


@internal
@view
def _local_contraction_limit() -> uint256:
    crv_usd_balance: uint256 = staticcall self.pool.balances(self.pool_crvusd_index)
    paired_token_balance: uint256 = self._trusted_paired_token_value(
        staticcall self.pool.balances(self.pool_paired_token_index)
    )
    if crv_usd_balance <= paired_token_balance:
        return 0
    return (crv_usd_balance - paired_token_balance) * self.action_imbalance_bps // BPS


@internal
@view
def _action_delay_elapsed() -> bool:
    last_intervention_at: uint256 = self.last_intervention_at
    return (
        last_intervention_at == 0
        or block.timestamp - last_intervention_at >= self.action_delay
    )


@internal
@view
def _available_expansion_without_policy() -> uint256:
    if self.all_execution_paused or self.expansion_paused:
        return 0
    if not self._action_delay_elapsed():
        return 0
    if not self._pool_rates_live():
        return 0

    budget: uint256 = min(
        staticcall crv_usd.balanceOf(self),
        self._remaining_exposure_capacity(),
    )
    donated_value: uint256 = self._trusted_paired_token_value(self._paired_token_balance())
    if budget <= donated_value:
        return 0
    return min(self._local_expansion_limit(), budget - donated_value)


@internal
@view
def _available_contraction_without_policy() -> uint256:
    if self.all_execution_paused or self.contraction_paused:
        return 0
    if not self._action_delay_elapsed():
        return 0
    if not self._pool_rates_live():
        return 0

    held: uint256 = self._lp_balance()
    if held == 0:
        return 0
    inventory_output: uint256 = staticcall self.pool.calc_withdraw_one_coin(
        held,
        convert(self.pool_crvusd_index, int128),
    )
    inventory_output = inventory_output * (BPS - self.amm_execution_buffer_bps) // BPS
    if inventory_output == 0:
        return 0
    inventory_output -= 1
    return min(self._local_contraction_limit(), inventory_output)


@external
@view
def available_expansion() -> uint256:
    """
    @notice Returns the most crvUSD that can be used for a policy-approved expansion now.
    """
    if not staticcall PegKeeperPolicy(self._policy_address()).can_expand():
        return 0
    return self._available_expansion_without_policy()


@external
@view
def available_contraction() -> uint256:
    """
    @notice Returns the most crvUSD that can be withdrawn by a policy-approved contraction now.
    """
    if not staticcall PegKeeperPolicy(self._policy_address()).can_contract():
        return 0
    return self._available_contraction_without_policy()


@external
@view
def estimate_caller_profit() -> uint256:
    """
    @notice Estimates update() caller compensation in crvUSD-value terms; returns zero when unavailable.
    """
    ok: bool = False
    response: Bytes[128] = empty(Bytes[128])
    ok, response = raw_call(
        self,
        method_id("preview_expansion()"),
        max_outsize=128,
        is_static_call=True,
        revert_on_failure=False,
    )
    if ok and len(response) == 128:
        lp_reward: uint256 = convert(slice(response, 64, 32), uint256)
        return self._lp_value(lp_reward)

    contraction_response: Bytes[96] = empty(Bytes[96])
    ok, contraction_response = raw_call(
        self,
        method_id("preview_contraction()"),
        max_outsize=96,
        is_static_call=True,
        revert_on_failure=False,
    )
    if ok and len(contraction_response) == 96:
        return convert(slice(contraction_response, 64, 32), uint256)
    return 0


@internal
@view
def _realized_contraction_profit(
    _crv_usd_received: uint256,
    _trusted_value_removed: uint256,
    _trusted_backing_after: uint256,
) -> uint256:
    principal_recovery: uint256 = _trusted_value_removed
    if self.debt > _trusted_backing_after:
        solvency_recovery: uint256 = self.debt - _trusted_backing_after
        if solvency_recovery > principal_recovery:
            principal_recovery = solvency_recovery

    if _crv_usd_received <= principal_recovery:
        return 0
    return _crv_usd_received - principal_recovery


@internal
def _transfer_exact_to(_token: ERC20, _recipient: address, _amount: uint256):
    if _amount > 0:
        recipient_balance_before: uint256 = staticcall _token.balanceOf(_recipient)
        extcall _token.transfer(_recipient, _amount)
        assert staticcall _token.balanceOf(_recipient) - recipient_balance_before == _amount


@internal
def _settle_keeper_contraction_and_reduce_exposure(
    _crv_usd_before: uint256,
    _crv_usd_after_withdrawal: uint256,
    _crv_usd_received: uint256,
    _trusted_value_removed: uint256,
    _trusted_backing_after: uint256,
    _reward_recipient: address,
) -> (uint256, uint256):
    gross_profit: uint256 = self._realized_contraction_profit(
        _crv_usd_received,
        _trusted_value_removed,
        _trusted_backing_after,
    )
    assert gross_profit > 0
    exit_margin: uint256 = _trusted_value_removed * self.normal_exit_min_profit_ppm // PPM
    assert gross_profit >= exit_margin
    keeper_reward: uint256 = self._keeper_reward(gross_profit)
    self._transfer_exact_to(crv_usd, _reward_recipient, keeper_reward)

    crv_usd_after_reward: uint256 = staticcall crv_usd.balanceOf(self)
    assert _crv_usd_after_withdrawal - crv_usd_after_reward == keeper_reward
    net_crv_usd: uint256 = crv_usd_after_reward - _crv_usd_before

    current_debt: uint256 = self.debt
    if net_crv_usd > current_debt:
        self.debt = 0
        self._transfer_exact_to(
            crv_usd,
            self._fee_receiver(),
            net_crv_usd - current_debt,
        )
    else:
        self.debt = current_debt - net_crv_usd
    return gross_profit, keeper_reward


@external
@view
def preview_contraction() -> (uint256, uint256, uint256):
    """
    @notice Estimates the canonical exact-crvUSD contraction.
    """
    self._require_contraction_policy()
    expected_crv_usd: uint256 = self._available_contraction_without_policy()
    assert expected_crv_usd > 0

    accounted: uint256 = self._lp_balance()
    quoted_lp_burn: uint256 = self._calc_lp_burn(expected_crv_usd)
    expected_lp_burn: uint256 = quoted_lp_burn + 1
    maximum_lp_burn: uint256 = self._maximum_lp_burn(quoted_lp_burn)
    assert maximum_lp_burn <= accounted
    unit_value: uint256 = self._lp_unit_value()
    trusted_before: uint256 = self._lp_value_at(accounted, unit_value)
    trusted_after: uint256 = self._lp_value_at(accounted - expected_lp_burn, unit_value)
    trusted_removed: uint256 = trusted_before - trusted_after
    gross_profit: uint256 = self._realized_contraction_profit(
        expected_crv_usd,
        trusted_removed,
        trusted_after,
    )
    assert gross_profit > 0
    exit_margin: uint256 = trusted_removed * self.normal_exit_min_profit_ppm // PPM
    assert gross_profit >= exit_margin
    keeper_reward: uint256 = self._keeper_reward(gross_profit)
    net_crv_usd: uint256 = expected_crv_usd - keeper_reward

    debt_after: uint256 = 0
    if self.debt > net_crv_usd:
        debt_after = self.debt - net_crv_usd
    assert trusted_after >= debt_after
    return expected_crv_usd, gross_profit, keeper_reward


@external
@view
def preview_expansion() -> (uint256, uint256, uint256, uint256):
    """
    @notice Estimates the canonical expansion from current data; actual results may differ.
    """
    self._require_expansion_policy()
    amount: uint256 = self._available_expansion_without_policy()
    assert amount > 0
    self._backing_price()

    lp_before: uint256 = self._lp_balance()
    unit_value: uint256 = self._lp_unit_value()
    lp_value_before: uint256 = self._lp_value_at(lp_before, unit_value)
    donated_paired_token: uint256 = self._paired_token_balance()
    donated_value: uint256 = self._trusted_paired_token_value(donated_paired_token)
    crv_usd_deployed: uint256 = amount + donated_value
    accounting_baseline: uint256 = lp_value_before + donated_value

    assert crv_usd_deployed <= staticcall crv_usd.balanceOf(self)
    debt_after: uint256 = self.debt + crv_usd_deployed
    assert debt_after <= self.max_debt
    assert debt_after <= staticcall self._controller_factory.debt_ceiling(self)

    lp_tokens_out: uint256 = self._calc_token_amount(crv_usd_deployed, donated_paired_token)
    lp_value_after: uint256 = self._lp_value_at(lp_before + lp_tokens_out, unit_value)
    assert lp_value_after >= accounting_baseline + crv_usd_deployed
    gross_profit: uint256 = lp_value_after - accounting_baseline - crv_usd_deployed
    reward_value: uint256 = self._keeper_reward(gross_profit)
    keeper_reward: uint256 = reward_value * PRECISION // unit_value
    assert keeper_reward <= lp_tokens_out

    retained_lp: uint256 = lp_before + lp_tokens_out - keeper_reward
    retained_value: uint256 = self._lp_value_at(retained_lp, unit_value)
    assert retained_value >= accounting_baseline
    assert self._meets_entry_floor(gross_profit, crv_usd_deployed)
    assert retained_value >= debt_after
    return crv_usd_deployed, gross_profit, keeper_reward, lp_tokens_out


@external
def set_backing_oracle_policy(
    _backing_oracle: PriceOracle,
    _min_backing_price: uint256,
):
    """
    @notice Changes the retained-backing price source and lowest accepted price.
    """
    assert self._is_admin(msg.sender)
    assert _backing_oracle.address != empty(address)
    assert _backing_oracle.address.codesize > 0
    assert _min_backing_price > 0 and _min_backing_price <= PRECISION

    self.backing_oracle = _backing_oracle
    self.min_backing_oracle_price = _min_backing_price
    log BackingOraclePolicyUpdated(
        backing_oracle=_backing_oracle.address,
        min_backing_price=_min_backing_price,
    )


@external
def set_amm_execution_buffer(_execution_buffer_bps: uint256):
    """
    @notice Changes the allowed LP-mint shortfall or LP-burn excess against AMM quotes.
    """
    assert self._is_admin(msg.sender)
    assert _execution_buffer_bps <= BPS

    self.amm_execution_buffer_bps = _execution_buffer_bps
    log AmmExecutionBufferUpdated(execution_buffer_bps=_execution_buffer_bps)


@internal
@view
def _lp_value_at(_lp_tokens: uint256, _virtual_price: uint256) -> uint256:
    return _lp_tokens * _virtual_price // PRECISION


@internal
@view
def _calc_token_amount(_crv_usd_amount: uint256, _paired_token_amount: uint256) -> uint256:
    if self.pool_uses_dynamic_arrays:
        dynamic_amounts: DynArray[uint256, 2] = [0, 0]
        dynamic_amounts[self.pool_crvusd_index] = _crv_usd_amount
        dynamic_amounts[self.pool_paired_token_index] = _paired_token_amount
        return staticcall DynamicLiquidityPool(self.pool.address).calc_token_amount(dynamic_amounts, True)
    else:
        fixed_amounts: uint256[2] = empty(uint256[2])
        fixed_amounts[self.pool_crvusd_index] = _crv_usd_amount
        fixed_amounts[self.pool_paired_token_index] = _paired_token_amount
        return staticcall FixedLiquidityPool(self.pool.address).calc_token_amount(fixed_amounts, True)


@internal
@view
def _calc_lp_burn(_crv_usd_amount: uint256) -> uint256:
    if self.pool_uses_dynamic_arrays:
        dynamic_amounts: DynArray[uint256, 2] = [0, 0]
        dynamic_amounts[self.pool_crvusd_index] = _crv_usd_amount
        return staticcall DynamicLiquidityPool(self.pool.address).calc_token_amount(dynamic_amounts, False)
    else:
        fixed_amounts: uint256[2] = empty(uint256[2])
        fixed_amounts[self.pool_crvusd_index] = _crv_usd_amount
        return staticcall FixedLiquidityPool(self.pool.address).calc_token_amount(fixed_amounts, False)


@internal
@view
def _maximum_lp_burn(_quoted_lp_burn: uint256) -> uint256:
    multiplier: uint256 = BPS + self.amm_execution_buffer_bps
    return (_quoted_lp_burn * multiplier + BPS - 1) // BPS + 1


@internal
def _remove_exact_crv_usd(_crv_usd_amount: uint256, _maximum_lp_tokens: uint256) -> uint256:
    if self.pool_uses_dynamic_arrays:
        dynamic_amounts: DynArray[uint256, 2] = [0, 0]
        dynamic_amounts[self.pool_crvusd_index] = _crv_usd_amount
        return extcall DynamicLiquidityPool(self.pool.address).remove_liquidity_imbalance(
            dynamic_amounts,
            _maximum_lp_tokens,
        )
    else:
        fixed_amounts: uint256[2] = empty(uint256[2])
        fixed_amounts[self.pool_crvusd_index] = _crv_usd_amount
        return extcall FixedLiquidityPool(self.pool.address).remove_liquidity_imbalance(
            fixed_amounts,
            _maximum_lp_tokens,
        )


@internal
def _deposit_to_pool(
    _crv_usd_amount: uint256,
    _paired_token_amount: uint256,
) -> uint256:
    quoted_lp: uint256 = self._calc_token_amount(_crv_usd_amount, _paired_token_amount)
    min_lp: uint256 = quoted_lp * (BPS - self.amm_execution_buffer_bps) // BPS

    crv_usd_before: uint256 = staticcall crv_usd.balanceOf(self)
    paired_token_before: uint256 = staticcall self._paired_token.balanceOf(self)
    lp_before: uint256 = self._lp_balance()

    if self.pool_uses_dynamic_arrays:
        dynamic_amounts: DynArray[uint256, 2] = [0, 0]
        dynamic_amounts[self.pool_crvusd_index] = _crv_usd_amount
        dynamic_amounts[self.pool_paired_token_index] = _paired_token_amount
        extcall DynamicLiquidityPool(self.pool.address).add_liquidity(dynamic_amounts, min_lp)
    else:
        fixed_amounts: uint256[2] = empty(uint256[2])
        fixed_amounts[self.pool_crvusd_index] = _crv_usd_amount
        fixed_amounts[self.pool_paired_token_index] = _paired_token_amount
        extcall FixedLiquidityPool(self.pool.address).add_liquidity(fixed_amounts, min_lp)
    assert crv_usd_before - staticcall crv_usd.balanceOf(self) == _crv_usd_amount
    assert paired_token_before - staticcall self._paired_token.balanceOf(self) == _paired_token_amount
    lp_received: uint256 = self._lp_balance() - lp_before
    assert lp_received >= min_lp
    return lp_received


@internal
def _settle_lp_expansion(
    _lp_before: uint256,
    _lp_value_before: uint256,
    _donated_paired_token_value: uint256,
    _entry_donation_value: uint256,
    _principal: uint256,
    _lp_received: uint256,
    _reward_recipient: address,
) -> (uint256, uint256):
    lp_after_deposit: uint256 = _lp_before + _lp_received
    unit_value_after: uint256 = self._lp_unit_value()
    lp_value_after: uint256 = self._lp_value_at(lp_after_deposit, unit_value_after)
    accounting_baseline: uint256 = _lp_value_before + _donated_paired_token_value
    entry_baseline: uint256 = _lp_value_before + _entry_donation_value
    gross_profit: uint256 = 0
    if lp_value_after > accounting_baseline + _principal:
        gross_profit = lp_value_after - accounting_baseline - _principal
    entry_profit: uint256 = 0
    if lp_value_after > entry_baseline + _principal:
        entry_profit = lp_value_after - entry_baseline - _principal
    assert self._meets_entry_floor(entry_profit, _principal)

    keeper_reward_value: uint256 = self._keeper_reward(gross_profit)
    keeper_reward: uint256 = keeper_reward_value * PRECISION // unit_value_after
    assert keeper_reward <= _lp_received
    self._transfer_exact_to(ERC20(self.pool.address), _reward_recipient, keeper_reward)

    retained_value: uint256 = self._lp_value(self._lp_balance())
    assert retained_value >= entry_baseline
    return gross_profit, keeper_reward


@internal
def _expand_supply(_reward_recipient: address) -> (uint256, uint256, uint256):
    assert _reward_recipient != empty(address)
    self._require_expansion_policy()
    crv_usd_amount: uint256 = self._available_expansion_without_policy()
    assert crv_usd_amount > 0
    self._backing_price()

    crv_usd_before: uint256 = staticcall crv_usd.balanceOf(self)
    paired_token_before: uint256 = self._paired_token_balance()
    lp_before: uint256 = self._lp_balance()
    unit_value_before: uint256 = self._lp_unit_value()
    lp_value_before: uint256 = self._lp_value_at(lp_before, unit_value_before)
    donated_paired_token_value: uint256 = self._trusted_paired_token_value(paired_token_before)

    crv_usd_deployed: uint256 = crv_usd_amount + donated_paired_token_value
    assert crv_usd_deployed <= crv_usd_before
    assert crv_usd_deployed <= self._remaining_exposure_capacity()

    lp_received: uint256 = self._deposit_to_pool(
        crv_usd_deployed,
        paired_token_before,
    )

    gross_profit: uint256 = 0
    keeper_reward: uint256 = 0
    gross_profit, keeper_reward = self._settle_lp_expansion(
        lp_before,
        lp_value_before,
        donated_paired_token_value,
        donated_paired_token_value,
        crv_usd_deployed,
        lp_received,
        _reward_recipient,
    )
    self.debt += crv_usd_deployed
    self.last_intervention_at = block.timestamp

    log Expanded(
        keeper=msg.sender,
        crv_usd_deployed=crv_usd_deployed,
        lp_tokens_received=lp_received,
        gross_profit=gross_profit,
        keeper_reward=keeper_reward,
    )
    return crv_usd_deployed, lp_received, keeper_reward


@external
@nonreentrant
def expand_supply() -> (uint256, uint256, uint256):
    """
    @notice Executes the canonical policy-approved crvUSD expansion.
    """
    return self._expand_supply(msg.sender)


@internal
@view
def _donation_match_amount(_donated_paired_token_value: uint256) -> uint256:
    policy: PegKeeperPolicy = PegKeeperPolicy(self._policy_address())
    if not staticcall policy.can_expand():
        return 0
    if staticcall policy.expansion_regime():
        return _donated_paired_token_value

    pool_crv_usd: uint256 = staticcall self.pool.balances(self.pool_crvusd_index)
    pool_paired_token_value: uint256 = self._trusted_paired_token_value(
        staticcall self.pool.balances(self.pool_paired_token_index)
    )
    paired_token_value_after: uint256 = pool_paired_token_value + _donated_paired_token_value
    if paired_token_value_after <= pool_crv_usd:
        return 0
    return min(_donated_paired_token_value, paired_token_value_after - pool_crv_usd)


@internal
def _settle_donated_paired_token(
    _max_paired_token_amount: uint256,
    _matching_budget: uint256,
) -> (uint256, uint256, uint256, uint256):
    paired_token_swept: uint256 = min(_max_paired_token_amount, self._paired_token_balance())
    if paired_token_swept == 0:
        return 0, 0, 0, 0

    self._backing_price()
    donated_paired_token_value: uint256 = self._trusted_paired_token_value(paired_token_swept)
    crv_usd_matched: uint256 = min(
        self._donation_match_amount(donated_paired_token_value),
        _matching_budget,
    )
    if crv_usd_matched > 0:
        assert crv_usd_matched <= staticcall crv_usd.balanceOf(self)
        assert crv_usd_matched <= self._remaining_exposure_capacity()

    lp_before: uint256 = self._lp_balance()
    unit_value_before: uint256 = self._lp_unit_value()
    lp_value_before: uint256 = self._lp_value_at(lp_before, unit_value_before)
    lp_received: uint256 = self._deposit_to_pool(
        crv_usd_matched,
        paired_token_swept,
    )
    gross_profit: uint256 = 0
    keeper_reward: uint256 = 0
    gross_profit, keeper_reward = self._settle_lp_expansion(
        lp_before,
        lp_value_before,
        donated_paired_token_value,
        0,
        crv_usd_matched,
        lp_received,
        msg.sender,
    )

    self.debt += crv_usd_matched

    log DonatedPairedTokenSwept(
        keeper=msg.sender,
        paired_token_swept=paired_token_swept,
        crv_usd_matched=crv_usd_matched,
        lp_tokens_received=lp_received,
        gross_profit=gross_profit,
        keeper_reward=keeper_reward,
    )
    return paired_token_swept, crv_usd_matched, lp_received, keeper_reward


@external
@nonreentrant
def sweep_donated_paired_token(_max_paired_token_amount: uint256) -> (uint256, uint256, uint256, uint256):
    """
    @notice Deposits donated paired tokens and matches only the crvUSD appropriate for the current regime.
    """
    assert not self.all_execution_paused
    assert not self.expansion_paused
    assert _max_paired_token_amount > 0

    matching_budget: uint256 = min(
        staticcall crv_usd.balanceOf(self),
        self._remaining_exposure_capacity(),
    )
    return self._settle_donated_paired_token(
        _max_paired_token_amount,
        matching_budget,
    )


@external
@nonreentrant
def withdraw_profit(_max_crv_usd_amount: uint256 = max_value(uint256)) -> uint256:
    """
    @notice Withdraws eligible protocol profit in crvUSD; the no-argument overload uses the maximum limit.
    """
    assert not self.all_execution_paused
    assert not self.expansion_paused
    assert self._pool_rates_live()

    backing_price: uint256 = self._backing_price()
    backing_before_sweep: uint256 = self._oracle_value(
        self._trusted_backing_value(),
        backing_price,
    )
    potential_surplus: uint256 = 0
    if backing_before_sweep > self.debt:
        potential_surplus = backing_before_sweep - self.debt
    donated_paired_token_value: uint256 = self._trusted_paired_token_value(self._paired_token_balance())
    potential_surplus += self._oracle_value(donated_paired_token_value, backing_price)

    available_budget: uint256 = min(
        staticcall crv_usd.balanceOf(self),
        self._remaining_exposure_capacity(),
    )
    withdrawal_reserve: uint256 = min(
        _max_crv_usd_amount,
        min(potential_surplus, available_budget),
    )
    self._settle_donated_paired_token(
        self._paired_token_balance(),
        available_budget - withdrawal_reserve,
    )

    trusted_backing: uint256 = self._oracle_value(
        self._trusted_backing_value(),
        self._backing_price(),
    )
    surplus: uint256 = 0
    if trusted_backing > self.debt:
        surplus = trusted_backing - self.debt

    crv_usd_balance_before: uint256 = staticcall crv_usd.balanceOf(self)
    exposure_capacity: uint256 = self._remaining_exposure_capacity()
    crv_usd_transferred: uint256 = _max_crv_usd_amount
    if crv_usd_transferred > surplus:
        crv_usd_transferred = surplus
    if crv_usd_transferred > crv_usd_balance_before:
        crv_usd_transferred = crv_usd_balance_before
    if crv_usd_transferred > exposure_capacity:
        crv_usd_transferred = exposure_capacity
    assert crv_usd_transferred > 0

    debt_after: uint256 = self.debt + crv_usd_transferred
    self.debt = debt_after

    fee_receiver: address = self._fee_receiver()
    self._transfer_exact_to(crv_usd, fee_receiver, crv_usd_transferred)
    crv_usd_balance_after: uint256 = staticcall crv_usd.balanceOf(self)
    assert crv_usd_balance_before - crv_usd_balance_after == crv_usd_transferred

    assert self._trusted_backing_value() >= debt_after

    log ProfitWithdrawn(
        caller=msg.sender,
        receiver=fee_receiver,
        crv_usd_transferred=crv_usd_transferred,
        debt_after=debt_after,
    )
    return crv_usd_transferred


@internal
def _contract_supply(_reward_recipient: address) -> (uint256, uint256, uint256):
    assert _reward_recipient != empty(address)
    self._require_contraction_policy()
    crv_usd_amount: uint256 = self._available_contraction_without_policy()
    assert crv_usd_amount > 0

    lp_before: uint256 = self._lp_balance()
    unit_value_before: uint256 = self._lp_unit_value()
    trusted_backing_before: uint256 = self._lp_value_at(lp_before, unit_value_before)
    quoted_lp_burn: uint256 = self._calc_lp_burn(crv_usd_amount)
    maximum_lp_burn: uint256 = self._maximum_lp_burn(quoted_lp_burn)
    assert maximum_lp_burn <= lp_before
    crv_usd_before: uint256 = staticcall crv_usd.balanceOf(self)

    reported_lp_burn: uint256 = self._remove_exact_crv_usd(
        crv_usd_amount,
        maximum_lp_burn,
    )

    lp_after: uint256 = self._lp_balance()
    lp_burned: uint256 = lp_before - lp_after
    assert lp_burned > 0 and lp_burned <= maximum_lp_burn
    assert reported_lp_burn == lp_burned
    crv_usd_after_withdrawal: uint256 = staticcall crv_usd.balanceOf(self)
    crv_usd_received: uint256 = crv_usd_after_withdrawal - crv_usd_before
    assert crv_usd_received == crv_usd_amount

    unit_value_after: uint256 = self._lp_unit_value()
    trusted_backing_after: uint256 = self._lp_value_at(lp_after, unit_value_after)
    trusted_value_removed: uint256 = trusted_backing_before - trusted_backing_after
    assert trusted_value_removed > 0

    gross_profit: uint256 = 0
    keeper_reward: uint256 = 0
    gross_profit, keeper_reward = self._settle_keeper_contraction_and_reduce_exposure(
        crv_usd_before,
        crv_usd_after_withdrawal,
        crv_usd_received,
        trusted_value_removed,
        trusted_backing_after,
        _reward_recipient,
    )
    self.last_intervention_at = block.timestamp

    log Contracted(
        keeper=msg.sender,
        lp_tokens_burned=lp_burned,
        crv_usd_received=crv_usd_received,
        gross_profit=gross_profit,
        keeper_reward=keeper_reward,
    )
    return lp_burned, crv_usd_received, keeper_reward


@external
@nonreentrant
def contract_supply() -> (uint256, uint256, uint256):
    """
    @notice Executes the canonical exact-crvUSD contraction.
    """
    return self._contract_supply(msg.sender)


@external
@view
def pool_rates_live() -> bool:
    """
    @notice Returns whether the pool is quoting, or halted on a rate it will not accept.
    @dev Always true for a pool with no rate bound.
    """
    return self._pool_rates_live()


@external
@nonreentrant
def poke_pool():
    """
    @notice Walks a halted pool's rates one bound back towards their sources.
    @dev Permissionless, and capped by the pool at one poke per block.
    """
    assert self.pool_prices_at_bounded_rates
    extcall BoundedRatePool(self.pool.address).poke_rates()


@external
@nonreentrant
def update(_beneficiary: address = msg.sender) -> uint256:
    """
    @notice Executes the sole canonical intervention and returns caller reward in crvUSD-value terms.
    """
    assert _beneficiary != empty(address)
    if not self._action_delay_elapsed():
        return 0
    if not self._pool_rates_live():
        return 0
    if self._local_expansion_limit() > 0:
        crv_usd_deployed: uint256 = 0
        lp_received: uint256 = 0
        keeper_reward_lp: uint256 = 0
        crv_usd_deployed, lp_received, keeper_reward_lp = self._expand_supply(_beneficiary)
        return self._lp_value(keeper_reward_lp)
    if self._local_contraction_limit() > 0:
        lp_burned: uint256 = 0
        crv_usd_received: uint256 = 0
        keeper_reward: uint256 = 0
        lp_burned, crv_usd_received, keeper_reward = self._contract_supply(_beneficiary)
        return keeper_reward
    raise


@external
@nonreentrant
def borrow_crvusd(_amount: uint256, _receiver: address):
    """
    @notice Gives an admin-selected receiver policy-approved crvUSD and records it as debt.
    """
    assert self._is_admin(msg.sender)
    assert not self.all_execution_paused
    assert not self.expansion_paused
    assert _amount > 0 and _receiver != empty(address)
    self._require_expansion_policy()
    assert self._action_delay_elapsed()
    assert _amount <= self._local_expansion_limit()
    self._backing_price()

    debt_after: uint256 = self.debt + _amount
    assert debt_after <= self.max_debt
    assert debt_after <= staticcall self._controller_factory.debt_ceiling(self)
    assert _amount <= staticcall crv_usd.balanceOf(self)

    self.debt = debt_after
    self.last_intervention_at = block.timestamp
    self._transfer_exact_to(crv_usd, _receiver, _amount)
    log CrvUsdBorrowed(
        caller=msg.sender,
        receiver=_receiver,
        amount=_amount,
        debt_after=debt_after,
    )


@external
def reduce_debt(_amount: uint256):
    """
    @notice Lets the admin reduce recorded debt, clamped at zero.
    """
    assert self._is_admin(msg.sender)

    reduction: uint256 = min(_amount, self.debt)
    self.debt -= reduction
    log DebtReduced(
        caller=msg.sender,
        requested_reduction=_amount,
        actual_reduction=reduction,
        debt_after=self.debt,
    )


@external
@payable
@nonreentrant
def execute(_target: address, _value: uint256, _data: Bytes[65535]) -> Bytes[65535]:
    """
    @notice Lets the admin call another address and returns any response.
    """
    assert self._is_admin(msg.sender)
    assert _target != empty(address)

    result: Bytes[65535] = raw_call(
        _target,
        _data,
        value=_value,
        max_outsize=65535,
    )
    selector: bytes4 = empty(bytes4)
    if len(_data) >= 4:
        selector = convert(slice(_data, 0, 4), bytes4)
    log Executed(
        target=_target,
        value=_value,
        selector=selector,
        data_hash=keccak256(_data),
    )
    return result


@external
@nonpayable
def commit_new_admin(_new_admin: address):
    """
    @notice Commit new admin of the Peg Keeper.
    @dev In order to revert, commit_new_admin(current_admin) may be called.
    @param _new_admin Address of the new admin.
    """
    assert msg.sender == self.admin
    assert _new_admin != empty(address)

    self.new_admin_deadline = block.timestamp + ADMIN_ACTIONS_DELAY
    self.future_admin = _new_admin
    log CommitNewAdmin(admin=_new_admin)


@external
@nonpayable
def apply_new_admin():
    """
    @notice Apply new admin of the Peg Keeper.
    @dev Should be executed from new admin.
    """
    new_admin: address = self.future_admin
    new_admin_deadline: uint256 = self.new_admin_deadline
    assert msg.sender == new_admin
    assert block.timestamp >= new_admin_deadline
    assert new_admin_deadline != 0

    self.admin = new_admin
    self.new_admin_deadline = 0
    log ApplyNewAdmin(admin=new_admin)


@external
def set_emergency_admin(_admin: address):
    """
    @notice Replaces the account allowed to pause keeper actions.
    """
    assert msg.sender == self.admin
    self.emergency_admin = _admin
    log SetEmergencyAdmin(admin=_admin)


@external
def set_policy_contract(_new_policy: address):
    """
    @notice Replaces the aggregate direction and admission policy used by this keeper.
    """
    assert self._is_admin(msg.sender)
    assert _new_policy != empty(address) and _new_policy.codesize > 0

    old_policy: address = self.policy
    self.policy = _new_policy
    log PolicyContractUpdated(old_policy=old_policy, new_policy=_new_policy)


@external
def set_keeper_profit_share_bps(_new_keeper_profit_share_bps: uint256):
    """
    @notice Changes this keeper's caller-reward share.
    """
    assert self._is_admin(msg.sender)
    assert _new_keeper_profit_share_bps <= BPS

    old_keeper_profit_share_bps: uint256 = self.keeper_profit_share_bps
    self.keeper_profit_share_bps = _new_keeper_profit_share_bps
    log KeeperProfitShareUpdated(
        old_keeper_profit_share_bps=old_keeper_profit_share_bps,
        new_keeper_profit_share_bps=_new_keeper_profit_share_bps,
    )


@external
def set_intervention_policy(
    _action_imbalance_bps: uint256,
    _action_delay: uint256,
):
    """
    @notice Changes the local-imbalance share and action delay.
    """
    assert self._is_admin(msg.sender)
    assert _action_imbalance_bps > 0
    assert _action_imbalance_bps <= BPS

    self.action_imbalance_bps = _action_imbalance_bps
    self.action_delay = _action_delay
    log InterventionPolicyUpdated(
        action_imbalance_bps=_action_imbalance_bps,
        action_delay=_action_delay,
    )


@external
def set_policy(
    _entry_min_profit_ppm: uint256,
    _normal_exit_min_profit_ppm: uint256,
    _max_debt: uint256,
):
    """
    @notice Changes local profit and crvUSD limits.
    """
    assert self._is_admin(msg.sender)
    assert _normal_exit_min_profit_ppm <= PPM
    assert _max_debt > 0

    self.entry_min_profit_ppm = _entry_min_profit_ppm
    self.normal_exit_min_profit_ppm = _normal_exit_min_profit_ppm
    self.max_debt = _max_debt

    log PolicyUpdated(
        entry_min_profit_ppm=_entry_min_profit_ppm,
        normal_exit_min_profit_ppm=_normal_exit_min_profit_ppm,
        max_debt=_max_debt,
    )


@external
def set_direction_paused(_direction: uint256, _paused: bool):
    """
    @notice Pauses or resumes expansion, contraction, or all execution.
    """
    admin: address = self.admin
    emergency_admin: address = self.emergency_admin
    assert msg.sender == admin or msg.sender == emergency_admin
    if msg.sender == emergency_admin:
        assert _paused

    if _direction == DIRECTION_EXPANSION:
        self.expansion_paused = _paused
    elif _direction == DIRECTION_CONTRACTION:
        self.contraction_paused = _paused
    elif _direction == DIRECTION_ALL:
        self.all_execution_paused = _paused
    else:
        raise

    log DirectionPaused(direction=_direction, paused=_paused)
