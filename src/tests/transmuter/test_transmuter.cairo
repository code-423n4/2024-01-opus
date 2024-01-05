mod test_transmuter {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use cmp::min;
    use debug::PrintTrait;
    use integer::BoundedInt;
    use opus::core::roles::transmuter_roles;
    use opus::core::transmuter::transmuter as transmuter_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::ITransmuter::{ITransmuterDispatcher, ITransmuterDispatcherTrait};
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::tests::transmuter::utils::transmuter_utils;
    use opus::utils::math::{fixed_point_to_wad, pow, wad_to_fixed_point};
    use snforge_std::{
        CheatTarget, ContractClass, EventAssertions, EventSpy, SpyOn, spy_events, start_prank, stop_prank
    };
    use starknet::ContractAddress;
    use starknet::contract_address::{contract_address_try_from_felt252, ContractAddressZeroable};
    use wadray::{
        Ray, RayZeroable, RAY_ONE, RAY_PERCENT, Signed, SignedWad, SignedWadZeroable, Wad, WadZeroable, WAD_ONE
    };

    //
    // Tests - Deployment 
    //

    // Check constructor function
    #[test]
    fn test_transmuter_deploy() {
        let mut spy = spy_events(SpyOn::All);
        let (_, transmuter, mock_usd_stable) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        // Check Transmuter getters
        let ceiling: Wad = transmuter_utils::INITIAL_CEILING.into();
        let receiver: ContractAddress = transmuter_utils::receiver();

        assert(transmuter.get_asset() == mock_usd_stable.contract_address, 'wrong asset');
        assert(transmuter.get_total_transmuted().is_zero(), 'wrong total transmuted');
        assert(transmuter.get_ceiling() == ceiling, 'wrong ceiling');
        assert(
            transmuter.get_percentage_cap() == transmuter_contract::INITIAL_PERCENTAGE_CAP.into(),
            'wrong percentage cap'
        );
        assert(transmuter.get_receiver() == receiver, 'wrong receiver');
        assert(transmuter.get_reversibility(), 'not reversible');
        assert(transmuter.get_transmute_fee().is_zero(), 'non-zero transmute fee');
        assert(transmuter.get_reverse_fee().is_zero(), 'non-zero reverse fee');
        assert(transmuter.get_live(), 'not live');
        assert(!transmuter.get_reclaimable(), 'reclaimable');

        let transmuter_ac: IAccessControlDispatcher = IAccessControlDispatcher {
            contract_address: transmuter.contract_address
        };
        let admin: ContractAddress = transmuter_utils::admin();
        assert(transmuter_ac.get_admin() == admin, 'wrong admin');
        assert(transmuter_ac.get_roles(admin) == transmuter_roles::default_admin_role(), 'wrong admin roles');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::CeilingUpdated(
                    transmuter_contract::CeilingUpdated { old_ceiling: WadZeroable::zero(), new_ceiling: ceiling, }
                ),
            ),
            (
                transmuter.contract_address,
                transmuter_contract::Event::ReceiverUpdated(
                    transmuter_contract::ReceiverUpdated {
                        old_receiver: ContractAddressZeroable::zero(), new_receiver: receiver
                    }
                ),
            ),
            (
                transmuter.contract_address,
                transmuter_contract::Event::PercentageCapUpdated(
                    transmuter_contract::PercentageCapUpdated {
                        cap: transmuter_contract::INITIAL_PERCENTAGE_CAP.into(),
                    }
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    //
    // Tests - Setters
    //

    #[test]
    fn test_set_ceiling() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        let mut spy = spy_events(SpyOn::One(transmuter.contract_address));

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        // 2_000_000 (Wad)
        let new_ceiling: Wad = 2000000000000000000000000_u128.into();
        transmuter.set_ceiling(new_ceiling);

        assert(transmuter.get_ceiling() == new_ceiling, 'wrong ceiling');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::CeilingUpdated(
                    transmuter_contract::CeilingUpdated {
                        old_ceiling: transmuter_utils::INITIAL_CEILING.into(), new_ceiling
                    }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_ceiling_unauthorized() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), common::badguy());
        // 2_000_000 (Wad)
        let new_ceiling: Wad = 2000000000000000000000000_u128.into();
        transmuter.set_ceiling(new_ceiling);
    }

    #[test]
    fn test_set_percentage_cap() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        let mut spy = spy_events(SpyOn::One(transmuter.contract_address));

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        // 5% (Ray)
        let cap: Ray = 50000000000000000000000000_u128.into();
        transmuter.set_percentage_cap(cap);

        assert(transmuter.get_percentage_cap() == cap, 'wrong percentage cap');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::PercentageCapUpdated(transmuter_contract::PercentageCapUpdated { cap }),
            )
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('TR: Exceeds upper bound',))]
    fn test_set_percentage_cap_too_high_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        // 100% + 1E-27 (Ray)
        let cap: Ray = (transmuter_contract::PERCENTAGE_CAP_UPPER_BOUND + 1).into();
        transmuter.set_percentage_cap(cap);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_percentage_cap_unauthorized_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), common::badguy());
        // 5% (Ray)
        let cap: Ray = 50000000000000000000000000_u128.into();
        transmuter.set_percentage_cap(cap);
    }

    #[test]
    fn test_set_receiver() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        let mut spy = spy_events(SpyOn::One(transmuter.contract_address));

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        let new_receiver: ContractAddress = contract_address_try_from_felt252('new receiver').unwrap();
        transmuter.set_receiver(new_receiver);

        assert(transmuter.get_receiver() == new_receiver, 'wrong receiver');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::ReceiverUpdated(
                    transmuter_contract::ReceiverUpdated { old_receiver: transmuter_utils::receiver(), new_receiver }
                ),
            )
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('TR: Zero address',))]
    fn test_set_receiver_zero_addr_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        transmuter.set_receiver(ContractAddressZeroable::zero());
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_receiver_unauthorized_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), common::badguy());
        let new_receiver: ContractAddress = contract_address_try_from_felt252('new receiver').unwrap();
        transmuter.set_receiver(new_receiver);
    }

    #[test]
    fn test_set_transmute_and_reverse_fee() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        let mut spy = spy_events(SpyOn::One(transmuter.contract_address));

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        // 0.5% (Ray)
        let new_fee: Ray = 5000000000000000000000000_u128.into();

        // transmute
        transmuter.set_transmute_fee(new_fee);

        assert(transmuter.get_transmute_fee() == new_fee, 'wrong transmute fee');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::TransmuteFeeUpdated(
                    transmuter_contract::TransmuteFeeUpdated { old_fee: RayZeroable::zero(), new_fee }
                )
            )
        ];
        spy.assert_emitted(@expected_events);

        // reverse
        transmuter.set_reverse_fee(new_fee);

        assert(transmuter.get_reverse_fee() == new_fee, 'wrong reverse fee');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::ReverseFeeUpdated(
                    transmuter_contract::ReverseFeeUpdated { old_fee: RayZeroable::zero(), new_fee }
                )
            )
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('TR: Exceeds max fee',))]
    fn test_set_transmute_fee_exceeds_max_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        // 1% + 1E-27 (Ray)
        let new_fee: Ray = 10000000000000000000000001_u128.into();
        transmuter.set_transmute_fee(new_fee);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_transmute_fee_unauthorized_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), common::badguy());
        // 0.5% (Ray)
        let new_fee: Ray = 5000000000000000000000000_u128.into();
        transmuter.set_transmute_fee(new_fee);
    }

    #[test]
    #[should_panic(expected: ('TR: Exceeds max fee',))]
    fn test_set_reverse_fee_exceeds_max_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        // 1% + 1E-27 (Ray)
        let new_fee: Ray = 10000000000000000000000001_u128.into();
        transmuter.set_reverse_fee(new_fee);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_reverse_fee_unauthorized_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), common::badguy());
        // 0.5% (Ray)
        let new_fee: Ray = 5000000000000000000000000_u128.into();
        transmuter.set_reverse_fee(new_fee);
    }

    #[test]
    fn test_toggle_reversibility_pass() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        let mut spy = spy_events(SpyOn::One(transmuter.contract_address));

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        transmuter.toggle_reversibility();
        assert(!transmuter.get_reversibility(), 'reversible');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::ReversibilityToggled(
                    transmuter_contract::ReversibilityToggled { reversibility: false }
                )
            )
        ];
        spy.assert_emitted(@expected_events);

        transmuter.toggle_reversibility();
        assert(transmuter.get_reversibility(), 'not reversible');

        let expected_events = array![
            (
                transmuter.contract_address,
                transmuter_contract::Event::ReversibilityToggled(
                    transmuter_contract::ReversibilityToggled { reversibility: true }
                )
            )
        ];
        spy.assert_emitted(@expected_events);
    }

    //
    // Tests - Transmute
    //

    #[test]
    fn test_transmute_with_preview_parametrized() {
        let transmuter_class: ContractClass = transmuter_utils::declare_transmuter();
        let token_class: ContractClass = transmuter_utils::declare_erc20();
        let (shrine, wad_transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::Some(transmuter_class), Option::Some(token_class)
        );
        let mock_nonwad_usd_stable = transmuter_utils::mock_nonwad_usd_stable_deploy(Option::Some(token_class));
        let nonwad_transmuter = transmuter_utils::transmuter_deploy(
            Option::Some(transmuter_class),
            shrine.contract_address,
            mock_nonwad_usd_stable.contract_address,
            transmuter_utils::receiver()
        );

        let mut transmuters: Span<ITransmuterDispatcher> = array![wad_transmuter, nonwad_transmuter].span();

        let transmute_fees: Span<Ray> = array![
            RayZeroable::zero(), // 0%
            1_u128.into(), // 1E-27 %
            1000000000000000000000000_u128.into(), // 0.1%
            2345000000000000000000000_u128.into(), // 0.2345
            10000000000000000000000000_u128.into(), // 1% 
        ]
            .span();

        let real_transmute_amt: u128 = 1000;
        let transmute_amt_wad: Wad = (real_transmute_amt * WAD_ONE).into();
        let expected_wad_transmuted_amts: Span<Wad> = array![
            transmute_amt_wad.into(), // 0% fee, 1000
            transmute_amt_wad.into(), // 1E-27% fee (loss of precision), 1000
            999000000000000000000_u128.into(), // 0.1% fee, 999.00
            997655000000000000137_u128.into(), // 0.2345% fee, 997.655...
            990000000000000000000_u128.into(), // 1% fee, 990.00
        ]
            .span();

        let user: ContractAddress = transmuter_utils::user();

        loop {
            match transmuters.pop_front() {
                Option::Some(transmuter) => {
                    let transmuter = *transmuter;
                    let asset = IERC20Dispatcher { contract_address: transmuter.get_asset() };

                    let mut spy = spy_events(SpyOn::One(transmuter.contract_address));

                    // approve Transmuter to transfer user's mock USD stable
                    start_prank(CheatTarget::One(asset.contract_address), user);
                    asset.approve(transmuter.contract_address, BoundedInt::max());
                    stop_prank(CheatTarget::One(asset.contract_address));

                    // Set up transmute amount to be equivalent to 1_000 (Wad) yin
                    let asset_decimals: u8 = asset.decimals();
                    let transmute_amt: u128 = real_transmute_amt * pow(10, asset_decimals);

                    let mut transmute_fees_copy = transmute_fees;
                    let mut expected_wad_transmuted_amts_copy = expected_wad_transmuted_amts;

                    loop {
                        match transmute_fees_copy.pop_front() {
                            Option::Some(transmute_fee) => {
                                start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
                                transmuter.set_transmute_fee(*transmute_fee);

                                start_prank(CheatTarget::One(transmuter.contract_address), user);

                                // check preview
                                let preview: Wad = transmuter.preview_transmute(transmute_amt);
                                let expected: Wad = *expected_wad_transmuted_amts_copy.pop_front().unwrap();
                                common::assert_equalish(
                                    preview,
                                    expected,
                                    (WAD_ONE / 100).into(), // error margin
                                    'wrong preview transmute amt'
                                );

                                // transmute
                                let expected_fee: Wad = transmute_amt_wad - preview;

                                let before_user_yin_bal: Wad = shrine.get_yin(user);
                                let before_total_yin: Wad = shrine.get_total_yin();
                                let before_total_transmuted: Wad = transmuter.get_total_transmuted();
                                let before_shrine_budget: SignedWad = shrine.get_budget();
                                let before_transmuter_asset_bal: u256 = asset.balance_of(transmuter.contract_address);

                                let expected_budget: SignedWad = before_shrine_budget + expected_fee.into();

                                transmuter.transmute(transmute_amt);
                                assert(shrine.get_yin(user) == before_user_yin_bal + preview, 'wrong user yin');
                                assert(shrine.get_total_yin() == before_total_yin + preview, 'wrong total yin');
                                assert(shrine.get_budget() == expected_budget, 'wrong budget');
                                assert(
                                    transmuter.get_total_transmuted() == before_total_transmuted + transmute_amt_wad,
                                    'wrong total transmuted'
                                );
                                assert(
                                    asset.balance_of(transmuter.contract_address) == before_transmuter_asset_bal
                                        + transmute_amt.into(),
                                    'wrong transmuter asset bal'
                                );

                                let expected_events = array![
                                    (
                                        transmuter.contract_address,
                                        transmuter_contract::Event::Transmute(
                                            transmuter_contract::Transmute {
                                                user, asset_amt: transmute_amt, yin_amt: preview, fee: expected_fee
                                            }
                                        )
                                    )
                                ];
                                spy.assert_emitted(@expected_events);
                            },
                            Option::None => { break; }
                        };
                    };
                },
                Option::None => { break; },
            };
        };
    }

    #[test]
    #[should_panic(expected: ('SH: Debt ceiling reached',))]
    fn test_transmute_exceeds_shrine_ceiling_fail() {
        let (shrine, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );
        let user: ContractAddress = transmuter_utils::user();

        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        let debt_ceiling: Wad = shrine.get_debt_ceiling();
        shrine.inject(user, debt_ceiling);

        transmuter.transmute(1_u128);
    }

    #[test]
    #[should_panic(expected: ('TR: Transmute is paused',))]
    fn test_transmute_exceeds_transmuter_ceiling_fail() {
        let (_, transmuter, asset) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::user());

        let ceiling: Wad = transmuter.get_ceiling();
        transmuter.transmute(ceiling.val);
        assert(transmuter.get_total_transmuted() == ceiling, 'sanity check');

        transmuter.transmute(1_u128.into());
    }

    #[test]
    #[should_panic(expected: ('TR: Transmute is paused',))]
    fn test_transmute_exceeds_percentage_cap_fail() {
        let (shrine, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());

        // reduce total supply to 1m yin 
        let target_total_yin: Wad = 1000000000000000000000000_u128.into();
        shrine.eject(transmuter_utils::receiver(), transmuter_utils::START_TOTAL_YIN.into() - target_total_yin);
        assert(shrine.get_total_yin() == target_total_yin, 'sanity check #1');

        stop_prank(CheatTarget::One(shrine.contract_address));

        // now, the cap is at 100_000
        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::user());
        let expected_cap: u128 = 100000 * WAD_ONE;
        transmuter.transmute(expected_cap + 1);
    }

    #[test]
    #[should_panic(expected: ('TR: Transmute is paused',))]
    fn test_transmute_yin_spot_price_too_low_fail() {
        let (shrine, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        shrine.update_yin_spot_price((WAD_ONE - 1).into());

        transmuter.transmute(1_u128.into());
    }

    //
    // Tests - Reverse
    //

    #[test]
    fn test_reverse_with_preview_parametrized() {
        let transmuter_class: ContractClass = transmuter_utils::declare_transmuter();
        let token_class: ContractClass = transmuter_utils::declare_erc20();

        let (shrine, wad_transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::Some(transmuter_class), Option::Some(token_class)
        );
        let mock_nonwad_usd_stable = transmuter_utils::mock_nonwad_usd_stable_deploy(Option::Some(token_class));
        let nonwad_transmuter = transmuter_utils::transmuter_deploy(
            Option::Some(transmuter_class),
            shrine.contract_address,
            mock_nonwad_usd_stable.contract_address,
            transmuter_utils::receiver()
        );

        let mut transmuters: Span<ITransmuterDispatcher> = array![wad_transmuter, nonwad_transmuter].span();

        let reverse_fees: Span<Ray> = array![
            RayZeroable::zero(), // 0%
            1_u128.into(), // 1E-27 %
            1000000000000000000000000_u128.into(), // 0.1%
            2345000000000000000000000_u128.into(), // 0.2345
            10000000000000000000000000_u128.into(), // 1% 
        ]
            .span();

        let real_reverse_amt: u128 = 1000;
        let reverse_yin_amt: Wad = (real_reverse_amt * WAD_ONE).into();

        let user: ContractAddress = transmuter_utils::user();

        loop {
            match transmuters.pop_front() {
                Option::Some(transmuter) => {
                    let transmuter = *transmuter;
                    let asset = IERC20Dispatcher { contract_address: transmuter.get_asset() };

                    // approve Transmuter to transfer user's mock USD stable
                    start_prank(CheatTarget::One(asset.contract_address), user);
                    asset.approve(transmuter.contract_address, BoundedInt::max());
                    stop_prank(CheatTarget::One(asset.contract_address));

                    // Transmute an amount of yin to set up Transmuter for reverse
                    let asset_decimals: u8 = asset.decimals();
                    let real_transmute_amt: u128 = reverse_fees.len().into() * real_reverse_amt;
                    let asset_decimal_scale: u128 = pow(10, asset_decimals);
                    let transmute_amt: u128 = real_transmute_amt * asset_decimal_scale;

                    start_prank(CheatTarget::One(transmuter.contract_address), user);
                    transmuter.transmute(transmute_amt);
                    stop_prank(CheatTarget::One(transmuter.contract_address));

                    let mut expected_reversed_asset_amts: Span<u128> = array![
                        wad_to_fixed_point(reverse_yin_amt, asset_decimals).into(), // 0% fee, 1000
                        wad_to_fixed_point(reverse_yin_amt, asset_decimals)
                            .into(), // 1E-27% fee (loss of precision), 1000
                        wad_to_fixed_point(reverse_yin_amt - WAD_ONE.into(), asset_decimals), // 0.1% fee, 999.00
                        wad_to_fixed_point(
                            reverse_yin_amt - 2345000000000000000_u128.into(), asset_decimals
                        ), // 0.2345% fee, 997.655...
                        wad_to_fixed_point(reverse_yin_amt - (10 * WAD_ONE).into(), asset_decimals), // 1% fee, 990.00
                    ]
                        .span();

                    let mut cumulative_asset_fees: u128 = 0;
                    let mut cumulative_yin_fees = WadZeroable::zero();
                    let mut reverse_fees_copy = reverse_fees;
                    loop {
                        match reverse_fees_copy.pop_front() {
                            Option::Some(reverse_fee) => {
                                let mut spy = spy_events(SpyOn::One(transmuter.contract_address));

                                start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
                                transmuter.set_reverse_fee(*reverse_fee);
                                stop_prank(CheatTarget::One(transmuter.contract_address));

                                start_prank(CheatTarget::One(transmuter.contract_address), user);

                                // check preview
                                let preview: u128 = transmuter.preview_reverse(reverse_yin_amt);
                                let expected: u128 = *expected_reversed_asset_amts.pop_front().unwrap();
                                common::assert_equalish(
                                    preview,
                                    expected,
                                    (asset_decimal_scale / 100), // error margin
                                    'wrong preview reverse amt'
                                );

                                // transmute
                                let expected_fee: Wad = wadray::rmul_rw(*reverse_fee, reverse_yin_amt);

                                let before_user_yin_bal: Wad = shrine.get_yin(user);
                                let before_total_yin: Wad = shrine.get_total_yin();
                                let before_total_transmuted: Wad = transmuter.get_total_transmuted();
                                let before_shrine_budget: SignedWad = shrine.get_budget();
                                let before_transmuter_asset_bal: u256 = asset.balance_of(transmuter.contract_address);

                                let expected_budget: SignedWad = before_shrine_budget + expected_fee.into();

                                transmuter.reverse(reverse_yin_amt);
                                assert(shrine.get_yin(user) == before_user_yin_bal - reverse_yin_amt, 'wrong user yin');
                                assert(shrine.get_total_yin() == before_total_yin - reverse_yin_amt, 'wrong total yin');
                                assert(shrine.get_budget() == expected_budget, 'wrong budget');
                                assert(
                                    transmuter.get_total_transmuted() == before_total_transmuted
                                        - reverse_yin_amt
                                        + expected_fee,
                                    'wrong total transmuted'
                                );
                                assert(
                                    asset.balance_of(transmuter.contract_address) == before_transmuter_asset_bal
                                        - preview.into(),
                                    'wrong transmuter asset bal'
                                );

                                let expected_events = array![
                                    (
                                        transmuter.contract_address,
                                        transmuter_contract::Event::Reverse(
                                            transmuter_contract::Reverse {
                                                user, asset_amt: preview, yin_amt: reverse_yin_amt, fee: expected_fee
                                            }
                                        )
                                    )
                                ];
                                spy.assert_emitted(@expected_events);

                                cumulative_asset_fees += (real_reverse_amt * asset_decimal_scale) - preview;
                                cumulative_yin_fees += expected_fee;

                                stop_prank(CheatTarget::One(transmuter.contract_address));
                            },
                            Option::None => { break; }
                        };
                    };

                    assert(
                        asset.balance_of(transmuter.contract_address) == cumulative_asset_fees.into(),
                        'wrong cumulative asset fees'
                    );
                    assert(transmuter.get_total_transmuted() == cumulative_yin_fees, 'wrong cumulative yin fees');
                },
                Option::None => { break; },
            };
        };
    }

    #[test]
    #[should_panic(expected: ('TR: Reverse is paused',))]
    fn test_reverse_disabled_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        transmuter.toggle_reversibility();
        assert(!transmuter.get_reversibility(), 'sanity check');

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::user());
        let transmute_amt: u128 = 1000 * WAD_ONE;
        transmuter.transmute(transmute_amt);

        transmuter.reverse(1_u128.into());
    }

    #[test]
    #[should_panic(expected: ('TR: Insufficient assets',))]
    fn test_reverse_zero_assets_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        let user: ContractAddress = transmuter_utils::user();
        let asset_amt: u128 = WAD_ONE;
        start_prank(CheatTarget::One(transmuter.contract_address), user);
        transmuter.transmute(asset_amt.into());

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        transmuter.sweep(asset_amt);

        start_prank(CheatTarget::One(transmuter.contract_address), user);
        transmuter.reverse(1_u128.into());
    }

    //
    // Tests - Sweep
    //

    #[test]
    fn test_sweep_parametrized_pass() {
        let shrine_class: ContractClass = shrine_utils::declare_shrine();
        let transmuter_class: ContractClass = transmuter_utils::declare_transmuter();
        let token_class: ContractClass = transmuter_utils::declare_erc20();

        let admin: ContractAddress = transmuter_utils::admin();
        let receiver: ContractAddress = transmuter_utils::receiver();
        let user: ContractAddress = transmuter_utils::user();

        let mut transmuter_ids: Span<u32> = array![0, 1].span();

        loop {
            match transmuter_ids.pop_front() {
                Option::Some(transmuter_id) => {
                    // parametrize transmuter and asset
                    let asset: IERC20Dispatcher = if *transmuter_id == 0 {
                        transmuter_utils::mock_wad_usd_stable_deploy(Option::Some(token_class))
                    } else {
                        transmuter_utils::mock_nonwad_usd_stable_deploy(Option::Some(token_class))
                    };
                    let asset_decimals: u8 = asset.decimals();

                    let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::Some(shrine_class));

                    let transmuter: ITransmuterDispatcher = transmuter_utils::transmuter_deploy(
                        Option::Some(transmuter_class), shrine.contract_address, asset.contract_address, receiver
                    );

                    let shrine_debt_ceiling: Wad = transmuter_utils::INITIAL_CEILING.into();
                    let seed_amt: Wad = (100000 * WAD_ONE).into();

                    transmuter_utils::setup_shrine_with_transmuter(
                        shrine, transmuter, shrine_debt_ceiling, seed_amt, receiver, user,
                    );

                    let mut transmute_asset_amts: Span<u128> = array![0, 1000 * pow(10, asset_decimals),].span();

                    loop {
                        match transmute_asset_amts.pop_front() {
                            Option::Some(transmute_asset_amt) => {
                                let mut spy = spy_events(SpyOn::One(transmuter.contract_address));

                                // parametrize amount to sweep
                                let mut sweep_amts: Array<u128> = array![
                                    0, 1, *transmute_asset_amt, *transmute_asset_amt + 1,
                                ];

                                if (*transmute_asset_amt).is_non_zero() {
                                    sweep_amts.append(*transmute_asset_amt - 1);
                                }

                                let mut sweep_amts: Span<u128> = sweep_amts.span();

                                loop {
                                    match sweep_amts.pop_front() {
                                        Option::Some(sweep_amt) => {
                                            start_prank(CheatTarget::One(transmuter.contract_address), user);
                                            transmuter.transmute(*transmute_asset_amt);

                                            let before_receiver_asset_bal: u256 = asset.balance_of(receiver);

                                            start_prank(CheatTarget::One(transmuter.contract_address), admin);
                                            transmuter.sweep(*sweep_amt);

                                            let adjusted_sweep_amt: u128 = min(*transmute_asset_amt, *sweep_amt);

                                            assert(
                                                asset.balance_of(receiver) == before_receiver_asset_bal
                                                    + adjusted_sweep_amt.into(),
                                                'wrong receiver asset bal'
                                            );

                                            if adjusted_sweep_amt.is_non_zero() {
                                                let expected_events = array![
                                                    (
                                                        transmuter.contract_address,
                                                        transmuter_contract::Event::Sweep(
                                                            transmuter_contract::Sweep {
                                                                recipient: receiver, asset_amt: adjusted_sweep_amt
                                                            }
                                                        )
                                                    )
                                                ];
                                                spy.assert_emitted(@expected_events);
                                            }

                                            // reset by sweeping all remaining amount
                                            transmuter.sweep(BoundedInt::max());
                                            assert(
                                                asset.balance_of(transmuter.contract_address).is_zero(), 'sanity check'
                                            );

                                            stop_prank(CheatTarget::One(transmuter.contract_address));
                                        },
                                        Option::None => { break; },
                                    };
                                };
                            },
                            Option::None => { break; },
                        };
                    };
                },
                Option::None => { break; },
            };
        };
    }

    //
    // Tests - Settle
    //

    #[test]
    fn test_settle_parametrized_pass() {
        let shrine_class: ContractClass = shrine_utils::declare_shrine();
        let transmuter_class: ContractClass = transmuter_utils::declare_transmuter();
        let token_class: ContractClass = transmuter_utils::declare_erc20();

        let transmuter_admin: ContractAddress = transmuter_utils::admin();
        let shrine_admin: ContractAddress = shrine_utils::admin();
        let receiver: ContractAddress = transmuter_utils::receiver();
        let user: ContractAddress = transmuter_utils::user();

        let mut transmuter_ids: Span<u32> = array![0, 1].span();

        loop {
            match transmuter_ids.pop_front() {
                Option::Some(transmuter_id) => {
                    // parametrize transmuter and asset
                    let asset: IERC20Dispatcher = if *transmuter_id == 0 {
                        transmuter_utils::mock_wad_usd_stable_deploy(Option::Some(token_class))
                    } else {
                        transmuter_utils::mock_nonwad_usd_stable_deploy(Option::Some(token_class))
                    };
                    let asset_decimals: u8 = asset.decimals();

                    let mut transmute_asset_amts: Span<u128> = array![0, 1000 * pow(10, asset_decimals),].span();

                    loop {
                        match transmute_asset_amts.pop_front() {
                            Option::Some(transmute_asset_amt) => {
                                // parametrize amount of yin in Transmuter at time of settlement
                                let mut transmuter_yin_amts: Array<Wad> = array![
                                    WadZeroable::zero(),
                                    1_u128.into(),
                                    fixed_point_to_wad(*transmute_asset_amt, asset_decimals),
                                    fixed_point_to_wad(*transmute_asset_amt + 1, asset_decimals),
                                ];

                                if (*transmute_asset_amt).is_non_zero() {
                                    transmuter_yin_amts
                                        .append(fixed_point_to_wad(*transmute_asset_amt - 1, asset_decimals));
                                }

                                let mut transmuter_yin_amts: Span<Wad> = transmuter_yin_amts.span();

                                loop {
                                    match transmuter_yin_amts.pop_front() {
                                        Option::Some(transmuter_yin_amt) => {
                                            let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(
                                                Option::Some(shrine_class)
                                            );

                                            let transmuter: ITransmuterDispatcher = transmuter_utils::transmuter_deploy(
                                                Option::Some(transmuter_class),
                                                shrine.contract_address,
                                                asset.contract_address,
                                                receiver,
                                            );

                                            let mut spy = spy_events(SpyOn::One(transmuter.contract_address));

                                            let shrine_debt_ceiling: Wad = transmuter_utils::INITIAL_CEILING.into();
                                            let seed_amt: Wad = (100000 * WAD_ONE).into();

                                            transmuter_utils::setup_shrine_with_transmuter(
                                                shrine, transmuter, shrine_debt_ceiling, seed_amt, receiver, user,
                                            );

                                            start_prank(CheatTarget::One(transmuter.contract_address), user);

                                            // transmute some amount
                                            transmuter.transmute(*transmute_asset_amt);
                                            let transmuted_yin_amt: Wad = transmuter.get_total_transmuted();

                                            stop_prank(CheatTarget::One(transmuter.contract_address));

                                            // set up the transmuter with the necessary yin amt
                                            start_prank(CheatTarget::One(shrine.contract_address), shrine_admin);
                                            shrine.inject(transmuter.contract_address, *transmuter_yin_amt);
                                            stop_prank(CheatTarget::One(shrine.contract_address));

                                            let before_receiver_asset_bal: u256 = asset.balance_of(receiver);
                                            let before_receiver_yin_bal: Wad = shrine.get_yin(receiver);
                                            let before_budget: SignedWad = shrine.get_budget();

                                            start_prank(
                                                CheatTarget::One(transmuter.contract_address), transmuter_admin
                                            );
                                            transmuter.settle();

                                            let mut expected_budget_adjustment = SignedWadZeroable::zero();
                                            let mut leftover_yin_amt = WadZeroable::zero();

                                            if *transmuter_yin_amt < transmuted_yin_amt {
                                                expected_budget_adjustment =
                                                    SignedWad {
                                                        val: (transmuted_yin_amt - *transmuter_yin_amt).val, sign: true
                                                    };
                                            } else {
                                                leftover_yin_amt = *transmuter_yin_amt - transmuted_yin_amt;
                                            }

                                            assert(
                                                shrine.get_budget() == before_budget + expected_budget_adjustment,
                                                'wrong budget'
                                            );
                                            assert(
                                                shrine.get_yin(receiver) == before_receiver_yin_bal + leftover_yin_amt,
                                                'wrong receiver yin'
                                            );
                                            assert(
                                                shrine.get_yin(transmuter.contract_address).is_zero(),
                                                'wrong transmuter yin'
                                            );
                                            assert(
                                                asset.balance_of(receiver) == before_receiver_asset_bal
                                                    + (*transmute_asset_amt).into(),
                                                'wrong receiver asset'
                                            );

                                            assert(
                                                transmuter.get_total_transmuted().is_zero(), 'wrong total transmuted'
                                            );
                                            assert(!transmuter.get_live(), 'not killed');

                                            let deficit: Wad = if expected_budget_adjustment.is_negative() {
                                                expected_budget_adjustment.val.into()
                                            } else {
                                                WadZeroable::zero()
                                            };
                                            let expected_events = array![
                                                (
                                                    transmuter.contract_address,
                                                    transmuter_contract::Event::Settle(
                                                        transmuter_contract::Settle { deficit }
                                                    ),
                                                )
                                            ];
                                            spy.assert_emitted(@expected_events);

                                            stop_prank(CheatTarget::One(transmuter.contract_address));
                                        },
                                        Option::None => { break; },
                                    };
                                };
                            },
                            Option::None => { break; },
                        };
                    };
                },
                Option::None => { break; },
            };
        };
    }

    #[test]
    #[should_panic(expected: ('TR: Transmuter is not live',))]
    fn test_transmute_after_settle_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        transmuter.settle();

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::user());
        transmuter.transmute(1_u128);
    }

    #[test]
    #[should_panic(expected: ('TR: Transmuter is not live',))]
    fn test_reverse_after_settle_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        transmuter.settle();

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::user());
        transmuter.reverse(1_u128.into());
    }

    #[test]
    #[should_panic(expected: ('TR: Transmuter is not live',))]
    fn test_sweep_after_settle_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        transmuter.settle();

        transmuter.sweep(BoundedInt::max());
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_sweep_unauthorized() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), common::badguy());
        transmuter.sweep(BoundedInt::max());
    }

    //
    // Tests - Shutdown
    //

    #[test]
    fn test_kill_and_reclaim_parametrized_pass() {
        let shrine_class: ContractClass = shrine_utils::declare_shrine();
        let transmuter_class: ContractClass = transmuter_utils::declare_transmuter();
        let token_class: ContractClass = transmuter_utils::declare_erc20();

        let admin: ContractAddress = transmuter_utils::admin();
        let receiver: ContractAddress = transmuter_utils::receiver();
        let user: ContractAddress = transmuter_utils::user();

        let mut transmuter_ids: Span<u32> = array![0, 1].span();

        loop {
            match transmuter_ids.pop_front() {
                Option::Some(transmuter_id) => {
                    // parametrize transmuter and asset
                    let asset: IERC20Dispatcher = if *transmuter_id == 0 {
                        transmuter_utils::mock_wad_usd_stable_deploy(Option::Some(token_class))
                    } else {
                        transmuter_utils::mock_nonwad_usd_stable_deploy(Option::Some(token_class))
                    };
                    let asset_decimals: u8 = asset.decimals();
                    let asset_decimal_scale: u128 = pow(10, asset_decimals);
                    let transmute_asset_amt: u128 = 1000 * pow(10, asset_decimals);

                    let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::Some(shrine_class));

                    let transmuter: ITransmuterDispatcher = transmuter_utils::transmuter_deploy(
                        Option::Some(transmuter_class), shrine.contract_address, asset.contract_address, receiver,
                    );

                    let shrine_debt_ceiling: Wad = transmuter_utils::INITIAL_CEILING.into();
                    let seed_amt: Wad = (100000 * WAD_ONE).into();

                    transmuter_utils::setup_shrine_with_transmuter(
                        shrine, transmuter, shrine_debt_ceiling, seed_amt, receiver, user,
                    );

                    let mut spy = spy_events(SpyOn::One(transmuter.contract_address));

                    start_prank(CheatTarget::One(transmuter.contract_address), user);

                    // transmute some amount
                    transmuter.transmute(transmute_asset_amt);
                    let transmuted_yin_amt: Wad = transmuter.get_total_transmuted();

                    start_prank(CheatTarget::One(transmuter.contract_address), admin);
                    transmuter.kill();

                    assert(!transmuter.get_live(), 'not killed');

                    let expected_events = array![
                        (
                            transmuter.contract_address,
                            transmuter_contract::Event::Killed(transmuter_contract::Killed {}),
                        )
                    ];
                    spy.assert_emitted(@expected_events);

                    transmuter.enable_reclaim();

                    start_prank(CheatTarget::One(transmuter.contract_address), user);

                    let asset_error_margin: u128 = asset_decimal_scale / 100;
                    let mut expected_events = ArrayTrait::new();

                    // first reclaim for 10% of original transmuted amount
                    let before_user_asset_bal: u256 = asset.balance_of(user);
                    let before_user_yin_bal: Wad = shrine.get_yin(user);

                    let first_reclaim_pct: Ray = (RAY_PERCENT * 10).into();
                    let first_reclaim_yin_amt: Wad = wadray::rmul_wr(transmuted_yin_amt, first_reclaim_pct);
                    let preview: u128 = transmuter.preview_reclaim(first_reclaim_yin_amt);
                    let expected_first_reclaim_asset_amt: u128 = wadray::rmul_wr(
                        transmute_asset_amt.into(), first_reclaim_pct
                    )
                        .val;
                    common::assert_equalish(
                        preview, expected_first_reclaim_asset_amt, asset_error_margin, 'wrong preview reclaim amt #1',
                    );

                    transmuter.reclaim(first_reclaim_yin_amt);
                    let first_user_asset_bal: u256 = asset.balance_of(user);
                    assert(first_user_asset_bal == before_user_asset_bal + preview.into(), 'wrong reclaim amt #1');

                    let first_user_yin_bal: Wad = shrine.get_yin(user);
                    assert(first_user_yin_bal == before_user_yin_bal - first_reclaim_yin_amt, 'wrong user yin #1');

                    expected_events
                        .append(
                            (
                                transmuter.contract_address,
                                transmuter_contract::Event::Reclaim(
                                    transmuter_contract::Reclaim {
                                        user, asset_amt: preview, yin_amt: first_reclaim_yin_amt,
                                    }
                                )
                            )
                        );

                    // second reclaim for 35% of original transmuted amount
                    let second_reclaim_pct: Ray = (RAY_PERCENT * 35).into();
                    let second_reclaim_yin_amt: Wad = wadray::rmul_wr(transmuted_yin_amt, second_reclaim_pct);
                    let preview: u128 = transmuter.preview_reclaim(second_reclaim_yin_amt);
                    let expected_second_reclaim_asset_amt: u128 = wadray::rmul_wr(
                        transmute_asset_amt.into(), second_reclaim_pct
                    )
                        .val;
                    common::assert_equalish(
                        preview, expected_second_reclaim_asset_amt, asset_error_margin, 'wrong preview reclaim amt #2',
                    );

                    transmuter.reclaim(second_reclaim_yin_amt);
                    let second_user_asset_bal: u256 = asset.balance_of(user);
                    assert(second_user_asset_bal == first_user_asset_bal + preview.into(), 'wrong reclaim amt #2');

                    let second_user_yin_bal: Wad = shrine.get_yin(user);
                    assert(second_user_yin_bal == first_user_yin_bal - second_reclaim_yin_amt, 'wrong user yin #2');

                    expected_events
                        .append(
                            (
                                transmuter.contract_address,
                                transmuter_contract::Event::Reclaim(
                                    transmuter_contract::Reclaim {
                                        user, asset_amt: preview, yin_amt: second_reclaim_yin_amt,
                                    }
                                )
                            )
                        );

                    // third reclaim for 100% of original transmuted amount, which should be capped
                    // to what is remaining
                    let third_reclaim_yin_amt: Wad = transmuted_yin_amt;
                    let reclaimable_yin: Wad = transmuter.get_total_transmuted();
                    let preview: u128 = transmuter.preview_reclaim(third_reclaim_yin_amt);
                    let expected_third_reclaim_asset_amt: u128 = asset
                        .balance_of(transmuter.contract_address)
                        .try_into()
                        .unwrap();
                    common::assert_equalish(
                        preview, expected_third_reclaim_asset_amt, asset_error_margin, 'wrong preview reclaim amt #3',
                    );

                    transmuter.reclaim(third_reclaim_yin_amt);
                    let third_user_asset_bal: u256 = asset.balance_of(user);
                    assert(third_user_asset_bal == second_user_asset_bal + preview.into(), 'wrong reclaim amt #3');

                    let third_user_yin_bal: Wad = shrine.get_yin(user);
                    assert(third_user_yin_bal == second_user_yin_bal - reclaimable_yin, 'wrong user yin #3');

                    expected_events
                        .append(
                            (
                                transmuter.contract_address,
                                transmuter_contract::Event::Reclaim(
                                    transmuter_contract::Reclaim { user, asset_amt: preview, yin_amt: reclaimable_yin, }
                                )
                            )
                        );
                    spy.assert_emitted(@expected_events);

                    // preview reclaim when transmuter has no assets
                    assert(transmuter.preview_reclaim(third_reclaim_yin_amt).is_zero(), 'preview should be zero');

                    stop_prank(CheatTarget::One(transmuter.contract_address));
                },
                Option::None => { break; },
            };
        };
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_kill_unauthorized() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), common::badguy());
        transmuter.kill();
    }

    #[test]
    #[should_panic(expected: ('TR: Transmuter is not live',))]
    fn test_transmute_after_kill_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        transmuter.kill();

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::user());
        transmuter.transmute(1_u128);
    }

    #[test]
    #[should_panic(expected: ('TR: Transmuter is not live',))]
    fn test_reverse_after_kill_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        transmuter.kill();

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::user());
        transmuter.transmute(1_u128.into());
    }

    #[test]
    #[should_panic(expected: ('TR: Transmuter is not live',))]
    fn test_sweep_after_kill_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        transmuter.kill();

        transmuter.sweep(BoundedInt::max());
    }

    #[test]
    #[should_panic(expected: ('TR: Reclaim unavailable',))]
    fn test_reclaim_disabled_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        transmuter.kill();

        transmuter.reclaim(BoundedInt::max());
    }

    #[test]
    #[should_panic(expected: ('TR: Transmuter is live',))]
    fn test_enable_reclaim_while_live_fail() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), transmuter_utils::admin());
        transmuter.enable_reclaim();
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_enable_reclaim_unauthorized() {
        let (_, transmuter, _) = transmuter_utils::shrine_with_mock_wad_usd_stable_transmuter(
            Option::None, Option::None
        );

        start_prank(CheatTarget::One(transmuter.contract_address), common::badguy());
        transmuter.enable_reclaim();
    }
}
