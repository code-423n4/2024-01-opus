mod test_pragma {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use debug::PrintTrait;
    use opus::core::roles::pragma_roles;
    use opus::core::shrine::shrine;
    use opus::external::pragma::pragma as pragma_contract;
    use opus::interfaces::IERC20::{IMintableDispatcher, IMintableDispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::IPragma::{IPragmaDispatcher, IPragmaDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::external::{IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait};
    use opus::mock::mock_pragma::{IMockPragmaDispatcher, IMockPragmaDispatcherTrait};
    use opus::tests::common;
    use opus::tests::external::utils::pragma_utils;
    use opus::tests::seer::utils::seer_utils;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::types::pragma::{PragmaPricesResponse, PriceValidityThresholds};
    use opus::utils::math::pow;
    use snforge_std::{start_prank, stop_prank, start_warp, CheatTarget, spy_events, SpyOn, EventSpy, EventAssertions};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{ContractAddress, contract_address_try_from_felt252, get_block_timestamp};
    use wadray::{Wad, WAD_DECIMALS, WAD_SCALE};

    //
    // Address constants
    //

    // TODO: this is not inlined as it would result in `Unknown ap change` error
    //       for `test_update_prices_invalid_gate`
    fn pepe_token_addr() -> ContractAddress {
        contract_address_try_from_felt252('PEPE').unwrap()
    }

    fn mock_eth_token_addr() -> ContractAddress {
        contract_address_try_from_felt252('ETH').unwrap()
    }

    //
    // Tests - Deployment and setters
    //

    #[test]
    fn test_pragma_setup() {
        let mut spy = spy_events(SpyOn::All);
        let (pragma, mock_pragma) = pragma_utils::pragma_deploy(Option::None, Option::None);

        // Check permissions
        let pragma_ac = IAccessControlDispatcher { contract_address: pragma.contract_address };
        let admin: ContractAddress = pragma_utils::admin();

        assert(pragma_ac.get_admin() == admin, 'wrong admin');
        assert(pragma_ac.get_roles(admin) == pragma_roles::default_admin_role(), 'wrong admin role');

        let oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        assert(oracle.get_name() == 'Pragma', 'wrong name');
        assert(oracle.get_oracle() == mock_pragma.contract_address, 'wrong oracle address');

        let expected_events = array![
            (
                pragma.contract_address,
                pragma_contract::Event::PriceValidityThresholdsUpdated(
                    pragma_contract::PriceValidityThresholdsUpdated {
                        old_thresholds: PriceValidityThresholds { freshness: 0, sources: 0 },
                        new_thresholds: PriceValidityThresholds {
                            freshness: pragma_utils::FRESHNESS_THRESHOLD, sources: pragma_utils::SOURCES_THRESHOLD
                        },
                    }
                )
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_set_price_validity_thresholds_pass() {
        let (pragma, _) = pragma_utils::pragma_deploy(Option::None, Option::None);
        let mut spy = spy_events(SpyOn::One(pragma.contract_address));

        let new_freshness: u64 = consteval_int!(5 * 60); // 5 minutes * 60 seconds
        let new_sources: u32 = 8;

        start_prank(CheatTarget::All, pragma_utils::admin());
        pragma.set_price_validity_thresholds(new_freshness, new_sources);

        let expected_events = array![
            (
                pragma.contract_address,
                pragma_contract::Event::PriceValidityThresholdsUpdated(
                    pragma_contract::PriceValidityThresholdsUpdated {
                        old_thresholds: PriceValidityThresholds {
                            freshness: pragma_utils::FRESHNESS_THRESHOLD, sources: pragma_utils::SOURCES_THRESHOLD
                        },
                        new_thresholds: PriceValidityThresholds { freshness: new_freshness, sources: new_sources },
                    }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('PGM: Freshness out of bounds',))]
    fn test_set_price_validity_threshold_freshness_too_low_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy(Option::None, Option::None);

        let invalid_freshness: u64 = pragma_contract::LOWER_FRESHNESS_BOUND - 1;
        let valid_sources: u32 = pragma_utils::SOURCES_THRESHOLD;

        start_prank(CheatTarget::All, pragma_utils::admin());
        pragma.set_price_validity_thresholds(invalid_freshness, valid_sources);
    }

    #[test]
    #[should_panic(expected: ('PGM: Freshness out of bounds',))]
    fn test_set_price_validity_threshold_freshness_too_high_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy(Option::None, Option::None);

        let invalid_freshness: u64 = pragma_contract::UPPER_FRESHNESS_BOUND + 1;
        let valid_sources: u32 = pragma_utils::SOURCES_THRESHOLD;

        start_prank(CheatTarget::All, pragma_utils::admin());
        pragma.set_price_validity_thresholds(invalid_freshness, valid_sources);
    }

    #[test]
    #[should_panic(expected: ('PGM: Sources out of bounds',))]
    fn test_set_price_validity_threshold_sources_too_low_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy(Option::None, Option::None);

        let valid_freshness: u64 = pragma_utils::FRESHNESS_THRESHOLD;
        let invalid_sources: u32 = pragma_contract::LOWER_SOURCES_BOUND - 1;

        start_prank(CheatTarget::All, pragma_utils::admin());
        pragma.set_price_validity_thresholds(valid_freshness, invalid_sources);
    }

    #[test]
    #[should_panic(expected: ('PGM: Sources out of bounds',))]
    fn test_set_price_validity_threshold_sources_too_high_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy(Option::None, Option::None);

        let valid_freshness: u64 = pragma_utils::FRESHNESS_THRESHOLD;
        let invalid_sources: u32 = pragma_contract::UPPER_SOURCES_BOUND + 1;

        start_prank(CheatTarget::All, pragma_utils::admin());
        pragma.set_price_validity_thresholds(valid_freshness, invalid_sources);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_price_validity_threshold_unauthorized_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy(Option::None, Option::None);

        let valid_freshness: u64 = pragma_utils::FRESHNESS_THRESHOLD;
        let valid_sources: u32 = pragma_utils::SOURCES_THRESHOLD;

        start_prank(CheatTarget::All, common::badguy());
        pragma.set_price_validity_thresholds(valid_freshness, valid_sources);
    }

    #[test]
    fn test_set_yang_pari_id_pass() {
        let (pragma, mock_pragma) = pragma_utils::pragma_deploy(Option::None, Option::None);
        let mut spy = spy_events(SpyOn::One(pragma.contract_address));

        // PEPE token is not added to sentinel, just needs to be deployed for the test to work
        let pepe_token: ContractAddress = common::deploy_token(
            'Pepe', 'PEPE', 18, 0.into(), common::non_zero_address(), Option::None
        );
        let pepe_token_pair_id: felt252 = pragma_utils::PEPE_USD_PAIR_ID;
        let price: u128 = 999 * pow(10_u128, pragma_utils::PRAGMA_DECIMALS);
        let current_ts: u64 = get_block_timestamp();
        // Seed first price update for PEPE token so that `Pragma.set_yang_pair_id` passes
        pragma_utils::mock_valid_price_update(mock_pragma, pepe_token, price.into(), current_ts);

        start_prank(CheatTarget::One(pragma.contract_address), pragma_utils::admin());
        pragma.set_yang_pair_id(pepe_token, pepe_token_pair_id);
        stop_prank(CheatTarget::One(pragma.contract_address));
        let expected_events = array![
            (
                pragma.contract_address,
                pragma_contract::Event::YangPairIdSet(
                    pragma_contract::YangPairIdSet { address: pepe_token, pair_id: pepe_token_pair_id },
                )
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_set_yang_pair_id_overwrite_pass() {
        let (pragma, mock_pragma) = pragma_utils::pragma_deploy(Option::None, Option::None);
        let mut spy = spy_events(SpyOn::One(pragma.contract_address));

        // PEPE token is not added to sentinel, just needs to be deployed for the test to work
        let pepe_token: ContractAddress = common::deploy_token(
            'Pepe', 'PEPE', 18, 0.into(), common::non_zero_address(), Option::None
        );
        let pepe_token_pair_id: felt252 = pragma_utils::PEPE_USD_PAIR_ID;
        let price: u128 = 999 * pow(10_u128, pragma_utils::PRAGMA_DECIMALS);
        let current_ts: u64 = get_block_timestamp();
        // Seed first price update for PEPE token so that `Pragma.set_yang_pair_id` passes
        pragma_utils::mock_valid_price_update(mock_pragma, pepe_token, price.into(), current_ts);

        start_prank(CheatTarget::One(pragma.contract_address), pragma_utils::admin());
        pragma.set_yang_pair_id(pepe_token, pepe_token_pair_id);

        // fake data for a second set_yang_pair_id, so its distinct from the first call
        let pepe_token_pair_id_2: felt252 = 'WILDPEPE/USD';
        let response = PragmaPricesResponse {
            price: price,
            decimals: pragma_utils::PRAGMA_DECIMALS.into(),
            last_updated_timestamp: current_ts + 100,
            num_sources_aggregated: pragma_utils::DEFAULT_NUM_SOURCES,
            expiration_timestamp: Option::None,
        };
        mock_pragma.next_get_data_median(pepe_token_pair_id_2, response);

        pragma.set_yang_pair_id(pepe_token, pepe_token_pair_id_2);
        let expected_events = array![
            (
                pragma.contract_address,
                pragma_contract::Event::YangPairIdSet(
                    pragma_contract::YangPairIdSet { address: pepe_token, pair_id: pepe_token_pair_id },
                )
            ),
            (
                pragma.contract_address,
                pragma_contract::Event::YangPairIdSet(
                    pragma_contract::YangPairIdSet { address: pepe_token, pair_id: pepe_token_pair_id_2 },
                )
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_yang_pair_id_unauthorized_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy(Option::None, Option::None);
        start_prank(CheatTarget::One(pragma.contract_address), common::badguy());
        pragma.set_yang_pair_id(mock_eth_token_addr(), pragma_utils::ETH_USD_PAIR_ID);
    }

    #[test]
    #[should_panic(expected: ('PGM: Invalid pair ID',))]
    fn test_set_yang_pair_id_invalid_pair_id_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy(Option::None, Option::None);
        start_prank(CheatTarget::One(pragma.contract_address), pragma_utils::admin());
        let invalid_pair_id = 0;
        pragma.set_yang_pair_id(mock_eth_token_addr(), invalid_pair_id);
    }

    #[test]
    #[should_panic(expected: ('PGM: Invalid yang address',))]
    fn test_set_yang_pair_id_invalid_yang_address_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy(Option::None, Option::None);
        start_prank(CheatTarget::One(pragma.contract_address), pragma_utils::admin());
        let invalid_yang_addr = ContractAddressZeroable::zero();
        pragma.set_yang_pair_id(invalid_yang_addr, pragma_utils::ETH_USD_PAIR_ID);
    }

    #[test]
    #[should_panic(expected: ('PGM: Unknown pair ID',))]
    fn test_set_yang_pair_id_unknown_pair_id_fail() {
        let (pragma, _) = pragma_utils::pragma_deploy(Option::None, Option::None);
        start_prank(CheatTarget::One(pragma.contract_address), pragma_utils::admin());
        pragma.set_yang_pair_id(pepe_token_addr(), pragma_utils::PEPE_USD_PAIR_ID);
    }

    #[test]
    #[should_panic(expected: ('PGM: Too many decimals',))]
    fn test_set_yang_pair_id_too_many_decimals_fail() {
        let (pragma, mock_pragma) = pragma_utils::pragma_deploy(Option::None, Option::None);

        let pragma_price_scale: u128 = pow(10_u128, pragma_utils::PRAGMA_DECIMALS);

        let pepe_price: u128 = 1000000 * pragma_price_scale; // random price
        let invalid_decimals: u32 = (WAD_DECIMALS + 1).into();
        let pepe_response = PragmaPricesResponse {
            price: pepe_price,
            decimals: invalid_decimals,
            last_updated_timestamp: 10000000,
            num_sources_aggregated: pragma_utils::DEFAULT_NUM_SOURCES,
            expiration_timestamp: Option::None,
        };
        mock_pragma.next_get_data_median(pragma_utils::PEPE_USD_PAIR_ID, pepe_response);

        start_prank(CheatTarget::One(pragma.contract_address), pragma_utils::admin());
        pragma.set_yang_pair_id(pepe_token_addr(), pragma_utils::PEPE_USD_PAIR_ID);
    }

    //
    // Tests - Functionality
    //

    #[test]
    fn test_fetch_price_pass() {
        let (pragma, mock_pragma) = pragma_utils::pragma_deploy(Option::None, Option::None);
        let (_sentinel, _shrine, yangs, _gates) = sentinel_utils::deploy_sentinel_with_gates(
            Option::None, Option::None, Option::None, Option::None
        );
        pragma_utils::add_yangs_to_pragma(pragma, yangs);

        let eth_addr = *yangs.at(0);
        let wbtc_addr = *yangs.at(1);

        // Perform a price update with starting exchange rate of 1 yang to 1 asset
        let first_ts = get_block_timestamp() + 1;
        start_warp(CheatTarget::All, first_ts);

        let mut eth_price: Wad = seer_utils::ETH_INIT_PRICE.into();
        pragma_utils::mock_valid_price_update(mock_pragma, eth_addr, eth_price, first_ts);

        let mut wbtc_price: Wad = seer_utils::WBTC_INIT_PRICE.into();
        pragma_utils::mock_valid_price_update(mock_pragma, wbtc_addr, wbtc_price, first_ts);

        start_prank(CheatTarget::One(pragma.contract_address), common::non_zero_address());
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr, false);
        let fetched_wbtc: Result<Wad, felt252> = pragma_oracle.fetch_price(wbtc_addr, false);

        assert(eth_price == fetched_eth.unwrap(), 'wrong ETH price 1');
        assert(wbtc_price == fetched_wbtc.unwrap(), 'wrong WBTC price 1');

        let next_ts = first_ts + shrine::TIME_INTERVAL;
        start_warp(CheatTarget::All, next_ts);
        eth_price += (10 * WAD_SCALE).into();
        pragma_utils::mock_valid_price_update(mock_pragma, eth_addr, eth_price, next_ts);
        wbtc_price += (10 * WAD_SCALE).into();
        pragma_utils::mock_valid_price_update(mock_pragma, wbtc_addr, wbtc_price, next_ts);
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr, false);
        let fetched_wbtc: Result<Wad, felt252> = pragma_oracle.fetch_price(wbtc_addr, false);

        assert(eth_price == fetched_eth.unwrap(), 'wrong ETH price 2');
        assert(wbtc_price == fetched_wbtc.unwrap(), 'wrong WBTC price 2');
    }

    #[test]
    fn test_fetch_price_too_soon() {
        let (pragma, mock_pragma) = pragma_utils::pragma_deploy(Option::None, Option::None);
        let mut spy = spy_events(SpyOn::One(pragma.contract_address));

        let (_sentinel, _shrine, yangs, _gates) = sentinel_utils::deploy_sentinel_with_gates(
            Option::None, Option::None, Option::None, Option::None
        );
        pragma_utils::add_yangs_to_pragma(pragma, yangs);

        let eth_addr = *yangs.at(0);
        let now: u64 = 100000000;
        start_warp(CheatTarget::All, now);

        let eth_price: Wad = seer_utils::ETH_INIT_PRICE.into();
        pragma_utils::mock_valid_price_update(mock_pragma, eth_addr, eth_price, now);

        start_prank(CheatTarget::One(pragma.contract_address), common::non_zero_address());
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr, false);

        // check if first fetch works, advance block time to be out of freshness range
        // and check if there's a error and if an event was emitted
        assert(eth_price == fetched_eth.unwrap(), 'wrong ETH price 1');
        start_warp(CheatTarget::All, now + pragma_utils::FRESHNESS_THRESHOLD + 1);
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr, false);
        assert(fetched_eth.unwrap_err() == 'PGM: Invalid price update', 'wrong result');

        let expected_events = array![
            (
                pragma.contract_address,
                pragma_contract::Event::InvalidPriceUpdate(
                    pragma_contract::InvalidPriceUpdate {
                        yang: eth_addr,
                        price: eth_price,
                        pragma_last_updated_ts: now,
                        pragma_num_sources: pragma_utils::DEFAULT_NUM_SOURCES,
                    }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);

        // now try forcing the fetch
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr, true);
        assert(eth_price == fetched_eth.unwrap(), 'wrong ETH price 2');
    }

    #[test]
    fn test_fetch_price_insufficient_sources() {
        let (pragma, mock_pragma) = pragma_utils::pragma_deploy(Option::None, Option::None);
        let mut spy = spy_events(SpyOn::One(pragma.contract_address));

        let (_sentinel, _shrine, yangs, _gates) = sentinel_utils::deploy_sentinel_with_gates(
            Option::None, Option::None, Option::None, Option::None
        );
        pragma_utils::add_yangs_to_pragma(pragma, yangs);

        let eth_addr = *yangs.at(0);
        let now: u64 = 100000000;
        start_warp(CheatTarget::All, now);

        let eth_price: Wad = seer_utils::ETH_INIT_PRICE.into();

        // prepare the response from mock oracle in such a way
        // that it has less than the required number of sources
        let num_sources: u32 = pragma_utils::SOURCES_THRESHOLD - 1;
        mock_pragma
            .next_get_data_median(
                pragma_utils::get_pair_id_for_yang(eth_addr),
                PragmaPricesResponse {
                    price: pragma_utils::convert_price_to_pragma_scale(eth_price),
                    decimals: pragma_utils::PRAGMA_DECIMALS.into(),
                    last_updated_timestamp: now,
                    num_sources_aggregated: num_sources,
                    expiration_timestamp: Option::None,
                }
            );

        start_prank(CheatTarget::One(pragma.contract_address), common::non_zero_address());
        let pragma_oracle = IOracleDispatcher { contract_address: pragma.contract_address };
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr, false);

        assert(fetched_eth.unwrap_err() == 'PGM: Invalid price update', 'wrong result');

        let expected_events = array![
            (
                pragma.contract_address,
                pragma_contract::Event::InvalidPriceUpdate(
                    pragma_contract::InvalidPriceUpdate {
                        yang: eth_addr, price: eth_price, pragma_last_updated_ts: now, pragma_num_sources: num_sources
                    }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);

        // now try forcing the fetch
        let fetched_eth: Result<Wad, felt252> = pragma_oracle.fetch_price(eth_addr, true);
        assert(eth_price == fetched_eth.unwrap(), 'wrong ETH price 2');
    }
}
