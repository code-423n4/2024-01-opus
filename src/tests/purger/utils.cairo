mod purger_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use cmp::min;
    use core::option::OptionTrait;
    use debug::PrintTrait;
    use opus::core::absorber::absorber as absorber_contract;
    use opus::core::purger::purger as purger_contract;
    use opus::core::roles::{absorber_roles, seer_roles, sentinel_roles, shrine_roles};
    use opus::core::shrine::shrine as shrine_contract;
    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::IAbsorber::{IAbsorberDispatcher, IAbsorberDispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::IPurger::{IPurgerDispatcher, IPurgerDispatcherTrait};
    use opus::interfaces::ISeer::{ISeerDispatcher, ISeerDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::mock::flash_liquidator::{flash_liquidator, IFlashLiquidatorDispatcher, IFlashLiquidatorDispatcherTrait};
    use opus::mock::mock_pragma::{IMockPragmaDispatcher, IMockPragmaDispatcherTrait};
    use opus::tests::absorber::utils::absorber_utils;
    use opus::tests::common;
    use opus::tests::seer::utils::seer_utils;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::{AssetBalance, Health};
    use opus::utils::math::pow;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, CheatTarget};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{
        ContractAddress, contract_address_to_felt252, contract_address_try_from_felt252, get_block_timestamp,
    };
    use wadray::{Ray, RayZeroable, RAY_ONE, RAY_PERCENT, Wad, WadZeroable, WAD_DECIMALS, WAD_ONE};

    //
    // Constants
    //

    const SEARCHER_YIN: u128 = 10000000000000000000000; // 10_000 (Wad)
    const TARGET_TROVE_YIN: u128 = 1000000000000000000000; // 1000 (Wad)

    const TARGET_TROVE_ETH_DEPOSIT_AMT: u128 = 2000000000000000000; // 2 (Wad) - ETH
    const TARGET_TROVE_WBTC_DEPOSIT_AMT: u128 = 50000000; // 0.5 (10 ** 8) - wBTC


    // Struct to group together all contract classes
    // needed for purger tests
    #[derive(Copy, Drop)]
    struct PurgerTestClasses {
        abbot: Option<ContractClass>,
        sentinel: Option<ContractClass>,
        token: Option<ContractClass>,
        gate: Option<ContractClass>,
        shrine: Option<ContractClass>,
        absorber: Option<ContractClass>,
        blesser: ContractClass,
        purger: ContractClass,
        pragma: Option<ContractClass>,
        mock_pragma: Option<ContractClass>,
        seer: Option<ContractClass>,
    }

    //
    // Address constants
    //

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('purger owner').unwrap()
    }

    fn random_user() -> ContractAddress {
        contract_address_try_from_felt252('random user').unwrap()
    }

    fn searcher() -> ContractAddress {
        contract_address_try_from_felt252('searcher').unwrap()
    }

    fn target_trove_owner() -> ContractAddress {
        contract_address_try_from_felt252('target trove owner').unwrap()
    }

    //
    // Constant helpers
    //

    fn target_trove_yang_asset_amts() -> Span<u128> {
        array![TARGET_TROVE_ETH_DEPOSIT_AMT, TARGET_TROVE_WBTC_DEPOSIT_AMT].span()
    }

    #[inline(always)]
    fn recipient_trove_yang_asset_amts() -> Span<u128> {
        array![30 * WAD_ONE, // 30 (Wad) - ETH
         500000000 // 5 (10 ** 8) - BTC
        ].span()
    }

    fn whale_trove_yang_asset_amts() -> Span<u128> {
        array![700 * WAD_ONE, // 700 (Wad) - ETH
         70000000000 // 700 (10 ** 8) - BTC
        ].span()
    }

    fn interesting_thresholds_for_liquidation() -> Span<Ray> {
        array![
            RayZeroable::zero(),
            RAY_PERCENT.into(),
            (70 * RAY_PERCENT).into(),
            (80 * RAY_PERCENT).into(),
            (90 * RAY_PERCENT).into(),
            (96 * RAY_PERCENT).into(),
            // theoretical upper bound beyond which a penalty is not guaranteed
            // for absorptions after deducting compensation, meaning providers
            // to the absorber will incur a loss for each absorption.
            (97 * RAY_PERCENT).into(),
            // Note that this threshold should not be used because it makes absorber
            // providers worse off, but it should not break the purger's logic.
            (99 * RAY_PERCENT).into(),
        ]
            .span()
    }

    // From around 78.74+% threshold onwards, absorptions liquidate all of the trove's debt
    fn interesting_thresholds_for_absorption_below_trove_debt() -> Span<Ray> {
        array![
            (65 * RAY_PERCENT).into(),
            (70 * RAY_PERCENT).into(),
            (75 * RAY_PERCENT).into(),
            787400000000000000000000000_u128.into()
        ]
            .span()
    }

    // From around 78.74+% threshold onwards, absorptions liquidate all of the trove's debt
    fn interesting_thresholds_for_absorption_entire_trove_debt() -> Span<Ray> {
        array![
            787500000000000000000000000_u128.into(), // 78.75%
            (80 * RAY_PERCENT).into(),
            (90 * RAY_PERCENT).into(),
            (96 * RAY_PERCENT).into(),
            // theoretical upper bound beyond which a penalty is not guaranteed
            // for absorptions after deducting compensation, meaning providers
            // to the absorber will incur a loss for each absorption.
            (97 * RAY_PERCENT).into(),
            // Note that this threshold should not be used because it makes absorber
            // providers worse off, but it should not break the purger's logic.
            (99 * RAY_PERCENT).into()
        ]
            .span()
    }

    // These values are selected based on the thresholds.
    // Refer to https://www.desmos.com/calculator/qoizltusle.
    fn ltvs_for_interesting_thresholds_for_absorption_below_trove_debt() -> Span<Span<Ray>> {
        // The max possible penalty LTV is last reached around this value for these thresholds
        let max_possible_penalty_ltv: Ray = 862200000000000000000000000_u128.into(); // 86.22%

        array![
            // First threshold of 65% (Ray)
            array![ // 71.18% (Ray) - LTV at which maximum penalty of 12.5% is first reached
                711800000000000000000000000_u128.into(), max_possible_penalty_ltv
            ]
                .span(),
            // Second threshold of 70% (Ray)
            array![ // 76.65% (Ray) - LTV at which maximum penalty of 12.5% is first reached
                766500000000000000000000000_u128.into(), max_possible_penalty_ltv
            ]
                .span(),
            // Third threshold of 75% (Ray)
            array![ // 82.13% (Ray) - LTV at which maximum penalty of 12.5% is reached
                821300000000000000000000000_u128.into(), max_possible_penalty_ltv,
            ]
                .span(),
            // Fourth threshold of 78.74% (Ray)
            array![ // 86.2203% (Ray) - LTV at which maximum penalty of 12.5% is reached
                862203000000000000000000000_u128.into(), 862222200000000000000000000_u128.into()
            ]
                .span()
        ]
            .span()
    }

    // These values are selected based on the thresholds.
    // Refer to https://www.desmos.com/calculator/b8drqdb32a.
    fn ltvs_for_interesting_thresholds_for_absorption_entire_trove_debt() -> Span<Span<Ray>> {
        let ninety_nine_pct: Ray = (RAY_ONE - RAY_PERCENT).into();
        let exceed_hundred_pct: Ray = (RAY_ONE + RAY_PERCENT).into();

        array![
            // First threshold of 78.75% (Ray)
            array![ // 86.23% (Ray) - Greater than LTV at which maximum penalty of 12.5% is last reached
                862300000000000000000000000_u128.into(), ninety_nine_pct, exceed_hundred_pct
            ]
                .span(),
            // Second threshold of 80% (Ray)
            array![ // 86.9% (Ray) - LTV at which maximum penalty is reached
                869000000000000000000000000_u128.into(), ninety_nine_pct, exceed_hundred_pct
            ]
                .span(),
            // Third threshold of 90% (Ray)
            array![ // 92.1% (Ray) - LTV at which maximum penalty is reached
                921000000000000000000000000_u128.into(), ninety_nine_pct, exceed_hundred_pct
            ]
                .span(),
            // Fourth threshold of 96% (Ray)
            array![ // Max penalty is already exceeded, so we simply increase the LTV by the smallest unit
                (96 * RAY_PERCENT + 1).into(), ninety_nine_pct, exceed_hundred_pct
            ]
                .span(),
            // Fifth threshold of 97% (Ray)
            // This is the highest possible threshold because it may not be possible to charge a
            // penalty after deducting compensation at this LTV and beyond
            array![ // Max penalty is already exceeded, so we simply increase the LTV by the smallest unit
                (97 * RAY_PERCENT + 1).into(), ninety_nine_pct, exceed_hundred_pct
            ]
                .span(),
            // Sixth threshold of 99% (Ray)
            // Note that this threshold should not be used because it makes absorber
            // providers worse off, but it should not break the purger's logic.
            array![ // Max penalty is already exceeded, so we simply increase the LTV by the smallest unit
                (99 * RAY_PERCENT + 1).into(), exceed_hundred_pct
            ]
                .span()
        ]
            .span()
    }

    // These values are selected based on the thresholds.
    // Refer to https://www.desmos.com/calculator/b8drqdb32a.
    // Note that thresholds >= 90% will be absorbable once LTV >= threshold
    fn interesting_thresholds_and_ltvs_below_absorption_ltv() -> (Span<Ray>, Span<Ray>) {
        let mut thresholds: Array<Ray> = array![
            (65 * RAY_PERCENT).into(),
            (70 * RAY_PERCENT).into(),
            (75 * RAY_PERCENT).into(),
            787400000000000000000000000_u128.into(), // 78.74% (Ray)
            787500000000000000000000000_u128.into(), // 78.75% (Ray)
            (80 * RAY_PERCENT).into()
        ];

        // The LTV at which the maximum penalty is reached minus 0.01%
        let mut trove_ltvs: Array<Ray> = array![
            711700000000000000000000000_u128.into(), // 71.17% (Ray)
            766400000000000000000000000_u128.into(), // 76.64% (Ray)
            821200000000000000000000000_u128.into(), // 82.12% (Ray)
            859200000000000000000000000_u128.into(), // 85.92% (Ray)
            862200000000000000000000000_u128.into(), // 86.22% (Ray)
            868900000000000000000000000_u128.into(), // 86.89% (Ray)
        ];

        (thresholds.span(), trove_ltvs.span())
    }

    fn interesting_yang_amts_for_recipient_trove() -> Span<Span<u128>> {
        array![
            // base case for ordinary redistributions
            recipient_trove_yang_asset_amts(),
            // recipient trove has dust amount of the first yang
            // 100 wei (Wad) ETH, 20 (10 ** 8) WBTC
            array![100_u128, 2000000000_u128].span(),
            // recipient trove has dust amount of a yang that is not the first yang
            // 50 (Wad) ETH, 0.00001 (10 ** 8) WBTC
            array![50 * WAD_ONE, 100_u128].span(),
            // exceptional redistribution because recipient trove does not have
            // WBTC yang but redistributed trove has WBTC yang
            // 50 (Wad) ETH, 0 WBTC
            array![50 * WAD_ONE, 0_u128].span()
        ]
            .span()
    }

    fn interesting_yang_amts_for_redistributed_trove() -> Span<Span<u128>> {
        array![target_trove_yang_asset_amts(), // Dust yang case
         // 20 (Wad) ETH, 100E-8 (WBTC decimals) WBTC
        array![20 * WAD_ONE, 100_u128].span()].span()
    }

    fn inoperational_absorber_yin_cases() -> Span<Wad> {
        array![ // minimum amount that must be provided based on initial shares
            absorber_contract::INITIAL_SHARES
                .into(), // largest possible amount of yin in Absorber based on initial shares
            (absorber_contract::MINIMUM_SHARES - 1).into()
        ]
            .span()
    }

    // Generate interesting cases for absorber's yin balance based on the
    // redistributed trove's debt to test absorption with partial redistribution
    fn generate_operational_absorber_yin_cases(trove_debt: Wad) -> Span<Wad> {
        array![
            // smallest possible amount of yin in Absorber based on initial shares
            absorber_contract::MINIMUM_SHARES.into(),
            (trove_debt.val / 3).into(),
            (trove_debt.val - 1000).into(),
            // trove's debt minus the smallest unit of Wad
            (trove_debt.val - 1).into()
        ]
            .span()
    }

    fn absorb_trove_debt_test_expected_penalties() -> Span<Ray> {
        array![
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
            .span()
    }

    //
    // Test setup helpers
    //

    fn purger_deploy(
        classes: Option<PurgerTestClasses>
    ) -> (
        IShrineDispatcher,
        IAbbotDispatcher,
        ISeerDispatcher,
        IAbsorberDispatcher,
        IPurgerDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>,
    ) {
        let classes = match classes {
            Option::Some(classes) => classes,
            Option::None => declare_contracts(),
        };

        let (shrine, sentinel, abbot, absorber, yangs, gates) = absorber_utils::absorber_deploy(
            classes.abbot, classes.sentinel, classes.token, classes.gate, classes.shrine, classes.absorber,
        );

        let reward_tokens: Span<ContractAddress> = absorber_utils::reward_tokens_deploy(classes.token);

        let reward_amts_per_blessing: Span<u128> = absorber_utils::reward_amts_per_blessing();
        absorber_utils::deploy_blesser_for_rewards(absorber, reward_tokens, reward_amts_per_blessing, classes.blesser);

        let seer = seer_utils::deploy_seer_using(classes.seer, shrine.contract_address, sentinel.contract_address);
        seer_utils::add_oracles(classes.pragma, classes.mock_pragma, seer);
        seer_utils::add_yangs(seer, yangs);

        start_prank(CheatTarget::One(seer.contract_address), seer_utils::admin());
        seer.update_prices();
        stop_prank(CheatTarget::One(seer.contract_address));

        let admin: ContractAddress = admin();

        let calldata = array![
            contract_address_to_felt252(admin),
            contract_address_to_felt252(shrine.contract_address),
            contract_address_to_felt252(sentinel.contract_address),
            contract_address_to_felt252(absorber.contract_address),
            contract_address_to_felt252(seer.contract_address)
        ];

        let purger_addr = classes.purger.deploy(@calldata).expect('failed deploy purger');

        let purger = IPurgerDispatcher { contract_address: purger_addr };

        // Approve Purger in Shrine
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        shrine_ac.grant_role(shrine_roles::purger(), purger_addr);

        // Approve Purger in Sentinel
        let sentinel_ac = IAccessControlDispatcher { contract_address: sentinel.contract_address };
        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::admin());
        sentinel_ac.grant_role(sentinel_roles::purger(), purger_addr);

        // Approve Purger in Seer
        let oracle_ac = IAccessControlDispatcher { contract_address: seer.contract_address };
        start_prank(CheatTarget::One(seer.contract_address), seer_utils::admin());
        oracle_ac.grant_role(seer_roles::purger(), purger_addr);

        // Approve Purger in Absorber
        let absorber_ac = IAccessControlDispatcher { contract_address: absorber.contract_address };
        start_prank(CheatTarget::One(absorber.contract_address), absorber_utils::admin());
        absorber_ac.grant_role(absorber_roles::purger(), purger_addr);

        // Increase debt ceiling
        let debt_ceiling: Wad = (100000 * WAD_ONE).into();
        shrine.set_debt_ceiling(debt_ceiling);

        stop_prank(CheatTarget::All);

        (shrine, abbot, seer, absorber, purger, yangs, gates)
    }

    fn purger_deploy_with_searcher(
        searcher_yin_amt: Wad, classes: Option<PurgerTestClasses>
    ) -> (
        IShrineDispatcher,
        IAbbotDispatcher,
        ISeerDispatcher,
        IAbsorberDispatcher,
        IPurgerDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>,
    ) {
        let (shrine, abbot, seer, absorber, purger, yangs, gates) = purger_deploy(classes);
        funded_searcher(abbot, yangs, gates, searcher_yin_amt);

        (shrine, abbot, seer, absorber, purger, yangs, gates)
    }

    fn flash_liquidator_deploy(
        shrine: ContractAddress,
        abbot: ContractAddress,
        flashmint: ContractAddress,
        purger: ContractAddress,
        fl_class: Option<ContractClass>,
    ) -> IFlashLiquidatorDispatcher {
        let calldata = array![
            contract_address_to_felt252(shrine),
            contract_address_to_felt252(abbot),
            contract_address_to_felt252(flashmint),
            contract_address_to_felt252(purger)
        ];

        let fl_class = match fl_class {
            Option::Some(class) => class,
            Option::None => declare('flash_liquidator'),
        };

        let flash_liquidator_addr = fl_class.deploy(@calldata).expect('failed deploy flash liquidator');

        IFlashLiquidatorDispatcher { contract_address: flash_liquidator_addr }
    }

    fn funded_searcher(
        abbot: IAbbotDispatcher, yangs: Span<ContractAddress>, gates: Span<IGateDispatcher>, yin_amt: Wad,
    ) {
        let user: ContractAddress = searcher();
        common::fund_user(user, yangs, recipient_trove_yang_asset_amts());
        common::open_trove_helper(abbot, user, yangs, recipient_trove_yang_asset_amts(), gates, yin_amt);
    }

    fn funded_absorber(
        shrine: IShrineDispatcher,
        abbot: IAbbotDispatcher,
        absorber: IAbsorberDispatcher,
        yangs: Span<ContractAddress>,
        gates: Span<IGateDispatcher>,
        amt: Wad,
    ) -> u64 {
        absorber_utils::provide_to_absorber(
            shrine, abbot, absorber, absorber_utils::provider_1(), yangs, recipient_trove_yang_asset_amts(), gates, amt,
        )
    }

    // Creates a healthy trove and returns the trove ID
    fn funded_healthy_trove(
        abbot: IAbbotDispatcher, yangs: Span<ContractAddress>, gates: Span<IGateDispatcher>, yin_amt: Wad,
    ) -> u64 {
        let user: ContractAddress = target_trove_owner();
        let deposit_amts: Span<u128> = target_trove_yang_asset_amts();
        common::fund_user(user, yangs, deposit_amts);
        common::open_trove_helper(abbot, user, yangs, deposit_amts, gates, yin_amt)
    }

    // Creates a trove with a lot of collateral
    // This is used to ensure the system doesn't unintentionally enter recovery mode during tests
    fn create_whale_trove(abbot: IAbbotDispatcher, yangs: Span<ContractAddress>, gates: Span<IGateDispatcher>) -> u64 {
        let user: ContractAddress = target_trove_owner();
        let deposit_amts: Span<u128> = whale_trove_yang_asset_amts();
        let yin_amt: Wad = WAD_ONE.into();
        common::fund_user(user, yangs, deposit_amts);
        common::open_trove_helper(abbot, user, yangs, deposit_amts, gates, yin_amt)
    }

    // Update thresholds for all yangs to the given value
    fn set_thresholds(shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>, threshold: Ray) {
        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => { shrine.set_threshold(*yang, threshold); },
                Option::None => { break; },
            };
        };
        stop_prank(CheatTarget::One(shrine.contract_address));
    }

    // Helper function to decrease yang prices by the given percentage
    fn decrease_yang_prices_by_pct(
        shrine: IShrineDispatcher, seer: ISeerDispatcher, mut yangs: Span<ContractAddress>, pct_decrease: Ray,
    ) {
        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang);
                    let new_price: Wad = wadray::rmul_wr(yang_price, (RAY_ONE.into() - pct_decrease));
                    shrine.advance(*yang, new_price);
                    seer_utils::mock_valid_price_update(seer, *yang, new_price);
                },
                Option::None => { break; },
            };
        };
        stop_prank(CheatTarget::One(shrine.contract_address));
    }

    // Helper function to adjust a trove's LTV to the target by manipulating the
    // yang prices
    fn lower_prices_to_raise_trove_ltv(
        shrine: IShrineDispatcher,
        seer: ISeerDispatcher,
        yangs: Span<ContractAddress>,
        value: Wad,
        debt: Wad,
        target_ltv: Ray,
    ) {
        let unhealthy_value: Wad = wadray::rmul_wr(debt, (RAY_ONE.into() / target_ltv));
        let decrease_pct: Ray = wadray::rdiv_ww((value - unhealthy_value), value);

        decrease_yang_prices_by_pct(shrine, seer, yangs, decrease_pct);
    }

    fn trigger_recovery_mode(
        shrine: IShrineDispatcher, abbot: IAbbotDispatcher, trove: u64, trove_owner: ContractAddress,
    ) {
        let shrine_health: Health = shrine.get_shrine_health();
        let rm_threshold: Ray = shrine_health.threshold * shrine_contract::RECOVERY_MODE_THRESHOLD_MULTIPLIER.into();
        // Add 1% to the amount needed to activate RM
        let amt_to_activate_rm: Wad = wadray::rmul_rw(
            (RAY_ONE + RAY_PERCENT).into(), (wadray::rmul_rw(rm_threshold, shrine_health.value) - shrine_health.debt)
        );

        // Sanity check that we are able to mint the amount of debt to trigger
        // recovery mode for the given trove
        let max_forge_amt: Wad = shrine.get_max_forge(trove);
        assert(amt_to_activate_rm <= max_forge_amt, 'recovery mode setup #1');

        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);
        abbot.forge(trove, amt_to_activate_rm, WadZeroable::zero());
        stop_prank(CheatTarget::One(abbot.contract_address));

        assert(shrine.is_recovery_mode(), 'recovery mode setup #2');
    }

    //
    // Test assertion helpers
    //

    fn get_expected_compensation_assets(
        trove_asset_amts: Span<u128>, trove_value: Wad, compensation_value: Wad
    ) -> Span<u128> {
        let expected_compensation_pct: Ray = wadray::rdiv_ww(compensation_value, trove_value);
        common::scale_span_by_pct(trove_asset_amts, expected_compensation_pct)
    }

    // Returns a tuple of the expected freed percentage of trove value and the
    // freed asset amounts
    fn get_expected_liquidation_assets(
        trove_asset_amts: Span<u128>, trove_value: Wad, close_amt: Wad, penalty: Ray, compensation_value: Option<Wad>
    ) -> (Ray, Span<u128>) {
        let freed_amt: Wad = wadray::rmul_wr(close_amt, RAY_ONE.into() + penalty);

        let value_offset: Wad = if compensation_value.is_some() {
            compensation_value.unwrap()
        } else {
            WadZeroable::zero()
        };
        let value_after_compensation: Wad = trove_value - value_offset;
        let expected_freed_pct_of_value_before_compensation: Ray = if freed_amt < value_after_compensation {
            wadray::rdiv_ww(freed_amt, trove_value)
        } else {
            wadray::rdiv_ww(value_after_compensation, trove_value)
        };
        let expected_freed_pct_of_value_after_compensation: Ray = if freed_amt < value_after_compensation {
            wadray::rdiv_ww(freed_amt, value_after_compensation)
        } else {
            expected_freed_pct_of_value_before_compensation
        };
        (
            expected_freed_pct_of_value_after_compensation,
            common::scale_span_by_pct(trove_asset_amts, expected_freed_pct_of_value_before_compensation)
        )
    }

    fn assert_trove_is_healthy(shrine: IShrineDispatcher, purger: IPurgerDispatcher, trove_id: u64) {
        assert(shrine.is_healthy(trove_id), 'should be healthy');

        assert(purger.preview_liquidate(trove_id).is_none(), 'should not be liquidatable');
        assert_trove_is_not_absorbable(purger, trove_id);
    }

    fn assert_trove_is_liquidatable(shrine: IShrineDispatcher, purger: IPurgerDispatcher, trove_id: u64, ltv: Ray) {
        assert(!shrine.is_healthy(trove_id), 'should not be healthy');
        let (penalty, _) = purger.preview_liquidate(trove_id).expect('Should be liquidatable');
        if ltv < RAY_ONE.into() {
            assert(penalty.is_non_zero(), 'penalty should not be 0');
        } else {
            assert(penalty.is_zero(), 'penalty should be 0');
        }
    }

    fn assert_trove_is_absorbable(shrine: IShrineDispatcher, purger: IPurgerDispatcher, trove_id: u64, ltv: Ray) {
        assert(!shrine.is_healthy(trove_id), 'should not be healthy');
        assert(purger.is_absorbable(trove_id), 'should be absorbable');

        let (penalty, _, _) = purger.preview_absorb(trove_id).expect('preview should be Option::Some');
        if ltv < (RAY_ONE - purger_contract::COMPENSATION_PCT).into() {
            assert(penalty.is_non_zero(), 'penalty should not be 0');
        } else {
            assert(penalty.is_zero(), 'penalty should be 0');
        }
    }

    fn assert_trove_is_not_absorbable(purger: IPurgerDispatcher, trove_id: u64) {
        assert(purger.preview_absorb(trove_id).is_none(), 'should not be absorbable');
    }

    fn assert_ltv_at_safety_margin(threshold: Ray, ltv: Ray) {
        let expected_ltv: Ray = purger_contract::THRESHOLD_SAFETY_MARGIN.into() * threshold;
        let error_margin: Ray = (RAY_PERCENT / 10).into(); // 0.1%
        common::assert_equalish(ltv, expected_ltv, error_margin, 'LTV not within safety margin');
    }

    // Helper function to assert that an address received the expected amount of assets based
    // on the before and after balances.
    // `before_asset_bals` and `after_asset_bals` should be retrieved using `get_token_balances`.
    fn assert_received_assets(
        mut before_asset_bals: Span<Span<u128>>,
        mut after_asset_bals: Span<Span<u128>>,
        mut expected_freed_assets: Span<AssetBalance>,
        error_margin: u128,
        message: felt252
    ) {
        loop {
            match expected_freed_assets.pop_front() {
                Option::Some(expected_freed_asset) => {
                    let mut before_asset_bal_arr: Span<u128> = *before_asset_bals.pop_front().unwrap();
                    let before_asset_bal: u128 = *before_asset_bal_arr.pop_front().unwrap();

                    let mut after_asset_bal_arr: Span<u128> = *after_asset_bals.pop_front().unwrap();
                    let after_asset_bal: u128 = *after_asset_bal_arr.pop_front().unwrap();

                    let expected_after_asset_bal: u128 = before_asset_bal + *expected_freed_asset.amount;

                    common::assert_equalish(after_asset_bal, expected_after_asset_bal, error_margin, message);
                },
                Option::None => { break; },
            };
        };
    }

    // Helper function to calculate the sum of the value of the given yangs
    fn get_sum_of_value(shrine: IShrineDispatcher, mut yangs: Span<ContractAddress>, mut amounts: Span<Wad>) -> Wad {
        let mut sum: Wad = WadZeroable::zero();
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang);
                    sum = sum + yang_price * *amounts.pop_front().unwrap();
                },
                Option::None => { break sum; }
            }
        }
    }

    fn declare_contracts() -> PurgerTestClasses {
        PurgerTestClasses {
            abbot: Option::Some(declare('abbot')),
            sentinel: Option::Some(declare('sentinel')),
            token: Option::Some(declare('erc20_mintable')),
            gate: Option::Some(declare('gate')),
            shrine: Option::Some(declare('shrine')),
            absorber: Option::Some(declare('absorber')),
            blesser: declare('blesser'),
            purger: declare('purger'),
            pragma: Option::Some(declare('pragma')),
            mock_pragma: Option::Some(declare('mock_pragma')),
            seer: Option::Some(declare('seer')),
        }
    }
}
