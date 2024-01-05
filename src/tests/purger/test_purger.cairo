mod test_purger {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use cmp::{max, min};
    use core::option::OptionTrait;
    use integer::BoundedU256;
    use opus::core::absorber::absorber as absorber_contract;
    use opus::core::purger::purger as purger_contract;
    use opus::core::roles::purger_roles;
    use opus::core::shrine::shrine as shrine_contract;
    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::IAbsorber::{IAbsorberDispatcher, IAbsorberDispatcherTrait};
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::mock::flash_liquidator::{IFlashLiquidatorDispatcher, IFlashLiquidatorDispatcherTrait};
    use opus::tests::absorber::utils::absorber_utils;
    use opus::tests::common;
    use opus::tests::flash_mint::utils::flash_mint_utils;
    use opus::tests::purger::utils::purger_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::{AssetBalance, Health};
    use opus::utils::math::{pow, scale_u128_by_ray};
    use snforge_std::{
        start_prank, stop_prank, start_warp, CheatTarget, PrintTrait, spy_events, SpyOn, EventSpy, EventAssertions,
        EventFetcher, event_name_hash
    };
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::{BoundedWad, Ray, RayZeroable, RAY_ONE, RAY_PERCENT, Wad, WadZeroable, WAD_ONE};

    //
    // Tests - Setup
    //

    #[test]
    fn test_purger_setup() {
        let mut spy = spy_events(SpyOn::All);
        let (_, _, _, _, purger, _, _) = purger_utils::purger_deploy(Option::None);

        let purger_ac = IAccessControlDispatcher { contract_address: purger.contract_address };
        assert(
            purger_ac.get_roles(purger_utils::admin()) == purger_roles::default_admin_role(), 'wrong role for admin'
        );

        let expected_events = array![
            (
                purger.contract_address,
                purger_contract::Event::PenaltyScalarUpdated(
                    purger_contract::PenaltyScalarUpdated { new_scalar: RAY_ONE.into(), }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    //
    // Tests - Setters
    //

    #[test]
    fn test_set_penalty_scalar_pass() {
        let (shrine, abbot, seer, _, purger, yangs, gates) = purger_utils::purger_deploy(Option::None);
        let mut spy = spy_events(SpyOn::One(purger.contract_address));

        purger_utils::create_whale_trove(abbot, yangs, gates);

        let target_trove: u64 = purger_utils::funded_healthy_trove(
            abbot, yangs, gates, purger_utils::TARGET_TROVE_YIN.into()
        );

        // Set thresholds to 91% so we can check the scalar is applied to the penalty
        let threshold: Ray = (91 * RAY_PERCENT).into();
        purger_utils::set_thresholds(shrine, yangs, threshold);

        let target_trove_health: Health = shrine.get_trove_health(target_trove);
        let target_ltv: Ray = threshold + RAY_PERCENT.into(); // 92%
        purger_utils::lower_prices_to_raise_trove_ltv(
            shrine, seer, yangs, target_trove_health.value, target_trove_health.debt, target_ltv
        );

        // sanity check that LTV is at the target liquidation LTV
        let target_trove_health: Health = shrine.get_trove_health(target_trove);
        let error_margin: Ray = 2000000_u128.into();
        common::assert_equalish(target_trove_health.ltv, target_ltv, error_margin, 'LTV sanity check');

        let mut expected_events: Array<(ContractAddress, purger_contract::Event)> = ArrayTrait::new();

        // Set scalar to 1
        start_prank(CheatTarget::One(purger.contract_address), purger_utils::admin());
        let penalty_scalar: Ray = RAY_ONE.into();
        purger.set_penalty_scalar(penalty_scalar);

        assert(purger.get_penalty_scalar() == penalty_scalar, 'wrong penalty scalar #1');

        let (penalty, _, _) = purger.preview_absorb(target_trove).expect('Should be absorbable');
        let expected_penalty: Ray = 41000000000000000000000000_u128.into(); // 4.1%
        let error_margin: Ray = (RAY_PERCENT / 100).into(); // 0.01%
        common::assert_equalish(penalty, expected_penalty, error_margin, 'wrong scalar penalty #1');

        expected_events
            .append(
                (
                    purger.contract_address,
                    purger_contract::Event::PenaltyScalarUpdated(
                        purger_contract::PenaltyScalarUpdated { new_scalar: penalty_scalar, }
                    )
                )
            );

        // Set scalar to 0.97
        let penalty_scalar: Ray = purger_contract::MIN_PENALTY_SCALAR.into();
        purger.set_penalty_scalar(penalty_scalar);

        assert(purger.get_penalty_scalar() == penalty_scalar, 'wrong penalty scalar #2');

        let (penalty, _, _) = purger.preview_absorb(target_trove).expect('Should be absorbable');
        let expected_penalty: Ray = 10700000000000000000000000_u128.into(); // 1.07%
        common::assert_equalish(penalty, expected_penalty, error_margin, 'wrong scalar penalty #2');

        expected_events
            .append(
                (
                    purger.contract_address,
                    purger_contract::Event::PenaltyScalarUpdated(
                        purger_contract::PenaltyScalarUpdated { new_scalar: penalty_scalar, }
                    )
                )
            );

        // Set scalar to 1.06
        let penalty_scalar: Ray = purger_contract::MAX_PENALTY_SCALAR.into();
        purger.set_penalty_scalar(penalty_scalar);

        assert(purger.get_penalty_scalar() == penalty_scalar, 'wrong penalty scalar #3');

        let (penalty, _, _) = purger.preview_absorb(target_trove).expect('Should be absorbable');
        let expected_penalty: Ray = 54300000000000000000000000_u128.into(); // 5.43%
        common::assert_equalish(penalty, expected_penalty, error_margin, 'wrong scalar penalty #3');

        expected_events
            .append(
                (
                    purger.contract_address,
                    purger_contract::Event::PenaltyScalarUpdated(
                        purger_contract::PenaltyScalarUpdated { new_scalar: penalty_scalar, }
                    )
                )
            );

        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_penalty_scalar_lower_bound() {
        let (shrine, abbot, seer, _, purger, yangs, gates) = purger_utils::purger_deploy(Option::None);

        purger_utils::create_whale_trove(abbot, yangs, gates);

        let target_trove: u64 = purger_utils::funded_healthy_trove(
            abbot, yangs, gates, purger_utils::TARGET_TROVE_YIN.into()
        );

        // Set thresholds to 90% so we can check the scalar is not applied to the penalty
        let threshold: Ray = (90 * RAY_PERCENT).into();
        purger_utils::set_thresholds(shrine, yangs, threshold);

        let target_trove_health: Health = shrine.get_trove_health(target_trove);
        // 91%; Note that if a penalty scalar is applied, then the trove would be absorbable
        // at this LTV because the penalty would be the maximum possible penalty. On the other
        // hand, if a penalty scalar is not applied, then the maximum possible penalty will be
        // reached from 92.09% onwards, so the trove would not be absorbable at this LTV
        let target_ltv: Ray = 910000000000000000000000000_u128.into();
        purger_utils::lower_prices_to_raise_trove_ltv(
            shrine, seer, yangs, target_trove_health.value, target_trove_health.debt, target_ltv
        );

        let target_trove_health: Health = shrine.get_trove_health(target_trove);
        // sanity check that threshold is correct
        assert(target_trove_health.threshold == threshold, 'threshold sanity check');

        // sanity check that LTV is at the target liquidation LTV
        let error_margin: Ray = 100000000_u128.into();
        common::assert_equalish(target_trove_health.ltv, target_ltv, error_margin, 'LTV sanity check');

        assert(purger.preview_absorb(target_trove).is_none(), 'should not be absorbable #1');

        // Set scalar to 1.06 and check the trove is still not absorbable.
        start_prank(CheatTarget::One(purger.contract_address), purger_utils::admin());
        let penalty_scalar: Ray = purger_contract::MAX_PENALTY_SCALAR.into();
        purger.set_penalty_scalar(penalty_scalar);

        assert(purger.preview_absorb(target_trove).is_none(), 'should not be absorbable #2');
    }

    #[test]
    #[should_panic(expected: ('PU: Invalid scalar',))]
    fn test_set_penalty_scalar_too_low_fail() {
        let (_, _, _, _, purger, _, _) = purger_utils::purger_deploy(Option::None);

        start_prank(CheatTarget::One(purger.contract_address), purger_utils::admin());
        purger.set_penalty_scalar((purger_contract::MIN_PENALTY_SCALAR - 1).into());
    }

    #[test]
    #[should_panic(expected: ('PU: Invalid scalar',))]
    fn test_set_penalty_scalar_too_high_fail() {
        let (_, _, _, _, purger, _, _) = purger_utils::purger_deploy(Option::None);

        start_prank(CheatTarget::One(purger.contract_address), purger_utils::admin());
        purger.set_penalty_scalar((purger_contract::MAX_PENALTY_SCALAR + 1).into());
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_penalty_scalar_unauthorized_fail() {
        let (_, _, _, _, purger, _, _) = purger_utils::purger_deploy(Option::None);

        start_prank(CheatTarget::One(purger.contract_address), common::badguy());
        purger.set_penalty_scalar(RAY_ONE.into());
    }

    //
    // Tests - Liquidate
    //

    // This test fixes the trove's debt to 1,000 in order to test the ground truth values of the
    // penalty and close amount when LTV is at threshold. The error margin is relaxed because
    // `lower_prices_to_raise_trove_ltv` may not put the trove in the exact LTV as the threshold.
    //
    // For low thresholds (arbitraily defined as 2% or less), the trove's debt is set based on the
    // value instead. See inline comments for more details.
    #[test]
    fn test_preview_liquidate_parametrized() {
        let classes = Option::Some(purger_utils::declare_contracts());

        let mut thresholds: Span<Ray> = purger_utils::interesting_thresholds_for_liquidation();

        let default_trove_debt: Wad = (WAD_ONE * 1000).into();

        // non-recovery mode
        let mut expected_max_close_amts: Span<Wad> = array![
            1_u128.into(), // 1 wei (0% threshold)
            13904898408200000000_u128.into(), // 13.904... (1% threshold)
            284822000000000000000_u128.into(), // 284.822 (70% threshold)
            386997000000000000000_u128.into(), // 386.997 (80% threshold)
            603509000000000000000_u128.into(), // 603.509 (90% threshold)
            908381000000000000000_u128.into(), // 908.381 (96% threshold)
            992098000000000000000_u128.into(), // 992.098 (97% threshold)
            default_trove_debt, // (99% threshold)
        ]
            .span();

        let mut expected_penalty: Span<Ray> = array![
            (3 * RAY_PERCENT).into(), // 3% (0% threshold)
            (3 * RAY_PERCENT).into(), // 3% (1% threshold)
            (3 * RAY_PERCENT).into(), // 3% (70% threshold)
            (3 * RAY_PERCENT).into(), // 3% (80% threshold)
            (3 * RAY_PERCENT).into(), // 3% (90% threshold)
            (3 * RAY_PERCENT).into(), // 3% (96% threshold)
            (3 * RAY_PERCENT).into(), // 3% (97% threshold)
            10101000000000000000000000_u128.into(), // 1.0101% (99% threshold)
        ]
            .span();

        // recovery mode
        let mut expected_rm_max_close_amts: Span<Wad> = array![
            1_u128.into(), // 1 wei (0% threshold)
            132807337144000000000_u128.into(), // 132.807... (1% threshold)
            734310354751000000000_u128.into(), // 734.310... (70% threshold, 49% rm threshold)
            854503464203000000000_u128.into(), // 854.503... (80% threshold, 56% rm threshold)
            default_trove_debt, // (90% threshold, 63% rm threshold)
            default_trove_debt, // (96% threshold. 67.2% rm threshold)
            default_trove_debt, // (97% threshold, 67.9% rm threshold)
            default_trove_debt, // (99% threshold, 69.3% rm threshold)
        ]
            .span();

        let mut expected_rm_penalty: Span<Ray> = array![
            (3 * RAY_PERCENT).into(), // 3% (0% threshold)
            (3 * RAY_PERCENT).into(), // 3% (1% threshold)
            purger_contract::MAX_PENALTY.into(), // 3% (70% threshold, 49% rm threshold)
            purger_contract::MAX_PENALTY.into(), // 3% (80% threshold, 56% rm threshold)
            purger_contract::MAX_PENALTY.into(), // 3% (90% threshold)
            purger_contract::MAX_PENALTY.into(), // 3% (96% threshold)
            purger_contract::MAX_PENALTY.into(), // 3% (97% threshold)
            10101000000000000000000000_u128.into(), // 1.0101% (99% threshold)
        ]
            .span();

        let mut expected_rm_thresholds: Span<Ray> = array![
            RayZeroable::zero(),
            // Expected threshold = 1% * 0.7 * (1% / 80%) = 0.00875%
            // Capped at 1% / 2 = 0.5%
            5000000000000000000000000_u128.into(),
            // Expected threshold = 70% * 0.7 * (70% / 70%) = 49%
            // which is greater than 70% / 2 = 35%
            (49 * RAY_PERCENT).into(),
            // Expected threshold = 80% * 0.7 * (80% / 80%) = 56%
            // which is greater than 80% / 2 = 40%
            (56 * RAY_PERCENT).into(),
            // Expected threshold = 90% * 0.7 * (90% / 90%) = 63%
            // which is greater than 90% / 2 = 45%
            (63 * RAY_PERCENT).into(),
            // Expected threshold = 96% * 0.7 * (96% / 96%) = 67.2%
            // which is greater than 96% / 2 = 48%
            (67 * RAY_PERCENT + (RAY_PERCENT / 5)).into(),
            // Expected threshold = 97% * 0.7 * (97% / 97%) = 67.9%
            // which is greater than 97% / 2 = 48.5%
            (67 * RAY_PERCENT + (RAY_PERCENT / 10) * 9).into(),
            // Expected threshold = 99% * 0.7 * (99% / 99%) = 69.3%
            // which is greater than 99% / 2 = 49.5%
            (69 * RAY_PERCENT + (RAY_PERCENT / 10) * 3).into(),
        ]
            .span();

        let dummy_threshold: Ray = (80 * RAY_PERCENT).into();

        loop {
            match thresholds.pop_front() {
                Option::Some(threshold) => {
                    let mut is_recovery_mode_fuzz: Span<bool> = array![false, true].span();
                    loop {
                        match is_recovery_mode_fuzz.pop_front() {
                            Option::Some(is_recovery_mode) => {
                                let (shrine, abbot, seer, absorber, purger, yangs, gates) = purger_utils::purger_deploy(
                                    classes
                                );

                                if !(*is_recovery_mode) {
                                    purger_utils::create_whale_trove(abbot, yangs, gates);
                                }

                                // If the threshold is below 2%, we set the trove's debt such that
                                // we get the desired ltv for the trove from the get-go in order to
                                // avoid overflow issues in `lower_prices_to_raise_trove_ltv`.
                                //
                                // This is because `lower_prices_to_raise_trove_ltv` is designed for
                                // raising the trove's LTV to the given *higher* LTV,
                                // not lowering it.
                                //
                                // NOTE: This 2% cut off is completely arbitrary and meant only for excluding
                                // the two test cases in `interesting_thresholds_for_liquidation`: 0% and 1%.
                                // If more low thresholds were added that were above 2% but below the
                                // starting LTV of the trove, then this cutoff would need to be adjusted.
                                let mut dummy_trove: u64 = 0;
                                let trove_debt = if *threshold > (RAY_PERCENT * 2).into() {
                                    default_trove_debt
                                } else {
                                    let target_trove_yang_amts: Span<Wad> = array![
                                        purger_utils::TARGET_TROVE_ETH_DEPOSIT_AMT.into(),
                                        (purger_utils::TARGET_TROVE_WBTC_DEPOSIT_AMT * pow(10_u128, 10)).into()
                                    ]
                                        .span();

                                    let trove_value: Wad = purger_utils::get_sum_of_value(
                                        shrine, yangs, target_trove_yang_amts
                                    );

                                    if (*is_recovery_mode) {
                                        // Create another trove to trigger recovery mode
                                        dummy_trove =
                                            purger_utils::funded_healthy_trove(abbot, yangs, gates, default_trove_debt);
                                    }

                                    wadray::rmul_wr(trove_value, *threshold) + 1_u128.into()
                                };

                                let target_trove: u64 = purger_utils::funded_healthy_trove(
                                    abbot, yangs, gates, trove_debt
                                );

                                purger_utils::set_thresholds(shrine, yangs, *threshold);

                                let target_trove_health: Health = shrine.get_trove_health(target_trove);

                                if *threshold > (RAY_PERCENT * 2).into() {
                                    purger_utils::lower_prices_to_raise_trove_ltv(
                                        shrine,
                                        seer,
                                        yangs,
                                        target_trove_health.value,
                                        target_trove_health.debt,
                                        *threshold
                                    );
                                } else if (*is_recovery_mode) {
                                    let dummy_trove_health: Health = shrine.get_trove_health(dummy_trove);

                                    purger_utils::lower_prices_to_raise_trove_ltv(
                                        shrine,
                                        seer,
                                        yangs,
                                        dummy_trove_health.value,
                                        dummy_trove_health.debt,
                                        dummy_threshold
                                    );
                                }

                                let target_trove_updated_health: Health = shrine.get_trove_health(target_trove);
                                purger_utils::assert_trove_is_liquidatable(
                                    shrine, purger, target_trove, target_trove_updated_health.ltv
                                );

                                if (*is_recovery_mode) {
                                    let expected_rm_threshold: Ray = *expected_rm_thresholds.pop_front().unwrap();
                                    common::assert_equalish(
                                        target_trove_updated_health.threshold,
                                        expected_rm_threshold,
                                        (RAY_PERCENT / 100).into(),
                                        'wrong rm threshold'
                                    );
                                }

                                let (penalty, max_close_amt) = purger
                                    .preview_liquidate(target_trove)
                                    .expect('Should be liquidatable');

                                let expected_penalty = if (*is_recovery_mode) {
                                    *expected_rm_penalty.pop_front().unwrap()
                                } else {
                                    *expected_penalty.pop_front().unwrap()
                                };

                                common::assert_equalish(
                                    penalty, expected_penalty, (RAY_ONE / 10).into(), 'wrong penalty'
                                );

                                let expected_max_close_amt = if (*is_recovery_mode) {
                                    *expected_rm_max_close_amts.pop_front().unwrap()
                                } else {
                                    *expected_max_close_amts.pop_front().unwrap()
                                };

                                common::assert_equalish(
                                    max_close_amt, expected_max_close_amt, (WAD_ONE * 2).into(), 'wrong max close amt'
                                );
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
    fn test_liquidate_pass() {
        let searcher_start_yin: Wad = purger_utils::SEARCHER_YIN.into();
        let (shrine, abbot, seer, _, purger, yangs, gates) = purger_utils::purger_deploy_with_searcher(
            searcher_start_yin, Option::None
        );
        let mut spy = spy_events(SpyOn::One(purger.contract_address));

        purger_utils::create_whale_trove(abbot, yangs, gates);

        let initial_trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
        let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, initial_trove_debt);

        // Accrue some interest
        common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

        let shrine_health: Health = shrine.get_shrine_health();
        let before_total_debt: Wad = shrine_health.debt;
        let target_trove_start_health: Health = shrine.get_trove_health(target_trove);
        let accrued_interest: Wad = target_trove_start_health.debt - initial_trove_debt;
        // Sanity check that some interest has accrued
        assert(accrued_interest.is_non_zero(), 'no interest accrued');

        let target_ltv: Ray = (target_trove_start_health.threshold.val + 1).into();
        purger_utils::lower_prices_to_raise_trove_ltv(
            shrine, seer, yangs, target_trove_start_health.value, target_trove_start_health.debt, target_ltv
        );

        // Sanity check that LTV is at the target liquidation LTV
        let target_trove_updated_start_health: Health = shrine.get_trove_health(target_trove);
        purger_utils::assert_trove_is_liquidatable(shrine, purger, target_trove, target_trove_updated_start_health.ltv);

        let (penalty, max_close_amt) = purger.preview_liquidate(target_trove).expect('Should be liquidatable');
        let searcher: ContractAddress = purger_utils::searcher();

        let before_searcher_asset_bals: Span<Span<u128>> = common::get_token_balances(yangs, array![searcher].span());

        start_prank(CheatTarget::One(purger.contract_address), searcher);
        let freed_assets: Span<AssetBalance> = purger.liquidate(target_trove, BoundedWad::max(), searcher);

        // Assert that total debt includes accrued interest on liquidated trove
        let shrine_health: Health = shrine.get_shrine_health();
        let after_total_debt: Wad = shrine_health.debt;
        assert(after_total_debt == before_total_debt + accrued_interest - max_close_amt, 'wrong total debt');

        // Check that LTV is close to safety margin
        let target_trove_after_health: Health = shrine.get_trove_health(target_trove);
        assert(
            target_trove_after_health.debt == target_trove_updated_start_health.debt - max_close_amt,
            'wrong debt after liquidation'
        );

        purger_utils::assert_ltv_at_safety_margin(target_trove_start_health.threshold, target_trove_after_health.ltv);

        // Check searcher yin balance
        assert(shrine.get_yin(searcher) == searcher_start_yin - max_close_amt, 'wrong searcher yin balance');

        let (expected_freed_pct, expected_freed_amts) = purger_utils::get_expected_liquidation_assets(
            purger_utils::target_trove_yang_asset_amts(),
            target_trove_updated_start_health.value,
            max_close_amt,
            penalty,
            Option::None
        );
        let expected_freed_assets: Span<AssetBalance> = common::combine_assets_and_amts(yangs, expected_freed_amts);

        // Check that searcher has received collateral
        purger_utils::assert_received_assets(
            before_searcher_asset_bals,
            common::get_token_balances(yangs, array![searcher].span()),
            expected_freed_assets,
            10_u128, // error margin
            'wrong searcher asset balance',
        );

        common::assert_asset_balances_equalish(
            freed_assets, expected_freed_assets, 10_u128, // error margin
             'wrong freed asset amount'
        );

        let expected_events = array![
            (
                purger.contract_address,
                purger_contract::Event::Purged(
                    purger_contract::Purged {
                        trove_id: target_trove,
                        purge_amt: max_close_amt,
                        percentage_freed: expected_freed_pct,
                        funder: searcher,
                        recipient: searcher,
                        freed_assets: freed_assets
                    }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);

        shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    fn test_liquidate_with_flashmint_pass() {
        let (shrine, abbot, seer, _, purger, yangs, gates) = purger_utils::purger_deploy_with_searcher(
            purger_utils::SEARCHER_YIN.into(), Option::None
        );

        purger_utils::create_whale_trove(abbot, yangs, gates);

        let target_trove: u64 = purger_utils::funded_healthy_trove(
            abbot, yangs, gates, purger_utils::TARGET_TROVE_YIN.into()
        );
        let flashmint = flash_mint_utils::flashmint_deploy(shrine.contract_address);
        let flash_liquidator = purger_utils::flash_liquidator_deploy(
            shrine.contract_address,
            abbot.contract_address,
            flashmint.contract_address,
            purger.contract_address,
            Option::None
        );

        // Fund flash liquidator contract with some collateral to open a trove
        // but not draw any debt
        common::fund_user(flash_liquidator.contract_address, yangs, absorber_utils::provider_asset_amts());

        // Accrue some interest
        common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

        // Update prices and multiplier 

        let target_trove_start_health: Health = shrine.get_trove_health(target_trove);
        let target_ltv: Ray = (target_trove_start_health.threshold.val + 1).into();
        purger_utils::lower_prices_to_raise_trove_ltv(
            shrine, seer, yangs, target_trove_start_health.value, target_trove_start_health.debt, target_ltv
        );

        // Sanity check that LTV is at the target liquidation LTV
        let target_trove_updated_start_health: Health = shrine.get_trove_health(target_trove);
        purger_utils::assert_trove_is_liquidatable(shrine, purger, target_trove, target_trove_updated_start_health.ltv);
        let (_, max_close_amt) = purger.preview_liquidate(target_trove).expect('Should be liquidatable');

        let searcher: ContractAddress = purger_utils::searcher();

        start_prank(CheatTarget::One(flash_liquidator.contract_address), searcher);
        flash_liquidator.flash_liquidate(target_trove, yangs, gates);

        // Check that LTV is close to safety margin
        let target_trove_after_health: Health = shrine.get_trove_health(target_trove);
        assert(
            target_trove_after_health.debt == target_trove_updated_start_health.debt - max_close_amt,
            'wrong debt after liquidation'
        );

        purger_utils::assert_ltv_at_safety_margin(target_trove_start_health.threshold, target_trove_after_health.ltv);

        shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
    }

    // This test parametrizes over thresholds (by setting all yangs thresholds to the given value)
    // and the LTV at liquidation, and checks for the following
    // 1. LTV has decreased
    // 2. trove's debt is reduced by the close amount
    // 3. If it is not a full liquidation, then the post-liquidation LTV is at the target safety margin
    fn test_liquidate(mut thresholds: Span<Ray>, expected_safe_ltv_count: usize) {
        let classes = Option::Some(purger_utils::declare_contracts());

        let mut safe_ltv_count: usize = 0;

        let low_ltv_cutoff: Ray = (2 * RAY_PERCENT).into();

        let dummy_threshold: Ray = (80 * RAY_PERCENT).into();

        loop {
            match thresholds.pop_front() {
                Option::Some(threshold) => {
                    let mut target_ltvs: Span<Ray> = array![
                        (*threshold.val + 1).into(), //just above threshold
                        *threshold + RAY_PERCENT.into(), // 1% above threshold
                        // halfway between threshold and 100%
                        *threshold + ((RAY_ONE.into() - *threshold).val / 2).into(),
                        (RAY_ONE - RAY_PERCENT).into(), // 99%
                        (RAY_ONE + RAY_PERCENT).into() // 101%
                    ]
                        .span();

                    // Assert that we hit the branch for safety margin check at least once per threshold
                    // If the threshold is zero we add to the `safe_ltv_count` and set this to true,
                    // thereby skipping this check for the given threshold, since a
                    // threshold of zero necessitates a full liquidation in all cases.
                    let mut safety_margin_achieved: bool = if (*threshold).is_non_zero() {
                        false
                    } else {
                        safe_ltv_count += 1;
                        true
                    };

                    // Inner loop iterating over LTVs at liquidation
                    loop {
                        match target_ltvs.pop_front() {
                            Option::Some(target_ltv) => {
                                let mut is_recovery_mode_fuzz: Span<bool> = array![false, true].span();

                                loop {
                                    match is_recovery_mode_fuzz.pop_front() {
                                        Option::Some(is_recovery_mode) => {
                                            let searcher_start_yin: Wad = purger_utils::SEARCHER_YIN.into();
                                            let (shrine, abbot, seer, _, purger, yangs, gates) =
                                                purger_utils::purger_deploy_with_searcher(
                                                searcher_start_yin, classes
                                            );

                                            let mut spy = spy_events(SpyOn::One(purger.contract_address));

                                            if !(*is_recovery_mode) {
                                                purger_utils::create_whale_trove(abbot, yangs, gates);
                                            }

                                            // NOTE: This 2% cut off is completely arbitrary and meant only for excluding
                                            // the two test cases in `interesting_thresholds_for_liquidation`: 0% and 1%.
                                            // If more low thresholds were added that were above 2% but below the
                                            // starting LTV of the trove, then this cutoff would need to be adjusted.
                                            let mut dummy_trove: u64 = 0;
                                            let target_ltv_above_cutoff = *target_ltv > low_ltv_cutoff;
                                            let trove_debt: Wad = if target_ltv_above_cutoff {
                                                // If target_ltv is above 2%, then we can set the trove's debt
                                                // to `TARGET_TROVE_YIN` and adjust prices in order to reach
                                                // the target LTV
                                                purger_utils::TARGET_TROVE_YIN.into()
                                            } else {
                                                // Otherwise, we set the debt for the trove such that we get
                                                // the desired ltv for the trove from the get-go in order
                                                // to avoid overflow issues in lower_prices_to_raise_trove_ltv
                                                //
                                                // This is because lower_prices_to_raise_trove_ltv is designed for
                                                // raising the trove's LTV to the given *higher* LTV,
                                                // not lowering it.
                                                let target_trove_yang_amts: Span<Wad> = array![
                                                    purger_utils::TARGET_TROVE_ETH_DEPOSIT_AMT.into(),
                                                    (purger_utils::TARGET_TROVE_WBTC_DEPOSIT_AMT * pow(10_u128, 10))
                                                        .into()
                                                ]
                                                    .span();

                                                let trove_value: Wad = purger_utils::get_sum_of_value(
                                                    shrine, yangs, target_trove_yang_amts
                                                );

                                                if (*is_recovery_mode) {
                                                    // Create another trove to trigger recovery mode
                                                    dummy_trove =
                                                        purger_utils::funded_healthy_trove(
                                                            abbot, yangs, gates, purger_utils::TARGET_TROVE_YIN.into()
                                                        );
                                                }

                                                wadray::rmul_wr(trove_value, *target_ltv) + 1_u128.into()
                                            };

                                            let target_trove: u64 = purger_utils::funded_healthy_trove(
                                                abbot, yangs, gates, trove_debt
                                            );

                                            // Set thresholds to provided value
                                            purger_utils::set_thresholds(shrine, yangs, *threshold);

                                            // Accrue some interest
                                            common::advance_intervals_and_refresh_prices_and_multiplier(
                                                shrine, yangs, 500
                                            );

                                            let target_trove_start_health: Health = shrine
                                                .get_trove_health(target_trove);

                                            if target_ltv_above_cutoff {
                                                purger_utils::lower_prices_to_raise_trove_ltv(
                                                    shrine,
                                                    seer,
                                                    yangs,
                                                    target_trove_start_health.value,
                                                    target_trove_start_health.debt,
                                                    *target_ltv
                                                );
                                            } else {
                                                if (*is_recovery_mode) {
                                                    let dummy_trove_health: Health = shrine
                                                        .get_trove_health(dummy_trove);

                                                    purger_utils::lower_prices_to_raise_trove_ltv(
                                                        shrine,
                                                        seer,
                                                        yangs,
                                                        dummy_trove_health.value,
                                                        dummy_trove_health.debt,
                                                        dummy_threshold
                                                    );
                                                }
                                            }

                                            // Get the updated values after adjusting prices
                                            // The threshold may have changed if in recovery mode
                                            let target_trove_updated_start_health: Health = shrine
                                                .get_trove_health(target_trove);

                                            let (penalty, max_close_amt) = purger
                                                .preview_liquidate(target_trove)
                                                .expect('Should be liquidatable');

                                            let searcher: ContractAddress = purger_utils::searcher();
                                            start_prank(CheatTarget::One(purger.contract_address), searcher);
                                            let freed_assets: Span<AssetBalance> = purger
                                                .liquidate(target_trove, BoundedWad::max(), searcher);

                                            // Check that LTV is close to safety margin
                                            let target_trove_after_health: Health = shrine
                                                .get_trove_health(target_trove);

                                            let is_fully_liquidated: bool = target_trove_updated_start_health
                                                .debt == max_close_amt;
                                            if !is_fully_liquidated {
                                                purger_utils::assert_ltv_at_safety_margin(
                                                    target_trove_updated_start_health.threshold,
                                                    target_trove_after_health.ltv
                                                );

                                                assert(
                                                    target_trove_after_health
                                                        .debt == target_trove_updated_start_health
                                                        .debt
                                                        - max_close_amt,
                                                    'wrong debt after liquidation'
                                                );

                                                if !safety_margin_achieved {
                                                    safe_ltv_count += 1;
                                                    safety_margin_achieved = true;
                                                }
                                            } else {
                                                assert(target_trove_after_health.debt.is_zero(), 'should be 0 debt');
                                            }

                                            let (expected_freed_pct, _) = purger_utils::get_expected_liquidation_assets(
                                                purger_utils::target_trove_yang_asset_amts(),
                                                target_trove_updated_start_health.value,
                                                max_close_amt,
                                                penalty,
                                                Option::None,
                                            );

                                            let expected_events = array![
                                                (
                                                    purger.contract_address,
                                                    purger_contract::Event::Purged(
                                                        purger_contract::Purged {
                                                            trove_id: target_trove,
                                                            purge_amt: max_close_amt,
                                                            percentage_freed: expected_freed_pct,
                                                            funder: searcher,
                                                            recipient: searcher,
                                                            freed_assets: freed_assets
                                                        }
                                                    )
                                                ),
                                            ];

                                            spy.assert_emitted(@expected_events);

                                            shrine_utils::assert_shrine_invariants(
                                                shrine, yangs, abbot.get_troves_count()
                                            );
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

        // We should hit the branch to check the post-liquidation LTV is at the expected safety margin
        // at least once per threshold, based on the target LTV that is just above the threshold.
        // This assertion provides this assurance.
        // Offset 1 for the 99% threshold where close amount is always equal to trove's debt
        assert(safe_ltv_count == expected_safe_ltv_count, 'at least one per threshold');
    }

    // We split this test up into 4 different tests both to take advantage of parallelization 
    // and because foundry currently has a max gas limit that cannot be changed
    #[test]
    fn test_liquidate_parametrized_1() {
        let thresholds: Span<Ray> = purger_utils::interesting_thresholds_for_liquidation();
        test_liquidate(array![*thresholds[0], *thresholds[1]].span(), 2);
    }

    #[test]
    fn test_liquidate_parametrized_2() {
        let thresholds: Span<Ray> = purger_utils::interesting_thresholds_for_liquidation();
        test_liquidate(array![*thresholds[2], *thresholds[3]].span(), 2);
    }

    #[test]
    fn test_liquidate_parametrized_3() {
        let thresholds: Span<Ray> = purger_utils::interesting_thresholds_for_liquidation();
        test_liquidate(array![*thresholds[4], *thresholds[5]].span(), 2);
    }

    #[test]
    fn liquidate_parametrized_4() {
        let thresholds: Span<Ray> = purger_utils::interesting_thresholds_for_liquidation();
        test_liquidate(array![*thresholds[6], *thresholds[7]].span(), 1);
    }

    #[test]
    #[should_panic(expected: ('PU: Not liquidatable',))]
    fn test_liquidate_trove_healthy_fail() {
        let (shrine, abbot, _, _, purger, yangs, gates) = purger_utils::purger_deploy_with_searcher(
            purger_utils::SEARCHER_YIN.into(), Option::None
        );
        let healthy_trove: u64 = purger_utils::funded_healthy_trove(
            abbot, yangs, gates, purger_utils::TARGET_TROVE_YIN.into()
        );

        purger_utils::assert_trove_is_healthy(shrine, purger, healthy_trove);

        let searcher: ContractAddress = purger_utils::searcher();
        start_prank(CheatTarget::One(purger.contract_address), searcher);
        purger.liquidate(healthy_trove, BoundedWad::max(), searcher);
    }

    #[test]
    #[should_panic(expected: ('PU: Not liquidatable',))]
    fn test_liquidate_trove_healthy_high_threshold_fail() {
        let (shrine, abbot, _, _, purger, yangs, gates) = purger_utils::purger_deploy_with_searcher(
            purger_utils::SEARCHER_YIN.into(), Option::None
        );
        let healthy_trove: u64 = purger_utils::funded_healthy_trove(
            abbot, yangs, gates, purger_utils::TARGET_TROVE_YIN.into()
        );

        let threshold: Ray = (95 * RAY_PERCENT).into();
        purger_utils::set_thresholds(shrine, yangs, threshold);
        let max_forge_amt: Wad = shrine.get_max_forge(healthy_trove);

        let healthy_trove_owner: ContractAddress = purger_utils::target_trove_owner();
        start_prank(CheatTarget::One(abbot.contract_address), healthy_trove_owner);
        abbot.forge(healthy_trove, max_forge_amt, 0_u128.into());
        stop_prank(CheatTarget::One(abbot.contract_address));

        // Sanity check that LTV is above absorption threshold and safe
        let health: Health = shrine.get_trove_health(healthy_trove);
        assert(health.ltv > purger_contract::ABSORPTION_THRESHOLD.into(), 'too low');
        purger_utils::assert_trove_is_healthy(shrine, purger, healthy_trove);

        let searcher: ContractAddress = purger_utils::searcher();
        start_prank(CheatTarget::One(purger.contract_address), searcher);
        purger.liquidate(healthy_trove, BoundedWad::max(), searcher);
    }

    #[test]
    #[should_panic(expected: ('SH: Insufficient yin balance',))]
    fn test_liquidate_insufficient_yin_fail() {
        let target_trove_yin: Wad = purger_utils::TARGET_TROVE_YIN.into();
        let searcher_yin: Wad = (target_trove_yin.val / 10).into();

        let (shrine, abbot, seer, _, purger, yangs, gates) = purger_utils::purger_deploy_with_searcher(
            searcher_yin, Option::None
        );
        let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, target_trove_yin);

        let target_trove_health: Health = shrine.get_trove_health(target_trove);

        let target_ltv: Ray = (target_trove_health.threshold.val + 1).into();
        purger_utils::lower_prices_to_raise_trove_ltv(
            shrine, seer, yangs, target_trove_health.value, target_trove_health.debt, target_ltv
        );

        // Sanity check that LTV is at the target liquidation LTV
        let updated_target_trove_health: Health = shrine.get_trove_health(target_trove);
        purger_utils::assert_trove_is_liquidatable(shrine, purger, target_trove, updated_target_trove_health.ltv);

        let searcher: ContractAddress = purger_utils::searcher();
        start_prank(CheatTarget::One(purger.contract_address), searcher);
        purger.liquidate(target_trove, BoundedWad::max(), searcher);
    }

    //
    // Tests - Absorb
    //

    // This test fixes the trove's debt to 1,000 in order to test the ground truth values of the
    // penalty and close amount when LTV is at threshold. The error margin is relaxed because the
    // `lower_prices_to_raise_trove_ltv` may not put the trove in the exact LTV as the threshold.
    #[test]
    fn test_preview_absorb_below_trove_debt_parametrized() {
        let classes = Option::Some(purger_utils::declare_contracts());

        let mut interesting_thresholds = purger_utils::interesting_thresholds_for_absorption_below_trove_debt();
        let mut target_ltvs: Span<Span<Ray>> =
            purger_utils::ltvs_for_interesting_thresholds_for_absorption_below_trove_debt();

        let trove_debt: Wad = (WAD_ONE * 1000).into();
        let expected_penalty: Ray = purger_contract::MAX_PENALTY.into();

        let mut expected_max_close_amts: Span<Wad> = array![
            593187000000000000000_u128.into(), // 593.187 (65% threshold, 71.18% LTV)
            696105000000000000000_u128.into(), // 696.105 (70% threshold, 76.65% LTV)
            842762000000000000000_u128.into(), // 842.762 (75% threshold, 82.13% LTV)
            999945000000000000000_u128.into(), // 999.945 (78.74% threshold, 86.2203% LTV)
        ]
            .span();

        let mut expected_rm_max_close_amts: Span<Wad> = array![
            896358337401000000000_u128.into(), // 896.358... (65% threshold, 71.18% LTV, 32.5% rm threshold)
            931454487512000000000_u128.into(), // 931.454... (70% threshold, 76.65% LTV, 35% rm threshold)
            969502867506000000000_u128.into(), // 969.503... (75% threshold, 82.13% LTV, 37.5% rm threshold)
            999985053373000000000_u128.into(), // 999.985... (78.74% threshold, 86.2203% LTV, 39.34% rm threshold)
        ]
            .span();

        loop {
            match interesting_thresholds.pop_front() {
                Option::Some(threshold) => {
                    let mut target_ltv_arr = *target_ltvs.pop_front().unwrap();
                    let target_ltv = *target_ltv_arr.pop_front().unwrap();
                    let mut is_recovery_mode_fuzz: Span<bool> = array![false, true].span();

                    loop {
                        match is_recovery_mode_fuzz.pop_front() {
                            Option::Some(is_recovery_mode) => {
                                let (shrine, abbot, seer, absorber, purger, yangs, gates) = purger_utils::purger_deploy(
                                    classes
                                );

                                start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
                                shrine.set_debt_ceiling((2000000 * WAD_ONE).into());
                                stop_prank(CheatTarget::One(shrine.contract_address));

                                let target_trove: u64 = purger_utils::funded_healthy_trove(
                                    abbot, yangs, gates, trove_debt
                                );

                                purger_utils::funded_absorber(
                                    shrine, abbot, absorber, yangs, gates, (trove_debt.val * 2).into()
                                );
                                purger_utils::set_thresholds(shrine, yangs, *threshold);

                                // In order to trigger recovery mode, we forge a large amount of debt
                                // on the other trove such that `recovery_mode_threshold / shrine_ltv`
                                // in `shrine.scale_threshold_for_recovery_mode` is a very small value,
                                // and therefore that function will always return the recovery mode
                                // threshold as half of the original threshold.
                                if (*is_recovery_mode) {
                                    start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
                                    shrine.set_debt_ceiling((10000000 * WAD_ONE).into());
                                    stop_prank(CheatTarget::One(shrine.contract_address));

                                    let whale_trove: u64 = purger_utils::create_whale_trove(abbot, yangs, gates);
                                    let whale_trove_owner: ContractAddress = purger_utils::target_trove_owner();
                                    purger_utils::trigger_recovery_mode(shrine, abbot, whale_trove, whale_trove_owner);
                                }

                                // Make the target trove absorbable
                                let target_trove_start_health: Health = shrine.get_trove_health(target_trove);
                                purger_utils::lower_prices_to_raise_trove_ltv(
                                    shrine,
                                    seer,
                                    yangs,
                                    target_trove_start_health.value,
                                    target_trove_start_health.debt,
                                    target_ltv
                                );

                                let target_trove_updated_start_health: Health = shrine.get_trove_health(target_trove);
                                if (*is_recovery_mode) {
                                    let expected_rm_threshold: Ray = (*threshold.val / 2).into();
                                    common::assert_equalish(
                                        target_trove_updated_start_health.threshold,
                                        expected_rm_threshold,
                                        (RAY_PERCENT / 100).into(),
                                        'wrong rm threshold'
                                    );
                                }

                                purger_utils::assert_trove_is_absorbable(
                                    shrine, purger, target_trove, target_trove_updated_start_health.ltv
                                );

                                let (penalty, max_close_amt, _) = purger
                                    .preview_absorb(target_trove)
                                    .expect('Should be absorbable');

                                common::assert_equalish(
                                    penalty, expected_penalty, (RAY_PERCENT / 10).into(), // 0.1%
                                     'wrong penalty'
                                );

                                let expected_max_close_amt = if *is_recovery_mode {
                                    *expected_rm_max_close_amts.pop_front().unwrap()
                                } else {
                                    *expected_max_close_amts.pop_front().unwrap()
                                };
                                common::assert_equalish(
                                    max_close_amt, expected_max_close_amt, (WAD_ONE / 10).into(), 'wrong max close amt'
                                );
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
    fn test_full_absorb_pass() {
        let (shrine, abbot, seer, absorber, purger, yangs, gates) = purger_utils::purger_deploy_with_searcher(
            purger_utils::SEARCHER_YIN.into(), Option::None
        );
        let initial_trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
        let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, initial_trove_debt);

        // Accrue some interest
        common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

        let target_trove_start_health: Health = shrine.get_trove_health(target_trove);
        let accrued_interest: Wad = target_trove_start_health.debt - initial_trove_debt;
        // Sanity check that some interest has accrued
        assert(accrued_interest.is_non_zero(), 'no interest accrued');

        // Fund the absorber with twice the target trove's debt
        let absorber_start_yin: Wad = (target_trove_start_health.debt.val * 2).into();
        purger_utils::funded_absorber(shrine, abbot, absorber, yangs, gates, absorber_start_yin);

        // sanity check
        assert(shrine.get_yin(absorber.contract_address) > target_trove_start_health.debt, 'not full absorption');

        let shrine_health: Health = shrine.get_shrine_health();
        let before_total_debt: Wad = shrine_health.debt;

        // Make the target trove absorbable
        let target_ltv: Ray = (purger_contract::ABSORPTION_THRESHOLD + 1).into();
        purger_utils::lower_prices_to_raise_trove_ltv(
            shrine, seer, yangs, target_trove_start_health.value, target_trove_start_health.debt, target_ltv
        );
        let target_trove_updated_start_health: Health = shrine.get_trove_health(target_trove);
        purger_utils::assert_trove_is_absorbable(shrine, purger, target_trove, target_trove_updated_start_health.ltv);

        let (penalty, max_close_amt, expected_compensation_value) = purger
            .preview_absorb(target_trove)
            .expect('Should be absorbable');
        let caller: ContractAddress = purger_utils::random_user();

        let before_caller_asset_bals: Span<Span<u128>> = common::get_token_balances(yangs, array![caller].span());
        let before_absorber_asset_bals: Span<Span<u128>> = common::get_token_balances(
            yangs, array![absorber.contract_address].span()
        );

        start_prank(CheatTarget::One(purger.contract_address), caller);
        let compensation: Span<AssetBalance> = purger.absorb(target_trove);

        // Assert that total debt includes accrued interest on liquidated trove
        let shrine_health: Health = shrine.get_shrine_health();
        let after_total_debt: Wad = shrine_health.debt;
        assert(after_total_debt == before_total_debt + accrued_interest - max_close_amt, 'wrong total debt');

        // Check absorption occured
        assert(absorber.get_absorptions_count() == 1, 'wrong absorptions count');

        // Check trove debt and LTV
        let target_trove_after_health: Health = shrine.get_trove_health(target_trove);
        assert(
            target_trove_after_health.debt == target_trove_start_health.debt - max_close_amt,
            'wrong debt after liquidation'
        );

        let is_fully_absorbed: bool = target_trove_after_health.debt.is_zero();
        if !is_fully_absorbed {
            purger_utils::assert_ltv_at_safety_margin(
                target_trove_start_health.threshold, target_trove_after_health.ltv
            );
        }

        // Check that caller has received compensation
        let target_trove_yang_asset_amts: Span<u128> = purger_utils::target_trove_yang_asset_amts();
        let expected_compensation_amts: Span<u128> = purger_utils::get_expected_compensation_assets(
            target_trove_yang_asset_amts, target_trove_updated_start_health.value, expected_compensation_value
        );
        let expected_compensation: Span<AssetBalance> = common::combine_assets_and_amts(
            yangs, expected_compensation_amts
        );
        purger_utils::assert_received_assets(
            before_caller_asset_bals,
            common::get_token_balances(yangs, array![caller].span()),
            expected_compensation,
            10_u128, // error margin
            'wrong caller asset balance',
        );

        common::assert_asset_balances_equalish(
            compensation, expected_compensation, 10_u128, // error margin
             'wrong freed asset amount'
        );

        // Check absorber yin balance
        assert(
            shrine.get_yin(absorber.contract_address) == absorber_start_yin - max_close_amt,
            'wrong absorber yin balance'
        );

        // Check that absorber has received collateral
        let (_, expected_freed_asset_amts) = purger_utils::get_expected_liquidation_assets(
            target_trove_yang_asset_amts,
            target_trove_updated_start_health.value,
            max_close_amt,
            penalty,
            Option::Some(expected_compensation_value)
        );

        let expected_freed_assets: Span<AssetBalance> = common::combine_assets_and_amts(
            yangs, expected_freed_asset_amts,
        );
        purger_utils::assert_received_assets(
            before_absorber_asset_bals,
            common::get_token_balances(yangs, array![absorber.contract_address].span()),
            expected_freed_assets,
            10_u128, // error margin
            'wrong absorber asset balance',
        );

        // let purged_event: purger_contract::Purged = common::pop_event_with_indexed_keys(
        //     purger.contract_address
        // )
        //     .unwrap();
        // common::assert_asset_balances_equalish(
        //     purged_event.freed_assets,
        //     expected_freed_assets,
        //     10_u128,
        //     'wrong freed assets for event'
        // );
        // assert(purged_event.trove_id == target_trove, 'wrong Purged trove ID');
        // assert(purged_event.purge_amt == max_close_amt, 'wrong Purged amt');
        // assert(purged_event.percentage_freed == RAY_ONE.into(), 'wrong Purged freed pct');
        // assert(purged_event.funder == absorber.contract_address, 'wrong Purged funder');
        // assert(purged_event.recipient == absorber.contract_address, 'wrong Purged recipient');

        // let compensate_event: purger_contract::Compensate = common::pop_event_with_indexed_keys(
        //     purger.contract_address
        // )
        //     .unwrap();
        // assert(
        //     compensate_event == purger_contract::Compensate { recipient: caller, compensation },
        //     'wrong Compensate event'
        // );

        shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
    }

    fn test_partial_absorb_with_redistribution_entire_trove_debt(
        recipient_trove_yang_asset_amts_param: Span<Span<u128>>
    ) {
        let classes = Option::Some(purger_utils::declare_contracts());

        let mut target_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_redistributed_trove();

        loop {
            match target_trove_yang_asset_amts_cases.pop_front() {
                Option::Some(target_trove_yang_asset_amts) => {
                    let mut recipient_trove_yang_asset_amts_cases = recipient_trove_yang_asset_amts_param;
                    loop {
                        match recipient_trove_yang_asset_amts_cases.pop_front() {
                            Option::Some(yang_asset_amts) => {
                                let initial_trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
                                let mut absorber_yin_cases: Span<Wad> =
                                    purger_utils::generate_operational_absorber_yin_cases(
                                    initial_trove_debt
                                );

                                match absorber_yin_cases.pop_front() {
                                    Option::Some(absorber_start_yin) => {
                                        let mut is_recovery_mode_fuzz: Span<bool> = array![false, true].span();
                                        loop {
                                            match is_recovery_mode_fuzz.pop_front() {
                                                Option::Some(is_recovery_mode) => {
                                                    let mut kill_absorber_fuzz: Span<bool> = array![true, false].span();

                                                    match kill_absorber_fuzz.pop_front() {
                                                        Option::Some(kill_absorber) => {
                                                            let (shrine, abbot, seer, absorber, purger, yangs, gates) =
                                                                purger_utils::purger_deploy(
                                                                classes
                                                            );

                                                            let mut purger_spy = spy_events(
                                                                SpyOn::One(purger.contract_address)
                                                            );
                                                            let mut shrine_spy = spy_events(
                                                                SpyOn::One(shrine.contract_address)
                                                            );

                                                            start_prank(
                                                                CheatTarget::One(shrine.contract_address),
                                                                shrine_utils::admin()
                                                            );
                                                            shrine.set_debt_ceiling((2000000 * WAD_ONE).into());
                                                            stop_prank(CheatTarget::One(shrine.contract_address));

                                                            let target_trove_owner: ContractAddress =
                                                                purger_utils::target_trove_owner();
                                                            common::fund_user(
                                                                target_trove_owner, yangs, *target_trove_yang_asset_amts
                                                            );
                                                            let target_trove: u64 = common::open_trove_helper(
                                                                abbot,
                                                                target_trove_owner,
                                                                yangs,
                                                                *target_trove_yang_asset_amts,
                                                                gates,
                                                                initial_trove_debt
                                                            );

                                                            // Skip interest accrual to facilitate parametrization of
                                                            // absorber's yin balance based on target trove's debt
                                                            //common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

                                                            let target_trove_start_health: Health = shrine
                                                                .get_trove_health(target_trove);

                                                            let recipient_trove_owner: ContractAddress =
                                                                absorber_utils::provider_1();
                                                            let recipient_trove: u64 =
                                                                absorber_utils::provide_to_absorber(
                                                                shrine,
                                                                abbot,
                                                                absorber,
                                                                recipient_trove_owner,
                                                                yangs,
                                                                *yang_asset_amts,
                                                                gates,
                                                                *absorber_start_yin,
                                                            );

                                                            // Make the target trove absorbable
                                                            let target_ltv: Ray = (purger_contract::ABSORPTION_THRESHOLD
                                                                + 1)
                                                                .into();

                                                            purger_utils::lower_prices_to_raise_trove_ltv(
                                                                shrine,
                                                                seer,
                                                                yangs,
                                                                target_trove_start_health.value,
                                                                target_trove_start_health.debt,
                                                                target_ltv
                                                            );

                                                            let mut target_trove_updated_start_health: Health = shrine
                                                                .get_trove_health(target_trove);
                                                            if *is_recovery_mode {
                                                                purger_utils::trigger_recovery_mode(
                                                                    shrine,
                                                                    abbot,
                                                                    recipient_trove,
                                                                    recipient_trove_owner
                                                                );

                                                                target_trove_updated_start_health = shrine
                                                                    .get_trove_health(target_trove);
                                                            } else {
                                                                assert(!shrine.is_recovery_mode(), 'recovery mode');
                                                            }

                                                            let shrine_health: Health = shrine.get_shrine_health();
                                                            let before_total_debt: Wad = shrine_health.debt;

                                                            let recipient_trove_start_health: Health = shrine
                                                                .get_trove_health(recipient_trove);

                                                            purger_utils::assert_trove_is_absorbable(
                                                                shrine,
                                                                purger,
                                                                target_trove,
                                                                target_trove_updated_start_health.ltv
                                                            );

                                                            let (penalty, max_close_amt, expected_compensation_value) =
                                                                purger
                                                                .preview_absorb(target_trove)
                                                                .expect('Should be absorbable');
                                                            let close_amt: Wad = *absorber_start_yin;

                                                            // Sanity check
                                                            assert(
                                                                shrine
                                                                    .get_yin(absorber.contract_address) < max_close_amt,
                                                                'not less than close amount'
                                                            );

                                                            let caller: ContractAddress = purger_utils::random_user();

                                                            let before_caller_asset_bals: Span<Span<u128>> =
                                                                common::get_token_balances(
                                                                yangs, array![caller].span()
                                                            );
                                                            let before_absorber_asset_bals: Span<Span<u128>> =
                                                                common::get_token_balances(
                                                                yangs, array![absorber.contract_address].span()
                                                            );

                                                            start_prank(
                                                                CheatTarget::One(purger.contract_address), caller
                                                            );
                                                            let compensation: Span<AssetBalance> = purger
                                                                .absorb(target_trove);

                                                            let shrine_health: Health = shrine.get_shrine_health();
                                                            let after_total_debt: Wad = shrine_health.debt;
                                                            assert(
                                                                after_total_debt == before_total_debt - close_amt,
                                                                'wrong total debt'
                                                            );

                                                            // Check absorption occured
                                                            assert(
                                                                absorber.get_absorptions_count() == 1,
                                                                'wrong absorptions count'
                                                            );

                                                            // Check trove debt, value and LTV
                                                            let target_trove_after_health: Health = shrine
                                                                .get_trove_health(target_trove);
                                                            assert(
                                                                target_trove_after_health.debt.is_zero(),
                                                                'wrong debt after liquidation'
                                                            );
                                                            assert(
                                                                target_trove_after_health.value.is_zero(),
                                                                'wrong value after liquidation'
                                                            );

                                                            // Check that caller has received compensation
                                                            let expected_compensation_amts: Span<u128> =
                                                                purger_utils::get_expected_compensation_assets(
                                                                *target_trove_yang_asset_amts,
                                                                target_trove_updated_start_health.value,
                                                                expected_compensation_value
                                                            );
                                                            let expected_compensation: Span<AssetBalance> =
                                                                common::combine_assets_and_amts(
                                                                yangs, expected_compensation_amts
                                                            );
                                                            purger_utils::assert_received_assets(
                                                                before_caller_asset_bals,
                                                                common::get_token_balances(
                                                                    yangs, array![caller].span()
                                                                ),
                                                                expected_compensation,
                                                                10_u128, // error margin
                                                                'wrong caller asset balance',
                                                            );

                                                            common::assert_asset_balances_equalish(
                                                                compensation,
                                                                expected_compensation,
                                                                10_u128, // error margin
                                                                'wrong freed asset amount'
                                                            );

                                                            // Check absorber yin balance is wiped out
                                                            assert(
                                                                shrine.get_yin(absorber.contract_address).is_zero(),
                                                                'wrong absorber yin balance'
                                                            );

                                                            // Check that absorber has received proportionate share of collateral
                                                            let (expected_freed_pct, expected_freed_asset_amts) =
                                                                purger_utils::get_expected_liquidation_assets(
                                                                *target_trove_yang_asset_amts,
                                                                target_trove_updated_start_health.value,
                                                                close_amt,
                                                                penalty,
                                                                Option::Some(expected_compensation_value),
                                                            );

                                                            let expected_freed_assets: Span<AssetBalance> =
                                                                common::combine_assets_and_amts(
                                                                yangs, expected_freed_asset_amts
                                                            );
                                                            purger_utils::assert_received_assets(
                                                                before_absorber_asset_bals,
                                                                common::get_token_balances(
                                                                    yangs, array![absorber.contract_address].span()
                                                                ),
                                                                expected_freed_assets,
                                                                100_u128, // error margin
                                                                'wrong absorber asset balance',
                                                            );

                                                            // Check redistribution occured
                                                            assert(
                                                                shrine.get_redistributions_count() == 1,
                                                                'wrong redistributions count'
                                                            );

                                                            // Check recipient trove's value and debt
                                                            let recipient_trove_after_health: Health = shrine
                                                                .get_trove_health(recipient_trove);
                                                            let redistributed_amt: Wad = max_close_amt - close_amt;
                                                            let expected_recipient_trove_debt: Wad =
                                                                recipient_trove_start_health
                                                                .debt
                                                                + redistributed_amt;

                                                            common::assert_equalish(
                                                                recipient_trove_after_health.debt,
                                                                expected_recipient_trove_debt,
                                                                (WAD_ONE / 100).into(), // error margin
                                                                'wrong recipient trove debt'
                                                            );

                                                            let redistributed_value: Wad =
                                                                target_trove_updated_start_health
                                                                .value
                                                                - wadray::rmul_wr(close_amt, RAY_ONE.into() + penalty)
                                                                - expected_compensation_value;
                                                            let expected_recipient_trove_value: Wad =
                                                                recipient_trove_start_health
                                                                .value
                                                                + redistributed_value;

                                                            common::assert_equalish(
                                                                recipient_trove_after_health.value,
                                                                expected_recipient_trove_value,
                                                                (WAD_ONE / 100).into(), // error margin
                                                                'wrong recipient trove value'
                                                            );

                                                            // Check Purger events
                                                            purger_spy.fetch_events();

                                                            let (_, purged_event) = purger_spy
                                                                .events
                                                                .pop_front()
                                                                .unwrap();

                                                            assert(
                                                                purged_event.keys.at(0) == @event_name_hash('Purged'),
                                                                'wrong event'
                                                            );

                                                            // common::assert_asset_balances_equalish(
                                                            //     purged_event.freed_assets,
                                                            //     expected_freed_assets,
                                                            //     1_u128,
                                                            //     'wrong freed assets for event'
                                                            // );
                                                            // assert(
                                                            //     purged_event.trove_id == target_trove,
                                                            //     'wrong Purged trove ID'
                                                            // );
                                                            // assert(
                                                            //     purged_event.purge_amt == close_amt,
                                                            //     'wrong Purged amt'
                                                            // );
                                                            // assert(
                                                            //     purged_event
                                                            //         .percentage_freed == expected_freed_pct,
                                                            //     'wrong Purged freed pct'
                                                            // );
                                                            // assert(
                                                            //     purged_event
                                                            //         .funder == absorber
                                                            //         .contract_address,
                                                            //     'wrong Purged funder'
                                                            // );
                                                            // assert(
                                                            //     purged_event
                                                            //         .recipient == absorber
                                                            //         .contract_address,
                                                            //     'wrong Purged recipient'
                                                            // );

                                                            // let compensate_event: purger_contract::Compensate =
                                                            //     common::pop_event_with_indexed_keys(
                                                            //     purger.contract_address
                                                            // )
                                                            //     .unwrap();
                                                            // assert(
                                                            //     compensate_event == purger_contract::Compensate {
                                                            //         recipient: caller, compensation
                                                            //     },
                                                            //     'wrong Compensate event'
                                                            //);

                                                            // Check Shrine event

                                                            let expected_redistribution_id = 1;
                                                            let expected_events = array![
                                                                (
                                                                    shrine.contract_address,
                                                                    shrine_contract::Event::TroveRedistributed(
                                                                        shrine_contract::TroveRedistributed {
                                                                            redistribution_id: expected_redistribution_id,
                                                                            trove_id: target_trove,
                                                                            debt: redistributed_amt,
                                                                        }
                                                                    )
                                                                ),
                                                            ];

                                                            shrine_spy.assert_emitted(@expected_events);

                                                            shrine_utils::assert_shrine_invariants(
                                                                shrine, yangs, abbot.get_troves_count()
                                                            );
                                                        },
                                                        Option::None => { break; },
                                                    };
                                                },
                                                Option::None => { break; },
                                            };
                                        };
                                    },
                                    Option::None => { break; },
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
    fn test_partial_absorb_with_redistribution_entire_trove_debt_parametrized1() {
        let recipient_trove_yang_asset_amts_cases: Span<Span<u128>> =
            purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_entire_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[0]].span()
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_entire_trove_debt_parametrized2() {
        let recipient_trove_yang_asset_amts_cases: Span<Span<u128>> =
            purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_entire_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[1]].span()
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_entire_trove_debt_parametrized3() {
        let recipient_trove_yang_asset_amts_cases: Span<Span<u128>> =
            purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_entire_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[2]].span()
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_entire_trove_debt_parametrized4() {
        let recipient_trove_yang_asset_amts_cases: Span<Span<u128>> =
            purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_entire_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[3]].span()
        );
    }


    // Regarding `absorber_yin_idx`:
    //
    //  - Index 0 is a dummy value for the absorber yin
    //    being a fraction of the trove's debt.
    //  - Index 1 is a dummy value for the lower bound
    //    of the absorber's yin.
    //  - Index 2 is a dummy value for the trove's debt
    //    minus the smallest unit of Wad (which would amount to
    //    1001 wei after including the initial amount in Absorber)

    fn test_partial_absorb_with_redistribution_below_trove_debt(
        recipient_trove_yang_asset_amts_param: Span<Span<u128>>, is_recovery_mode: bool, absorber_yin_idx: usize
    ) {
        let classes = Option::Some(purger_utils::declare_contracts());

        let mut target_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_redistributed_trove();

        loop {
            match target_trove_yang_asset_amts_cases.pop_front() {
                Option::Some(target_trove_yang_asset_amts) => {
                    let mut recipient_trove_yang_asset_amts_cases = recipient_trove_yang_asset_amts_param;
                    loop {
                        match recipient_trove_yang_asset_amts_cases.pop_front() {
                            Option::Some(yang_asset_amts) => {
                                let mut interesting_thresholds =
                                    purger_utils::interesting_thresholds_for_absorption_below_trove_debt();
                                let mut target_ltvs: Span<Span<Ray>> =
                                    purger_utils::ltvs_for_interesting_thresholds_for_absorption_below_trove_debt();
                                loop {
                                    match interesting_thresholds.pop_front() {
                                        Option::Some(threshold) => {
                                            // Use only the first value which guarantees the max absorption amount is less
                                            // than the trove's debt
                                            let mut target_ltvs_arr: Span<Ray> = *target_ltvs.pop_front().unwrap();
                                            let target_ltv: Ray = *target_ltvs_arr.pop_front().unwrap();

                                            let mut kill_absorber_fuzz: Span<bool> = array![true, false].span();

                                            match kill_absorber_fuzz.pop_front() {
                                                Option::Some(kill_absorber) => {
                                                    let (shrine, abbot, mock_pragma, absorber, purger, yangs, gates) =
                                                        purger_utils::purger_deploy(
                                                        classes
                                                    );

                                                    let mut purger_spy = spy_events(
                                                        SpyOn::One(purger.contract_address)
                                                    );
                                                    let mut shrine_spy = spy_events(
                                                        SpyOn::One(shrine.contract_address)
                                                    );

                                                    let target_trove_owner: ContractAddress =
                                                        purger_utils::target_trove_owner();
                                                    common::fund_user(
                                                        target_trove_owner, yangs, *target_trove_yang_asset_amts
                                                    );
                                                    let initial_trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
                                                    let target_trove: u64 = common::open_trove_helper(
                                                        abbot,
                                                        target_trove_owner,
                                                        yangs,
                                                        *target_trove_yang_asset_amts,
                                                        gates,
                                                        initial_trove_debt
                                                    );

                                                    // Accrue some interest
                                                    common::advance_intervals_and_refresh_prices_and_multiplier(
                                                        shrine, yangs, 500
                                                    );

                                                    let whale_trove: u64 = purger_utils::create_whale_trove(
                                                        abbot, yangs, gates
                                                    );

                                                    let target_trove_start_health: Health = shrine
                                                        .get_trove_health(target_trove);
                                                    let accrued_interest: Wad = target_trove_start_health.debt
                                                        - initial_trove_debt;
                                                    // Sanity check that some interest has accrued
                                                    assert(accrued_interest.is_non_zero(), 'no interest accrued');

                                                    purger_utils::set_thresholds(shrine, yangs, *threshold);

                                                    // Make the target trove absorbable
                                                    purger_utils::lower_prices_to_raise_trove_ltv(
                                                        shrine,
                                                        mock_pragma,
                                                        yangs,
                                                        target_trove_start_health.value,
                                                        target_trove_start_health.debt,
                                                        target_ltv
                                                    );

                                                    let target_trove_start_health: Health = shrine
                                                        .get_trove_health(target_trove);

                                                    purger_utils::assert_trove_is_absorbable(
                                                        shrine, purger, target_trove, target_trove_start_health.ltv
                                                    );

                                                    let (penalty, max_close_amt, expected_compensation_value) = purger
                                                        .preview_absorb(target_trove)
                                                        .expect('Should be absorbable');

                                                    // sanity check
                                                    assert(
                                                        max_close_amt < target_trove_start_health.debt,
                                                        'close amt not below trove debt'
                                                    );

                                                    let caller: ContractAddress = purger_utils::random_user();

                                                    let before_caller_asset_bals: Span<Span<u128>> =
                                                        common::get_token_balances(
                                                        yangs, array![caller].span()
                                                    );
                                                    let before_absorber_asset_bals: Span<Span<u128>> =
                                                        common::get_token_balances(
                                                        yangs, array![absorber.contract_address].span()
                                                    );

                                                    let recipient_trove_owner: ContractAddress =
                                                        absorber_utils::provider_1();

                                                    // Provide the minimum to absorber.
                                                    // The actual amount will be provided after 
                                                    // recovery mode adjustment is made.
                                                    let recipient_trove: u64 = absorber_utils::provide_to_absorber(
                                                        shrine,
                                                        abbot,
                                                        absorber,
                                                        recipient_trove_owner,
                                                        yangs,
                                                        *yang_asset_amts,
                                                        gates,
                                                        absorber_contract::MINIMUM_SHARES.into(),
                                                    );
                                                    start_prank(
                                                        CheatTarget::One(abbot.contract_address), recipient_trove_owner
                                                    );
                                                    abbot.forge(recipient_trove, max_close_amt, WadZeroable::zero());

                                                    start_prank(
                                                        CheatTarget::One(abbot.contract_address), target_trove_owner
                                                    );
                                                    abbot.close_trove(whale_trove);
                                                    stop_prank(CheatTarget::One(abbot.contract_address));

                                                    let mut target_trove_updated_start_health: Health = shrine
                                                        .get_trove_health(target_trove);

                                                    if is_recovery_mode {
                                                        purger_utils::trigger_recovery_mode(
                                                            shrine, abbot, recipient_trove, recipient_trove_owner
                                                        );

                                                        target_trove_updated_start_health = shrine
                                                            .get_trove_health(target_trove);
                                                    } else {
                                                        assert(!shrine.is_recovery_mode(), 'recovery mode');
                                                    }

                                                    // Preview absorption again based on adjustments for recovery mode                                                            
                                                    let (penalty, max_close_amt, expected_compensation_value) = purger
                                                        .preview_absorb(target_trove)
                                                        .expect('Should be absorbable');

                                                    // sanity check
                                                    assert(
                                                        max_close_amt < target_trove_start_health.debt,
                                                        'close amt not below trove debt'
                                                    );

                                                    let before_recipient_trove_health: Health = shrine
                                                        .get_trove_health(recipient_trove);

                                                    let shrine_health: Health = shrine.get_shrine_health();
                                                    let before_total_debt: Wad = shrine_health.debt;

                                                    // Fund absorber based on adjusted max close amount
                                                    // after recovery mode has been set up
                                                    let mut absorber_start_yin: Wad = if absorber_yin_idx == 0 {
                                                        // Fund the absorber with 1/3 of the max close amount
                                                        (max_close_amt.val / 3).into()
                                                    } else {
                                                        if absorber_yin_idx == 1 {
                                                            absorber_contract::MINIMUM_SHARES.into()
                                                        } else {
                                                            (max_close_amt.val - 1).into()
                                                        }
                                                    };

                                                    let close_amt = absorber_start_yin;
                                                    absorber_start_yin -= absorber_contract::MINIMUM_SHARES.into();

                                                    if absorber_start_yin.is_non_zero() {
                                                        start_prank(
                                                            CheatTarget::One(shrine.contract_address),
                                                            recipient_trove_owner
                                                        );
                                                        let yin = IERC20Dispatcher {
                                                            contract_address: shrine.contract_address
                                                        };
                                                        stop_prank(CheatTarget::One(shrine.contract_address));

                                                        start_prank(
                                                            CheatTarget::One(absorber.contract_address),
                                                            recipient_trove_owner
                                                        );
                                                        absorber.provide(absorber_start_yin);

                                                        stop_prank(CheatTarget::One(absorber.contract_address));
                                                    }

                                                    assert(
                                                        shrine.get_yin(absorber.contract_address) < max_close_amt,
                                                        'not less than close amount'
                                                    );
                                                    assert(
                                                        shrine.get_yin(absorber.contract_address) == close_amt,
                                                        'absorber has close amount'
                                                    );

                                                    if *kill_absorber {
                                                        absorber_utils::kill_absorber(absorber);
                                                        assert(!absorber.get_live(), 'sanity check');
                                                    }

                                                    start_prank(CheatTarget::One(purger.contract_address), caller);
                                                    let compensation: Span<AssetBalance> = purger.absorb(target_trove);

                                                    // Assert that total debt includes accrued interest on liquidated trove
                                                    let shrine_health: Health = shrine.get_shrine_health();
                                                    let after_total_debt: Wad = shrine_health.debt;
                                                    assert(
                                                        after_total_debt == before_total_debt
                                                            + accrued_interest
                                                            - close_amt,
                                                        'wrong total debt'
                                                    );

                                                    // Check absorption occured
                                                    assert(
                                                        absorber.get_absorptions_count() == 1, 'wrong absorptions count'
                                                    );

                                                    // Check trove debt, value and LTV
                                                    let target_trove_after_health: Health = shrine
                                                        .get_trove_health(target_trove);

                                                    let expected_liquidated_value: Wad = wadray::rmul_wr(
                                                        max_close_amt, RAY_ONE.into() + penalty
                                                    );
                                                    let expected_after_value: Wad = target_trove_updated_start_health
                                                        .value
                                                        - expected_compensation_value
                                                        - expected_liquidated_value;
                                                    assert(
                                                        target_trove_after_health.debt.is_non_zero(),
                                                        'debt should not be 0'
                                                    );

                                                    let expected_after_debt: Wad = target_trove_updated_start_health
                                                        .debt
                                                        - max_close_amt;
                                                    assert(
                                                        target_trove_after_health.debt == expected_after_debt,
                                                        'wrong debt after liquidation'
                                                    );

                                                    assert(
                                                        target_trove_after_health.value.is_non_zero(),
                                                        'value should not be 0'
                                                    );

                                                    common::assert_equalish(
                                                        target_trove_after_health.value,
                                                        expected_after_value,
                                                        // (10 ** 15) error margin
                                                        1000000000000000_u128.into(),
                                                        'wrong value after liquidation'
                                                    );

                                                    purger_utils::assert_ltv_at_safety_margin(
                                                        target_trove_updated_start_health.threshold,
                                                        target_trove_after_health.ltv
                                                    );

                                                    // Check that caller has received compensation
                                                    let expected_compensation_amts: Span<u128> =
                                                        purger_utils::get_expected_compensation_assets(
                                                        *target_trove_yang_asset_amts,
                                                        target_trove_updated_start_health.value,
                                                        expected_compensation_value
                                                    );
                                                    let expected_compensation: Span<AssetBalance> =
                                                        common::combine_assets_and_amts(
                                                        yangs, expected_compensation_amts
                                                    );
                                                    purger_utils::assert_received_assets(
                                                        before_caller_asset_bals,
                                                        common::get_token_balances(yangs, array![caller].span()),
                                                        expected_compensation,
                                                        10_u128, // error margin
                                                        'wrong caller asset balance'
                                                    );

                                                    common::assert_asset_balances_equalish(
                                                        compensation,
                                                        expected_compensation,
                                                        10_u128, // error margin
                                                        'wrong freed asset amount'
                                                    );

                                                    // Check absorber yin balance is wiped out
                                                    assert(
                                                        shrine.get_yin(absorber.contract_address).is_zero(),
                                                        'wrong absorber yin balance'
                                                    );

                                                    // Check that absorber has received proportionate share of collateral
                                                    let (expected_freed_pct, expected_freed_amts) =
                                                        purger_utils::get_expected_liquidation_assets(
                                                        *target_trove_yang_asset_amts,
                                                        target_trove_updated_start_health.value,
                                                        close_amt,
                                                        penalty,
                                                        Option::Some(expected_compensation_value),
                                                    );
                                                    let expected_freed_assets: Span<AssetBalance> =
                                                        common::combine_assets_and_amts(
                                                        yangs, expected_freed_amts
                                                    );
                                                    purger_utils::assert_received_assets(
                                                        before_absorber_asset_bals,
                                                        common::get_token_balances(
                                                            yangs, array![absorber.contract_address].span()
                                                        ),
                                                        expected_freed_assets,
                                                        100_u128, // error margin
                                                        'wrong absorber asset balance'
                                                    );

                                                    // Check redistribution occured
                                                    assert(
                                                        shrine.get_redistributions_count() == 1,
                                                        'wrong redistributions count'
                                                    );

                                                    // Check recipient trove's debt
                                                    let after_recipient_trove_health = shrine
                                                        .get_trove_health(recipient_trove);
                                                    let expected_redistributed_amt: Wad = max_close_amt - close_amt;
                                                    let expected_recipient_trove_debt: Wad =
                                                        before_recipient_trove_health
                                                        .debt
                                                        + expected_redistributed_amt;

                                                    common::assert_equalish(
                                                        after_recipient_trove_health.debt,
                                                        expected_recipient_trove_debt,
                                                        (WAD_ONE / 100).into(), // error margin
                                                        'wrong recipient trove debt'
                                                    );

                                                    let redistributed_value: Wad = wadray::rmul_wr(
                                                        expected_redistributed_amt, RAY_ONE.into() + penalty
                                                    );
                                                    let expected_recipient_trove_value: Wad =
                                                        before_recipient_trove_health
                                                        .value
                                                        + redistributed_value;

                                                    common::assert_equalish(
                                                        after_recipient_trove_health.value,
                                                        expected_recipient_trove_value,
                                                        (WAD_ONE / 100).into(), // error margin
                                                        'wrong recipient trove value'
                                                    );

                                                    // Check remainder yang assets for redistributed trove is correct
                                                    let expected_remainder_pct: Ray = wadray::rdiv_ww(
                                                        expected_after_value, target_trove_updated_start_health.value
                                                    );
                                                    let mut expected_remainder_trove_yang_asset_amts =
                                                        common::scale_span_by_pct(
                                                        *target_trove_yang_asset_amts, expected_remainder_pct
                                                    );

                                                    let mut yangs_copy = yangs;
                                                    let mut gates_copy = gates;
                                                    loop {
                                                        match expected_remainder_trove_yang_asset_amts.pop_front() {
                                                            Option::Some(expected_asset_amt) => {
                                                                let gate: IGateDispatcher = *gates_copy
                                                                    .pop_front()
                                                                    .unwrap();
                                                                let remainder_trove_yang: Wad = shrine
                                                                    .get_deposit(
                                                                        *yangs_copy.pop_front().unwrap(), target_trove
                                                                    );
                                                                let remainder_asset_amt: u128 = gate
                                                                    .convert_to_assets(remainder_trove_yang);

                                                                common::assert_equalish(
                                                                    remainder_asset_amt,
                                                                    *expected_asset_amt,
                                                                    10000000_u128.into(),
                                                                    'wrong remainder yang asset'
                                                                );
                                                            },
                                                            Option::None => { break; },
                                                        };
                                                    };

                                                    // Check Purger events

                                                    purger_spy.fetch_events();

                                                    let (_, purged_event) = purger_spy.events.pop_front().unwrap();

                                                    assert(
                                                        purged_event.keys.at(0) == @event_name_hash('Purged'),
                                                        'wrong event'
                                                    );

                                                    // let purged_event: purger_contract::Purged =
                                                    //     common::pop_event_with_indexed_keys(
                                                    //     purger.contract_address
                                                    // )
                                                    //     .unwrap();
                                                    // common::assert_asset_balances_equalish(
                                                    //     purged_event.freed_assets,
                                                    //     expected_freed_assets,
                                                    //     1000_u128,
                                                    //     'wrong freed assets for event'
                                                    // );
                                                    // assert(
                                                    //     purged_event
                                                    //         .trove_id == target_trove,
                                                    //     'wrong Purged trove ID'
                                                    // );
                                                    // assert(
                                                    //     purged_event.purge_amt == close_amt,
                                                    //     'wrong Purged amt'
                                                    // );
                                                    // common::assert_equalish(
                                                    //     purged_event.percentage_freed,
                                                    //     expected_freed_pct,
                                                    //     1000000_u128.into(),
                                                    //     'wrong Purged freed pct'
                                                    // );
                                                    // assert(
                                                    //     purged_event
                                                    //         .funder == absorber
                                                    //         .contract_address,
                                                    //     'wrong Purged funder'
                                                    // );
                                                    // assert(
                                                    //     purged_event
                                                    //         .recipient == absorber
                                                    //         .contract_address,
                                                    //     'wrong Purged recipient'
                                                    // );

                                                    // let compensate_event: purger_contract::Compensate =
                                                    //     common::pop_event_with_indexed_keys(
                                                    //     purger.contract_address
                                                    // )
                                                    //     .unwrap();
                                                    // assert(
                                                    //     compensate_event == purger_contract::Compensate {
                                                    //         recipient: caller, compensation
                                                    //     },
                                                    //     'wrong Compensate event'
                                                    // );

                                                    // TODO: uncomment once gas limit can be increased
                                                    // Check Shrine event
                                                    // let expected_redistribution_id = 1;
                                                    // let expected_events =
                                                    //     array![
                                                    //     (shrine.contract_address,
                                                    //     shrine_contract::Event::TroveRedistributed(
                                                    //         shrine_contract::TroveRedistributed {
                                                    //             redistribution_id: expected_redistribution_id,
                                                    //             trove_id: target_trove,
                                                    //             debt: expected_redistributed_amt,
                                                    //         }
                                                    //     )),
                                                    // ];

                                                    // shrine_spy.assert_emitted(@expected_events);

                                                    shrine_utils::assert_shrine_invariants(
                                                        shrine, yangs, abbot.get_troves_count(),
                                                    );
                                                },
                                                Option::None => { break; },
                                            };
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
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized1() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[0]].span(), false, 0
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized2() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[0]].span(), false, 1
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized3() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[0]].span(), false, 2
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized4() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[0]].span(), true, 0
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized5() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[0]].span(), true, 1
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized6() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[0]].span(), true, 2
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized7() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[1]].span(), false, 0
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized8() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[1]].span(), false, 1
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized9() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[1]].span(), false, 2
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized10() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[1]].span(), true, 0
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized11() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[1]].span(), true, 1
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized12() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[1]].span(), true, 2
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized13() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[2]].span(), false, 0
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized14() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[2]].span(), false, 1
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized15() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[2]].span(), false, 2
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized16() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[2]].span(), true, 0
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized17() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[2]].span(), true, 1
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized18() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[2]].span(), true, 2
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized19() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[3]].span(), false, 0
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized20() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[3]].span(), false, 1
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized21() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[3]].span(), false, 2
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized22() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[3]].span(), true, 0
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized23() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[3]].span(), true, 1
        );
    }

    #[test]
    fn test_partial_absorb_with_redistribution_below_trove_debt_parametrized24() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_partial_absorb_with_redistribution_below_trove_debt(
            array![*recipient_trove_yang_asset_amts_cases[3]].span(), true, 2
        );
    }
    // Note that the absorber has zero shares in this test because no provider has
    // provided yin yet.
    fn test_absorb_full_redistribution(recipient_trove_yang_asset_amts_param: Span<Span<u128>>) {
        let classes = Option::Some(purger_utils::declare_contracts());

        let mut target_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_redistributed_trove();

        loop {
            match target_trove_yang_asset_amts_cases.pop_front() {
                Option::Some(target_trove_yang_asset_amts) => {
                    let mut recipient_trove_yang_asset_amts_cases = recipient_trove_yang_asset_amts_param;
                    loop {
                        match recipient_trove_yang_asset_amts_cases.pop_front() {
                            Option::Some(yang_asset_amts) => {
                                let mut absorber_yin_cases: Span<Wad> =
                                    purger_utils::inoperational_absorber_yin_cases();
                                loop {
                                    match absorber_yin_cases.pop_front() {
                                        Option::Some(absorber_start_yin) => {
                                            let mut is_recovery_mode_fuzz: Span<bool> = array![false, true].span();
                                            loop {
                                                match is_recovery_mode_fuzz.pop_front() {
                                                    Option::Some(is_recovery_mode) => {
                                                        let mut kill_absorber_fuzz: Span<bool> = array![true, false]
                                                            .span();

                                                        match kill_absorber_fuzz.pop_front() {
                                                            Option::Some(kill_absorber) => {
                                                                let (
                                                                    shrine, abbot, seer, absorber, purger, yangs, gates
                                                                ) =
                                                                    purger_utils::purger_deploy(
                                                                    classes
                                                                );

                                                                let mut purger_spy = spy_events(
                                                                    SpyOn::One(purger.contract_address)
                                                                );
                                                                let mut shrine_spy = spy_events(
                                                                    SpyOn::One(shrine.contract_address)
                                                                );

                                                                start_prank(
                                                                    CheatTarget::One(shrine.contract_address),
                                                                    shrine_utils::admin()
                                                                );
                                                                shrine.set_debt_ceiling((2000000 * WAD_ONE).into());
                                                                stop_prank(CheatTarget::One(shrine.contract_address));

                                                                let initial_trove_debt: Wad =
                                                                    purger_utils::TARGET_TROVE_YIN
                                                                    .into();
                                                                let target_trove_owner: ContractAddress =
                                                                    purger_utils::target_trove_owner();
                                                                common::fund_user(
                                                                    target_trove_owner,
                                                                    yangs,
                                                                    *target_trove_yang_asset_amts
                                                                );
                                                                let target_trove: u64 = common::open_trove_helper(
                                                                    abbot,
                                                                    target_trove_owner,
                                                                    yangs,
                                                                    *target_trove_yang_asset_amts,
                                                                    gates,
                                                                    purger_utils::TARGET_TROVE_YIN.into()
                                                                );

                                                                // Accrue some interest
                                                                common::advance_intervals_and_refresh_prices_and_multiplier(
                                                                    shrine, yangs, 500
                                                                );

                                                                let target_trove_start_health: Health = shrine
                                                                    .get_trove_health(target_trove);
                                                                let accrued_interest: Wad = target_trove_start_health
                                                                    .debt
                                                                    - initial_trove_debt;
                                                                // Sanity check that some interest has accrued
                                                                assert(
                                                                    accrued_interest.is_non_zero(),
                                                                    'no interest accrued'
                                                                );

                                                                let mut recipient_trove: u64 = if *is_recovery_mode {
                                                                    let recipient_trove_owner: ContractAddress =
                                                                        absorber_utils::provider_1();

                                                                    let trove_id: u64 =
                                                                        absorber_utils::provide_to_absorber(
                                                                        shrine,
                                                                        abbot,
                                                                        absorber,
                                                                        recipient_trove_owner,
                                                                        yangs,
                                                                        *yang_asset_amts,
                                                                        gates,
                                                                        *absorber_start_yin,
                                                                    );

                                                                    purger_utils::trigger_recovery_mode(
                                                                        shrine, abbot, trove_id, recipient_trove_owner
                                                                    );

                                                                    trove_id
                                                                } else {
                                                                    purger_utils::create_whale_trove(
                                                                        abbot, yangs, gates
                                                                    )
                                                                };

                                                                let shrine_health: Health = shrine.get_shrine_health();
                                                                let before_total_debt: Wad = shrine_health.debt;

                                                                let target_ltv: Ray =
                                                                    (purger_contract::ABSORPTION_THRESHOLD
                                                                    + 1)
                                                                    .into();
                                                                purger_utils::lower_prices_to_raise_trove_ltv(
                                                                    shrine,
                                                                    seer,
                                                                    yangs,
                                                                    target_trove_start_health.value,
                                                                    target_trove_start_health.debt,
                                                                    target_ltv
                                                                );

                                                                let target_trove_updated_start_health: Health = shrine
                                                                    .get_trove_health(target_trove);

                                                                // Sanity check to ensure recovery mode paramterization is correct
                                                                // Due to the changes in yang prices, there may be a very slight
                                                                // deviation in the threshold. Therefore, we treat the new threshold
                                                                // as equal to the previous threshold if it is within 0.1%
                                                                // (i.e. recovery mode is not activated)
                                                                if *is_recovery_mode {
                                                                    assert(
                                                                        shrine.is_recovery_mode(), 'not recovery mode'
                                                                    );
                                                                } else {
                                                                    assert(!shrine.is_recovery_mode(), 'recovery mode');
                                                                }

                                                                let before_recipient_trove_health: Health = shrine
                                                                    .get_trove_health(recipient_trove);

                                                                purger_utils::assert_trove_is_absorbable(
                                                                    shrine,
                                                                    purger,
                                                                    target_trove,
                                                                    target_trove_updated_start_health.ltv
                                                                );

                                                                let caller: ContractAddress =
                                                                    purger_utils::random_user();
                                                                let before_caller_asset_bals: Span<Span<u128>> =
                                                                    common::get_token_balances(
                                                                    yangs, array![caller].span()
                                                                );

                                                                if *kill_absorber {
                                                                    absorber_utils::kill_absorber(absorber);
                                                                    assert(!absorber.get_live(), 'sanity check');
                                                                }

                                                                let (_, _, expected_compensation_value) = purger
                                                                    .preview_absorb(target_trove)
                                                                    .expect('Should be absorbable');

                                                                start_prank(
                                                                    CheatTarget::One(purger.contract_address), caller
                                                                );
                                                                let compensation: Span<AssetBalance> = purger
                                                                    .absorb(target_trove);

                                                                // Assert that total debt includes accrued interest on liquidated trove
                                                                let shrine_health: Health = shrine.get_shrine_health();
                                                                let after_total_debt: Wad = shrine_health.debt;
                                                                assert(
                                                                    after_total_debt == before_total_debt
                                                                        + accrued_interest,
                                                                    'wrong total debt'
                                                                );

                                                                // Check that caller has received compensation
                                                                let expected_compensation_amts: Span<u128> =
                                                                    purger_utils::get_expected_compensation_assets(
                                                                    *target_trove_yang_asset_amts,
                                                                    target_trove_updated_start_health.value,
                                                                    expected_compensation_value
                                                                );
                                                                let expected_compensation: Span<AssetBalance> =
                                                                    common::combine_assets_and_amts(
                                                                    yangs, expected_compensation_amts
                                                                );
                                                                purger_utils::assert_received_assets(
                                                                    before_caller_asset_bals,
                                                                    common::get_token_balances(
                                                                        yangs, array![caller].span()
                                                                    ),
                                                                    expected_compensation,
                                                                    10_u128, // error margin
                                                                    'wrong caller asset balance',
                                                                );

                                                                common::assert_asset_balances_equalish(
                                                                    compensation,
                                                                    expected_compensation,
                                                                    10_u128, // error margin
                                                                    'wrong freed asset amount'
                                                                );

                                                                let target_trove_after_health: Health = shrine
                                                                    .get_trove_health(target_trove);
                                                                assert(
                                                                    shrine.is_healthy(target_trove), 'should be healthy'
                                                                );
                                                                assert(
                                                                    target_trove_after_health.ltv.is_zero(),
                                                                    'LTV should be 0'
                                                                );
                                                                assert(
                                                                    target_trove_after_health.value.is_zero(),
                                                                    'value should be 0'
                                                                );
                                                                assert(
                                                                    target_trove_after_health.debt.is_zero(),
                                                                    'debt should be 0'
                                                                );

                                                                // Check no absorption occured
                                                                assert(
                                                                    absorber.get_absorptions_count() == 0,
                                                                    'wrong absorptions count'
                                                                );

                                                                // Check redistribution occured
                                                                assert(
                                                                    shrine.get_redistributions_count() == 1,
                                                                    'wrong redistributions count'
                                                                );

                                                                // Check recipient trove's value and debt
                                                                let after_recipient_trove_health = shrine
                                                                    .get_trove_health(recipient_trove);
                                                                let expected_recipient_trove_debt: Wad =
                                                                    before_recipient_trove_health
                                                                    .debt
                                                                    + target_trove_start_health.debt;

                                                                common::assert_equalish(
                                                                    after_recipient_trove_health.debt,
                                                                    expected_recipient_trove_debt,
                                                                    (WAD_ONE / 100).into(), // error margin
                                                                    'wrong recipient trove debt'
                                                                );

                                                                let redistributed_value: Wad =
                                                                    target_trove_updated_start_health
                                                                    .value
                                                                    - expected_compensation_value;
                                                                let expected_recipient_trove_value: Wad =
                                                                    before_recipient_trove_health
                                                                    .value
                                                                    + redistributed_value;
                                                                common::assert_equalish(
                                                                    after_recipient_trove_health.value,
                                                                    expected_recipient_trove_value,
                                                                    (WAD_ONE / 100).into(), // error margin
                                                                    'wrong recipient trove value'
                                                                );

                                                                // Check Purger events

                                                                purger_spy.fetch_events();

                                                                let (_, purged_event) = purger_spy
                                                                    .events
                                                                    .pop_front()
                                                                    .unwrap();

                                                                assert(
                                                                    purged_event
                                                                        .keys
                                                                        .at(0) == @event_name_hash('Compensate'),
                                                                    'wrong event'
                                                                );

                                                                // Note that this indirectly asserts that `Purged`
                                                                // is not emitted if it does not revert because
                                                                // `Purged` would have been emitted before `Compensate`
                                                                // let compensate_event: purger_contract::Compensate =
                                                                //     common::pop_event_with_indexed_keys(
                                                                //     purger.contract_address
                                                                // )
                                                                //     .unwrap();
                                                                // assert(
                                                                //     compensate_event == purger_contract::Compensate {
                                                                //         recipient: caller, compensation
                                                                //     },
                                                                //     'wrong Compensate event'
                                                                // );

                                                                // Check Shrine event
                                                                let expected_redistribution_id = 1;
                                                                let expected_events = array![
                                                                    (
                                                                        shrine.contract_address,
                                                                        shrine_contract::Event::TroveRedistributed(
                                                                            shrine_contract::TroveRedistributed {
                                                                                redistribution_id: expected_redistribution_id,
                                                                                trove_id: target_trove,
                                                                                debt: target_trove_updated_start_health
                                                                                    .debt,
                                                                            }
                                                                        )
                                                                    ),
                                                                ];

                                                                shrine_spy.assert_emitted(@expected_events);

                                                                shrine_utils::assert_shrine_invariants(
                                                                    shrine, yangs, abbot.get_troves_count(),
                                                                );
                                                            },
                                                            Option::None => { break; },
                                                        };
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
                },
                Option::None => { break; },
            };
        };
    }

    #[test]
    fn test_absorb_full_redistribution_parametrized1() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_absorb_full_redistribution(array![*recipient_trove_yang_asset_amts_cases[0]].span());
    }

    #[test]
    fn test_absorb_full_redistribution_parametrized2() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_absorb_full_redistribution(array![*recipient_trove_yang_asset_amts_cases[1]].span());
    }

    #[test]
    fn test_absorb_full_redistribution_parametrized3() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_absorb_full_redistribution(array![*recipient_trove_yang_asset_amts_cases[2]].span());
    }

    #[test]
    fn test_absorb_full_redistribution_parametrized4() {
        let mut recipient_trove_yang_asset_amts_cases = purger_utils::interesting_yang_amts_for_recipient_trove();
        test_absorb_full_redistribution(array![*recipient_trove_yang_asset_amts_cases[3]].span());
    }

    // This test parametrizes over thresholds (by setting all yangs thresholds to the given value)
    // and the LTV at liquidation, and checks for the following for thresholds up to 78.74%:
    // 1. LTV has decreased to the target safety margin
    // 2. trove's debt is reduced by the close amount, which is less than the trove's debt
    #[test]
    fn test_absorb_less_than_trove_debt_parametrized() {
        let classes = Option::Some(purger_utils::declare_contracts());

        let mut thresholds: Span<Ray> = purger_utils::interesting_thresholds_for_absorption_below_trove_debt();
        let mut target_ltvs_by_threshold: Span<Span<Ray>> =
            purger_utils::ltvs_for_interesting_thresholds_for_absorption_below_trove_debt();

        loop {
            match thresholds.pop_front() {
                Option::Some(threshold) => {
                    let mut target_ltvs: Span<Ray> = *target_ltvs_by_threshold.pop_front().unwrap();

                    // Inner loop iterating over LTVs at liquidation
                    loop {
                        match target_ltvs.pop_front() {
                            Option::Some(target_ltv) => {
                                let mut is_recovery_mode_fuzz: Span<bool> = array![false, true].span();
                                loop {
                                    match is_recovery_mode_fuzz.pop_front() {
                                        Option::Some(is_recovery_mode) => {
                                            let mut kill_absorber_fuzz: Span<bool> = array![true, false].span();

                                            match kill_absorber_fuzz.pop_front() {
                                                Option::Some(kill_absorber) => {
                                                    let (shrine, abbot, seer, absorber, purger, yangs, gates) =
                                                        purger_utils::purger_deploy(
                                                        classes
                                                    );

                                                    // Set thresholds to provided value
                                                    purger_utils::set_thresholds(shrine, yangs, *threshold);

                                                    let whale_trove: u64 = purger_utils::create_whale_trove(
                                                        abbot, yangs, gates
                                                    );

                                                    let trove_debt: Wad = (purger_utils::TARGET_TROVE_YIN * 5).into();
                                                    let target_trove: u64 = purger_utils::funded_healthy_trove(
                                                        abbot, yangs, gates, trove_debt
                                                    );

                                                    // Accrue some interest
                                                    common::advance_intervals_and_refresh_prices_and_multiplier(
                                                        shrine, yangs, 500
                                                    );

                                                    let target_trove_start_health: Health = shrine
                                                        .get_trove_health(target_trove);

                                                    // Fund the absorber with twice the target trove's debt
                                                    let absorber_start_yin: Wad = (target_trove_start_health.debt.val
                                                        * 2)
                                                        .into();
                                                    let other_trove_owner: ContractAddress =
                                                        absorber_utils::provider_1();
                                                    let other_trove: u64 = purger_utils::funded_absorber(
                                                        shrine, abbot, absorber, yangs, gates, absorber_start_yin
                                                    );

                                                    // sanity check
                                                    assert(
                                                        shrine
                                                            .get_yin(
                                                                absorber.contract_address
                                                            ) > target_trove_start_health
                                                            .debt,
                                                        'not full absorption'
                                                    );

                                                    // Make the target trove absorbable
                                                    purger_utils::lower_prices_to_raise_trove_ltv(
                                                        shrine,
                                                        seer,
                                                        yangs,
                                                        target_trove_start_health.value,
                                                        target_trove_start_health.debt,
                                                        *target_ltv
                                                    );

                                                    let mut target_trove_updated_start_health: Health = shrine
                                                        .get_trove_health(target_trove);

                                                    if *is_recovery_mode {
                                                        start_prank(
                                                            CheatTarget::One(abbot.contract_address),
                                                            purger_utils::target_trove_owner()
                                                        );
                                                        abbot.close_trove(whale_trove);
                                                        stop_prank(CheatTarget::One(abbot.contract_address));

                                                        purger_utils::trigger_recovery_mode(
                                                            shrine, abbot, other_trove, other_trove_owner
                                                        );

                                                        target_trove_updated_start_health = shrine
                                                            .get_trove_health(target_trove);
                                                    } else {
                                                        assert(!shrine.is_recovery_mode(), 'recovery mode');
                                                    }

                                                    purger_utils::assert_trove_is_absorbable(
                                                        shrine,
                                                        purger,
                                                        target_trove,
                                                        target_trove_updated_start_health.ltv
                                                    );

                                                    if *kill_absorber {
                                                        absorber_utils::kill_absorber(absorber);
                                                        assert(!absorber.get_live(), 'sanity check');
                                                    }

                                                    let (penalty, max_close_amt, expected_compensation_value) = purger
                                                        .preview_absorb(target_trove)
                                                        .expect('Should be absorbable');
                                                    assert(
                                                        max_close_amt < target_trove_updated_start_health.debt,
                                                        'close amount == debt'
                                                    );

                                                    let caller: ContractAddress = purger_utils::random_user();
                                                    start_prank(CheatTarget::One(purger.contract_address), caller);
                                                    let compensation: Span<AssetBalance> = purger.absorb(target_trove);

                                                    // Check that LTV is close to safety margin
                                                    let target_trove_after_health: Health = shrine
                                                        .get_trove_health(target_trove);
                                                    assert(
                                                        target_trove_after_health
                                                            .debt == target_trove_updated_start_health
                                                            .debt
                                                            - max_close_amt,
                                                        'wrong debt after liquidation'
                                                    );

                                                    purger_utils::assert_ltv_at_safety_margin(
                                                        target_trove_updated_start_health.threshold,
                                                        target_trove_after_health.ltv
                                                    );

                                                    let (expected_freed_pct, expected_freed_amts) =
                                                        purger_utils::get_expected_liquidation_assets(
                                                        purger_utils::target_trove_yang_asset_amts(),
                                                        target_trove_updated_start_health.value,
                                                        max_close_amt,
                                                        penalty,
                                                        Option::Some(expected_compensation_value)
                                                    );
                                                    let expected_freed_assets: Span<AssetBalance> =
                                                        common::combine_assets_and_amts(
                                                        yangs, expected_freed_amts
                                                    );

                                                    // let purged_event: purger_contract::Purged =
                                                    //     common::pop_event_with_indexed_keys(
                                                    //     purger.contract_address
                                                    // )
                                                    //     .unwrap();
                                                    // common::assert_asset_balances_equalish(
                                                    //     purged_event.freed_assets,
                                                    //     expected_freed_assets,
                                                    //     1000_u128,
                                                    //     'wrong freed assets for event'
                                                    // );
                                                    // assert(
                                                    //     purged_event.trove_id == target_trove,
                                                    //     'wrong Purged trove ID'
                                                    // );
                                                    // assert(
                                                    //     purged_event.purge_amt == max_close_amt,
                                                    //     'wrong Purged amt'
                                                    // );
                                                    // common::assert_equalish(
                                                    //     purged_event.percentage_freed,
                                                    //     expected_freed_pct,
                                                    //     1000000_u128.into(),
                                                    //     'wrong Purged freed pct'
                                                    // );
                                                    // assert(
                                                    //     purged_event.funder == absorber.contract_address,
                                                    //     'wrong Purged funder'
                                                    // );
                                                    // assert(
                                                    //     purged_event.recipient == absorber.contract_address,
                                                    //     'wrong Purged recipient'
                                                    // );

                                                    // let compensate_event: purger_contract::Compensate =
                                                    //     common::pop_event_with_indexed_keys(
                                                    //     purger.contract_address
                                                    // )
                                                    //     .unwrap();
                                                    // assert(
                                                    //     compensate_event == purger_contract::Compensate {
                                                    //         recipient: caller, compensation
                                                    //     },
                                                    //     'wrong Compensate event'
                                                    // );

                                                    shrine_utils::assert_shrine_invariants(
                                                        shrine, yangs, abbot.get_troves_count()
                                                    );
                                                },
                                                Option::None => { break; },
                                            };
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

    // This test parametrizes over thresholds (by setting all yangs thresholds to the given value)
    // and the LTV at liquidation, and checks that the trove's debt is absorbed in full for thresholds
    // from 78.74% onwards.
    fn test_absorb_trove_debt(is_recovery_mode: bool) {
        let classes = Option::Some(purger_utils::declare_contracts());

        let mut thresholds: Span<Ray> = purger_utils::interesting_thresholds_for_absorption_entire_trove_debt();
        let mut target_ltvs_by_threshold: Span<Span<Ray>> =
            purger_utils::ltvs_for_interesting_thresholds_for_absorption_entire_trove_debt();

        // This array should match `target_ltvs_by_threshold`. However, since only the first
        // LTV in the inner span of `target_ltvs_by_threshold` has a non-zero penalty, and the
        // penalty will be zero from the seocnd LTV of 99% (Ray) onwards, we flatten
        // the array to be concise.
        let ninety_nine_pct: Ray = (RAY_ONE - RAY_PERCENT).into();
        let mut expected_penalties: Span<Ray> = array![
            // First threshold of 78.75% (Ray)
            124889600000000000000000000_u128.into(), // 12.48896% (Ray); 86.23% LTV
            // Second threshold of 80% (Ray)
            116217800000000000000000000_u128.into(), // 11.62178% (Ray); 86.9% LTV
            // Third threshold of 90% (Ray)
            53196900000000000000000000_u128.into(), // 5.31969% (Ray); 92.1% LTV
            // Fourth threshold of 96% (Ray)
            10141202000000000000000000_u128.into(), // 1.0104102; (96 + 1 wei)% LTV
            // Fifth threshold of 97% (Ray)
            RayZeroable::zero(), // Dummy value since all target LTVs do not have a penalty
            // Sixth threshold of 99% (Ray)
            RayZeroable::zero(), // Dummy value since all target LTVs do not have a penalty
        ]
            .span();

        loop {
            match thresholds.pop_front() {
                Option::Some(threshold) => {
                    let mut target_ltvs: Span<Ray> = *target_ltvs_by_threshold.pop_front().unwrap();
                    let expected_penalty: Ray = *expected_penalties.pop_front().unwrap();
                    // Inner loop iterating over LTVs at liquidation
                    loop {
                        match target_ltvs.pop_front() {
                            Option::Some(target_ltv) => {
                                let mut kill_absorber_fuzz: Span<bool> = array![true, false].span();

                                match kill_absorber_fuzz.pop_front() {
                                    Option::Some(kill_absorber) => {
                                        let (shrine, abbot, seer, absorber, purger, yangs, gates) =
                                            purger_utils::purger_deploy(
                                            classes
                                        );

                                        // Set thresholds to provided value
                                        purger_utils::set_thresholds(shrine, yangs, *threshold);

                                        let trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
                                        let target_trove: u64 = purger_utils::funded_healthy_trove(
                                            abbot, yangs, gates, trove_debt
                                        );

                                        // Accrue some interest
                                        common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

                                        let target_trove_start_health: Health = shrine.get_trove_health(target_trove);

                                        // Fund the absorber with twice the target trove's debt
                                        let absorber_start_yin: Wad = (target_trove_start_health.debt.val * 2).into();
                                        let other_trove_owner: ContractAddress = absorber_utils::provider_1();
                                        let other_trove: u64 = purger_utils::funded_absorber(
                                            shrine, abbot, absorber, yangs, gates, absorber_start_yin
                                        );

                                        // sanity check
                                        assert(
                                            shrine.get_yin(absorber.contract_address) > target_trove_start_health.debt,
                                            'not full absorption'
                                        );

                                        // Make the target trove absorbable
                                        purger_utils::lower_prices_to_raise_trove_ltv(
                                            shrine,
                                            seer,
                                            yangs,
                                            target_trove_start_health.value,
                                            target_trove_start_health.debt,
                                            *target_ltv
                                        );

                                        let mut target_trove_updated_start_health: Health = shrine
                                            .get_trove_health(target_trove);

                                        if is_recovery_mode {
                                            purger_utils::trigger_recovery_mode(
                                                shrine, abbot, other_trove, other_trove_owner
                                            );
                                            target_trove_updated_start_health = shrine.get_trove_health(target_trove);
                                        } else {
                                            assert(!shrine.is_recovery_mode(), 'recovery mode');
                                        }

                                        purger_utils::assert_trove_is_absorbable(
                                            shrine, purger, target_trove, target_trove_updated_start_health.ltv
                                        );

                                        if *kill_absorber {
                                            absorber_utils::kill_absorber(absorber);
                                            assert(!absorber.get_live(), 'sanity check');
                                        }

                                        let (penalty, max_close_amt, expected_compensation_value) = purger
                                            .preview_absorb(target_trove)
                                            .expect('Should be absorbable');
                                        assert(
                                            max_close_amt == target_trove_updated_start_health.debt,
                                            'close amount != debt'
                                        );
                                        if *target_ltv >= ninety_nine_pct {
                                            assert(penalty.is_zero(), 'wrong penalty');
                                        } else {
                                            common::assert_equalish(
                                                penalty,
                                                expected_penalty,
                                                (RAY_PERCENT / 10).into(), // 0.1%
                                                'wrong penalty'
                                            )
                                        }

                                        let caller: ContractAddress = purger_utils::random_user();
                                        start_prank(CheatTarget::One(purger.contract_address), caller);
                                        let compensation: Span<AssetBalance> = purger.absorb(target_trove);

                                        // Check that LTV is close to safety margin
                                        let target_trove_after_health: Health = shrine.get_trove_health(target_trove);
                                        assert(target_trove_after_health.ltv.is_zero(), 'wrong LTV after liquidation');
                                        assert(
                                            target_trove_after_health.value.is_zero(), 'wrong value after liquidation'
                                        );
                                        assert(
                                            target_trove_after_health.debt.is_zero(), 'wrong debt after liquidation'
                                        );

                                        let target_trove_yang_asset_amts: Span<u128> =
                                            purger_utils::target_trove_yang_asset_amts();
                                        let (_, expected_freed_asset_amts) =
                                            purger_utils::get_expected_liquidation_assets(
                                            target_trove_yang_asset_amts,
                                            target_trove_updated_start_health.value,
                                            max_close_amt,
                                            penalty,
                                            Option::Some(expected_compensation_value)
                                        );

                                        let expected_freed_assets: Span<AssetBalance> = common::combine_assets_and_amts(
                                            yangs, expected_freed_asset_amts,
                                        );

                                        // let purged_event: purger_contract::Purged =
                                        //     common::pop_event_with_indexed_keys(
                                        //     purger.contract_address
                                        // )
                                        //     .unwrap();
                                        // assert(
                                        //     purged_event.trove_id == target_trove,
                                        //     'wrong Purged trove ID'
                                        // );
                                        // assert(
                                        //     purged_event.purge_amt == max_close_amt,
                                        //     'wrong Purged amt'
                                        // );
                                        // assert(
                                        //     purged_event.percentage_freed == RAY_ONE.into(),
                                        //     'wrong Purged freed pct'
                                        // );
                                        // assert(
                                        //     purged_event.funder == absorber.contract_address,
                                        //     'wrong Purged funder'
                                        // );
                                        // assert(
                                        //     purged_event.recipient == absorber.contract_address,
                                        //     'wrong Purged recipient'
                                        // );
                                        // common::assert_asset_balances_equalish(
                                        //     purged_event.freed_assets,
                                        //     expected_freed_assets,
                                        //     100000_u128,
                                        //     'wrong freed assets for event'
                                        // );

                                        // let compensate_event: purger_contract::Compensate =
                                        //     common::pop_event_with_indexed_keys(
                                        //     purger.contract_address
                                        // )
                                        //     .unwrap();
                                        // assert(
                                        //     compensate_event == purger_contract::Compensate {
                                        //         recipient: caller, compensation
                                        //     },
                                        //     'wrong Compensate event'
                                        // );

                                        shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
                                    },
                                    Option::None => { break; },
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
    fn test_absorb_trove_debt_parametrized1() {
        test_absorb_trove_debt(false);
    }

    #[test]
    fn test_absorb_trove_debt_parametrized2() {
        test_absorb_trove_debt(true);
    }

    #[test]
    #[should_panic(expected: ('PU: Not absorbable',))]
    fn test_absorb_trove_healthy_fail() {
        let (shrine, abbot, _, absorber, purger, yangs, gates) = purger_utils::purger_deploy_with_searcher(
            purger_utils::SEARCHER_YIN.into(), Option::None
        );

        let trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
        let healthy_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, trove_debt);

        purger_utils::funded_absorber(shrine, abbot, absorber, yangs, gates, trove_debt);

        purger_utils::assert_trove_is_healthy(shrine, purger, healthy_trove);

        start_prank(CheatTarget::One(purger.contract_address), purger_utils::random_user());
        purger.absorb(healthy_trove);
    }

    #[test]
    #[should_panic(expected: ('PU: Not absorbable',))]
    fn test_absorb_below_absorbable_ltv_fail() {
        let (shrine, abbot, seer, absorber, purger, yangs, gates) = purger_utils::purger_deploy_with_searcher(
            purger_utils::SEARCHER_YIN.into(), Option::None
        );

        purger_utils::create_whale_trove(abbot, yangs, gates);

        let trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
        let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, trove_debt);
        purger_utils::funded_absorber(shrine, abbot, absorber, yangs, gates, trove_debt);

        let target_trove_health: Health = shrine.get_trove_health(target_trove);
        let target_ltv: Ray = target_trove_health.threshold + RAY_PERCENT.into();
        purger_utils::lower_prices_to_raise_trove_ltv(
            shrine, seer, yangs, target_trove_health.value, target_trove_health.debt, target_ltv
        );

        purger_utils::assert_trove_is_liquidatable(shrine, purger, target_trove, target_trove_health.ltv);
        purger_utils::assert_trove_is_not_absorbable(purger, target_trove);

        start_prank(CheatTarget::One(purger.contract_address), purger_utils::random_user());
        purger.absorb(target_trove);
    }

    // For thresholds < 90%, check that the LTV at which the trove is absorbable minus
    // 0.01% is not absorbable.
    #[test]
    fn test_absorb_marginally_below_absorbable_ltv_not_absorbable() {
        let classes = Option::Some(purger_utils::declare_contracts());

        let (mut thresholds, mut target_ltvs) = purger_utils::interesting_thresholds_and_ltvs_below_absorption_ltv();

        loop {
            match thresholds.pop_front() {
                Option::Some(threshold) => {
                    let searcher_start_yin: Wad = purger_utils::SEARCHER_YIN.into();
                    let (shrine, abbot, seer, absorber, purger, yangs, gates) =
                        purger_utils::purger_deploy_with_searcher(
                        searcher_start_yin, classes
                    );

                    purger_utils::create_whale_trove(abbot, yangs, gates);

                    // Set thresholds to provided value
                    purger_utils::set_thresholds(shrine, yangs, *threshold);

                    let trove_debt: Wad = purger_utils::TARGET_TROVE_YIN.into();
                    let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, trove_debt);

                    // Accrue some interest
                    common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

                    let target_trove_start_health: Health = shrine.get_trove_health(target_trove);

                    // Fund the absorber with twice the target trove's debt
                    let absorber_start_yin: Wad = (target_trove_start_health.debt.val * 2).into();
                    purger_utils::funded_absorber(shrine, abbot, absorber, yangs, gates, absorber_start_yin);

                    // Adjust the trove to the target LTV
                    purger_utils::lower_prices_to_raise_trove_ltv(
                        shrine,
                        seer,
                        yangs,
                        target_trove_start_health.value,
                        target_trove_start_health.debt,
                        *target_ltvs.pop_front().unwrap()
                    );

                    let updated_target_trove_start_health: Health = shrine.get_trove_health(target_trove);
                    purger_utils::assert_trove_is_liquidatable(
                        shrine, purger, target_trove, updated_target_trove_start_health.ltv
                    );
                    purger_utils::assert_trove_is_not_absorbable(purger, target_trove);
                },
                Option::None => { break; },
            };
        };
    }

    #[test]
    #[ignore]
    fn test_liquidate_suspended_yang() {
        let (shrine, abbot, _, absorber, purger, yangs, gates) = purger_utils::purger_deploy_with_searcher(
            purger_utils::SEARCHER_YIN.into(), Option::None
        );

        // user 1 opens a trove with ETH and BTC that is close to liquidation
        // `funded_healthy_trove` supplies 2 ETH and 0.5 BTC totalling $9000 in value, so we
        // create $6000 of debt to ensure the trove is closer to liquidation
        let trove_debt: Wad = (6000 * WAD_ONE).into();
        let target_trove: u64 = purger_utils::funded_healthy_trove(abbot, yangs, gates, trove_debt);

        // Suspend BTC
        let btc: ContractAddress = *yangs[1];
        let current_timestamp: u64 = get_block_timestamp();

        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        shrine.suspend_yang(btc);
        stop_prank(CheatTarget::One(shrine.contract_address));

        assert(shrine.is_healthy(target_trove), 'should still be healthy');

        // The trove has $6000 in debt and $9000 in collateral. BTC's value must decrease
        let target_trove_start_health: Health = shrine.get_trove_health(target_trove);

        let eth_threshold: Ray = shrine_utils::YANG1_THRESHOLD.into();
        let btc_threshold: Ray = shrine_utils::YANG2_THRESHOLD.into();

        let (eth_price, _, _) = shrine.get_current_yang_price(*yangs[0]);
        let (btc_price, _, _) = shrine.get_current_yang_price(*yangs[1]);

        let eth_value: Wad = eth_price * shrine.get_deposit(*yangs[0], target_trove);
        let btc_value: Wad = btc_price * shrine.get_deposit(*yangs[1], target_trove);

        // These represent the percentages of the total value of the trove each
        // of the yangs respectively make up
        let eth_weight: Ray = wadray::rdiv_ww(eth_value, target_trove_start_health.value);
        let btc_weight: Ray = wadray::rdiv_ww(btc_value, target_trove_start_health.value);

        // We need to decrease BTC's threshold until the trove threshold equals `ltv`
        // we derive the decrease factor from the following equation:
        //
        // NOTE: decrease factor is the value which, if we multiply BTC's threshold by it, will give us
        // the threshold BTC must have in order for the trove's threshold to equal its LTV
        //
        // (eth_value / total_value) * eth_threshold + (btc_value / total_value) * btc_threshold * decrease_factor = ltv
        // eth_weight * eth_threshold + btc_weight * btc_threshold * decrease_factor = ltv
        // btc_weight * btc_threshold * decrease_factor = ltv - eth_weight * eth_threshold
        // decrease_factor = (ltv - eth_weight * eth_threshold) / (btc_weight * btc_threshold)
        let btc_threshold_decrease_factor: Ray = (target_trove_start_health.ltv - eth_weight * eth_threshold)
            / (btc_weight * btc_threshold);
        let ts_diff: u64 = shrine_contract::SUSPENSION_GRACE_PERIOD
            - scale_u128_by_ray(shrine_contract::SUSPENSION_GRACE_PERIOD.into(), btc_threshold_decrease_factor)
                .try_into()
                .unwrap();

        // Adding one to offset any precision loss
        let new_timestamp: u64 = current_timestamp + ts_diff + 1;
        start_warp(CheatTarget::All, new_timestamp);

        assert(!shrine.is_healthy(target_trove), 'should be unhealthy');

        // Liquidate the trove
        let searcher = purger_utils::searcher();
        start_prank(CheatTarget::One(purger.contract_address), searcher);
        purger.liquidate(target_trove, target_trove_start_health.debt, searcher);

        // Sanity checks
        let target_trove_after_health: Health = shrine.get_trove_health(target_trove);

        assert(target_trove_after_health.debt < target_trove_start_health.debt, 'trove not correctly liquidated');

        assert(
            IERC20Dispatcher { contract_address: shrine.contract_address }
                .balance_of(searcher)
                .try_into()
                .unwrap() < purger_utils::SEARCHER_YIN,
            'searcher yin not used'
        );

        purger_utils::assert_ltv_at_safety_margin(target_trove_after_health.threshold, target_trove_after_health.ltv);
    }

    #[test]
    #[ignore]
    fn test_liquidate_suspended_yang_threshold_near_zero() {
        let (shrine, abbot, _, absorber, purger, yangs, gates) = purger_utils::purger_deploy_with_searcher(
            purger_utils::SEARCHER_YIN.into(), Option::None
        );

        // We run the same tests using both searcher liquidations and absorptions as the liquidation methods.
        let mut liquidate_via_absorption_param: Span<bool> = array![
            false, //true - we comment this parametrization out for now, due to failing in CI
        ]
            .span();

        // We parametrize this test with both a reasonable starting LTV and a very low starting LTV
        let trove_debt_param: Span<Wad> = array![(600 * WAD_ONE).into(), (20 * WAD_ONE).into()].span();

        // We also parametrize the test with the desired threshold after liquidation
        let desired_threshold_param: Span<Ray> = array![
            RAY_PERCENT.into(),
            (RAY_PERCENT / 4).into(),
            // This is the smallest possible desired threshold that
            // doesn't result in advancing the time enough to make
            // the suspension permanent
            (RAY_ONE + 1).into() / (RAY_ONE * shrine_contract::SUSPENSION_GRACE_PERIOD.into()).into(),
        ]
            .span();

        let eth: ContractAddress = *yangs[0];
        let eth_gate: IGateDispatcher = *gates[0];

        let target_user: ContractAddress = purger_utils::target_trove_owner();

        common::fund_user(target_user, array![eth].span(), array![(10 * WAD_ONE).into()].span());

        // Have the searcher provide half of his yin to the absorber
        let searcher = purger_utils::searcher();
        let yin_erc20 = IERC20Dispatcher { contract_address: shrine.contract_address };

        start_prank(CheatTarget::Multiple(array![shrine.contract_address, absorber.contract_address]), searcher);
        yin_erc20.approve(absorber.contract_address, (purger_utils::SEARCHER_YIN / 2).into());
        stop_prank(CheatTarget::One(shrine.contract_address));

        absorber.provide((purger_utils::SEARCHER_YIN / 2).into());
        stop_prank(CheatTarget::One(absorber.contract_address));

        loop {
            match liquidate_via_absorption_param.pop_front() {
                Option::Some(liquidate_via_absorption) => {
                    let mut trove_debt_param_copy = trove_debt_param;
                    loop {
                        match trove_debt_param_copy.pop_front() {
                            Option::Some(trove_debt) => {
                                let mut desired_threshold_param_copy = desired_threshold_param;
                                loop {
                                    match desired_threshold_param_copy.pop_front() {
                                        Option::Some(desired_threshold) => {
                                            let mut is_recovery_mode_fuzz: Span<bool> = array![false, true].span();
                                            loop {
                                                match is_recovery_mode_fuzz.pop_front() {
                                                    Option::Some(is_recovery_mode) => {
                                                        let target_trove: u64 = common::open_trove_helper(
                                                            abbot,
                                                            target_user,
                                                            array![eth].span(),
                                                            array![(WAD_ONE / 2).into()].span(),
                                                            array![eth_gate].span(),
                                                            *trove_debt
                                                        );

                                                        // Suspend ETH
                                                        let current_timestamp = get_block_timestamp();

                                                        start_prank(
                                                            CheatTarget::One(shrine.contract_address),
                                                            shrine_utils::admin()
                                                        );
                                                        shrine.suspend_yang(eth);
                                                        stop_prank(CheatTarget::One(shrine.contract_address));

                                                        // Advance the time stamp such that the ETH threshold falls to `desired_threshold`
                                                        let eth_threshold: Ray = shrine_utils::YANG1_THRESHOLD.into();

                                                        let decrease_factor: Ray = *desired_threshold / eth_threshold;
                                                        let ts_diff: u64 = shrine_contract::SUSPENSION_GRACE_PERIOD
                                                            - scale_u128_by_ray(
                                                                shrine_contract::SUSPENSION_GRACE_PERIOD.into(),
                                                                decrease_factor
                                                            )
                                                                .try_into()
                                                                .unwrap();

                                                        start_warp(CheatTarget::All, current_timestamp + ts_diff);

                                                        // Check that the threshold has decreased to the desired value

                                                        if *is_recovery_mode {
                                                            let whale_trove_owner: ContractAddress =
                                                                purger_utils::target_trove_owner();
                                                            let whale_trove: u64 = purger_utils::create_whale_trove(
                                                                abbot, yangs, gates
                                                            );

                                                            purger_utils::trigger_recovery_mode(
                                                                shrine, abbot, whale_trove, whale_trove_owner
                                                            );

                                                            let (_, threshold_before_liquidation) = shrine
                                                                .get_yang_threshold(eth);
                                                            assert(
                                                                threshold_before_liquidation < *desired_threshold
                                                                    - 100000000000000000000_u128.into(),
                                                                'not recovery mode'
                                                            )
                                                        } else {
                                                            let (_, threshold_before_liquidation) = shrine
                                                                .get_yang_threshold(eth);

                                                            common::assert_equalish(
                                                                threshold_before_liquidation,
                                                                *desired_threshold,
                                                                // 0.0000001 = 10^-7 (ray). Precision
                                                                // is limited by the precision of timestamps,
                                                                // which is only in seconds
                                                                100000000000000000000_u128.into(),
                                                                'wrong eth threshold'
                                                            );
                                                        }

                                                        // We want to compare the yin balance of the liquidator
                                                        // before and after the liquidation. In the case of absorption
                                                        // we check the absorber's balance, and in the case of
                                                        // searcher liquidation we check the searcher's balance.
                                                        let before_liquidation_yin_balance: u256 =
                                                            if *liquidate_via_absorption {
                                                            yin_erc20.balance_of(absorber.contract_address)
                                                        } else {
                                                            yin_erc20.balance_of(searcher)
                                                        };

                                                        // Liquidate the trove
                                                        start_prank(
                                                            CheatTarget::One(purger.contract_address), searcher
                                                        );

                                                        if *liquidate_via_absorption {
                                                            purger.absorb(target_trove);
                                                        } else {
                                                            purger.liquidate(target_trove, *trove_debt, searcher);
                                                        }

                                                        // Sanity checks
                                                        let target_trove_after_health: Health = shrine
                                                            .get_trove_health(target_trove);

                                                        assert(
                                                            target_trove_after_health.debt < *trove_debt,
                                                            'trove not correctly liquidated'
                                                        );

                                                        // Checking that the liquidator's yin balance has decreased
                                                        // after liquidation
                                                        if *liquidate_via_absorption {
                                                            assert(
                                                                yin_erc20
                                                                    .balance_of(
                                                                        absorber.contract_address
                                                                    ) < before_liquidation_yin_balance,
                                                                'absorber yin not used'
                                                            );
                                                        } else {
                                                            assert(
                                                                yin_erc20
                                                                    .balance_of(
                                                                        searcher
                                                                    ) < before_liquidation_yin_balance,
                                                                'searcher yin not used'
                                                            );
                                                        }

                                                        start_prank(
                                                            CheatTarget::One(shrine.contract_address),
                                                            shrine_utils::admin()
                                                        );
                                                        shrine.unsuspend_yang(eth);
                                                        stop_prank(CheatTarget::One(shrine.contract_address));
                                                    },
                                                    Option::None => { break; },
                                                };
                                            };
                                        },
                                        Option::None => { break; }
                                    }
                                };
                            },
                            Option::None => { break; }
                        };
                    };
                },
                Option::None => { break; }
            }
        };
    }
    #[derive(Copy, Drop, PartialEq)]
    enum AbsorbType {
        Full: (),
        Partial: (),
        None: (),
    }

    #[test]
    #[ignore]
    fn test_absorb_low_thresholds() {
        let whale_trove_owner: ContractAddress = purger_utils::target_trove_owner();

        let searcher_start_yin: Wad = (purger_utils::SEARCHER_YIN * 6).into();
        // Execution time is significantly reduced
        // by only deploying the contracts once for all parametrizations
        let (shrine, abbot, _, absorber, purger, yangs, gates) = purger_utils::purger_deploy_with_searcher(
            searcher_start_yin, Option::None
        );

        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        shrine.set_debt_ceiling((10000000 * WAD_ONE).into());

        let yin_erc20: IERC20Dispatcher = IERC20Dispatcher { contract_address: shrine.contract_address };

        let searcher = purger_utils::searcher();

        // Approve absorber for maximum yin
        start_prank(CheatTarget::One(shrine.contract_address), searcher);
        yin_erc20.approve(absorber.contract_address, BoundedU256::max());

        stop_prank(CheatTarget::One(shrine.contract_address));

        // Parameters
        let mut thresholds_param: Span<Ray> = array![RayZeroable::zero(), RAY_PERCENT.into(),].span();

        let absorb_type_param: Span<AbsorbType> = array![AbsorbType::Full, AbsorbType::Partial, AbsorbType::None]
            .span();

        loop {
            match thresholds_param.pop_front() {
                Option::Some(threshold) => {
                    let mut target_ltvs_param: Span<Ray> = array![
                        *threshold + 1_u128.into(), *threshold + (RAY_ONE / 2).into(),
                    ]
                        .span();

                    loop {
                        match target_ltvs_param.pop_front() {
                            Option::Some(target_ltv) => {
                                let mut absorb_type_param_copy = absorb_type_param;
                                loop {
                                    match absorb_type_param_copy.pop_front() {
                                        Option::Some(absorb_type) => {
                                            let mut is_recovery_mode_fuzz: Span<bool> = array![false, true].span();
                                            loop {
                                                match is_recovery_mode_fuzz.pop_front() {
                                                    Option::Some(is_recovery_mode) => {
                                                        // Calculating the `trove_debt` necessary to achieve
                                                        // the `target_ltv`
                                                        let target_trove_yang_amts: Span<Wad> = array![
                                                            (*gates[0])
                                                                .convert_to_yang(
                                                                    purger_utils::TARGET_TROVE_ETH_DEPOSIT_AMT
                                                                ),
                                                            (*gates[1])
                                                                .convert_to_yang(
                                                                    purger_utils::TARGET_TROVE_WBTC_DEPOSIT_AMT
                                                                ),
                                                        ]
                                                            .span();

                                                        let trove_value: Wad = purger_utils::get_sum_of_value(
                                                            shrine, yangs, target_trove_yang_amts
                                                        );

                                                        // Add 100 Wad to guarantee recovery mode for non-zero debt.
                                                        // In case of rounding down to zero, set to 1 wei.
                                                        let trove_debt: Wad = max(
                                                            wadray::rmul_wr(trove_value, *target_ltv)
                                                                + (100 * WAD_ONE).into(),
                                                            1_u128.into()
                                                        );

                                                        // We skip test cases of partial liquidations where
                                                        // the trove debt is less than the minimum shares in absorber.
                                                        // While it can be done, it is complicated to set up the absorber in such a
                                                        // way that the remaining yin is less than the minimum shares.
                                                        if *absorb_type == AbsorbType::Partial
                                                            && trove_debt <= absorber_contract::MINIMUM_SHARES.into() {
                                                            continue;
                                                        }
                                                        // Resetting the thresholds to reasonable values
                                                        // to allow for creating troves at higher LTVs
                                                        purger_utils::set_thresholds(
                                                            shrine, yangs, (80 * RAY_PERCENT).into()
                                                        );

                                                        // Clearing/"resetting" the absorber
                                                        // if it needs to be reset
                                                        if yin_erc20
                                                            .balance_of(absorber.contract_address)
                                                            .is_non_zero() {
                                                            let (eth_price, _, _) = shrine
                                                                .get_current_yang_price(*yangs[0]);
                                                            let (wbtc_price, _, _) = shrine
                                                                .get_current_yang_price(*yangs[1]);

                                                            start_warp(
                                                                CheatTarget::All,
                                                                get_block_timestamp()
                                                                    + absorber_contract::REQUEST_COOLDOWN
                                                            );

                                                            // Update yang prices to save gas on fetching them in Shrine functions
                                                            start_prank(
                                                                CheatTarget::One(shrine.contract_address),
                                                                shrine_utils::admin()
                                                            );
                                                            shrine.advance(*yangs[0], eth_price);
                                                            shrine.advance(*yangs[1], wbtc_price);
                                                            stop_prank(CheatTarget::One(shrine.contract_address));

                                                            // Make a removal request and then remove the searcher's position
                                                            start_prank(
                                                                CheatTarget::One(absorber.contract_address), searcher
                                                            );
                                                            absorber.request();
                                                            stop_prank(CheatTarget::One(absorber.contract_address));

                                                            start_warp(
                                                                CheatTarget::All,
                                                                get_block_timestamp()
                                                                    + absorber_contract::REQUEST_COOLDOWN
                                                            );

                                                            let searcher_provided_yin: Wad = absorber
                                                                .preview_remove(searcher);
                                                            // Removing any remaining yin, and/or
                                                            // remaining absorbed assets due to the
                                                            // provider.

                                                            if searcher_provided_yin.is_non_zero() {
                                                                absorber.remove(searcher_provided_yin);
                                                            } else {
                                                                absorber.reap();
                                                            }
                                                        }

                                                        // Creating the trove to be liquidated
                                                        let target_trove: u64 = purger_utils::funded_healthy_trove(
                                                            abbot, yangs, gates, trove_debt
                                                        );

                                                        // Now, the searcher deposits some yin into the absorber
                                                        // The amount depends on whether we want a full or partial absorption, or
                                                        // a full redistribution

                                                        start_prank(
                                                            CheatTarget::One(absorber.contract_address), searcher
                                                        );

                                                        match *absorb_type {
                                                            AbsorbType::Full => {
                                                                // We provide *at least* the minimum shares
                                                                absorber
                                                                    .provide(
                                                                        max(
                                                                            trove_debt,
                                                                            absorber_contract::MINIMUM_SHARES.into()
                                                                        )
                                                                    );
                                                            },
                                                            AbsorbType::Partial => {
                                                                // We add 1 wei in the event that `trove_debt` is extremely small,
                                                                // to avoid the provision amount from being zero.

                                                                absorber
                                                                    .provide(
                                                                        max(
                                                                            (trove_debt.val / 2).into() + 1_u128.into(),
                                                                            absorber_contract::MINIMUM_SHARES.into()
                                                                        )
                                                                    );
                                                            },
                                                            AbsorbType::None => {},
                                                        };

                                                        stop_prank(CheatTarget::One(absorber.contract_address));

                                                        let whale_trove: u64 = if *is_recovery_mode {
                                                            // Mint enough debt to trigger recovery mode before
                                                            // thresholds are set to a very low value
                                                            let trove_id: u64 = purger_utils::create_whale_trove(
                                                                abbot, yangs, gates
                                                            );
                                                            purger_utils::trigger_recovery_mode(
                                                                shrine, abbot, trove_id, whale_trove_owner
                                                            );

                                                            trove_id
                                                        } else {
                                                            // Otherwise, create a whale trove to prevent recovery
                                                            // mode from beign triggered
                                                            let deposit_amts: Span<u128> =
                                                                purger_utils::whale_trove_yang_asset_amts();
                                                            common::fund_user(whale_trove_owner, yangs, deposit_amts);
                                                            common::open_trove_helper(
                                                                abbot,
                                                                whale_trove_owner,
                                                                yangs,
                                                                deposit_amts,
                                                                gates,
                                                                WAD_ONE.into()
                                                            )
                                                        };

                                                        // Setting the threshold to the desired value
                                                        // the target trove is now absorbable
                                                        purger_utils::set_thresholds(shrine, yangs, *threshold);

                                                        let target_trove_start_health: Health = shrine
                                                            .get_trove_health(target_trove);
                                                        if *is_recovery_mode && (*threshold).is_non_zero() {
                                                            assert(shrine.is_recovery_mode(), 'not recovery mode');
                                                        } else if (*threshold).is_non_zero() {
                                                            // skip zero threshold because recovery mode
                                                            // is unavoidable
                                                            assert(!shrine.is_recovery_mode(), 'recovery mode');
                                                        }

                                                        let (penalty, max_close_amt, expected_compensation_value) =
                                                            purger
                                                            .preview_absorb(target_trove)
                                                            .expect('Should be absorbable');

                                                        start_prank(
                                                            CheatTarget::One(purger.contract_address), searcher
                                                        );

                                                        let absorber_eth_bal_before_absorb: u128 = IERC20Dispatcher {
                                                            contract_address: *yangs[0]
                                                        }
                                                            .balance_of(absorber.contract_address)
                                                            .try_into()
                                                            .unwrap();
                                                        let absorber_wbtc_bal_before_absorb: u128 = IERC20Dispatcher {
                                                            contract_address: *yangs[1]
                                                        }
                                                            .balance_of(absorber.contract_address)
                                                            .try_into()
                                                            .unwrap();

                                                        let absorber_yin_bal_before_absorb: Wad = yin_erc20
                                                            .balance_of(absorber.contract_address)
                                                            .try_into()
                                                            .unwrap();

                                                        let compensation: Span<AssetBalance> = purger
                                                            .absorb(target_trove);

                                                        // Checking that the compensation is correct
                                                        let actual_eth_comp: AssetBalance = *compensation[0];
                                                        let actual_wbtc_comp: AssetBalance = *compensation[1];

                                                        let expected_compensation_pct: Ray = wadray::rdiv_ww(
                                                            purger_contract::COMPENSATION_CAP.into(),
                                                            target_trove_start_health.value
                                                        );

                                                        let expected_eth_comp: u128 = scale_u128_by_ray(
                                                            purger_utils::TARGET_TROVE_ETH_DEPOSIT_AMT,
                                                            expected_compensation_pct
                                                        );

                                                        let expected_wbtc_comp: u128 = scale_u128_by_ray(
                                                            purger_utils::TARGET_TROVE_WBTC_DEPOSIT_AMT,
                                                            expected_compensation_pct
                                                        );

                                                        common::assert_equalish(
                                                            expected_eth_comp,
                                                            actual_eth_comp.amount,
                                                            1_u128,
                                                            'wrong eth compensation'
                                                        );

                                                        common::assert_equalish(
                                                            expected_wbtc_comp,
                                                            actual_wbtc_comp.amount,
                                                            1_u128,
                                                            'wrong wbtc compensation'
                                                        );

                                                        let actual_compensation_value: Wad =
                                                            purger_utils::get_sum_of_value(
                                                            shrine,
                                                            yangs,
                                                            array![
                                                                (*gates[0]).convert_to_yang(actual_eth_comp.amount),
                                                                (*gates[1]).convert_to_yang(actual_wbtc_comp.amount)
                                                            ]
                                                                .span()
                                                        );

                                                        common::assert_equalish(
                                                            expected_compensation_value,
                                                            actual_compensation_value,
                                                            10000000000000000_u128.into(),
                                                            'wrong compensation value'
                                                        );

                                                        // If the trove wasn't fully liquidated, check
                                                        // that it is healthy
                                                        if max_close_amt < trove_debt {
                                                            assert(
                                                                shrine.is_healthy(target_trove),
                                                                'trove should be healthy'
                                                            );
                                                        }

                                                        // Checking that the absorbed assets are equal in value to the
                                                        // debt liquidated, plus the penalty
                                                        if *absorb_type != AbsorbType::None {
                                                            // We subtract the absorber balance before the liquidation
                                                            //  in order to avoid including any leftover
                                                            // absorbed assets from previous liquidations
                                                            // in the calculation for the value of the
                                                            // absorption that *just* occured

                                                            let absorbed_eth: Wad = common::get_erc20_bal_as_yang(
                                                                *gates[0], *yangs[0], absorber.contract_address
                                                            )
                                                                - (*gates[0])
                                                                    .convert_to_yang(absorber_eth_bal_before_absorb);
                                                            let absorbed_wbtc: Wad = common::get_erc20_bal_as_yang(
                                                                *gates[1], *yangs[1], absorber.contract_address
                                                            )
                                                                - (*gates[1])
                                                                    .convert_to_yang(absorber_wbtc_bal_before_absorb);

                                                            let (current_eth_yang_price, _, _) = shrine
                                                                .get_current_yang_price(*yangs[0]);
                                                            let (current_wbtc_yang_price, _, _) = shrine
                                                                .get_current_yang_price(*yangs[1]);

                                                            let absorber_eth_value: Wad = absorbed_eth
                                                                * current_eth_yang_price;
                                                            let absorber_wbtc_value: Wad = absorbed_wbtc
                                                                * current_wbtc_yang_price;

                                                            let absorbed_assets_value = absorber_eth_value
                                                                + absorber_wbtc_value;

                                                            let max_absorb_amt = min(
                                                                max_close_amt, absorber_yin_bal_before_absorb
                                                            );

                                                            common::assert_equalish(
                                                                absorbed_assets_value,
                                                                wadray::rmul_wr(
                                                                    max_absorb_amt, (RAY_ONE.into() + penalty)
                                                                ),
                                                                10000000000000000_u128.into(),
                                                                'wrong absorbed assets value'
                                                            );
                                                        }

                                                        start_prank(
                                                            CheatTarget::One(abbot.contract_address), whale_trove_owner
                                                        );
                                                        abbot.close_trove(whale_trove);
                                                        stop_prank(CheatTarget::One(abbot.contract_address));
                                                    },
                                                    Option::None => { break; }
                                                };
                                            };
                                        },
                                        Option::None => { break; },
                                    };
                                };
                            },
                            Option::None => { break; }
                        };
                    };
                },
                Option::None => { break; }
            };
        };
    }
}
