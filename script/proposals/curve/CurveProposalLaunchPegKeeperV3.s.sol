// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseCurveProposal} from "./BaseCurveProposal.sol";
import {IAggMonetaryPolicy} from "../../../src/interfaces/IAggMonetaryPolicy.sol";
import {IChainlinkStablecoinOracle} from "../../../src/interfaces/IChainlinkStablecoinOracle.sol";
import {IControllerFactory} from "../../../src/interfaces/IControllerFactory.sol";
import {IERC20} from "../../../src/interfaces/IERC20.sol";
import {IPegKeeperPolicy} from "../../../src/interfaces/IPegKeeperPolicy.sol";
import {IPegKeeperRegistry} from "../../../src/interfaces/IPegKeeperRegistry.sol";
import {IPegKeeperV3} from "../../../src/interfaces/IPegKeeperV3.sol";

/// @title CurveProposalLaunchPegKeeperV3
/// @notice Registers and funds three preconfigured standalone PegKeeperV3 contracts.
contract CurveProposalLaunchPegKeeperV3 is BaseCurveProposal {
    string public constant DEPLOYMENT_INPUT_PATH =
        "deployments/mainnet/PegKeeperV3-deployment.json";

    uint256 public constant KEEPER_RUNTIME_SIZE = 15_187;
    bytes32 public constant EXPECTED_KEEPER_RUNTIME_HASH =
        0x418be17ea754b8b279ff2ffa4c8574a26f999d5a506806fdcc349e5eab9f0279;
    uint256 public constant POLICY_RUNTIME_SIZE = 905;
    bytes32 public constant EXPECTED_POLICY_RUNTIME_HASH =
        0xa11f74514ddad33cebd3ea933e1bf8d802b74107af7b3bc23b0bb6a0067a758c;
    uint256 public constant REGISTRY_RUNTIME_SIZE = 1_296;
    bytes32 public constant EXPECTED_REGISTRY_RUNTIME_HASH =
        0xa8701fd3d6a78297bb59b5d1466c6e20e96e41959650282aa03b4e7b4015e8a8;
    uint256 public constant CHAINLINK_ORACLE_CORE_SIZE = 431;
    uint256 public constant CHAINLINK_ORACLE_RUNTIME_SIZE = 527;
    bytes32 public constant EXPECTED_CHAINLINK_ORACLE_CORE_HASH =
        0xf2ae2f566e1a5cb82fd67cdf92523dfbb47e6a21347d35a57342cab36791287a;

    uint256 public constant FRXUSD_ENTRY_MIN_PROFIT_PPM = 10;
    uint256 public constant FRXUSD_EXIT_MIN_PROFIT_PPM = 150;
    uint256 public constant STABLECOIN_ENTRY_MIN_PROFIT_PPM = 300;
    uint256 public constant STABLECOIN_EXIT_MIN_PROFIT_PPM = 80;
    uint256 public constant KEEPER_PROFIT_SHARE_BPS = 3_000;
    uint256 public constant ACTION_IMBALANCE_BPS = 2_000;
    uint256 public constant ACTION_DELAY = 12 seconds;
    uint256 public constant MIN_BACKING_ORACLE_PRICE = 999_000_000_000_000_000;
    uint256 public constant FRXUSD_CHAINLINK_MAX_DELAY = 26 hours;
    uint256 public constant STABLECOIN_CHAINLINK_MAX_DELAY = 26 hours;
    uint256 public constant AMM_EXECUTION_BUFFER_BPS = 3;

    uint256 public constant FRXUSD_CAP = 150_000_000e18;
    uint256 public constant USDC_CAP = 150_000_000e18;
    uint256 public constant USDT_CAP = 150_000_000e18;

    address public constant CURVE_EMERGENCY_ADMIN = 0x467947EE34aF926cF1DCac093870f613C96B1E0c;
    address public constant CRVUSD_AGGREGATE_ORACLE = 0x18672b1b0c623a30089A280Ed9256379fb0E4E62;
    address public constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;
    address public constant CRVUSD_MONETARY_POLICY = 0x07491D124ddB3Ef59a8938fCB3EE50F9FA0b9251;
    address public constant CRVUSD_LEGACY_MONETARY_POLICY =
        0xc684432FD6322c6D58b6bC5d28B18569aA0AD0A1;

    address public constant FRXUSD_USD_PROXY = 0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83;
    address public constant USDC_USD_PROXY = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address public constant USDT_USD_PROXY = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    address public constant FRXUSD_CRVUSD_POOL = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1;
    address public constant USDC_CRVUSD_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address public constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    address public constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address public pegKeeperPolicy;
    address public pegKeeperRegistry;
    address public frxUsdOracle;
    address public usdcOracle;
    address public usdtOracle;
    address public frxUsdKeeper;
    address public usdcKeeper;
    address public usdtKeeper;

    function run() external returns (uint256 proposalId) {
        loadDeployment(DEPLOYMENT_INPUT_PATH);
        vm.startBroadcast();
        proposalId = proposeOwnershipVote(
            buildProposalScript(), "Register and fund three standalone direct PegKeeperV3 keepers"
        );
        vm.stopBroadcast();
    }

    function loadDeployment(string memory path) public {
        string memory json = vm.readFile(path);
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "deployment chain");
        pegKeeperPolicy = vm.parseJsonAddress(json, ".policy");
        pegKeeperRegistry = vm.parseJsonAddress(json, ".registry");
        frxUsdOracle = vm.parseJsonAddress(json, ".frxUsdUsdOracle");
        usdcOracle = vm.parseJsonAddress(json, ".usdcUsdOracle");
        usdtOracle = vm.parseJsonAddress(json, ".usdtUsdOracle");
        frxUsdKeeper = vm.parseJsonAddress(json, ".frxUsdPegKeeper");
        usdcKeeper = vm.parseJsonAddress(json, ".usdcPegKeeper");
        usdtKeeper = vm.parseJsonAddress(json, ".usdtPegKeeper");
    }

    function setDeployment(
        address policy,
        address registry,
        address[3] calldata oracles,
        address[3] calldata keepers
    ) external {
        require(
            policy != address(0) && registry != address(0) && oracles[0] != address(0)
                && oracles[1] != address(0) && oracles[2] != address(0) && keepers[0] != address(0)
                && keepers[1] != address(0) && keepers[2] != address(0),
            "zero dependency"
        );
        pegKeeperPolicy = policy;
        pegKeeperRegistry = registry;
        frxUsdOracle = oracles[0];
        usdcOracle = oracles[1];
        usdtOracle = oracles[2];
        frxUsdKeeper = keepers[0];
        usdcKeeper = keepers[1];
        usdtKeeper = keepers[2];
    }

    function expectedKeeper(uint256 keeperNumber) public view returns (address) {
        require(pegKeeperPolicy != address(0), "policy not set");
        require(keeperNumber > 0 && keeperNumber <= 3, "keeper number");
        if (keeperNumber == 1) return frxUsdKeeper;
        if (keeperNumber == 2) return usdcKeeper;
        return usdtKeeper;
    }

    function buildProposalScript() public view override returns (bytes memory script) {
        script = buildScript(CURVE_OWNERSHIP_AGENT, buildProposalActions());
    }

    function buildProposalActions() public view returns (Action[] memory actions) {
        _validateDependencies();
        _validateMonetaryPolicies();

        address[] memory keepers = new address[](3);
        keepers[0] = frxUsdKeeper;
        keepers[1] = usdcKeeper;
        keepers[2] = usdtKeeper;
        actions = new Action[](10);
        actions[0] = Action({
            target: pegKeeperRegistry,
            data: abi.encodeWithSelector(IPegKeeperRegistry.add_peg_keepers.selector, keepers)
        });
        uint256 actionIndex = 1;
        for (uint256 i; i < keepers.length; ++i) {
            actions[actionIndex++] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, keepers[i]);
            actions[actionIndex++] =
                _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, keepers[i]);
        }

        actions[7] = _debtCeilingAction(frxUsdKeeper, FRXUSD_CAP);
        actions[8] = _debtCeilingAction(usdcKeeper, USDC_CAP);
        actions[9] = _debtCeilingAction(usdtKeeper, USDT_CAP);
    }

    function _validateDependencies() internal view {
        require(pegKeeperPolicy != address(0), "policy not set");
        require(pegKeeperRegistry != address(0), "registry not set");

        IPegKeeperPolicy policy = IPegKeeperPolicy(pegKeeperPolicy);
        require(policy.admin() == CURVE_OWNERSHIP_AGENT, "policy admin");
        require(policy.future_admin() == address(0), "policy future admin");
        require(policy.new_admin_deadline() == 0, "policy admin deadline");
        require(policy.aggregateCrvUsdOracle() == CRVUSD_AGGREGATE_ORACLE, "aggregate oracle");
        require(policy.fee_receiver() == FEE_SPLITTER, "fee receiver");
        require(pegKeeperPolicy.code.length == POLICY_RUNTIME_SIZE, "policy size");
        require(pegKeeperPolicy.codehash == EXPECTED_POLICY_RUNTIME_HASH, "policy hash");

        IPegKeeperRegistry registry = IPegKeeperRegistry(pegKeeperRegistry);
        require(registry.admin() == CURVE_OWNERSHIP_AGENT, "registry admin");
        require(registry.future_admin() == address(0), "registry future admin");
        require(registry.new_admin_deadline() == 0, "registry admin deadline");
        require(registry.peg_keeper_count() == 0, "registry keeper count");
        require(!registry.is_active(frxUsdKeeper), "frxUSD already registered");
        require(!registry.is_active(usdcKeeper), "USDC already registered");
        require(!registry.is_active(usdtKeeper), "USDT already registered");
        require(pegKeeperRegistry.code.length == REGISTRY_RUNTIME_SIZE, "registry size");
        require(pegKeeperRegistry.codehash == EXPECTED_REGISTRY_RUNTIME_HASH, "registry hash");

        _validateKeeperAssets(
            frxUsdKeeper, FRXUSD_CRVUSD_POOL, FRXUSD, FRXUSD, frxUsdOracle, false, true
        );
        _validateKeeperConfig(
            frxUsdKeeper, FRXUSD_ENTRY_MIN_PROFIT_PPM, FRXUSD_EXIT_MIN_PROFIT_PPM, FRXUSD_CAP, 1
        );
        _validateKeeperAssets(usdcKeeper, USDC_CRVUSD_POOL, USDC, USDC, usdcOracle, false, false);
        _validateKeeperConfig(
            usdcKeeper, STABLECOIN_ENTRY_MIN_PROFIT_PPM, STABLECOIN_EXIT_MIN_PROFIT_PPM, USDC_CAP, 2
        );
        _validateKeeperAssets(usdtKeeper, USDT_CRVUSD_POOL, USDT, USDT, usdtOracle, false, false);
        _validateKeeperConfig(
            usdtKeeper, STABLECOIN_ENTRY_MIN_PROFIT_PPM, STABLECOIN_EXIT_MIN_PROFIT_PPM, USDT_CAP, 3
        );

        _validateChainlinkOracle(frxUsdOracle, FRXUSD_USD_PROXY, FRXUSD_CHAINLINK_MAX_DELAY);
        _validateChainlinkOracle(usdcOracle, USDC_USD_PROXY, STABLECOIN_CHAINLINK_MAX_DELAY);
        _validateChainlinkOracle(usdtOracle, USDT_USD_PROXY, STABLECOIN_CHAINLINK_MAX_DELAY);
    }

    function _validateKeeperAssets(
        address keeperAddress,
        address expectedPool,
        address expectedPairedToken,
        address expectedBackingAsset,
        address expectedOracle,
        bool expectedErc4626,
        bool expectedDynamicArrays
    ) internal view {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        require(keeperAddress.code.length > 0, "keeper code");
        require(keeperAddress.code.length == KEEPER_RUNTIME_SIZE, "keeper size");
        require(keeperAddress.codehash == EXPECTED_KEEPER_RUNTIME_HASH, "keeper hash");
        require(keeper.policy() == pegKeeperPolicy, "keeper policy");
        require(keeper.controller_factory() == CURVE_CRVUSD_CONTROLLER_FACTORY, "keeper controller");
        require(keeper.pool() == expectedPool, "keeper pool");
        require(keeper.paired_token() == expectedPairedToken, "keeper paired token");
        require(keeper.backing_asset() == expectedBackingAsset, "keeper backing asset");
        require(keeper.backing_oracle() == expectedOracle, "keeper oracle");
        require(keeper.paired_token_is_erc4626() == expectedErc4626, "keeper ERC4626 mode");
        require(keeper.pool_uses_dynamic_arrays() == expectedDynamicArrays, "keeper liquidity mode");
    }

    function _validateKeeperConfig(
        address keeperAddress,
        uint256 expectedEntryProfit,
        uint256 expectedExitProfit,
        uint256 expectedLocalCap,
        uint256 expectedIndex
    ) internal view {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        require(
            keeper.crv_usd() == IControllerFactory(CURVE_CRVUSD_CONTROLLER_FACTORY).stablecoin(),
            "keeper crvUSD"
        );
        require(keeper.keeper_index() == expectedIndex, "keeper index");
        require(keeper.min_backing_oracle_price() == MIN_BACKING_ORACLE_PRICE, "oracle floor");
        require(keeper.entry_min_profit_ppm() == expectedEntryProfit, "entry profit");
        require(keeper.normal_exit_min_profit_ppm() == expectedExitProfit, "exit profit");
        require(keeper.keeper_profit_share_bps() == KEEPER_PROFIT_SHARE_BPS, "profit share");
        require(keeper.max_debt() == expectedLocalCap, "local cap");
        require(keeper.action_imbalance_bps() == ACTION_IMBALANCE_BPS, "imbalance share");
        require(keeper.action_delay() == ACTION_DELAY, "action delay");
        require(keeper.amm_execution_buffer_bps() == AMM_EXECUTION_BUFFER_BPS, "AMM buffer");
        require(keeper.admin() == CURVE_OWNERSHIP_AGENT, "keeper admin");
        require(keeper.future_admin() == address(0), "keeper future admin");
        require(keeper.new_admin_deadline() == 0, "keeper admin deadline");
        require(keeper.emergency_admin() == CURVE_EMERGENCY_ADMIN, "keeper emergency admin");
        require(!keeper.expansion_paused(), "keeper expansion paused");
        require(!keeper.contraction_paused(), "keeper contraction paused");
        require(!keeper.all_execution_paused(), "keeper execution paused");
        require(keeper.debt() == 0, "keeper debt");
        require(
            IControllerFactory(CURVE_CRVUSD_CONTROLLER_FACTORY).debt_ceiling(keeperAddress) == 0,
            "keeper prefunded"
        );
        address crvUsd = IControllerFactory(CURVE_CRVUSD_CONTROLLER_FACTORY).stablecoin();
        address pool = keeper.pool();
        require(
            IERC20(crvUsd).allowance(keeperAddress, CURVE_CRVUSD_CONTROLLER_FACTORY)
                == type(uint256).max,
            "keeper ControllerFactory allowance"
        );
        require(
            IERC20(crvUsd).allowance(keeperAddress, pool) == type(uint256).max,
            "keeper pool crvUSD allowance"
        );
        require(
            IERC20(keeper.paired_token()).allowance(keeperAddress, pool) == type(uint256).max,
            "keeper pool paired-token allowance"
        );
    }

    function _validateChainlinkOracle(address adapter, address expectedFeed, uint256 maxDelay)
        internal
        view
    {
        require(adapter.code.length == CHAINLINK_ORACLE_RUNTIME_SIZE, "chainlink oracle size");
        require(
            _coreHash(adapter, CHAINLINK_ORACLE_CORE_SIZE) == EXPECTED_CHAINLINK_ORACLE_CORE_HASH,
            "chainlink oracle hash"
        );
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        require(oracle.feed() == expectedFeed, "oracle feed");
        require(oracle.feed_decimals() == 8, "oracle decimals");
        require(oracle.max_delay() == maxDelay, "oracle delay");
        require(oracle.price() >= MIN_BACKING_ORACLE_PRICE, "oracle price");
    }

    function _validateMonetaryPolicies() internal view {
        _validateMonetaryPolicy(CRVUSD_MONETARY_POLICY);
        _validateMonetaryPolicy(CRVUSD_LEGACY_MONETARY_POLICY);
    }

    function _validateMonetaryPolicy(address policyAddress) internal view {
        IAggMonetaryPolicy monetaryPolicy = IAggMonetaryPolicy(policyAddress);
        require(monetaryPolicy.admin() == CURVE_OWNERSHIP_AGENT, "monetary policy admin");
        require(
            monetaryPolicy.CONTROLLER_FACTORY() == CURVE_CRVUSD_CONTROLLER_FACTORY,
            "monetary policy factory"
        );
    }

    function _debtCeilingAction(address keeper, uint256 cap) internal view returns (Action memory) {
        return _executeViaCrvUsdEDAOProxy(
            CURVE_CRVUSD_CONTROLLER_FACTORY,
            abi.encodeWithSelector(IControllerFactory.set_debt_ceiling.selector, keeper, cap)
        );
    }

    function _monetaryPolicyAction(address policyAddress, address keeper)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            target: policyAddress,
            data: abi.encodeWithSelector(IAggMonetaryPolicy.add_peg_keeper.selector, keeper)
        });
    }

    function _coreHash(address target, uint256 size) internal view returns (bytes32 result) {
        assembly {
            let pointer := mload(0x40)
            extcodecopy(target, pointer, 0, size)
            result := keccak256(pointer, size)
        }
    }
}
