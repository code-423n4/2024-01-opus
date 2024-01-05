mod pragma_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use debug::PrintTrait;
    use opus::core::roles::{pragma_roles, shrine_roles};
    use opus::external::pragma::pragma as pragma_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::IPragma::{IPragmaDispatcher, IPragmaDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::external::{IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait};
    use opus::mock::mock_pragma::{
        mock_pragma as mock_pragma_contract, IMockPragmaDispatcher, IMockPragmaDispatcherTrait
    };
    use opus::tests::seer::utils::seer_utils::{ETH_INIT_PRICE, WBTC_INIT_PRICE};
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::pragma::PragmaPricesResponse;
    use opus::utils::math::pow;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, CheatTarget};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{
        ContractAddress, contract_address_to_felt252, contract_address_try_from_felt252, get_block_timestamp,
    };
    use wadray::{Wad, WAD_DECIMALS, WAD_SCALE};

    //
    // Constants
    //

    const FRESHNESS_THRESHOLD: u64 = consteval_int!(30 * 60); // 30 minutes * 60 seconds
    const SOURCES_THRESHOLD: u32 = 3;
    const UPDATE_FREQUENCY: u64 = consteval_int!(10 * 60); // 10 minutes * 60 seconds
    const DEFAULT_NUM_SOURCES: u32 = 5;
    const ETH_USD_PAIR_ID: felt252 = 'ETH/USD';
    const WBTC_USD_PAIR_ID: felt252 = 'BTC/USD';
    const PEPE_USD_PAIR_ID: felt252 = 'PEPE/USD';
    const PRAGMA_DECIMALS: u8 = 8;

    //
    // Constant addresses
    //

    #[inline(always)]
    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('pragma owner').unwrap()
    }

    //
    // Test setup helpers
    //

    fn mock_pragma_deploy(mock_pragma_class: Option<ContractClass>) -> IMockPragmaDispatcher {
        let mut calldata: Array<felt252> = ArrayTrait::new();

        let mock_pragma_class = match mock_pragma_class {
            Option::Some(class) => class,
            Option::None => declare('mock_pragma'),
        };

        let mock_pragma_addr = mock_pragma_class.deploy(@calldata).expect('failed deploy pragma');

        IMockPragmaDispatcher { contract_address: mock_pragma_addr }
    }

    fn pragma_deploy(
        pragma_class: Option<ContractClass>, mock_pragma_class: Option<ContractClass>
    ) -> (IPragmaDispatcher, IMockPragmaDispatcher) {
        let mock_pragma: IMockPragmaDispatcher = mock_pragma_deploy(mock_pragma_class);
        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(admin()),
            contract_address_to_felt252(mock_pragma.contract_address),
            FRESHNESS_THRESHOLD.into(),
            SOURCES_THRESHOLD.into(),
        ];

        let pragma_class = match pragma_class {
            Option::Some(class) => class,
            Option::None => declare('pragma'),
        };

        let pragma_addr = pragma_class.deploy(@calldata).expect('failed deploy pragma');

        let pragma = IPragmaDispatcher { contract_address: pragma_addr };

        (pragma, mock_pragma)
    }

    fn add_yangs_to_pragma(pragma: IPragmaDispatcher, yangs: Span<ContractAddress>) {
        let eth_yang = *yangs.at(0);
        let wbtc_yang = *yangs.at(1);

        // add_yang does an assert on the response decimals, so we
        // need to provide a valid mock response for it to pass
        let oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        let mock_pragma = IMockPragmaDispatcher { contract_address: oracle.get_oracle() };
        mock_valid_price_update(mock_pragma, eth_yang, ETH_INIT_PRICE.into(), get_block_timestamp());
        mock_valid_price_update(mock_pragma, wbtc_yang, WBTC_INIT_PRICE.into(), get_block_timestamp());

        // Add yangs to Pragma
        start_prank(CheatTarget::One(pragma.contract_address), admin());
        pragma.set_yang_pair_id(eth_yang, ETH_USD_PAIR_ID);
        pragma.set_yang_pair_id(wbtc_yang, WBTC_USD_PAIR_ID);
        stop_prank(CheatTarget::One(pragma.contract_address));
    }

    //
    // Helpers
    //

    fn convert_price_to_pragma_scale(price: Wad) -> u128 {
        let scale: u128 = pow(10_u128, WAD_DECIMALS - PRAGMA_DECIMALS);
        price.val / scale
    }

    fn get_pair_id_for_yang(yang: ContractAddress) -> felt252 {
        let erc20 = IERC20Dispatcher { contract_address: yang };
        let symbol: felt252 = erc20.symbol();

        if symbol == 'ETH' {
            ETH_USD_PAIR_ID
        } else if symbol == 'WBTC' {
            WBTC_USD_PAIR_ID
        } else if symbol == 'PEPE' {
            PEPE_USD_PAIR_ID
        } else {
            0
        }
    }

    // Helper function to add a valid price update to the mock Pragma oracle
    // using default values for decimals and number of sources.
    fn mock_valid_price_update(mock_pragma: IMockPragmaDispatcher, yang: ContractAddress, price: Wad, timestamp: u64) {
        let response = PragmaPricesResponse {
            price: convert_price_to_pragma_scale(price),
            decimals: PRAGMA_DECIMALS.into(),
            last_updated_timestamp: timestamp,
            num_sources_aggregated: DEFAULT_NUM_SOURCES,
            expiration_timestamp: Option::None,
        };
        let pair_id: felt252 = get_pair_id_for_yang(yang);
        mock_pragma.next_get_data_median(pair_id, response);
    }
}
