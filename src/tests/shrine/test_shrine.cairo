mod test_shrine {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use debug::PrintTrait;
    use integer::BoundedU256;
    use opus::core::roles::shrine_roles;
    use opus::core::shrine::shrine as shrine_contract;
    use opus::interfaces::IERC20::{
        IERC20Dispatcher, IERC20DispatcherTrait, IERC20CamelOnlyDispatcher, IERC20CamelOnlyDispatcherTrait
    };
    use opus::interfaces::ISRC5::{ISRC5Dispatcher, ISRC5DispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::{Health, Trove, YangSuspensionStatus};
    use snforge_std::{start_prank, stop_prank, start_warp, CheatTarget, spy_events, SpyOn, EventSpy, EventAssertions};
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable, contract_address_try_from_felt252};
    use starknet::get_block_timestamp;
    use wadray::{
        BoundedRay, Ray, RayZeroable, RAY_ONE, RAY_PERCENT, RAY_SCALE, SignedWad, Wad, WadZeroable, WAD_DECIMALS,
        WAD_PERCENT, WAD_ONE, WAD_SCALE
    };

    //
    // Tests - Deployment and initial setup of Shrine
    //

    // Check constructor function
    #[test]
    fn test_shrine_deploy() {
        let mut spy = spy_events(SpyOn::All);
        let shrine_addr = shrine_utils::shrine_deploy(Option::None);

        // Check ERC-20 getters
        let yin: IERC20Dispatcher = IERC20Dispatcher { contract_address: shrine_addr };
        assert(yin.name() == shrine_utils::YIN_NAME, 'wrong name');
        assert(yin.symbol() == shrine_utils::YIN_SYMBOL, 'wrong symbol');
        assert(yin.decimals() == WAD_DECIMALS, 'wrong decimals');

        // Check Shrine getters
        let shrine = shrine_utils::shrine(shrine_addr);

        assert(shrine.get_live(), 'not live');
        let (multiplier, _, _) = shrine.get_current_multiplier();
        assert(multiplier == RAY_ONE.into(), 'wrong multiplier');
        assert(shrine.get_minimum_trove_value().is_zero(), 'wrong min trove value');

        let shrine_accesscontrol: IAccessControlDispatcher = IAccessControlDispatcher { contract_address: shrine_addr };
        assert(shrine_accesscontrol.get_admin() == shrine_utils::admin(), 'wrong admin');

        let expected_events = array![
            (
                shrine_addr,
                shrine_contract::Event::MultiplierUpdated(
                    shrine_contract::MultiplierUpdated {
                        multiplier: shrine_contract::INITIAL_MULTIPLIER.into(),
                        cumulative_multiplier: shrine_contract::INITIAL_MULTIPLIER.into(),
                        interval: shrine_utils::get_interval(shrine_utils::DEPLOYMENT_TIMESTAMP) - 1,
                    }
                )
            )
        ];

        spy.assert_emitted(@expected_events);
    }

    // Checks the following functions
    // - `set_debt_ceiling`
    // - `add_yang`
    // - initial threshold and value of Shrine
    #[test]
    fn test_shrine_setup() {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine_addr));
        shrine_utils::shrine_setup(shrine_addr);

        let expected_events = array![
            // NOTE: Can't currently check events emitted in the constructor
            // (
            //     shrine_addr,
            //     shrine_contract::Event::MultiplierUpdated(
            //         shrine_contract::MultiplierUpdated {
            //             multiplier: shrine_contract::INITIAL_MULTIPLIER.into(),
            //             cumulative_multiplier: shrine_contract::INITIAL_MULTIPLIER.into(),
            //             interval: shrine_utils::get_interval(shrine_utils::DEPLOYMENT_TIMESTAMP) - 1,
            //         }
            //     )
            // ),
            (
                shrine_addr,
                shrine_contract::Event::DebtCeilingUpdated(
                    shrine_contract::DebtCeilingUpdated { ceiling: shrine_utils::DEBT_CEILING.into() }
                )
            )
        ];

        spy.assert_emitted(@expected_events);

        // Check debt ceiling and minimum trove value
        let shrine = shrine_utils::shrine(shrine_addr);
        assert(shrine.get_minimum_trove_value() == shrine_utils::MINIMUM_TROVE_VALUE.into(), 'wrong min trove value');
        assert(shrine.get_debt_ceiling() == shrine_utils::DEBT_CEILING.into(), 'wrong debt ceiling');

        // Check yangs
        assert(shrine.get_yangs_count() == 3, 'wrong yangs count');

        let expected_era: u64 = 1;

        let mut yang_addrs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        let mut start_prices: Span<Wad> = shrine_utils::three_yang_start_prices();
        let mut thresholds: Span<Ray> = array![
            shrine_utils::YANG1_THRESHOLD.into(),
            shrine_utils::YANG2_THRESHOLD.into(),
            shrine_utils::YANG3_THRESHOLD.into(),
        ]
            .span();
        let mut base_rates: Span<Ray> = array![
            shrine_utils::YANG1_BASE_RATE.into(),
            shrine_utils::YANG2_BASE_RATE.into(),
            shrine_utils::YANG3_BASE_RATE.into(),
        ]
            .span();

        let mut yang_id = 1;

        loop {
            match yang_addrs.pop_front() {
                Option::Some(yang_addr) => {
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang_addr);
                    let expected_yang_price = *start_prices.pop_front().unwrap();
                    assert(yang_price == expected_yang_price, 'wrong yang start price');

                    let (raw_threshold, _) = shrine.get_yang_threshold(*yang_addr);
                    let expected_threshold = *thresholds.pop_front().unwrap();
                    assert(raw_threshold == expected_threshold, 'wrong yang threshold');

                    let expected_rate = *base_rates.pop_front().unwrap();
                    assert(shrine.get_yang_rate(*yang_addr, expected_era) == expected_rate, 'wrong yang base rate');

                    yang_id += 1;
                },
                Option::None => { break; }
            };
        };

        // Check shrine threshold and value
        let shrine_health: Health = shrine.get_shrine_health();
        // recovery mode threshold will be zero if threshold is zero
        assert(shrine_health.threshold.is_zero(), 'wrong shrine threshold');
        assert(shrine_health.value.is_zero(), 'wrong shrine value');
        assert(shrine_health.ltv == BoundedRay::max(), 'wrong shrine LTV');
    }

    // Checks `advance` and `set_multiplier`, and their cumulative values
    #[test]
    fn test_shrine_setup_with_feed() {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        shrine_utils::shrine_setup(shrine_addr);
        let shrine: IShrineDispatcher = IShrineDispatcher { contract_address: shrine_addr };

        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        let yang_addrs = shrine_utils::three_yang_addrs();
        let yang_start_prices = shrine_utils::three_yang_start_prices();
        let yang_feeds = shrine_utils::advance_prices_and_set_multiplier(
            shrine, shrine_utils::FEED_LEN, yang_addrs, yang_start_prices,
        );

        let shrine = shrine_utils::shrine(shrine_addr);

        let mut exp_start_cumulative_prices: Array<Wad> = array![
            *yang_start_prices.at(0), *yang_start_prices.at(1), *yang_start_prices.at(2),
        ];

        let mut expected_events: Array<(ContractAddress, shrine_contract::Event)> = ArrayTrait::new();

        let start_interval: u64 = shrine_utils::get_interval(shrine_utils::DEPLOYMENT_TIMESTAMP);
        let mut yang_addrs_copy = yang_addrs;
        let mut exp_start_cumulative_prices_copy = exp_start_cumulative_prices.span();
        loop {
            match yang_addrs_copy.pop_front() {
                Option::Some(yang_addr) => {
                    // `Shrine.add_yang` sets the initial price for `current_interval - 1`
                    let (_, start_cumulative_price) = shrine.get_yang_price(*yang_addr, start_interval - 1);
                    assert(
                        start_cumulative_price == *exp_start_cumulative_prices_copy.pop_front().unwrap(),
                        'wrong start cumulative price'
                    );
                },
                Option::None => { break (); }
            };
        };

        let (_, start_cumulative_multiplier) = shrine.get_multiplier(start_interval - 1);
        assert(start_cumulative_multiplier == Ray { val: RAY_ONE }, 'wrong start cumulative mul');
        let mut expected_cumulative_multiplier = start_cumulative_multiplier;

        let yang_feed_len = (*yang_feeds.at(0)).len();
        let mut idx = 0;
        let mut expected_yang_cumulative_prices = exp_start_cumulative_prices;
        loop {
            if idx == yang_feed_len {
                break ();
            }

            let interval = start_interval + idx.into();

            let mut yang_addrs_copy = yang_addrs;
            let mut yang_idx = 0;

            // Create a copy of the current cumulative prices
            let mut expected_yang_cumulative_prices_copy = expected_yang_cumulative_prices.span();
            // Reset array to track the latest cumulative prices
            expected_yang_cumulative_prices = ArrayTrait::new();
            loop {
                match yang_addrs_copy.pop_front() {
                    Option::Some(yang_addr) => {
                        let (price, cumulative_price) = shrine.get_yang_price(*yang_addr, interval);
                        let expected_price = *yang_feeds.at(yang_idx)[idx];
                        assert(price == expected_price, 'wrong price in feed');

                        let prev_cumulative_price = *expected_yang_cumulative_prices_copy.at(yang_idx);
                        let expected_cumulative_price = prev_cumulative_price + price;

                        expected_yang_cumulative_prices.append(expected_cumulative_price);
                        assert(cumulative_price == expected_cumulative_price, 'wrong cumulative price in feed');

                        expected_events
                            .append(
                                (
                                    shrine.contract_address,
                                    shrine_contract::Event::YangPriceUpdated(
                                        shrine_contract::YangPriceUpdated {
                                            yang: *yang_addr,
                                            price: expected_price,
                                            cumulative_price: expected_cumulative_price,
                                            interval
                                        }
                                    ),
                                ),
                            );

                        yang_idx += 1;
                    },
                    Option::None => { break; },
                };
            };

            expected_cumulative_multiplier += RAY_ONE.into();
            let (multiplier, cumulative_multiplier) = shrine.get_multiplier(interval);
            assert(multiplier == Ray { val: RAY_ONE }, 'wrong multiplier in feed');
            assert(cumulative_multiplier == expected_cumulative_multiplier, 'wrong cumulative mul in feed');

            expected_events
                .append(
                    (
                        shrine.contract_address,
                        shrine_contract::Event::MultiplierUpdated(
                            shrine_contract::MultiplierUpdated {
                                multiplier: RAY_ONE.into(),
                                cumulative_multiplier: expected_cumulative_multiplier,
                                interval
                            }
                        ),
                    ),
                );
            idx += 1;
        };
        spy.assert_emitted(@expected_events);
    }

    //
    // Tests - Trove parameters
    //

    #[test]
    fn test_set_trove_minimum_value() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        let new_value: Wad = (100 * WAD_ONE).into();
        shrine.set_minimum_trove_value(new_value);
        assert(shrine.get_minimum_trove_value() == new_value, 'wrong min trove value');
        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::MinimumTroveValueUpdated(
                    shrine_contract::MinimumTroveValueUpdated { value: new_value }
                )
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_trove_minimum_value_unauthorized() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_prank(CheatTarget::One(shrine.contract_address), common::badguy());
        let new_value: Wad = (100 * WAD_ONE).into();
        shrine.set_minimum_trove_value(new_value);
    }

    //
    // Tests - Yang onboarding and parameters
    //

    #[test]
    fn test_add_yang() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        let admin = shrine_utils::admin();
        start_prank(CheatTarget::One(shrine.contract_address), admin);

        let current_rate_era: u64 = shrine.get_current_rate_era();
        let yangs_count: u32 = shrine.get_yangs_count();
        assert(yangs_count == 3, 'incorrect yangs count');

        let new_yang_address: ContractAddress = contract_address_try_from_felt252('new yang').unwrap();
        let new_yang_threshold: Ray = 600000000000000000000000000_u128.into(); // 60% (Ray)
        let new_yang_start_price: Wad = 5000000000000000000_u128.into(); // 5 (Wad)
        let new_yang_rate: Ray = 60000000000000000000000000_u128.into(); // 6% (Ray)

        shrine.add_yang(new_yang_address, new_yang_threshold, new_yang_start_price, new_yang_rate, WadZeroable::zero());

        let expected_yangs_count: u32 = yangs_count + 1;
        assert(shrine.get_yangs_count() == expected_yangs_count, 'incorrect yangs count');
        assert(shrine.get_yang_total(new_yang_address).is_zero(), 'incorrect yang total');

        let (current_yang_price, _, _) = shrine.get_current_yang_price(new_yang_address);
        assert(current_yang_price == new_yang_start_price, 'incorrect yang price');
        let (raw_threshold, _) = shrine.get_yang_threshold(new_yang_address);
        assert(raw_threshold == new_yang_threshold, 'incorrect yang threshold');

        assert(shrine.get_yang_rate(new_yang_address, current_rate_era) == new_yang_rate, 'incorrect yang rate');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::ThresholdUpdated(
                    shrine_contract::ThresholdUpdated { yang: new_yang_address, threshold: new_yang_threshold }
                )
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::YangAdded(
                    shrine_contract::YangAdded {
                        yang: new_yang_address,
                        yang_id: expected_yangs_count,
                        start_price: new_yang_start_price,
                        initial_rate: new_yang_rate
                    }
                )
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::YangTotalUpdated(
                    shrine_contract::YangTotalUpdated { yang: new_yang_address, total: WadZeroable::zero() }
                )
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('SH: Yang already exists',))]
    fn test_add_yang_duplicate_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine
            .add_yang(
                shrine_utils::yang1_addr(),
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                WadZeroable::zero()
            );
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_add_yang_unauthorized() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_prank(CheatTarget::All, common::badguy());
        shrine
            .add_yang(
                shrine_utils::yang1_addr(),
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                WadZeroable::zero()
            );
    }

    #[test]
    fn test_set_threshold() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        let yang1_addr = shrine_utils::yang1_addr();
        let new_threshold: Ray = 900000000000000000000000000_u128.into();

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.set_threshold(yang1_addr, new_threshold);
        let (raw_threshold, _) = shrine.get_yang_threshold(yang1_addr);
        assert(raw_threshold == new_threshold, 'threshold not updated');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::ThresholdUpdated(
                    shrine_contract::ThresholdUpdated { yang: yang1_addr, threshold: new_threshold }
                )
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('SH: Threshold > max',))]
    fn test_set_threshold_exceeds_max() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let invalid_threshold: Ray = (RAY_SCALE + 1).into();

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.set_threshold(shrine_utils::yang1_addr(), invalid_threshold);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_threshold_unauthorized() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let new_threshold: Ray = 900000000000000000000000000_u128.into();

        start_prank(CheatTarget::All, common::badguy());
        shrine.set_threshold(shrine_utils::yang1_addr(), new_threshold);
    }

    #[test]
    #[should_panic(expected: ('SH: Yang does not exist',))]
    fn test_set_threshold_invalid_yang() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.set_threshold(shrine_utils::invalid_yang_addr(), shrine_utils::YANG1_THRESHOLD.into());
    }

    #[test]
    fn test_update_rates_pass() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_prank(CheatTarget::All, shrine_utils::admin());

        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        shrine
            .update_rates(
                yangs,
                array![
                    shrine_contract::USE_PREV_BASE_RATE.into(),
                    shrine_contract::USE_PREV_BASE_RATE.into(),
                    RAY_ONE.into(),
                ]
                    .span()
            );

        let expected_rate_era: u64 = 2;
        assert(shrine.get_current_rate_era() == expected_rate_era, 'wrong rate era');

        let mut expected_rates: Span<Ray> = array![
            shrine_utils::YANG1_BASE_RATE.into(), shrine_utils::YANG2_BASE_RATE.into(), RAY_ONE.into()
        ]
            .span();

        let mut yangs_copy = yangs;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    let expected_rate = *expected_rates.pop_front().unwrap();
                    assert(shrine.get_yang_rate(*yang, expected_rate_era) == expected_rate, 'wrong rate');
                },
                Option::None => { break; }
            };
        };
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_update_rates_unauthorized() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_prank(CheatTarget::All, common::badguy());
        shrine
            .update_rates(
                shrine_utils::three_yang_addrs(),
                array![
                    shrine_contract::USE_PREV_BASE_RATE.into(),
                    shrine_contract::USE_PREV_BASE_RATE.into(),
                    shrine_contract::USE_PREV_BASE_RATE.into(),
                ]
                    .span()
            );
    }

    #[test]
    #[should_panic(expected: ('SH: Rate out of bounds',))]
    fn test_update_rates_exceed_max_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine
            .update_rates(
                shrine_utils::three_yang_addrs(),
                array![
                    shrine_contract::USE_PREV_BASE_RATE.into(),
                    shrine_contract::USE_PREV_BASE_RATE.into(),
                    (RAY_ONE + 2).into(),
                ]
                    .span()
            );
    }

    #[test]
    #[should_panic(expected: ('SH: yangs.len != new_rates.len',))]
    fn test_update_rates_array_length_mismatch() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine
            .update_rates(
                shrine_utils::three_yang_addrs(),
                array![shrine_contract::USE_PREV_BASE_RATE.into(), shrine_contract::USE_PREV_BASE_RATE.into(),].span()
            );
    }

    #[test]
    #[should_panic(expected: ('SH: Too few yangs',))]
    fn test_update_rates_too_few_yangs() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine
            .update_rates(
                shrine_utils::two_yang_addrs_reversed(),
                array![shrine_contract::USE_PREV_BASE_RATE.into(), shrine_contract::USE_PREV_BASE_RATE.into(),].span()
            );
    }

    #[test]
    #[should_panic(expected: ('SH: Yang does not exist',))]
    fn test_update_rates_invalid_yangs() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine
            .update_rates(
                array![shrine_utils::yang1_addr(), shrine_utils::yang2_addr(), shrine_utils::invalid_yang_addr(),]
                    .span(),
                array![
                    shrine_contract::USE_PREV_BASE_RATE.into(),
                    shrine_contract::USE_PREV_BASE_RATE.into(),
                    shrine_contract::USE_PREV_BASE_RATE.into(),
                ]
                    .span()
            );
    }

    #[test]
    #[should_panic(expected: ('SH: Incorrect rate update',))]
    fn test_update_rates_not_all_yangs() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine
            .update_rates(
                array![shrine_utils::yang1_addr(), shrine_utils::yang2_addr(), shrine_utils::yang1_addr(),].span(),
                array![
                    shrine_contract::USE_PREV_BASE_RATE.into(),
                    shrine_contract::USE_PREV_BASE_RATE.into(),
                    21000000000000000000000000_u128.into(), // 2.1% (Ray)
                ]
                    .span()
            );
    }

    //
    // Tests - Shrine kill
    //

    #[test]
    fn test_kill() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        assert(shrine.get_live(), 'should be live');

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        let forge_amt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine_utils::trove1_forge(shrine, forge_amt);

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.kill();

        // Check eject pass
        shrine.eject(common::trove1_owner_addr(), 1_u128.into());

        assert(!shrine.get_live(), 'should not be live');

        let expected_events: Span<shrine_contract::Event> = array![
            shrine_contract::Event::Killed(shrine_contract::Killed {}),
        ]
            .span();

        let expected_events = array![
            (shrine.contract_address, shrine_contract::Event::Killed(shrine_contract::Killed {}))
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('SH: System is not live',))]
    fn test_killed_deposit_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        assert(shrine.get_live(), 'should be live');

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.kill();
        assert(!shrine.get_live(), 'should not be live');

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
    }

    #[test]
    #[should_panic(expected: ('SH: System is not live',))]
    fn test_killed_withdraw_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        assert(shrine.get_live(), 'should be live');
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.kill();
        assert(!shrine.get_live(), 'should not be live');

        shrine_utils::trove1_withdraw(shrine, 1_u128.into());
    }

    #[test]
    #[should_panic(expected: ('SH: System is not live',))]
    fn test_killed_forge_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        assert(shrine.get_live(), 'should be live');
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.kill();
        assert(!shrine.get_live(), 'should not be live');

        let forge_amt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine_utils::trove1_forge(shrine, forge_amt);
    }

    #[test]
    #[should_panic(expected: ('SH: System is not live',))]
    fn test_killed_melt_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        assert(shrine.get_live(), 'should be live');
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, shrine_utils::TROVE1_FORGE_AMT.into());

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.kill();
        assert(!shrine.get_live(), 'should not be live');

        shrine_utils::trove1_melt(shrine, 1_u128.into());
    }

    #[test]
    #[should_panic(expected: ('SH: System is not live',))]
    fn test_killed_inject_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        assert(shrine.get_live(), 'should be live');

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.kill();
        assert(!shrine.get_live(), 'should not be live');

        shrine.inject(shrine_utils::admin(), 1_u128.into());
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_kill_unauthorized() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        assert(shrine.get_live(), 'should be live');

        start_prank(CheatTarget::All, common::badguy());
        shrine.kill();
    }

    //
    // Tests - trove deposit
    //

    #[test]
    fn test_shrine_deposit_pass() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        let deposit_amt: Wad = shrine_utils::TROVE1_YANG1_DEPOSIT.into();
        shrine_utils::trove1_deposit(shrine, deposit_amt);

        let trove_id = common::TROVE_1;
        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        let yang = *yangs.at(0);

        assert(shrine.get_yang_total(yang) == shrine_utils::TROVE1_YANG1_DEPOSIT.into(), 'incorrect yang total');
        assert(
            shrine.get_deposit(yang, trove_id) == shrine_utils::TROVE1_YANG1_DEPOSIT.into(), 'incorrect yang deposit'
        );

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang);
        let max_forge_amt: Wad = shrine.get_max_forge(trove_id);

        let mut yang_prices: Array<Wad> = array![yang1_price];
        let mut yang_amts: Array<Wad> = array![shrine_utils::TROVE1_YANG1_DEPOSIT.into()];
        let mut yang_thresholds: Array<Ray> = array![shrine_utils::YANG1_THRESHOLD.into()];

        let expected_max_forge: Wad = shrine_utils::calculate_max_forge(
            yang_prices.span(), yang_amts.span(), yang_thresholds.span()
        );
        assert(max_forge_amt == expected_max_forge, 'incorrect max forge amt');

        shrine_utils::assert_total_yang_invariant(shrine, yangs, 1);

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TroveUpdated(
                    shrine_contract::TroveUpdated {
                        trove_id: trove_id,
                        trove: Trove {
                            charge_from: shrine_utils::current_interval(), debt: WadZeroable::zero(), last_rate_era: 1
                        },
                    }
                )
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::YangTotalUpdated(
                    shrine_contract::YangTotalUpdated { yang, total: deposit_amt, }
                )
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::DepositUpdated(
                    shrine_contract::DepositUpdated { yang, trove_id, amount: deposit_amt, }
                )
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('SH: Yang does not exist',))]
    fn test_shrine_deposit_invalid_yang_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_prank(CheatTarget::All, shrine_utils::admin());

        shrine.deposit(shrine_utils::invalid_yang_addr(), common::TROVE_1, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_shrine_deposit_unauthorized() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_prank(CheatTarget::All, common::badguy());

        shrine.deposit(shrine_utils::yang1_addr(), common::TROVE_1, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
    }

    //
    // Tests - Trove withdraw
    //

    #[test]
    fn test_shrine_withdraw_pass() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        start_prank(CheatTarget::All, shrine_utils::admin());

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        let withdraw_amt: Wad = (shrine_utils::TROVE1_YANG1_DEPOSIT / 3).into();
        shrine_utils::trove1_withdraw(shrine, withdraw_amt);

        let trove_id: u64 = common::TROVE_1;
        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        let yang1_addr = *yangs.at(0);
        let remaining_amt: Wad = shrine_utils::TROVE1_YANG1_DEPOSIT.into() - withdraw_amt;
        assert(shrine.get_yang_total(yang1_addr) == remaining_amt, 'incorrect yang total');
        assert(shrine.get_deposit(yang1_addr, trove_id) == remaining_amt, 'incorrect yang deposit');

        let trove_health: Health = shrine.get_trove_health(trove_id);
        assert(trove_health.ltv.is_zero(), 'LTV should be zero');

        assert(shrine.is_healthy(trove_id), 'trove should be healthy');

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let max_forge_amt: Wad = shrine.get_max_forge(trove_id);

        let mut yang_prices: Array<Wad> = array![yang1_price];
        let mut yang_amts: Array<Wad> = array![remaining_amt];
        let mut yang_thresholds: Array<Ray> = array![shrine_utils::YANG1_THRESHOLD.into()];

        let expected_max_forge: Wad = shrine_utils::calculate_max_forge(
            yang_prices.span(), yang_amts.span(), yang_thresholds.span()
        );
        assert(max_forge_amt == expected_max_forge, 'incorrect max forge amt');

        shrine_utils::assert_total_yang_invariant(shrine, yangs, 1);

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TroveUpdated(
                    shrine_contract::TroveUpdated {
                        trove_id: trove_id,
                        trove: Trove {
                            charge_from: shrine_utils::current_interval(), debt: WadZeroable::zero(), last_rate_era: 1
                        },
                    }
                )
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::YangTotalUpdated(
                    shrine_contract::YangTotalUpdated { yang: yang1_addr, total: remaining_amt }
                )
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::DepositUpdated(
                    shrine_contract::DepositUpdated { yang: yang1_addr, trove_id, amount: remaining_amt }
                )
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_shrine_forged_partial_withdraw_pass() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, shrine_utils::TROVE1_FORGE_AMT.into());

        start_prank(CheatTarget::All, shrine_utils::admin());
        let withdraw_amt: Wad = (shrine_utils::TROVE1_YANG1_DEPOSIT / 3).into();
        shrine_utils::trove1_withdraw(shrine, withdraw_amt);

        let yang1_addr = shrine_utils::yang1_addr();
        let remaining_amt: Wad = shrine_utils::TROVE1_YANG1_DEPOSIT.into() - withdraw_amt;
        assert(shrine.get_yang_total(yang1_addr) == remaining_amt, 'incorrect yang total');
        assert(shrine.get_deposit(yang1_addr, common::TROVE_1) == remaining_amt, 'incorrect yang deposit');

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let expected_ltv: Ray = wadray::rdiv_ww(shrine_utils::TROVE1_FORGE_AMT.into(), (yang1_price * remaining_amt));
        let trove_health: Health = shrine.get_trove_health(common::TROVE_1);
        assert(trove_health.ltv == expected_ltv, 'incorrect LTV');
    }

    #[test]
    #[should_panic(expected: ('SH: Below minimum trove value',))]
    fn test_shrine_withdraw_trove_below_min_value_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        // Deposit 1 ETH and forge the smallest unit of debt
        shrine_utils::trove1_deposit(shrine, WAD_ONE.into());
        shrine_utils::trove1_forge(shrine, 1_u128.into());
        let trove_id: u64 = common::TROVE_1;

        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());

        // Set ETH's price to exactly the minimum trove value
        let eth: ContractAddress = shrine_utils::yang1_addr();
        shrine.advance(eth, shrine_utils::MINIMUM_TROVE_VALUE.into());

        // Withdraw the smallest unit of ETH yang
        shrine.withdraw(eth, trove_id, 1_u128.into());
    }

    #[test]
    #[should_panic(expected: ('SH: Yang does not exist',))]
    fn test_shrine_withdraw_invalid_yang_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_prank(CheatTarget::All, shrine_utils::admin());

        shrine.withdraw(shrine_utils::invalid_yang_addr(), common::TROVE_1, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_shrine_withdraw_unauthorized() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());

        start_prank(CheatTarget::All, common::badguy());

        shrine.withdraw(shrine_utils::yang1_addr(), common::TROVE_1, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
    }

    #[test]
    #[should_panic(expected: ('SH: Insufficient yang balance',))]
    fn test_shrine_withdraw_insufficient_yang_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());

        start_prank(CheatTarget::All, shrine_utils::admin());

        shrine.withdraw(shrine_utils::yang1_addr(), common::TROVE_1, (shrine_utils::TROVE1_YANG1_DEPOSIT + 1).into());
    }

    #[test]
    #[should_panic(expected: ('SH: Insufficient yang balance',))]
    fn test_shrine_withdraw_zero_yang_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        start_prank(CheatTarget::All, shrine_utils::admin());

        shrine.withdraw(shrine_utils::yang2_addr(), common::TROVE_1, (shrine_utils::TROVE1_YANG1_DEPOSIT + 1).into());
    }

    #[test]
    #[should_panic(expected: ('SH: Trove LTV is too high',))]
    fn test_shrine_withdraw_unsafe_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, shrine_utils::TROVE1_FORGE_AMT.into());

        let trove_health: Health = shrine.get_trove_health(common::TROVE_1);
        let (yang1_price, _, _) = shrine.get_current_yang_price(shrine_utils::yang1_addr());

        // Value of trove needed for existing forged amount to be safe
        let unsafe_trove_value: Wad = wadray::rdiv_wr(shrine_utils::TROVE1_FORGE_AMT.into(), trove_health.threshold);
        // Amount of yang to be withdrawn to decrease the trove's value to unsafe
        // `WAD_SCALE` is added to account for loss of precision from fixed point division
        let unsafe_withdraw_yang_amt: Wad = (trove_health.value - unsafe_trove_value) / yang1_price + WAD_SCALE.into();
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.withdraw(shrine_utils::yang1_addr(), common::TROVE_1, unsafe_withdraw_yang_amt);
    }

    //
    // Tests - Trove forge
    //

    #[test]
    fn test_shrine_forge_pass() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());

        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        let yang1_addr: ContractAddress = *yangs.at(0);

        let forge_amt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();

        let trove_id: u64 = common::TROVE_1;
        let before_max_forge_amt: Wad = shrine.get_max_forge(trove_id);
        shrine_utils::trove1_forge(shrine, forge_amt);

        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.debt == forge_amt, 'incorrect system debt');

        let trove_health: Health = shrine.get_trove_health(trove_id);
        assert(trove_health.debt == forge_amt, 'incorrect trove debt');

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let expected_value: Wad = yang1_price * shrine_utils::TROVE1_YANG1_DEPOSIT.into();
        let expected_ltv: Ray = wadray::rdiv_ww(forge_amt, expected_value);
        assert(trove_health.ltv == expected_ltv, 'incorrect ltv');

        assert(shrine.is_healthy(trove_id), 'trove should be healthy');

        let after_max_forge_amt: Wad = shrine.get_max_forge(trove_id);
        assert(after_max_forge_amt == before_max_forge_amt - forge_amt, 'incorrect max forge amt');

        let yin = shrine_utils::yin(shrine.contract_address);
        let trove1_owner_addr: ContractAddress = common::trove1_owner_addr();
        assert(yin.balance_of(trove1_owner_addr) == forge_amt.into(), 'incorrect ERC-20 balance');
        assert(yin.total_supply() == forge_amt.into(), 'incorrect ERC-20 balance');

        shrine_utils::assert_total_troves_debt_invariant(shrine, yangs, 1);

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TotalTrovesDebtUpdated(
                    shrine_contract::TotalTrovesDebtUpdated { total: forge_amt }
                )
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::TroveUpdated(
                    shrine_contract::TroveUpdated {
                        trove_id,
                        trove: Trove {
                            charge_from: shrine_utils::current_interval(), debt: forge_amt, last_rate_era: 1
                        },
                    }
                )
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::Transfer(
                    shrine_contract::Transfer {
                        from: ContractAddressZeroable::zero(), to: trove1_owner_addr, value: forge_amt.into(),
                    }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('SH: Below minimum trove value',))]
    fn test_shrine_forge_trove_below_min_value_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        // Deposit 1 ETH
        shrine_utils::trove1_deposit(shrine, WAD_ONE.into());

        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());

        // Set ETH's price to just below the minimum trove value
        let eth: ContractAddress = shrine_utils::yang1_addr();
        shrine.advance(eth, (shrine_utils::MINIMUM_TROVE_VALUE - 1).into());

        shrine_utils::trove1_forge(shrine, 1_u128.into());
    }

    #[test]
    #[should_panic(expected: ('SH: Trove LTV is too high',))]
    fn test_shrine_forge_zero_deposit_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        shrine.forge(shrine_utils::common::trove3_owner_addr(), common::TROVE_3, 1_u128.into(), WadZeroable::zero());
    }

    #[test]
    #[should_panic(expected: ('SH: Trove LTV is too high',))]
    fn test_shrine_forge_unsafe_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());

        // prevent recovery mode
        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());

        shrine.deposit(shrine_utils::yang1_addr(), common::TROVE_2, shrine_utils::WHALE_TROVE_YANG1_DEPOSIT.into());
        assert(!shrine.is_recovery_mode(), 'recovery mode');

        let max_forge_amt: Wad = shrine.get_max_forge(common::TROVE_1);
        let unsafe_forge_amt: Wad = (max_forge_amt.val + 1).into();

        shrine.forge(common::trove1_owner_addr(), common::TROVE_1, unsafe_forge_amt, WadZeroable::zero());
    }

    #[test]
    #[should_panic(expected: ('SH: Debt ceiling reached',))]
    fn test_shrine_forge_ceiling_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());

        start_prank(CheatTarget::All, shrine_utils::admin());

        // deposit more collateral
        let additional_yang1_amt: Wad = (shrine_utils::TROVE1_YANG1_DEPOSIT * 10).into();
        shrine.deposit(shrine_utils::yang1_addr(), common::TROVE_1, additional_yang1_amt);

        let unsafe_amt: Wad = (shrine_utils::TROVE1_FORGE_AMT * 10).into();
        shrine.forge(common::trove1_owner_addr(), common::TROVE_1, unsafe_amt, WadZeroable::zero());
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_shrine_forge_unauthorized() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());

        start_prank(CheatTarget::All, common::badguy());

        shrine
            .forge(
                common::trove1_owner_addr(),
                common::TROVE_1,
                shrine_utils::TROVE1_FORGE_AMT.into(),
                WadZeroable::zero(),
            );
    }

    // TODO: assert event is not emitted once Starknet Foundry adds support
    #[test]
    #[should_panic]
    fn test_shrine_forge_no_forgefee_emitted_when_zero() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());

        let forge_amt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        let trove_id: u64 = common::TROVE_1;
        shrine_utils::trove1_forge(shrine, forge_amt);

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::ForgeFeePaid(
                    shrine_contract::ForgeFeePaid { trove_id, fee: WadZeroable::zero(), fee_pct: WadZeroable::zero(), }
                )
            )
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_shrine_forge_nonzero_forge_fee() {
        let yin_price1: Wad = 980000000000000000_u128.into(); // 0.98 (wad)
        let yin_price2: Wad = 985000000000000000_u128.into(); // 0.985 (wad)
        let forge_amt: Wad = 100000000000000000000_u128.into(); // 100 (wad)
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        let trove_id: u64 = common::TROVE_1;
        let trove1_owner: ContractAddress = common::trove1_owner_addr();

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());

        start_prank(CheatTarget::All, shrine_utils::admin());

        let before_max_forge_amt: Wad = shrine.get_max_forge(trove_id);
        shrine.update_yin_spot_price(yin_price1);
        let after_max_forge_amt: Wad = shrine.get_max_forge(trove_id);

        let fee_pct: Wad = shrine.get_forge_fee_pct();

        assert(after_max_forge_amt == before_max_forge_amt / (WAD_ONE.into() + fee_pct), 'incorrect max forge amt');

        let before_budget: SignedWad = shrine.get_budget();

        shrine.forge(trove1_owner, trove_id, forge_amt, fee_pct);

        let trove_health: Health = shrine.get_trove_health(common::TROVE_1);
        let fee = trove_health.debt - forge_amt;
        assert(trove_health.debt - forge_amt == fee_pct * forge_amt, 'wrong forge fee charged #1');

        let intermediate_budget: SignedWad = shrine.get_budget();
        assert(intermediate_budget == before_budget + fee.into(), 'wrong budget #1');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::ForgeFeePaid(shrine_contract::ForgeFeePaid { trove_id, fee, fee_pct })
            )
        ];
        spy.assert_emitted(@expected_events);

        shrine.update_yin_spot_price(yin_price2);
        let fee_pct: Wad = shrine.get_forge_fee_pct();
        shrine.forge(trove1_owner, trove_id, forge_amt, fee_pct);

        let new_trove_health: Health = shrine.get_trove_health(common::TROVE_1);
        let fee = new_trove_health.debt - trove_health.debt - forge_amt;
        assert(
            new_trove_health.debt - trove_health.debt - forge_amt == fee_pct * forge_amt, 'wrong forge fee charged #2'
        );
        assert(shrine.get_budget() == intermediate_budget + fee.into(), 'wrong budget #2');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::ForgeFeePaid(shrine_contract::ForgeFeePaid { trove_id, fee, fee_pct })
            )
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('SH: forge_fee% > max_forge_fee%',))]
    fn test_shrine_forge_fee_exceeds_max() {
        let yin_price1: Wad = 985000000000000000_u128.into(); // 0.985 (wad)
        let yin_price2: Wad = 970000000000000000_u128.into(); // 0.985 (wad)
        let trove1_owner: ContractAddress = common::trove1_owner_addr();

        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        start_prank(CheatTarget::All, shrine_utils::admin());

        shrine.update_yin_spot_price(yin_price1);
        // Front end fetches the forge fee for the user
        let stale_fee_pct: Wad = shrine.get_forge_fee_pct();

        // Oops! Whale dumps and yin price suddenly drops, causing the forge fee to increase
        shrine.update_yin_spot_price(yin_price2);

        // Should revert since the forge fee exceeds the maximum set by the frontend
        shrine.forge(trove1_owner, common::TROVE_1, shrine_utils::TROVE1_FORGE_AMT.into(), stale_fee_pct);
    }

    //
    // Tests - Trove melt
    //

    #[test]
    fn test_shrine_melt_pass() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        let deposit_amt: Wad = shrine_utils::TROVE1_YANG1_DEPOSIT.into();
        shrine_utils::trove1_deposit(shrine, deposit_amt);

        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs();
        let yang1_addr: ContractAddress = *yangs.at(0);

        let forge_amt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine_utils::trove1_forge(shrine, forge_amt);

        let yin = shrine_utils::yin(shrine.contract_address);
        let trove_id: u64 = common::TROVE_1;
        let trove1_owner_addr = common::trove1_owner_addr();

        let shrine_health: Health = shrine.get_shrine_health();
        let before_total_debt: Wad = shrine_health.debt;
        let before_trove_health: Health = shrine.get_trove_health(trove_id);
        let before_yin_bal: u256 = yin.balance_of(trove1_owner_addr);
        let before_max_forge_amt: Wad = shrine.get_max_forge(trove_id);
        let melt_amt: Wad = (shrine_utils::TROVE1_YANG1_DEPOSIT / 3_u128).into();

        let outstanding_amt: Wad = forge_amt - melt_amt;
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.melt(trove1_owner_addr, trove_id, melt_amt);

        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.debt == before_total_debt - melt_amt, 'incorrect total debt');

        let after_trove_health: Health = shrine.get_trove_health(trove_id);
        assert(after_trove_health.debt == before_trove_health.debt - melt_amt, 'incorrect trove debt');

        let after_yin_bal: u256 = yin.balance_of(trove1_owner_addr);
        assert(after_yin_bal == before_yin_bal - melt_amt.into(), 'incorrect yin balance');

        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let expected_ltv: Ray = wadray::rdiv_ww(outstanding_amt, (yang1_price * deposit_amt));
        assert(after_trove_health.ltv == expected_ltv, 'incorrect LTV');

        assert(shrine.is_healthy(trove_id), 'trove should be healthy');

        let after_max_forge_amt: Wad = shrine.get_max_forge(trove_id);
        assert(after_max_forge_amt == before_max_forge_amt + melt_amt, 'incorrect max forge amount');

        shrine_utils::assert_total_troves_debt_invariant(shrine, yangs, 1);

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TotalTrovesDebtUpdated(
                    shrine_contract::TotalTrovesDebtUpdated { total: after_trove_health.debt }
                )
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::TroveUpdated(
                    shrine_contract::TroveUpdated {
                        trove_id,
                        trove: Trove {
                            charge_from: shrine_utils::current_interval(),
                            debt: after_trove_health.debt,
                            last_rate_era: 1
                        },
                    }
                )
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::Transfer(
                    shrine_contract::Transfer {
                        from: trove1_owner_addr, to: ContractAddressZeroable::zero(), value: melt_amt.into(),
                    }
                )
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_shrine_melt_unauthorized() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());

        start_prank(CheatTarget::All, common::badguy());
        shrine.melt(common::trove1_owner_addr(), common::TROVE_1, 1_u128.into());
    }

    #[test]
    #[should_panic(expected: ('SH: Insufficient yin balance',))]
    fn test_shrine_melt_insufficient_yin() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, shrine_utils::TROVE1_FORGE_AMT.into());

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.melt(common::trove2_owner_addr(), common::TROVE_1, 1_u128.into());
    }

    //
    // Tests - Yin transfers
    //

    #[test]
    fn test_yin_transfer_pass() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, shrine_utils::TROVE1_FORGE_AMT.into());

        let yin = shrine_utils::yin(shrine.contract_address);
        let yin_user: ContractAddress = shrine_utils::yin_user_addr();
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        start_prank(CheatTarget::All, trove1_owner);

        let success: bool = yin.transfer(yin_user, shrine_utils::TROVE1_FORGE_AMT.into());

        yin.transfer(yin_user, 0);
        assert(success, 'yin transfer fail');
        assert(yin.balance_of(trove1_owner).is_zero(), 'wrong transferor balance');
        assert(yin.balance_of(yin_user) == shrine_utils::TROVE1_FORGE_AMT.into(), 'wrong transferee balance');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::Transfer(
                    shrine_contract::Transfer {
                        from: trove1_owner, to: yin_user, value: shrine_utils::TROVE1_FORGE_AMT.into(),
                    }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('SH: Insufficient yin balance',))]
    fn test_yin_transfer_fail_insufficient() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, shrine_utils::TROVE1_FORGE_AMT.into());

        let yin = shrine_utils::yin(shrine.contract_address);
        let yin_user: ContractAddress = shrine_utils::yin_user_addr();
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        start_prank(CheatTarget::All, trove1_owner);

        yin.transfer(yin_user, (shrine_utils::TROVE1_FORGE_AMT + 1).into());
    }

    #[test]
    #[should_panic(expected: ('SH: Insufficient yin balance',))]
    fn test_yin_transfer_fail_zero_bal() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        let yin = shrine_utils::yin(shrine.contract_address);
        let yin_user: ContractAddress = shrine_utils::yin_user_addr();
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        start_prank(CheatTarget::All, trove1_owner);

        yin.transfer(yin_user, 1_u256);
    }

    #[test]
    fn test_yin_transfer_from_pass() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, shrine_utils::TROVE1_FORGE_AMT.into());

        let yin = shrine_utils::yin(shrine.contract_address);
        let yin_user: ContractAddress = shrine_utils::yin_user_addr();

        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        let transfer_amt: u256 = shrine_utils::TROVE1_FORGE_AMT.into();
        start_prank(CheatTarget::All, trove1_owner);
        yin.approve(yin_user, transfer_amt);

        start_prank(CheatTarget::All, yin_user);
        let success: bool = yin.transfer_from(trove1_owner, yin_user, transfer_amt);

        assert(success, 'yin transfer fail');

        assert(yin.balance_of(trove1_owner).is_zero(), 'wrong transferor balance');
        assert(yin.balance_of(yin_user) == transfer_amt, 'wrong transferee balance');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::Approval(
                    shrine_contract::Approval { owner: trove1_owner, spender: yin_user, value: transfer_amt, }
                )
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::Transfer(
                    shrine_contract::Transfer { from: trove1_owner, to: yin_user, value: transfer_amt, }
                )
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_yin_camelCase_support() {
        // same test as test_yin_transfer_from_pass above,
        // but uses balanceOf, transferFrom and adds a call to totalSupply

        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, shrine_utils::TROVE1_FORGE_AMT.into());

        let yin = shrine_utils::yin(shrine.contract_address);
        let camel_yin = IERC20CamelOnlyDispatcher { contract_address: yin.contract_address };
        let yin_user: ContractAddress = shrine_utils::yin_user_addr();

        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        let transfer_amt: u256 = shrine_utils::TROVE1_FORGE_AMT.into();
        start_prank(CheatTarget::All, trove1_owner);
        yin.approve(yin_user, transfer_amt);

        assert(yin.total_supply() == camel_yin.totalSupply(), 'wrong total supply');

        start_prank(CheatTarget::All, yin_user);
        let success: bool = camel_yin.transferFrom(trove1_owner, yin_user, transfer_amt);

        assert(success, 'yin transfer fail');

        assert(camel_yin.balanceOf(trove1_owner).is_zero(), 'wrong transferor balance');
        assert(camel_yin.balanceOf(yin_user) == transfer_amt, 'wrong transferee balance');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::Approval(
                    shrine_contract::Approval { owner: trove1_owner, spender: yin_user, value: transfer_amt, }
                )
            ),
            (
                shrine.contract_address,
                shrine_contract::Event::Transfer(
                    shrine_contract::Transfer { from: trove1_owner, to: yin_user, value: transfer_amt, }
                )
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('SH: Insufficient yin allowance',))]
    fn test_yin_transfer_from_unapproved_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine_utils::trove1_forge(shrine, shrine_utils::TROVE1_FORGE_AMT.into());

        let yin = shrine_utils::yin(shrine.contract_address);
        let yin_user: ContractAddress = shrine_utils::yin_user_addr();
        start_prank(CheatTarget::All, yin_user);
        yin.transfer_from(common::trove1_owner_addr(), yin_user, 1_u256);
    }

    #[test]
    #[should_panic(expected: ('SH: Insufficient yin allowance',))]
    fn test_yin_transfer_from_insufficient_allowance_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.forge(trove1_owner, common::TROVE_1, shrine_utils::TROVE1_FORGE_AMT.into(), WadZeroable::zero());

        let yin = shrine_utils::yin(shrine.contract_address);
        let yin_user: ContractAddress = shrine_utils::yin_user_addr();

        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        start_prank(CheatTarget::All, trove1_owner);
        let approve_amt: u256 = (shrine_utils::TROVE1_FORGE_AMT / 2).into();
        yin.approve(yin_user, approve_amt);

        start_prank(CheatTarget::All, yin_user);
        yin.transfer_from(trove1_owner, yin_user, approve_amt + 1_u256);
    }

    #[test]
    #[should_panic(expected: ('SH: Insufficient yin balance',))]
    fn test_yin_transfer_from_insufficient_balance_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.forge(trove1_owner, common::TROVE_1, shrine_utils::TROVE1_FORGE_AMT.into(), WadZeroable::zero());

        let yin = shrine_utils::yin(shrine.contract_address);
        let yin_user: ContractAddress = shrine_utils::yin_user_addr();

        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        start_prank(CheatTarget::All, trove1_owner);
        yin.approve(yin_user, BoundedU256::max());

        start_prank(CheatTarget::All, yin_user);
        yin.transfer_from(trove1_owner, yin_user, (shrine_utils::TROVE1_FORGE_AMT + 1).into());
    }

    #[test]
    #[should_panic(expected: ('SH: No transfer to 0 address',))]
    fn test_yin_transfer_zero_address_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.forge(trove1_owner, common::TROVE_1, shrine_utils::TROVE1_FORGE_AMT.into(), WadZeroable::zero());

        let yin = shrine_utils::yin(shrine.contract_address);
        let yin_user: ContractAddress = shrine_utils::yin_user_addr();

        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        start_prank(CheatTarget::All, trove1_owner);
        yin.approve(yin_user, BoundedU256::max());

        start_prank(CheatTarget::All, yin_user);
        yin.transfer_from(trove1_owner, ContractAddressZeroable::zero(), 1_u256);
    }

    #[test]
    fn test_yin_melt_after_transfer() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        shrine_utils::trove1_deposit(shrine, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        let forge_amt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine_utils::trove1_forge(shrine, forge_amt);

        let yin = shrine_utils::yin(shrine.contract_address);
        let yin_user: ContractAddress = shrine_utils::yin_user_addr();

        let trove1_owner: ContractAddress = common::trove1_owner_addr();
        start_prank(CheatTarget::All, trove1_owner);

        let transfer_amt: Wad = (forge_amt.val / 2).into();
        yin.transfer(yin_user, transfer_amt.val.into());

        let melt_amt: Wad = forge_amt - transfer_amt;

        shrine_utils::trove1_melt(shrine, melt_amt);

        let trove_health: Health = shrine.get_trove_health(common::TROVE_1);
        let expected_debt: Wad = forge_amt - melt_amt;
        assert(trove_health.debt == expected_debt, 'wrong debt after melt');

        assert(shrine.get_yin(trove1_owner) == forge_amt - melt_amt - transfer_amt, 'wrong balance');
    }

    //
    // Tests - Access control
    //

    // TODO: Uncomment this test once foundry is more stable
    // #[test]
    // fn test_auth() {
    //     let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
    //     let shrine = shrine_utils::shrine(shrine_addr);
    //     let shrine_accesscontrol: IAccessControlDispatcher = IAccessControlDispatcher {
    //         contract_address: shrine_addr
    //     };

    //     let admin: ContractAddress = shrine_utils::admin();
    //     let new_admin: ContractAddress = contract_address_try_from_felt252('new shrine admin')
    //         .unwrap();

    //     assert(shrine_accesscontrol.get_admin() == admin, 'wrong admin');

    //     // Authorizing an address and testing that it can use authorized functions
    //     start_prank(CheatTarget::One(shrine_addr), admin);
    //     shrine_accesscontrol.grant_role(shrine_roles::SET_DEBT_CEILING, new_admin);
    //     assert(
    //         shrine_accesscontrol.has_role(shrine_roles::SET_DEBT_CEILING, new_admin),
    //         'role not granted'
    //     );
    //     assert(
    //         shrine_accesscontrol.get_roles(new_admin) == shrine_roles::SET_DEBT_CEILING,
    //         'role not granted'
    //     );

    //     start_prank(CheatTarget::One(shrine_addr), new_admin);
    //     let new_ceiling: Wad = (WAD_SCALE + 1).into();
    //     shrine.set_debt_ceiling(new_ceiling);
    //     assert(shrine.get_debt_ceiling() == new_ceiling, 'wrong debt ceiling');

    //     // Revoking an address
    //     start_prank(CheatTarget::One(shrine_addr), admin);
    //     shrine_accesscontrol.revoke_role(shrine_roles::SET_DEBT_CEILING, new_admin);
    //     assert(
    //         !shrine_accesscontrol.has_role(shrine_roles::SET_DEBT_CEILING, new_admin),
    //         'role not revoked'
    //     );
    //     assert(shrine_accesscontrol.get_roles(new_admin) == 0, 'role not revoked');
    // }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_revoke_role() {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);

        let shrine = shrine_utils::shrine(shrine_addr);
        let shrine_accesscontrol: IAccessControlDispatcher = IAccessControlDispatcher { contract_address: shrine_addr };

        let admin: ContractAddress = shrine_utils::admin();
        start_prank(CheatTarget::One(shrine_addr), admin);

        let new_admin: ContractAddress = contract_address_try_from_felt252('new shrine admin').unwrap();

        shrine_accesscontrol.grant_role(shrine_roles::SET_DEBT_CEILING, new_admin);
        shrine_accesscontrol.revoke_role(shrine_roles::SET_DEBT_CEILING, new_admin);

        start_prank(CheatTarget::One(shrine.contract_address), new_admin);
        let new_ceiling: Wad = (WAD_SCALE + 1).into();
        shrine.set_debt_ceiling(new_ceiling);
    }

    //
    // Tests - Price and multiplier updates
    // Note that core functionality is already tested in `test_shrine_setup_with_feed`
    //

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_advance_unauthorized() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_prank(CheatTarget::All, common::badguy());
        shrine.advance(shrine_utils::yang1_addr(), shrine_utils::YANG1_START_PRICE.into());
    }

    #[test]
    #[should_panic(expected: ('SH: Yang does not exist',))]
    fn test_advance_invalid_yang() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.advance(shrine_utils::invalid_yang_addr(), shrine_utils::YANG1_START_PRICE.into());
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_multiplier_unauthorized() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_prank(CheatTarget::All, common::badguy());
        shrine.set_multiplier(RAY_SCALE.into());
    }

    //
    // Tests - Inject/eject
    //

    #[test]
    fn test_shrine_inject_and_eject() {
        assert(true, 'test');
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        let yin = shrine_utils::yin(shrine.contract_address);
        let trove1_owner = common::trove1_owner_addr();

        let before_total_supply: u256 = yin.total_supply();
        let before_user_bal: u256 = yin.balance_of(trove1_owner);
        let before_total_yin: Wad = shrine.get_total_yin();
        let before_user_yin: Wad = shrine.get_yin(trove1_owner);

        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());

        let inject_amt = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine.inject(trove1_owner, inject_amt);

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::Transfer(
                    shrine_contract::Transfer {
                        from: ContractAddressZeroable::zero(), to: trove1_owner, value: inject_amt.into(),
                    }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);

        assert(yin.total_supply() == before_total_supply + inject_amt.into(), 'incorrect total supply');
        assert(yin.balance_of(trove1_owner) == before_user_bal + inject_amt.val.into(), 'incorrect user balance');
        assert(shrine.get_total_yin() == before_total_yin + inject_amt, 'incorrect total yin');
        assert(shrine.get_yin(trove1_owner) == before_user_yin + inject_amt, 'incorrect user yin');

        shrine.eject(trove1_owner, inject_amt);
        assert(yin.total_supply() == before_total_supply, 'incorrect total supply');
        assert(yin.balance_of(trove1_owner) == before_user_bal, 'incorrect user balance');
        assert(shrine.get_total_yin() == before_total_yin, 'incorrect total yin');
        assert(shrine.get_yin(trove1_owner) == before_user_yin, 'incorrect user yin');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::Transfer(
                    shrine_contract::Transfer {
                        from: trove1_owner, to: ContractAddressZeroable::zero(), value: inject_amt.into(),
                    }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('SH: Debt ceiling reached',))]
    fn test_shrine_inject_exceeds_debt_ceiling_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let trove1_owner = common::trove1_owner_addr();

        start_prank(CheatTarget::All, shrine_utils::admin());

        let inject_amt = shrine.get_debt_ceiling() + 1_u128.into();
        shrine.inject(trove1_owner, inject_amt);
    }

    #[test]
    #[should_panic(expected: ('SH: Debt ceiling reached',))]
    fn test_shrine_inject_exceeds_debt_ceiling_neg_budget_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let trove1_owner = common::trove1_owner_addr();

        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());

        let inject_amt = shrine.get_debt_ceiling().into();
        shrine.inject(trove1_owner, inject_amt);
        assert(shrine.get_total_yin() == inject_amt, 'sanity check #1');

        let deficit: SignedWad = SignedWad { val: 1, sign: true };
        shrine.adjust_budget(deficit);
        assert(shrine.get_budget() == deficit, 'sanity check #2');

        shrine.inject(trove1_owner, 1_u128.into());
    }

    //
    // Tests - Price and multiplier
    //

    #[test]
    #[should_panic(expected: ('SH: Price cannot be 0',))]
    fn test_shrine_advance_zero_value_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.advance(shrine_utils::yang1_addr(), WadZeroable::zero());
    }

    #[test]
    #[should_panic(expected: ('SH: Multiplier cannot be 0',))]
    fn test_shrine_set_multiplier_zero_value_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.set_multiplier(RayZeroable::zero());
    }

    #[test]
    #[should_panic(expected: ('SH: Multiplier exceeds maximum',))]
    fn test_shrine_set_multiplier_exceeds_max_fail() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.set_multiplier((RAY_SCALE * 10 + 1).into());
    }

    //
    // Tests - Getters for trove information
    //

    #[test]
    fn test_trove_unhealthy() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        // Depositing lots of collateral in another trove
        // to avoid entering recovery mode
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.deposit(shrine_utils::yang1_addr(), common::TROVE_2, (50 * WAD_ONE).into());

        let deposit_amt: Wad = shrine_utils::TROVE1_YANG1_DEPOSIT.into();
        shrine_utils::trove1_deposit(shrine, deposit_amt);
        let forge_amt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine_utils::trove1_forge(shrine, forge_amt);

        let trove_health: Health = shrine.get_trove_health(common::TROVE_1);

        let unsafe_price: Wad = wadray::rdiv_wr(trove_health.debt, shrine_utils::YANG1_THRESHOLD.into()) / deposit_amt;

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.advance(shrine_utils::yang1_addr(), unsafe_price);

        assert(shrine.is_healthy(common::TROVE_1), 'should be unhealthy');
    }

    #[test]
    fn test_get_trove_health() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        let yang1_addr: ContractAddress = shrine_utils::yang1_addr();
        let yang2_addr: ContractAddress = shrine_utils::yang2_addr();

        let mut yangs: Array<ContractAddress> = array![yang1_addr, yang2_addr];
        let mut yang_amts: Array<Wad> = array![
            shrine_utils::TROVE1_YANG1_DEPOSIT.into(), shrine_utils::TROVE1_YANG2_DEPOSIT.into(),
        ];

        // Manually set the prices
        let yang1_price: Wad = 2500000000000000000000_u128.into(); // 2_500 (Wad)
        let yang2_price: Wad = 625000000000000000000_u128.into(); // 625 (Wad)
        let mut yang_prices: Array<Wad> = array![yang1_price, yang2_price];

        let mut yang_amts_copy: Span<Wad> = yang_amts.span();
        let mut yangs_copy: Span<ContractAddress> = yangs.span();
        let mut yang_prices_copy: Span<Wad> = yang_prices.span();

        start_prank(CheatTarget::All, shrine_utils::admin());
        loop {
            match yang_amts_copy.pop_front() {
                Option::Some(yang_amt) => {
                    let yang: ContractAddress = *yangs_copy.pop_front().unwrap();
                    shrine.deposit(yang, common::TROVE_1, *yang_amt);

                    shrine.advance(yang, *yang_prices_copy.pop_front().unwrap());
                },
                Option::None => { break (); }
            };
        };
        let mut yang_thresholds: Array<Ray> = array![
            shrine_utils::YANG1_THRESHOLD.into(), shrine_utils::YANG2_THRESHOLD.into(),
        ];

        let (expected_threshold, expected_value) = shrine_utils::calculate_trove_threshold_and_value(
            yang_prices.span(), yang_amts.span(), yang_thresholds.span()
        );
        let trove_health: Health = shrine.get_trove_health(common::TROVE_1);
        assert(trove_health.threshold == expected_threshold, 'wrong threshold');

        let forge_amt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine_utils::trove1_forge(shrine, forge_amt);
        let trove_health: Health = shrine.get_trove_health(common::TROVE_1);
        let expected_ltv: Ray = wadray::rdiv_ww(forge_amt, expected_value);
        assert(trove_health.ltv == expected_ltv, 'wrong LTV');
    }

    #[test]
    fn test_zero_value_trove() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        let trove_health: Health = shrine.get_trove_health(common::TROVE_3);
        assert(trove_health.threshold.is_zero(), 'threshold should be 0');
        assert(trove_health.ltv.is_zero(), 'LTV should be 0');
        assert(trove_health.value.is_zero(), 'value should be 0');
        assert(trove_health.debt.is_zero(), 'debt should be 0');
    }

    //
    // Tests - Getters for shrine threshold and value
    //

    #[test]
    fn test_get_shrine_health() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        let yang1_addr: ContractAddress = shrine_utils::yang1_addr();
        let yang2_addr: ContractAddress = shrine_utils::yang2_addr();

        let mut yangs: Array<ContractAddress> = array![yang1_addr, yang2_addr];

        let mut yang_amts: Array<Wad> = array![
            shrine_utils::TROVE1_YANG1_DEPOSIT.into(), shrine_utils::TROVE1_YANG2_DEPOSIT.into(),
        ];

        // Manually set the prices
        let yang1_price: Wad = 2500000000000000000000_u128.into(); // 2_500 (Wad)
        let yang2_price: Wad = 625000000000000000000_u128.into(); // 625 (Wad)
        let mut yang_prices: Array<Wad> = array![yang1_price, yang2_price];

        let mut yang_amts_copy: Span<Wad> = yang_amts.span();
        let mut yangs_copy: Span<ContractAddress> = yangs.span();
        let mut yang_prices_copy: Span<Wad> = yang_prices.span();

        // Deposit into troves 1 and 2, with trove 2 getting twice
        // the amount of trove 1
        start_prank(CheatTarget::All, shrine_utils::admin());
        loop {
            match yang_amts_copy.pop_front() {
                Option::Some(yang_amt) => {
                    let yang: ContractAddress = *yangs_copy.pop_front().unwrap();
                    shrine.deposit(yang, common::TROVE_1, *yang_amt);
                    // Deposit twice the amount into trove 2
                    shrine.deposit(yang, common::TROVE_2, (*yang_amt.val * 2).into());

                    shrine.advance(yang, *yang_prices_copy.pop_front().unwrap());
                },
                Option::None => { break (); }
            };
        };

        // Update the amounts with the total amount deposited into troves 1 and 2
        let mut yang_amts: Array<Wad> = array![
            (shrine_utils::TROVE1_YANG1_DEPOSIT * 3).into(), (shrine_utils::TROVE1_YANG2_DEPOSIT * 3).into(),
        ];

        let mut yang_thresholds: Array<Ray> = array![
            shrine_utils::YANG1_THRESHOLD.into(), shrine_utils::YANG2_THRESHOLD.into(),
        ];

        let (expected_threshold, expected_value) = shrine_utils::calculate_trove_threshold_and_value(
            yang_prices.span(), yang_amts.span(), yang_thresholds.span()
        );
        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.threshold == expected_threshold, 'wrong threshold');
        assert(shrine_health.value == expected_value, 'wrong value');
    }

    // Tests - Getter for forge fee
    #[test]
    fn test_shrine_get_forge_fee() {
        let error_margin: Wad = 5_u128.into(); // 5 * 10^-18 (wad)

        let first_yin_price: Wad = 995000000000000000_u128.into(); // 0.995 (wad)
        let second_yin_price: Wad = 994999999999999999_u128.into(); // 0.994999... (wad)
        let third_yin_price: Wad = 980000000000000000_u128.into(); // 0.98 (wad)
        let fourth_yin_price: Wad = (shrine_contract::FORGE_FEE_CAP_PRICE - 1).into();

        let third_forge_fee: Wad = 39810717055349725_u128.into(); // 0.039810717055349725 (wad)

        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        start_prank(CheatTarget::All, shrine_utils::admin());

        shrine.update_yin_spot_price(first_yin_price);
        assert(shrine.get_forge_fee_pct().is_zero(), 'wrong forge fee #1');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::YinPriceUpdated(
                    shrine_contract::YinPriceUpdated { old_price: WAD_ONE.into(), new_price: first_yin_price, }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);

        shrine.update_yin_spot_price(second_yin_price);
        common::assert_equalish(shrine.get_forge_fee_pct(), WAD_PERCENT.into(), error_margin, 'wrong forge fee #2');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::YinPriceUpdated(
                    shrine_contract::YinPriceUpdated { old_price: first_yin_price, new_price: second_yin_price, }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);

        // forge fee should be capped to `FORGE_FEE_CAP_PCT`
        shrine.update_yin_spot_price(third_yin_price);
        common::assert_equalish(shrine.get_forge_fee_pct(), third_forge_fee, error_margin, 'wrong forge fee #3');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::YinPriceUpdated(
                    shrine_contract::YinPriceUpdated { old_price: second_yin_price, new_price: third_yin_price, }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    //
    // Tests - yang suspension
    //

    #[test]
    fn test_get_yang_suspension_status_basic() {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        shrine_utils::shrine_setup(shrine_addr);
        let shrine = shrine_utils::shrine(shrine_addr);

        let status_yang1 = shrine.get_yang_suspension_status(shrine_utils::yang1_addr());
        assert(status_yang1 == YangSuspensionStatus::None, 'yang1');
        let status_yang2 = shrine.get_yang_suspension_status(shrine_utils::yang2_addr());
        assert(status_yang2 == YangSuspensionStatus::None, 'yang2');
        let status_yang3 = shrine.get_yang_suspension_status(shrine_utils::yang3_addr());
        assert(status_yang3 == YangSuspensionStatus::None, 'yang3');
    }

    #[test]
    #[should_panic(expected: ('SH: Yang does not exist',))]
    fn test_get_yang_suspension_status_nonexisting_yang() {
        let shrine = shrine_utils::shrine(shrine_utils::shrine_deploy(Option::None));
        shrine.get_yang_suspension_status(shrine_utils::invalid_yang_addr());
    }

    #[test]
    #[should_panic(expected: ('SH: Yang does not exist',))]
    fn test_suspend_yang_non_existing_yang() {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        shrine_utils::shrine_setup(shrine_addr);
        let shrine = shrine_utils::shrine(shrine_addr);
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.suspend_yang(shrine_utils::invalid_yang_addr());
    }

    #[test]
    #[should_panic(expected: ('SH: Yang does not exist',))]
    fn test_unsuspend_yang_non_existing_yang() {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        shrine_utils::shrine_setup(shrine_addr);
        let shrine = shrine_utils::shrine(shrine_addr);
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.unsuspend_yang(shrine_utils::invalid_yang_addr());
    }

    #[test]
    fn test_yang_suspend_and_unsuspend() {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine_addr));

        shrine_utils::shrine_setup(shrine_addr);
        let shrine = shrine_utils::shrine(shrine_addr);
        let yang = shrine_utils::yang1_addr();
        let start_ts = shrine_utils::DEPLOYMENT_TIMESTAMP;

        start_warp(CheatTarget::All, start_ts);
        start_prank(CheatTarget::All, shrine_utils::admin());

        // initiate yang's suspension, starting now
        shrine.suspend_yang(yang);

        // check suspension status
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Temporary, 'status 1');

        // check event emission
        spy
            .assert_emitted(
                @array![
                    (
                        shrine_addr,
                        shrine_contract::Event::YangSuspended(
                            shrine_contract::YangSuspended { yang, timestamp: get_block_timestamp() }
                        )
                    ),
                ]
            );

        // setting block time to a second before the suspension would be permanent
        start_warp(CheatTarget::All, start_ts + shrine_contract::SUSPENSION_GRACE_PERIOD - 1);

        // reset the suspension by setting yang's ts to 0
        shrine.unsuspend_yang(yang);

        // check suspension status
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::None, 'status 2');

        // check event emission
        spy
            .assert_emitted(
                @array![
                    (
                        shrine_addr,
                        shrine_contract::Event::YangUnsuspended(
                            shrine_contract::YangUnsuspended { yang, timestamp: get_block_timestamp() }
                        )
                    ),
                ]
            );
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_suspend_yang_not_authorized() {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        shrine_utils::shrine_setup(shrine_addr);
        let shrine = shrine_utils::shrine(shrine_addr);
        let yang = shrine_utils::yang1_addr();
        start_prank(CheatTarget::All, common::badguy());

        shrine.suspend_yang(yang);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_unsuspend_yang_not_authorized() {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        shrine_utils::shrine_setup(shrine_addr);
        let shrine = shrine_utils::shrine(shrine_addr);
        let yang = shrine_utils::yang1_addr();

        // We directly unsuspend the yang instead of suspending it first, because
        // an unauthorized call to `suspend_yang` has the same error message, which
        // can be ambiguous when trying to understand which part of the test failed.
        start_prank(CheatTarget::All, common::badguy());
        shrine.unsuspend_yang(yang);
    }

    #[test]
    fn test_yang_suspension_progress_temp_to_permanent() {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine_addr));

        shrine_utils::shrine_setup(shrine_addr);
        let shrine = shrine_utils::shrine(shrine_addr);

        let yang = shrine_utils::yang1_addr();
        let start_ts = shrine_utils::DEPLOYMENT_TIMESTAMP;

        start_warp(CheatTarget::All, start_ts);
        start_prank(CheatTarget::All, shrine_utils::admin());

        // initiate yang's suspension, starting now
        shrine.suspend_yang(yang);

        // check suspension status
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Temporary, 'status 1');

        // check event emission
        spy
            .assert_emitted(
                @array![
                    (
                        shrine_addr,
                        shrine_contract::Event::YangSuspended(
                            shrine_contract::YangSuspended { yang, timestamp: get_block_timestamp() }
                        )
                    ),
                ]
            );

        // check threshold (should be the same at the beginning)
        let (raw_threshold, _) = shrine.get_yang_threshold(yang);
        assert(raw_threshold == shrine_utils::YANG1_THRESHOLD.into(), 'threshold 1');

        // the threshold should decrease by 1% in this amount of time
        let one_pct = shrine_contract::SUSPENSION_GRACE_PERIOD / 100;

        // move time forward
        start_warp(CheatTarget::All, start_ts + one_pct);

        // check suspension status
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Temporary, 'status 2');

        // check threshold
        let (raw_threshold, _) = shrine.get_yang_threshold(yang);
        assert(raw_threshold == (shrine_utils::YANG1_THRESHOLD / 100 * 99).into(), 'threshold 2');

        // move time forward
        start_warp(CheatTarget::All, start_ts + one_pct * 20);

        // check suspension status
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Temporary, 'status 3');

        // check threshold
        let (raw_threshold, _) = shrine.get_yang_threshold(yang);
        assert(raw_threshold == (shrine_utils::YANG1_THRESHOLD / 100 * 80).into(), 'threshold 3');

        // move time forward to a second before permanent suspension
        start_warp(CheatTarget::All, start_ts + shrine_contract::SUSPENSION_GRACE_PERIOD - 1);

        // check suspension status
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Temporary, 'status 4');

        // check threshold
        let (raw_threshold, _) = shrine.get_yang_threshold(yang);
        // expected threshold is YANG1_THRESHOLD * (1 / SUSPENSION_GRACE_PERIOD)
        // that is about 0.0000050735 Ray, err margin is 10^-12 Ray
        common::assert_equalish(
            raw_threshold, 50735000000000000000_u128.into(), 1000000000000000_u128.into(), 'threshold 4'
        );

        // move time forward to end of temp suspension, start of permanent one
        start_warp(CheatTarget::All, start_ts + shrine_contract::SUSPENSION_GRACE_PERIOD);

        // check suspension status
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Permanent, 'status 5');

        // check threshold
        let (raw_threshold, _) = shrine.get_yang_threshold(yang);
        assert(raw_threshold == RayZeroable::zero(), 'threshold 5');
    }

    #[test]
    #[should_panic(expected: ('SH: Suspension is permanent',))]
    fn test_yang_suspension_cannot_reset_after_permanent() {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        shrine_utils::shrine_setup(shrine_addr);
        let shrine = shrine_utils::shrine(shrine_addr);

        let yang = shrine_utils::yang1_addr();
        let start_ts = shrine_utils::DEPLOYMENT_TIMESTAMP;

        start_warp(CheatTarget::All, start_ts);
        start_prank(CheatTarget::All, shrine_utils::admin());

        // mark permanent
        shrine.suspend_yang(yang);
        start_warp(CheatTarget::All, start_ts + shrine_contract::SUSPENSION_GRACE_PERIOD);

        // sanity check
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Permanent, 'delisted');

        // trying to reset yang suspension status, should fail
        shrine.unsuspend_yang(yang);
    }

    #[test]
    #[should_panic(expected: ('SH: Already suspended',))]
    fn test_yang_already_suspended_temporary() {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        shrine_utils::shrine_setup(shrine_addr);
        let shrine = shrine_utils::shrine(shrine_addr);

        let yang = shrine_utils::yang1_addr();
        let start_ts = shrine_utils::DEPLOYMENT_TIMESTAMP;

        start_warp(CheatTarget::All, start_ts);
        start_prank(CheatTarget::All, shrine_utils::admin());

        // suspend yang
        shrine.suspend_yang(yang);

        // sanity check
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Temporary, 'should be temporary');

        // trying to suspend an already suspended yang, should fail
        shrine.suspend_yang(yang);
    }

    #[test]
    #[should_panic(expected: ('SH: Already suspended',))]
    fn test_yang_already_suspended_permanent() {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        shrine_utils::shrine_setup(shrine_addr);
        let shrine = shrine_utils::shrine(shrine_addr);

        let yang = shrine_utils::yang1_addr();
        let start_ts = shrine_utils::DEPLOYMENT_TIMESTAMP;

        start_warp(CheatTarget::All, start_ts);
        start_prank(CheatTarget::All, shrine_utils::admin());

        // suspend yang
        shrine.suspend_yang(yang);

        // make permanent
        start_warp(CheatTarget::All, start_ts + shrine_contract::SUSPENSION_GRACE_PERIOD);

        // sanity check
        let status = shrine.get_yang_suspension_status(yang);
        assert(status == YangSuspensionStatus::Permanent, 'should be permanent');

        // trying to suspend an already suspended yang, should fail
        shrine.suspend_yang(yang);
    }

    // In this test, we have two troves. Both are initially healthy. And then suddenly the
    // LTV of the larger trove drops enough such that the global LTV is above the
    // recovery mode threshold, and high enough above the threshold such that
    // the second (smaller) trove is now underwater.
    #[test]
    fn test_recovery_mode_previously_healthy_trove_now_unhealthy() {
        let shrine: IShrineDispatcher = shrine_utils::recovery_mode_test_setup(Option::None);

        // Trove 1 should be healthy
        assert(shrine.is_healthy(common::TROVE_1), 'should be healthy #1');

        // Increasing the whale trove's LTV to just above the recovery mode threshold
        // Since it makes up the vast majority of collateral (and debt), the global
        // LTV will be almost equal to the whale trove's LTV
        let shrine_health: Health = shrine.get_shrine_health();
        let rm_threshold: Ray = shrine_health.threshold * shrine_contract::RECOVERY_MODE_THRESHOLD_MULTIPLIER.into();

        //  whale_trove_forge_amt / (whale_trove_deposit_value - x) = rm_threshold * 1.01
        //  whale_trove_forge_amt = rm_threshold * 1.01 * whale_trove_deposit_value - rm_threshold * 1.01 * x
        //  x = - (whale_trove_forge_amt - rm_threshold * 1.01 * whale_trove_deposit_value) / (rm_threshold * 1.01)
        //  x = whale_trove_deposit_value - whale_trove_forge_amt/(rm_threshold * 1.01)

        let threshold_scalar: Ray = (RAY_ONE + RAY_PERCENT).into();
        let whale_trove_deposit_value: Wad = shrine_utils::WHALE_TROVE_YANG1_DEPOSIT.into()
            * shrine_utils::YANG1_START_PRICE.into();
        let whale_trove_forge_amt: Wad = shrine_utils::WHALE_TROVE_FORGE_AMT.into();
        let initial_collateral_value_to_withdraw: Wad = whale_trove_deposit_value
            - wadray::rdiv_wr(whale_trove_forge_amt, rm_threshold * threshold_scalar);

        start_prank(CheatTarget::All, shrine_utils::admin());

        let (_, prev_yang1_threshold) = shrine.get_yang_threshold(shrine_utils::yang1_addr());
        shrine
            .withdraw(
                shrine_utils::yang1_addr(),
                common::WHALE_TROVE,
                initial_collateral_value_to_withdraw / shrine_utils::YANG1_START_PRICE.into()
            );

        // At this point, recovery mode should be activated but trove 1 should still be healthy,
        // since the liquidation threshold decrease is gradual
        let (_, current_threshold) = shrine.get_yang_threshold(shrine_utils::yang1_addr());
        assert(current_threshold < prev_yang1_threshold, 'recovery mode not active');
        assert(shrine.is_healthy(common::TROVE_1), 'should be healthy #2');

        // Now we withdraw just enough collateral from the whale trove
        // so that trove 1 is underwater
        //
        // z = x + y, where x is from the last equation and y is the additional collateral
        // value that must be withdrawn to reach the desired threshold reduction.
        //
        // trove1_ltv - 10^(-24) = (trove1_threshold * THRESHOLD_DECREASE_FACTOR * rm_threshold) / (whale_trove_forge_amt / (whale_trove_deposit_value - z))
        // trove1_ltv - 10^(-24) = (whale_trove_deposit_value - z) * (trove1_threshold * THRESHOLD_DECREASE_FACTOR * rm_threshold) / whale_trove_forge_amt
        // (whale_trove_deposit_value - z) = (trove1_ltv - 10^(-24)) * whale_trove_forge_amt / (trove1_threshold * THRESHOLD_DECREASE_FACTOR * rm_threshold)
        // z = whale_trove_deposit_value - ((trove1_ltv - 10^(-24)) * whale_trove_forge_amt) / (trove1_threshold * THRESHOLD_DECREASE_FACTOR * rm_threshold)

        let trove1_ltv: Ray = wadray::rdiv_ww(
            shrine_utils::RECOVERY_TESTS_TROVE1_FORGE_AMT.into(),
            shrine_utils::TROVE1_YANG1_DEPOSIT.into() * shrine_utils::YANG1_START_PRICE.into()
        );
        let trove1_threshold: Ray = shrine_utils::YANG1_THRESHOLD.into();

        let shrine_health: Health = shrine.get_shrine_health();
        let rm_threshold: Ray = shrine_health.threshold * shrine_contract::RECOVERY_MODE_THRESHOLD_MULTIPLIER.into();

        let total_collateral_value_to_withdraw = whale_trove_deposit_value
            - wadray::rdiv_wr(
                wadray::rmul_rw((trove1_ltv - 1000_u128.into()), whale_trove_forge_amt),
                trove1_threshold * shrine_contract::THRESHOLD_DECREASE_FACTOR.into() * rm_threshold
            );

        // y = z - x
        let remaining_collateral_value_to_withdraw = total_collateral_value_to_withdraw
            - initial_collateral_value_to_withdraw;
        shrine
            .withdraw(
                shrine_utils::yang1_addr(),
                common::WHALE_TROVE,
                remaining_collateral_value_to_withdraw / shrine_utils::YANG1_START_PRICE.into()
            );

        // Now trove1 should be underwater, while the whale trove should still be healthy.
        assert(!shrine.is_healthy(common::TROVE_1), 'should be unhealthy');
        assert(shrine.is_healthy(common::WHALE_TROVE), 'should be healthy #3');
    }

    // Invariant test: scaling the "raw" trove threshold for recovery mode is
    // the same as scaling each yang threshold individually and only then
    // calculating the trove threshold
    #[test]
    fn test_recovery_mode_invariant() {
        let shrine: IShrineDispatcher = shrine_utils::recovery_mode_test_setup(Option::None);

        let yang2_deposit: Wad = (2 * WAD_ONE).into();
        start_prank(CheatTarget::All, shrine_utils::admin());
        // We deposit some yang2 into trove1 in order to alter its collateral composition,
        // and subsequently its threshold
        shrine.deposit(shrine_utils::yang2_addr(), common::TROVE_1, yang2_deposit);

        // We then withdraw collateral from the whale trove in order to bring up the global LTV
        // and activate recovery mode
        shrine.withdraw(shrine_utils::yang1_addr(), common::WHALE_TROVE, (200 * WAD_ONE).into());

        // Sanity check that recovery mode is active
        let (_, threshold) = shrine.get_yang_threshold(shrine_utils::yang1_addr());
        assert(threshold < shrine_utils::YANG1_THRESHOLD.into(), 'recovery mode not active');

        // Getting the trove threshold as calculated by Shrine
        let trove_health: Health = shrine.get_trove_health(common::TROVE_1);

        // Getting the trove threshold as calculated by scaling each yang threshold individually

        let (_, yang1_threshold) = shrine.get_yang_threshold(shrine_utils::yang1_addr());
        let (_, yang2_threshold) = shrine.get_yang_threshold(shrine_utils::yang2_addr());

        let yang1_deposit_value = shrine_utils::TROVE1_YANG1_DEPOSIT.into() * shrine_utils::YANG1_START_PRICE.into();
        let yang2_deposit_value = yang2_deposit * shrine_utils::YANG2_START_PRICE.into();

        let alternative_threshold: Ray = wadray::wdiv_rw(
            wadray::wmul_wr(yang1_deposit_value, yang1_threshold)
                + wadray::wmul_wr(yang2_deposit_value, yang2_threshold),
            yang1_deposit_value + yang2_deposit_value
        );

        assert(trove_health.threshold == alternative_threshold, 'invariant did not hold');
    }

    #[test]
    fn test_src5_for_erc20_support() {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        let src5 = ISRC5Dispatcher { contract_address: shrine_addr };
        assert(src5.supports_interface(shrine_contract::ISRC5_ID), 'should support SRC5');
        assert(src5.supports_interface(shrine_contract::IERC20_ID), 'should support ERC20');
        assert(src5.supports_interface(shrine_contract::IERC20_CAMEL_ID), 'should support ERC20 Camel');
    }
}
