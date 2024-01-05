mod sentinel_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use integer::BoundedU256;
    use opus::core::roles::{sentinel_roles, shrine_roles};
    use opus::core::sentinel::sentinel as sentinel_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::gate::utils::gate_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, CheatTarget, PrintTrait};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{ContractAddress, contract_address_to_felt252, contract_address_try_from_felt252, get_caller_address};
    use wadray::{Wad, Ray};

    const ETH_ASSET_MAX: u128 = 1000000000000000000000; // 1000 (wad)
    const WBTC_ASSET_MAX: u128 = 100000000000; // 1000 * 10**8

    #[inline(always)]
    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('sentinel admin').unwrap()
    }

    #[inline(always)]
    fn mock_abbot() -> ContractAddress {
        contract_address_try_from_felt252('mock abbot').unwrap()
    }

    #[inline(always)]
    fn dummy_yang_addr() -> ContractAddress {
        contract_address_try_from_felt252('dummy yang').unwrap()
    }

    #[inline(always)]
    fn dummy_yang_gate_addr() -> ContractAddress {
        contract_address_try_from_felt252('dummy yang token').unwrap()
    }

    //
    // Test setup
    //

    fn deploy_sentinel(
        sentinel_class: Option<ContractClass>, shrine_class: Option<ContractClass>,
    ) -> (ISentinelDispatcher, ContractAddress) {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(shrine_class);

        let calldata: Array<felt252> = array![
            contract_address_to_felt252(admin()), contract_address_to_felt252(shrine_addr)
        ];

        let sentinel_class = match sentinel_class {
            Option::Some(class) => class,
            Option::None => declare('sentinel')
        };

        let sentinel_addr = sentinel_class.deploy(@calldata).expect('failed deploy sentinel');

        // Grant `abbot` role to `mock_abbot`
        start_prank(CheatTarget::One(sentinel_addr), admin());
        IAccessControlDispatcher { contract_address: sentinel_addr }.grant_role(sentinel_roles::abbot(), mock_abbot());

        let shrine_ac = IAccessControlDispatcher { contract_address: shrine_addr };
        start_prank(CheatTarget::One(shrine_addr), shrine_utils::admin());

        shrine_ac.grant_role(shrine_roles::sentinel(), sentinel_addr);
        shrine_ac.grant_role(shrine_roles::abbot(), mock_abbot());

        stop_prank(CheatTarget::Multiple(array![shrine_addr, sentinel_addr]));

        (ISentinelDispatcher { contract_address: sentinel_addr }, shrine_addr)
    }

    fn deploy_sentinel_with_gates(
        sentinel_class: Option<ContractClass>,
        token_class: Option<ContractClass>,
        gate_class: Option<ContractClass>,
        shrine_class: Option<ContractClass>,
    ) -> (ISentinelDispatcher, IShrineDispatcher, Span<ContractAddress>, Span<IGateDispatcher>) {
        let (sentinel, shrine_addr) = deploy_sentinel(sentinel_class, shrine_class);

        let token_class = Option::Some(
            match token_class {
                Option::Some(class) => class,
                Option::None => declare('erc20_mintable')
            }
        );

        let gate_class = Option::Some(
            match gate_class {
                Option::Some(class) => class,
                Option::None => declare('gate')
            }
        );

        let (eth, eth_gate) = add_eth_yang(sentinel, shrine_addr, token_class, gate_class);
        let (wbtc, wbtc_gate) = add_wbtc_yang(sentinel, shrine_addr, token_class, gate_class);

        let mut assets: Array<ContractAddress> = array![eth, wbtc];
        let mut gates: Array<IGateDispatcher> = array![eth_gate, wbtc_gate];

        (sentinel, IShrineDispatcher { contract_address: shrine_addr }, assets.span(), gates.span())
    }

    fn deploy_sentinel_with_eth_gate(
        token_class: Option<ContractClass>
    ) -> (ISentinelDispatcher, IShrineDispatcher, ContractAddress, IGateDispatcher) {
        let (sentinel, shrine_addr) = deploy_sentinel(Option::None, Option::None);
        let (eth, eth_gate) = add_eth_yang(sentinel, shrine_addr, token_class, Option::None);

        (sentinel, IShrineDispatcher { contract_address: shrine_addr }, eth, eth_gate)
    }

    fn add_eth_yang(
        sentinel: ISentinelDispatcher,
        shrine_addr: ContractAddress,
        token_class: Option<ContractClass>,
        gate_class: Option<ContractClass>,
    ) -> (ContractAddress, IGateDispatcher) {
        let eth: ContractAddress = common::eth_token_deploy(token_class);

        let eth_gate: ContractAddress = gate_utils::gate_deploy(
            eth, shrine_addr, sentinel.contract_address, gate_class
        );

        let eth_erc20 = IERC20Dispatcher { contract_address: eth };

        // Transferring the initial deposit amounts to `admin()`
        start_prank(CheatTarget::One(eth), common::eth_hoarder());
        eth_erc20.transfer(admin(), sentinel_contract::INITIAL_DEPOSIT_AMT.into());
        start_prank(CheatTarget::One(eth), admin());
        eth_erc20.approve(sentinel.contract_address, sentinel_contract::INITIAL_DEPOSIT_AMT.into());
        stop_prank(CheatTarget::One(eth));

        start_prank(CheatTarget::One(sentinel.contract_address), admin());

        sentinel
            .add_yang(
                eth,
                ETH_ASSET_MAX,
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                eth_gate
            );

        stop_prank(CheatTarget::One(sentinel.contract_address));

        (eth, IGateDispatcher { contract_address: eth_gate })
    }

    fn add_wbtc_yang(
        sentinel: ISentinelDispatcher,
        shrine_addr: ContractAddress,
        token_class: Option<ContractClass>,
        gate_class: Option<ContractClass>,
    ) -> (ContractAddress, IGateDispatcher) {
        let wbtc: ContractAddress = common::wbtc_token_deploy(token_class);
        let wbtc_gate: ContractAddress = gate_utils::gate_deploy(
            wbtc, shrine_addr, sentinel.contract_address, gate_class
        );

        let wbtc_erc20 = IERC20Dispatcher { contract_address: wbtc };

        // Transferring the initial deposit amounts to `admin()`
        start_prank(CheatTarget::One(wbtc), common::wbtc_hoarder());
        wbtc_erc20.transfer(admin(), sentinel_contract::INITIAL_DEPOSIT_AMT.into());
        start_prank(CheatTarget::One(wbtc), admin());
        wbtc_erc20.approve(sentinel.contract_address, sentinel_contract::INITIAL_DEPOSIT_AMT.into());
        stop_prank(CheatTarget::One(wbtc));

        start_prank(CheatTarget::One(sentinel.contract_address), admin());
        sentinel
            .add_yang(
                wbtc,
                WBTC_ASSET_MAX,
                shrine_utils::YANG2_THRESHOLD.into(),
                shrine_utils::YANG2_START_PRICE.into(),
                shrine_utils::YANG2_BASE_RATE.into(),
                wbtc_gate
            );
        stop_prank(CheatTarget::Multiple(array![sentinel.contract_address, wbtc]));

        (wbtc, IGateDispatcher { contract_address: wbtc_gate })
    }

    fn approve_max(gate: IGateDispatcher, token: ContractAddress, user: ContractAddress) {
        let token_erc20 = IERC20Dispatcher { contract_address: token };
        let prev_address: ContractAddress = get_caller_address();
        start_prank(CheatTarget::One(token), user);
        token_erc20.approve(gate.contract_address, BoundedU256::max());
        stop_prank(CheatTarget::One(token));
    }
}
