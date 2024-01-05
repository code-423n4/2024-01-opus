mod seer_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use debug::PrintTrait;
    use opus::core::roles::shrine_roles;
    use opus::core::seer::seer as seer_contract;
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::IPragma::{IPragmaDispatcher, IPragmaDispatcherTrait};
    use opus::interfaces::ISeer::{ISeerDispatcher, ISeerDispatcherTrait};
    use opus::interfaces::ISentinel::ISentinelDispatcher;
    use opus::interfaces::IShrine::IShrineDispatcher;
    use opus::mock::mock_pragma::{IMockPragmaDispatcher, IMockPragmaDispatcherTrait};
    use opus::tests::external::utils::pragma_utils;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, CheatTarget};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{
        contract_address_to_felt252, contract_address_try_from_felt252, get_block_timestamp, ContractAddress
    };
    use wadray::Wad;

    //
    // Constants
    //

    const ETH_INIT_PRICE: u128 = 1888000000000000000000; // Wad scale
    const WBTC_INIT_PRICE: u128 = 20000000000000000000000; // Wad scale

    const UPDATE_FREQUENCY: u64 = consteval_int!(30 * 60); // 30 minutes

    //
    // Address constants
    //

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('seer owner').unwrap()
    }

    fn dummy_eth() -> ContractAddress {
        contract_address_try_from_felt252('eth token').unwrap()
    }

    fn dummy_wbtc() -> ContractAddress {
        contract_address_try_from_felt252('wbtc token').unwrap()
    }

    fn deploy_seer(
        seer_class: Option<ContractClass>, sentinel_class: Option<ContractClass>, shrine_class: Option<ContractClass>
    ) -> (ISeerDispatcher, ISentinelDispatcher, IShrineDispatcher) {
        let (sentinel_dispatcher, shrine) = sentinel_utils::deploy_sentinel(sentinel_class, shrine_class);
        let calldata: Array<felt252> = array![
            contract_address_to_felt252(admin()),
            contract_address_to_felt252(shrine),
            contract_address_to_felt252(sentinel_dispatcher.contract_address),
            UPDATE_FREQUENCY.into()
        ];

        let seer_class = match seer_class {
            Option::Some(class) => class,
            Option::None => declare('seer')
        };

        let seer_addr = seer_class.deploy(@calldata).expect('failed seer deploy');

        // Allow Seer to advance Shrine
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine };
        start_prank(CheatTarget::One(shrine), shrine_utils::admin());
        shrine_ac.grant_role(shrine_roles::seer(), seer_addr);
        stop_prank(CheatTarget::One(shrine));

        (
            ISeerDispatcher { contract_address: seer_addr },
            sentinel_dispatcher,
            IShrineDispatcher { contract_address: shrine }
        )
    }

    fn deploy_seer_using(
        seer_class: Option<ContractClass>, shrine: ContractAddress, sentinel: ContractAddress
    ) -> ISeerDispatcher {
        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(admin()),
            contract_address_to_felt252(shrine),
            contract_address_to_felt252(sentinel),
            UPDATE_FREQUENCY.into()
        ];

        let seer_class = match seer_class {
            Option::Some(class) => class,
            Option::None => declare('seer')
        };

        let seer_addr = seer_class.deploy(@calldata).expect('failed seer deploy');

        // Allow Seer to advance Shrine
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine };
        start_prank(CheatTarget::One(shrine), shrine_utils::admin());
        shrine_ac.grant_role(shrine_roles::seer(), seer_addr);
        stop_prank(CheatTarget::One(shrine));

        ISeerDispatcher { contract_address: seer_addr }
    }

    fn add_oracles(
        pragma_class: Option<ContractClass>, mock_pragma_class: Option<ContractClass>, seer: ISeerDispatcher
    ) -> Span<ContractAddress> {
        let mut oracles: Array<ContractAddress> = ArrayTrait::new();

        let (pragma, _) = pragma_utils::pragma_deploy(pragma_class, mock_pragma_class);
        oracles.append(pragma.contract_address);
        let pragma_ac = IAccessControlDispatcher { contract_address: pragma.contract_address };

        start_prank(CheatTarget::One(seer.contract_address), admin());
        seer.set_oracles(oracles.span());
        stop_prank(CheatTarget::One(seer.contract_address));

        oracles.span()
    }

    fn add_yangs(seer: ISeerDispatcher, yangs: Span<ContractAddress>) {
        let oracles: Span<ContractAddress> = seer.get_oracles();
        // assuming first oracle is Pragma
        let pragma = IPragmaDispatcher { contract_address: *oracles.at(0) };
        pragma_utils::add_yangs_to_pragma(pragma, yangs);
    }

    fn mock_valid_price_update(seer: ISeerDispatcher, yang: ContractAddress, price: Wad) {
        let current_ts: u64 = get_block_timestamp();
        let oracles: Span<ContractAddress> = seer.get_oracles();

        // assuming first oracle is Pragma
        let pragma = IOracleDispatcher { contract_address: *oracles.at(0) };
        let mock_pragma = IMockPragmaDispatcher { contract_address: pragma.get_oracle() };
        pragma_utils::mock_valid_price_update(mock_pragma, yang, price, current_ts);
    }
}
