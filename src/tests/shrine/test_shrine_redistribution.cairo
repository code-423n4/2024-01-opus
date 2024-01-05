mod test_shrine_redistribution {
    use debug::PrintTrait;
    use opus::core::shrine::shrine as shrine_contract;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::{ExceptionalYangRedistribution, Health, YangBalance, YangRedistribution};
    use snforge_std::{
        declare, ContractClass, ContractClassTrait, start_prank, CheatTarget, spy_events, SpyOn, EventSpy,
        EventAssertions
    };
    use starknet::ContractAddress;
    use wadray::{Ray, RayZeroable, RAY_ONE, RAY_PERCENT, Wad, WadZeroable, WAD_ONE};

    //
    // Setup
    //

    const TROVE2_YANG1_DEPOSIT: u128 = 2370000000000000000; // 2.37 (Wad)
    const TROVE2_YANG2_DEPOSIT: u128 = 8310000000000000000; // 8.31 (Wad)
    const TROVE2_YANG3_DEPOSIT: u128 = 1320000000000000000; // 1.32 (Wad)
    const TROVE2_FORGE_AMT: u128 = 3456000000000000000000; // 3_456 (Wad)

    const TROVE3_YANG1_DEPOSIT: u128 = 4950000000000000000; // 4.95 (Wad)
    const TROVE3_YANG2_DEPOSIT: u128 = 6500000000000000000; // 6.5 (Wad)
    const TROVE3_YANG3_DEPOSIT: u128 = 2111000000000000000; // 2.111 (Wad)
    const TROVE3_FORGE_AMT: u128 = 2222000000000000000000; // 2_222 (Wad)

    fn setup_trove1(shrine: IShrineDispatcher) {
        let yang1_addr = shrine_utils::yang1_addr();
        let yang2_addr = shrine_utils::yang2_addr();

        let trove1_owner = common::trove1_owner_addr();
        shrine.deposit(yang1_addr, common::TROVE_1, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, common::TROVE_1, shrine_utils::TROVE1_YANG2_DEPOSIT.into());
        shrine.forge(trove1_owner, common::TROVE_1, shrine_utils::TROVE1_FORGE_AMT.into(), 0_u128.into());
    }

    fn setup_trove2(shrine: IShrineDispatcher) {
        let yang1_addr = shrine_utils::yang1_addr();
        let yang2_addr = shrine_utils::yang2_addr();

        let trove2_owner = common::trove2_owner_addr();
        shrine.deposit(yang1_addr, common::TROVE_2, TROVE2_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, common::TROVE_2, TROVE2_YANG2_DEPOSIT.into());
        shrine.forge(trove2_owner, common::TROVE_2, TROVE2_FORGE_AMT.into(), 0_u128.into());
    }

    fn setup_trove3(shrine: IShrineDispatcher) {
        let yang1_addr = shrine_utils::yang1_addr();
        let yang2_addr = shrine_utils::yang2_addr();

        let trove3_owner = shrine_utils::common::trove3_owner_addr();
        shrine.deposit(yang1_addr, common::TROVE_3, TROVE3_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, common::TROVE_3, TROVE3_YANG2_DEPOSIT.into());
        shrine.forge(trove3_owner, common::TROVE_3, TROVE3_FORGE_AMT.into(), 0_u128.into());
    }

    // Helper function to set up three troves
    // - Trove 1 deposits and forges the amounts specified in `src/tests/shrine/utils.cairo`
    // - Troves 2 and 3 deposits and forges the amounts specified in this file
    fn redistribution_setup(shrine_class: Option<ContractClass>) -> IShrineDispatcher {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(shrine_class);

        start_prank(CheatTarget::All, shrine_utils::admin());
        setup_trove1(shrine);
        setup_trove2(shrine);
        setup_trove3(shrine);

        shrine
    }

    // Helper function to return the total debt error from a redistribution
    fn get_redistributed_debt_error(
        shrine: IShrineDispatcher, mut yang_addrs: Span<ContractAddress>, redistribution_id: u32
    ) -> Wad {
        let mut cumulative_error: Wad = WadZeroable::zero();

        loop {
            match yang_addrs.pop_front() {
                Option::Some(yang) => {
                    let yang_redistribution = shrine.get_redistribution_for_yang(*yang, redistribution_id);
                    cumulative_error += yang_redistribution.error;
                },
                Option::None => { break cumulative_error; },
            };
        }
    }

    // Returns a tuple of arrays which are the expected values from redistributing a trove
    // - value liquidated for each yang
    // - unit debt after redistributing debt for each yang
    // - error after redistributing debt for each yang
    // - expected amount of yangs remaining after redistribution
    // Note that once the remaining redistribution value falls below the threshold, an early
    // return will be performed, so yangs with dust value of debt will not be included.
    fn preview_trove_redistribution(
        shrine: IShrineDispatcher, mut yang_addrs: Span<ContractAddress>, trove: u64
    ) -> (Span<Wad>, Span<Wad>, Span<Wad>, Span<Wad>) {
        let trove_health: Health = shrine.get_trove_health(trove);

        let mut trove_yang_values: Array<Wad> = ArrayTrait::new();
        let mut expected_unit_debts: Array<Wad> = ArrayTrait::new();
        let mut expected_errors: Array<Wad> = ArrayTrait::new();
        let mut expected_remaining_yangs: Array<Wad> = ArrayTrait::new();
        let mut cumulative_redistributed_debt: Wad = WadZeroable::zero();

        loop {
            match yang_addrs.pop_front() {
                Option::Some(yang) => {
                    // Calculate value liquidated for each yang
                    let deposited = shrine.get_deposit(*yang, trove);
                    let (yang_price, _, _) = shrine.get_current_yang_price(*yang);
                    let yang_value = yang_price * deposited;

                    trove_yang_values.append(yang_price * deposited);

                    // Calculate redistributed unit debt and error after redistributing debt
                    // for each yang
                    let mut expected_yang_debt = wadray::rmul_rw(
                        wadray::rdiv_ww(yang_value, trove_health.value), trove_health.debt,
                    );
                    cumulative_redistributed_debt += expected_yang_debt;
                    let remainder = trove_health.debt - cumulative_redistributed_debt;
                    if remainder < shrine_contract::ROUNDING_THRESHOLD.into() {
                        expected_yang_debt += remainder;
                        cumulative_redistributed_debt += remainder;
                    }

                    let expected_remaining_yang = shrine.get_yang_total(*yang)
                        - deposited
                        - shrine.get_initial_yang_amt(*yang);
                    let expected_unit_debt = expected_yang_debt / expected_remaining_yang;
                    expected_remaining_yangs.append(expected_remaining_yang);
                    expected_unit_debts.append(expected_unit_debt);

                    let actual_redistributed_debt = expected_unit_debt * expected_remaining_yang;
                    let expected_error = expected_yang_debt - actual_redistributed_debt;

                    expected_errors.append(expected_error);

                    if remainder < shrine_contract::ROUNDING_THRESHOLD.into() {
                        break;
                    }
                },
                Option::None => { break; }
            };
        };
        (trove_yang_values.span(), expected_unit_debts.span(), expected_errors.span(), expected_remaining_yangs.span())
    }

    // Returns a tuple of
    // 1. the expected debt for the recipient trove from the redistribution
    // 2. the amount of redistributed debt based on unit debt per yang and errors, less
    //    errors carried over from the previous redistribution
    fn assert_redistribution_is_correct(
        shrine: IShrineDispatcher,
        mut yangs: Span<ContractAddress>,
        mut expected_remaining_yangs: Span<Wad>,
        mut recipient_trove_yangs: Span<Wad>,
        redistributed_trove_id: u64,
        redistributed_trove_debt: Wad,
        redistributed_trove_value: Wad,
        mut redistributed_trove_yang_values: Span<Wad>,
        expected_redistribution_id: u32,
        mut prev_errors: Span<Wad>,
    ) -> (Wad, Wad) {
        let mut expected_recipient_trove_debt_increment = WadZeroable::zero();
        let mut cumulative_redistributed_debt = WadZeroable::zero();

        let has_errors: bool = prev_errors.len() > 0;

        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    assert(shrine.get_deposit(*yang, redistributed_trove_id).is_zero(), 'deposit should be 0');

                    let recipient_trove_yang_deposit = *recipient_trove_yangs.pop_front().unwrap();
                    let remaining_yang = *expected_remaining_yangs.pop_front().unwrap();

                    // Calculate the amount of debt redistributed for the yang, checking for
                    // rounding threshold,
                    let mut expected_yang_debt = wadray::rmul_rw(
                        wadray::rdiv_ww(
                            *redistributed_trove_yang_values.pop_front().unwrap(), redistributed_trove_value
                        ),
                        redistributed_trove_debt
                    );
                    // Use a temporary variable for cumulative redistributed debt to check for rounding
                    let tmp_cumulative_redistributed_debt = cumulative_redistributed_debt + expected_yang_debt;
                    let remainder = redistributed_trove_debt - tmp_cumulative_redistributed_debt;
                    if remainder < shrine_contract::ROUNDING_THRESHOLD.into() {
                        expected_yang_debt += remainder;
                    }

                    // If provided, include the error from previous redistribution to calculate
                    // unit debt
                    let mut prev_error = WadZeroable::zero();
                    if has_errors {
                        prev_error = *prev_errors.pop_front().unwrap();
                        expected_yang_debt += prev_error;
                    }

                    let expected_unit_debt = expected_yang_debt / remaining_yang;
                    let redistribution = shrine.get_redistribution_for_yang(*yang, expected_redistribution_id);

                    common::assert_equalish(
                        expected_unit_debt, redistribution.unit_debt, 1_u128.into(), 'wrong unit debt'
                    );

                    expected_recipient_trove_debt_increment += recipient_trove_yang_deposit * expected_unit_debt;

                    // Calculate cumulative redistributed debt for subsequent check
                    let expected_cumulative_increment = remaining_yang * expected_unit_debt;
                    cumulative_redistributed_debt += expected_cumulative_increment;
                    let expected_error = expected_yang_debt - expected_cumulative_increment;
                    cumulative_redistributed_debt += expected_error;

                    // If provided, exclude the error from previous redistribution to calculate
                    // the redistributed trove's debt
                    if has_errors {
                        cumulative_redistributed_debt -= prev_error;
                    }
                },
                Option::None => { break; }
            };
        };

        (expected_recipient_trove_debt_increment, cumulative_redistributed_debt)
    }

    //
    // Tests
    //

    #[test]
    fn test_shrine_one_redistribution() {
        let shrine: IShrineDispatcher = redistribution_setup(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));
        let before_trove2_health: Health = shrine.get_trove_health(common::TROVE_2);

        // Note order is reversed to match `yangs`
        let mut trove2_yang_deposits: Array<Wad> = array![TROVE2_YANG2_DEPOSIT.into(), TROVE2_YANG1_DEPOSIT.into()];
        let mut trove2_yang_deposits = trove2_yang_deposits.span();

        let redistributed_trove: u64 = common::TROVE_1;
        let recipient_trove: u64 = common::TROVE_2;
        let yangs: Span<ContractAddress> = shrine_utils::two_yang_addrs_reversed();
        let (trove1_yang_values, _, _, expected_remaining_yangs) = preview_trove_redistribution(
            shrine, yangs, redistributed_trove
        );

        // Simulate purge with 0 yin to update the trove's debt
        start_prank(CheatTarget::All, shrine_utils::admin());
        let trove1_owner = common::trove1_owner_addr();
        let trove1_health: Health = shrine.get_trove_health(redistributed_trove);
        shrine.melt(trove1_owner, redistributed_trove, WadZeroable::zero());

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(redistributed_trove, trove1_health.debt, RAY_ONE.into());

        let (attributed_yangs, attributed_debt) = shrine.get_redistributions_attributed_to_trove(redistributed_trove);
        assert(attributed_debt.is_zero(), 'should be zero');
        assert(attributed_yangs.len().is_zero(), 'should be empty');

        let expected_redistribution_id: u32 = 1;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');

        let empty_errors: Span<Wad> = ArrayTrait::new().span();
        let (expected_trove2_debt_increment, cumulative_redistributed_debt) = assert_redistribution_is_correct(
            shrine,
            yangs,
            expected_remaining_yangs,
            trove2_yang_deposits,
            redistributed_trove,
            trove1_health.debt,
            trove1_health.value,
            trove1_yang_values,
            expected_redistribution_id,
            empty_errors, // Dummy values
        );

        let expected_trove2_debt = before_trove2_health.debt + expected_trove2_debt_increment;

        // Check invariant of [(yang1_total * yang1_unit_debt + error) + ... (yang2 ...) + rounding]
        // is equal to redistributed trove's debt
        assert(cumulative_redistributed_debt == trove1_health.debt, 'wrong redistributed debt');

        let after_trove2_health: Health = shrine.get_trove_health(recipient_trove);

        assert(after_trove2_health.debt == expected_trove2_debt, 'wrong debt after redistribution');

        assert(shrine.get_trove_redistribution_id(recipient_trove) == 0, 'wrong redistribution id');

        let (attr_yangs, attr_debt) = shrine.get_redistributions_attributed_to_trove(recipient_trove);
        assert(attr_yangs.len().is_zero(), 'wrong attributed yangs');
        assert(attr_debt == expected_trove2_debt_increment, 'wrong attributed debt');

        // Trigger an update in trove 2 with an empty melt
        shrine.melt(trove1_owner, recipient_trove, WadZeroable::zero());
        assert(shrine.get_trove_redistribution_id(recipient_trove) == expected_redistribution_id, 'wrong id');

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TroveRedistributed(
                    shrine_contract::TroveRedistributed {
                        redistribution_id: expected_redistribution_id,
                        trove_id: redistributed_trove,
                        debt: trove1_health.debt,
                    }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);

        shrine_utils::assert_shrine_invariants(shrine, yangs, 3);
    }

    #[test]
    fn test_shrine_two_redistributions() {
        let shrine: IShrineDispatcher = redistribution_setup(Option::None);

        let redistributed_trove1: u64 = common::TROVE_1;
        let redistributed_trove2: u64 = common::TROVE_2;
        let recipient_trove: u64 = common::TROVE_3;

        let yangs: Span<ContractAddress> = shrine_utils::two_yang_addrs_reversed();
        let (_, _, expected_redistributed_trove1_errors, _) = preview_trove_redistribution(
            shrine, yangs, redistributed_trove1
        );

        // Perform first redistribution - covered by previous test
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.melt(common::trove1_owner_addr(), redistributed_trove1, WadZeroable::zero());

        let redistributed_trove1_health: Health = shrine.get_trove_health(redistributed_trove1);
        let redistributed_trove2_start_health = shrine.get_trove_health(redistributed_trove2);
        shrine.redistribute(redistributed_trove1, redistributed_trove1_health.debt, RAY_ONE.into());

        let before_recipient_trove_health: Health = shrine.get_trove_health(recipient_trove);

        let (mut redistributed_trove2_yang_values, _, _, expected_remaining_yangs) = preview_trove_redistribution(
            shrine, yangs, redistributed_trove2
        );

        // Perform second redistribution
        shrine.melt(common::trove2_owner_addr(), redistributed_trove2, WadZeroable::zero());
        let redistributed_trove2_health: Health = shrine.get_trove_health(redistributed_trove2);

        shrine.redistribute(redistributed_trove2, redistributed_trove2_health.debt, RAY_ONE.into());

        let (attributed_yangs, attributed_debt) = shrine.get_redistributions_attributed_to_trove(redistributed_trove2);
        assert(attributed_debt.is_zero(), 'should be zero');
        assert(attributed_yangs.len().is_zero(), 'should be empty');

        let expected_redistribution_id: u32 = 2;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');

        let (expected_recipient_trove_debt_increment, cumulative_redistributed_debt) = assert_redistribution_is_correct(
            shrine,
            yangs,
            expected_remaining_yangs,
            expected_remaining_yangs, // Trove 3 is the only remaining trove
            redistributed_trove2,
            redistributed_trove2_health.debt,
            redistributed_trove2_health.value,
            redistributed_trove2_yang_values,
            expected_redistribution_id,
            expected_redistributed_trove1_errors,
        );

        let expected_recipient_trove_debt = before_recipient_trove_health.debt
            + expected_recipient_trove_debt_increment;

        // Check invariant of [(yang1_total * yang1_unit_debt + error) + ... (yang2 ...) + rounding]
        // is equal to redistributed trove's debt
        assert(redistributed_trove2_health.debt == cumulative_redistributed_debt, 'wrong redistributed debt');

        let after_recipient_trove_health: Health = shrine.get_trove_health(recipient_trove);
        assert(after_recipient_trove_health.debt == expected_recipient_trove_debt, 'wrong debt after redistribution');

        assert(shrine.get_trove_redistribution_id(recipient_trove) == 0, 'wrong redistribution id');

        let (attr_yangs, attr_debt) = shrine.get_redistributions_attributed_to_trove(recipient_trove);
        assert(attr_yangs.len().is_zero(), 'wrong attributed yangs');
        let expected_recipient_trove_debt_total_increment = redistributed_trove1_health.debt
            + redistributed_trove2_start_health.debt;
        common::assert_equalish(
            attr_debt, expected_recipient_trove_debt_total_increment, 10_u128.into(), 'wrong attributed debt'
        );

        // Trigger an update in trove 3 with an empty melt
        shrine.melt(common::trove2_owner_addr(), recipient_trove, WadZeroable::zero());
        assert(shrine.get_trove_redistribution_id(recipient_trove) == expected_redistribution_id, 'wrong id');

        shrine_utils::assert_shrine_invariants(shrine, yangs, 3);
    }

    // Parametrized test to check that partial redistribution of a trove results in the correct
    // value and debt for the redistributed trove.
    #[test]
    fn test_shrine_redistribution_parametrized() {
        let shrine_class = shrine_utils::declare_shrine();

        let mut percentages: Array<Ray> = array![
            (15 * RAY_PERCENT).into(), (99 * RAY_PERCENT).into(), (100 * RAY_PERCENT).into(), RayZeroable::zero(),
        ];

        let mut pct_value_to_redistribute_arr = percentages.span();
        let mut pct_debt_to_redistribute_arr = percentages.span();

        let mut salt: felt252 = 0;
        loop {
            match pct_value_to_redistribute_arr.pop_front() {
                Option::Some(pct_value_to_redistribute) => {
                    loop {
                        match pct_debt_to_redistribute_arr.pop_front() {
                            Option::Some(pct_debt_to_redistribute) => {
                                let shrine: IShrineDispatcher = redistribution_setup(Option::Some(shrine_class));
                                let mut spy = spy_events(SpyOn::One(shrine.contract_address));

                                let yangs: Span<ContractAddress> = shrine_utils::two_yang_addrs_reversed();
                                let redistributed_trove = common::TROVE_1;

                                // Simulate purge with 0 yin to update the trove's debt
                                start_prank(CheatTarget::All, shrine_utils::admin());
                                let trove1_owner = common::trove1_owner_addr();
                                let before_redistributed_trove_health: Health = shrine
                                    .get_trove_health(redistributed_trove);
                                shrine.melt(trove1_owner, redistributed_trove, WadZeroable::zero());

                                assert(shrine.get_redistributions_count() == 0, 'wrong start state');
                                let debt_to_redistribute: Wad = wadray::rmul_wr(
                                    before_redistributed_trove_health.debt, *pct_debt_to_redistribute
                                );
                                shrine
                                    .redistribute(
                                        redistributed_trove, debt_to_redistribute, *pct_value_to_redistribute
                                    );

                                let after_redistributed_trove_health: Health = shrine
                                    .get_trove_health(redistributed_trove);
                                assert(
                                    after_redistributed_trove_health.debt == before_redistributed_trove_health.debt
                                        - debt_to_redistribute,
                                    'wrong redistributed trove debt'
                                );

                                let expected_redistribution_id: u32 = 1;

                                let expected_events = array![
                                    (
                                        shrine.contract_address,
                                        shrine_contract::Event::TroveRedistributed(
                                            shrine_contract::TroveRedistributed {
                                                redistribution_id: expected_redistribution_id,
                                                trove_id: redistributed_trove,
                                                debt: debt_to_redistribute,
                                            }
                                        )
                                    ),
                                ];

                                spy.assert_emitted(@expected_events);

                                shrine_utils::assert_shrine_invariants(shrine, yangs, 3);
                                // We are unable to test the trove value in a sensible way here because
                                // the yang price has not been updated to reflect any rebasing of the
                                // asset amount per yang wad. Instead, refer to the tests for purger
                                // for assertions on the redistributed trove's value.
                                salt += 1;
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
    fn test_shrine_redistribute_dust_yang_rounding() {
        // Manually set up troves so that the redistributed trove has a dust amount of one yang
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_prank(CheatTarget::All, shrine_utils::admin());
        setup_trove1(shrine);
        setup_trove3(shrine);

        let yang1_addr = shrine_utils::yang1_addr();
        let yang2_addr = shrine_utils::yang2_addr();

        let trove2_owner = common::trove2_owner_addr();
        let redistributed_trove = common::TROVE_2;
        let trove2_yang1_amt: Wad = 1000000000000000000000_u128.into(); // 1E-15 (Wad)
        let trove2_yang2_amt: Wad = 1000_u128.into(); // 1_000 (Wad)
        shrine.deposit(yang1_addr, redistributed_trove, trove2_yang1_amt);
        shrine.deposit(yang2_addr, redistributed_trove, trove2_yang2_amt);
        shrine.forge(trove2_owner, redistributed_trove, TROVE2_FORGE_AMT.into(), 0_u128.into());

        // Get information before redistribution
        let trove2_health: Health = shrine.get_trove_health(redistributed_trove);

        // Sanity check that the amount of debt attributed to YANG_2 falls below the threshold
        let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);
        let expected_yang2_redistributed_value = trove2_yang2_amt * yang2_price;

        let trove2_yang2_debt = wadray::rmul_rw(
            wadray::rdiv_ww(expected_yang2_redistributed_value, trove2_health.value), trove2_health.debt
        );
        assert(trove2_yang2_debt < shrine_contract::ROUNDING_THRESHOLD.into(), 'not below rounding threshold');

        // Redistribute trove 2
        shrine.melt(trove2_owner, redistributed_trove, WadZeroable::zero());
        shrine.redistribute(redistributed_trove, trove2_health.debt, RAY_ONE.into());

        let (attributed_yangs, attributed_debt) = shrine.get_redistributions_attributed_to_trove(redistributed_trove);
        assert(attributed_debt.is_zero(), 'should be zero');
        assert(attributed_yangs.len().is_zero(), 'should be empty');

        // Check that yang 1 unit debt is zero
        let expected_redistribution_id: u32 = 1;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');
        assert(
            shrine.get_redistribution_for_yang(yang2_addr, expected_redistribution_id).unit_debt.is_zero(),
            'should be skipped'
        );

        // Check trove 2 has no yang 1, and some amount of yang 2.
        assert(shrine.get_deposit(yang1_addr, redistributed_trove).is_zero(), 'yang 1 should be zero');
        assert(shrine.get_deposit(yang2_addr, redistributed_trove).is_non_zero(), 'yang 2 should not be zero');

        // Check that all of trove 2's debt was distributed to yang 1
        let expected_remaining_yang1: Wad = (shrine_utils::TROVE1_YANG1_DEPOSIT + TROVE3_YANG1_DEPOSIT).into();
        let expected_unit_debt_for_yang2 = trove2_health.debt / expected_remaining_yang1;
        assert(
            shrine
                .get_redistribution_for_yang(yang1_addr, expected_redistribution_id)
                .unit_debt == expected_unit_debt_for_yang2,
            'wrong unit debt'
        );

        shrine_utils::assert_shrine_invariants(shrine, shrine_utils::two_yang_addrs(), 3);
    }

    #[test]
    fn test_shrine_one_exceptional_redistribution_one_recipient_yang() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mut spy = spy_events(SpyOn::One(shrine.contract_address));

        // Manually set up troves so that the redistributed trove (trove 1) uses all three yangs
        // while the recipient troves (trove 2 and 3) uses only yang 2.
        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs_reversed();
        let yang1_addr = *yangs.at(2);
        let yang2_addr = *yangs.at(1);
        let yang3_addr = *yangs.at(0);

        let trove1_owner = common::trove1_owner_addr();
        let redistributed_trove: u64 = common::TROVE_1;

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.deposit(yang1_addr, redistributed_trove, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, redistributed_trove, shrine_utils::TROVE1_YANG2_DEPOSIT.into());
        shrine.deposit(yang3_addr, redistributed_trove, shrine_utils::TROVE1_YANG3_DEPOSIT.into());
        shrine.forge(trove1_owner, redistributed_trove, shrine_utils::TROVE1_FORGE_AMT.into(), 0_u128.into());

        let trove2_owner = common::trove2_owner_addr();
        let recipient_trove1: u64 = common::TROVE_2;
        shrine.deposit(yang2_addr, recipient_trove1, TROVE2_YANG2_DEPOSIT.into());
        shrine.forge(trove2_owner, recipient_trove1, TROVE2_FORGE_AMT.into(), 0_u128.into());

        let trove3_owner = common::trove3_owner_addr();
        let recipient_trove2: u64 = common::TROVE_3;
        shrine.deposit(yang2_addr, recipient_trove2, TROVE3_YANG2_DEPOSIT.into());
        shrine.forge(trove3_owner, recipient_trove2, TROVE3_FORGE_AMT.into(), 0_u128.into());

        let before_recipient_trove1_health: Health = shrine.get_trove_health(recipient_trove1);
        let before_recipient_trove2_health: Health = shrine.get_trove_health(recipient_trove2);

        // Note that since there is only one yang in recipient troves, the check here is a lot simpler because
        // all redistributions will follow the same proportion. See the next test with two recipient yangs for
        // a more detailed calculation when there is more than one recipient yang with different proportions
        let total_recipient_troves_value: Wad = before_recipient_trove1_health.value
            + before_recipient_trove2_health.value;
        let expected_recipient_trove1_pct: Ray = wadray::rdiv_ww(
            before_recipient_trove1_health.value, total_recipient_troves_value
        );
        let expected_recipient_trove2_pct: Ray = wadray::rdiv_ww(
            before_recipient_trove2_health.value, total_recipient_troves_value
        );

        let total_recipient_troves_yang2: Wad = (TROVE2_YANG2_DEPOSIT + TROVE3_YANG2_DEPOSIT).into();

        // Simulate purge with 0 yin to update the trove's debt
        let redistributed_trove_health: Health = shrine.get_trove_health(redistributed_trove);
        shrine.melt(trove1_owner, redistributed_trove, WadZeroable::zero());

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(redistributed_trove, redistributed_trove_health.debt, RAY_ONE.into());

        let expected_redistribution_id: u32 = 1;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');

        let recipient_troves_yang2_amt: Wad = (TROVE2_YANG2_DEPOSIT + TROVE3_YANG2_DEPOSIT).into();

        let yang2_unit_debt: Wad = shrine.get_redistribution_for_yang(yang2_addr, expected_redistribution_id).unit_debt;
        let yang1_to_yang2_unit_debt: Wad = shrine
            .get_exceptional_redistribution_for_yang_to_yang(yang2_addr, expected_redistribution_id, yang1_addr)
            .unit_debt;
        let yang3_to_yang2_unit_debt: Wad = shrine
            .get_exceptional_redistribution_for_yang_to_yang(yang2_addr, expected_redistribution_id, yang3_addr)
            .unit_debt;

        // Check redistributions attributed to recipient troves
        let expected_recipient_trove1_yang1_amt: Wad = wadray::rmul_wr(
            shrine_utils::TROVE1_YANG1_DEPOSIT.into(), expected_recipient_trove1_pct
        );
        let expected_recipient_trove1_yang3_amt: Wad = wadray::rmul_wr(
            shrine_utils::TROVE1_YANG3_DEPOSIT.into(), expected_recipient_trove1_pct
        );
        let expected_recipient_trove1_attr_yangs: Span<YangBalance> = array![
            YangBalance { yang_id: 1, amount: expected_recipient_trove1_yang1_amt },
            YangBalance { yang_id: 3, amount: expected_recipient_trove1_yang3_amt },
        ]
            .span();

        let expected_recipient_trove1_attr_debt: Wad = wadray::rmul_wr(
            redistributed_trove_health.debt, expected_recipient_trove1_pct
        );

        let (recipient_trove1_attr_yangs, recipient_trove1_attr_debt) = shrine
            .get_redistributions_attributed_to_trove(recipient_trove1);
        common::assert_yang_balances_equalish(
            recipient_trove1_attr_yangs,
            expected_recipient_trove1_attr_yangs,
            (WAD_ONE / 100).into(),
            'wrong attributed yangs'
        );
        common::assert_equalish(
            recipient_trove1_attr_debt,
            expected_recipient_trove1_attr_debt,
            (WAD_ONE / 100).into(),
            'wrong attributed debt'
        );

        let expected_recipient_trove2_yang1_amt: Wad = wadray::rmul_wr(
            shrine_utils::TROVE1_YANG1_DEPOSIT.into(), expected_recipient_trove2_pct
        );
        let expected_recipient_trove2_yang3_amt: Wad = wadray::rmul_wr(
            shrine_utils::TROVE1_YANG3_DEPOSIT.into(), expected_recipient_trove2_pct
        );
        let expected_recipient_trove2_attr_yangs: Span<YangBalance> = array![
            YangBalance { yang_id: 1, amount: expected_recipient_trove2_yang1_amt },
            YangBalance { yang_id: 3, amount: expected_recipient_trove2_yang3_amt },
        ]
            .span();

        let expected_recipient_trove2_attr_debt: Wad = wadray::rmul_wr(
            redistributed_trove_health.debt, expected_recipient_trove2_pct
        );

        let (recipient_trove2_attr_yangs, recipient_trove2_attr_debt) = shrine
            .get_redistributions_attributed_to_trove(recipient_trove2);
        common::assert_yang_balances_equalish(
            recipient_trove2_attr_yangs,
            expected_recipient_trove2_attr_yangs,
            (WAD_ONE / 100).into(),
            'wrong attributed yangs'
        );
        common::assert_equalish(
            recipient_trove2_attr_debt,
            expected_recipient_trove2_attr_debt,
            (WAD_ONE / 100).into(),
            'wrong attributed debt'
        );

        // Trigger an update in recipient troves with an empty melt
        shrine.melt(trove1_owner, recipient_trove1, WadZeroable::zero());
        shrine.melt(trove1_owner, recipient_trove2, WadZeroable::zero());

        assert(shrine.get_trove_redistribution_id(recipient_trove1) == expected_redistribution_id, 'wrong id');
        assert(shrine.get_trove_redistribution_id(recipient_trove2) == expected_redistribution_id, 'wrong id');

        let after_recipient_trove1_health: Health = shrine.get_trove_health(recipient_trove1);
        let after_recipient_trove2_health: Health = shrine.get_trove_health(recipient_trove2);

        //
        // Yangs assertions
        //

        // Check that troves 2 and 3 receives trove 1's yang1 and yang3
        assert(shrine.get_deposit(yang1_addr, redistributed_trove).is_zero(), 'should be 0 yang 1 left');
        let recipient_trove1_yang1_amt: Wad = shrine.get_deposit(yang1_addr, recipient_trove1);
        common::assert_equalish(
            recipient_trove1_yang1_amt,
            expected_recipient_trove1_yang1_amt,
            10_u128.into(), // error margin
            'wrong recipient trove 1 yang 1'
        );

        let recipient_trove2_yang1_amt: Wad = shrine.get_deposit(yang1_addr, recipient_trove2);
        common::assert_equalish(
            recipient_trove2_yang1_amt,
            expected_recipient_trove2_yang1_amt,
            10_u128.into(), // error margin
            'wrong recipient trove 2 yang 1'
        );

        // Total supply of yang1 should have been reduced by the error from loss of precision
        let exc_yang1_redistribution: ExceptionalYangRedistribution = shrine
            .get_exceptional_redistribution_for_yang_to_yang(yang2_addr, expected_redistribution_id, yang1_addr);
        let expected_redistributed_yang1_amt: Wad = (total_recipient_troves_yang2 * exc_yang1_redistribution.unit_yang);
        let expected_error: Wad = shrine_utils::TROVE1_YANG1_DEPOSIT.into() - expected_redistributed_yang1_amt;
        assert(
            shrine.get_yang_total(yang1_addr) == shrine_utils::TROVE1_YANG1_DEPOSIT.into() - expected_error,
            'wrong yang 1 total'
        );

        assert(shrine.get_deposit(yang2_addr, redistributed_trove).is_zero(), 'should be 0 yang 2 left');

        assert(shrine.get_deposit(yang3_addr, redistributed_trove).is_zero(), 'should be 0 yang 3 left');
        let recipient_trove1_yang3_amt: Wad = shrine.get_deposit(yang3_addr, recipient_trove1);
        common::assert_equalish(
            recipient_trove1_yang3_amt,
            expected_recipient_trove1_yang3_amt,
            10_u128.into(), // error margin
            'wrong recipient trove 1 yang 3'
        );

        let recipient_trove2_yang3_amt: Wad = shrine.get_deposit(yang3_addr, recipient_trove2);
        common::assert_equalish(
            recipient_trove2_yang3_amt,
            expected_recipient_trove2_yang3_amt,
            10_u128.into(), // error margin
            'wrong recipient trove 2 yang 3'
        );

        // Total supply of yang1 should have been reduced by the error from loss of precision
        let exc_yang3_redistribution: ExceptionalYangRedistribution = shrine
            .get_exceptional_redistribution_for_yang_to_yang(yang2_addr, expected_redistribution_id, yang3_addr);
        let expected_redistributed_yang3_amt: Wad = (total_recipient_troves_yang2 * exc_yang3_redistribution.unit_yang);
        let expected_error: Wad = shrine_utils::TROVE1_YANG3_DEPOSIT.into() - expected_redistributed_yang3_amt;
        assert(
            shrine.get_yang_total(yang3_addr) == shrine_utils::TROVE1_YANG3_DEPOSIT.into() - expected_error,
            'wrong yang 3 total'
        );

        //
        // Debt assertions
        //

        // Check that recipient troves receives their proportion of trove 1's entire debt
        let expected_recipient_trove1_debt: Wad = before_recipient_trove1_health.debt
            + expected_recipient_trove1_attr_debt;
        common::assert_equalish(
            after_recipient_trove1_health.debt,
            expected_recipient_trove1_debt,
            10_u128.into(), // error margin
            'wrong recipient trove 1 debt',
        );

        let expected_recipient_trove2_debt: Wad = before_recipient_trove2_health.debt
            + expected_recipient_trove2_attr_debt;
        common::assert_equalish(
            after_recipient_trove2_health.debt,
            expected_recipient_trove2_debt,
            10_u128.into(), // error margin
            'wrong recipient trove 2 debt',
        );

        let recipient_troves_debt_increment: Wad = (after_recipient_trove1_health.debt
            - before_recipient_trove1_health.debt)
            + (after_recipient_trove2_health.debt - before_recipient_trove2_health.debt);
        common::assert_equalish(
            redistributed_trove_health.debt,
            recipient_troves_debt_increment,
            20_u128.into(), // error margin
            'wrong recipients debt increment',
        );

        // Check invariant that redistributed unit debt should be equal to all debt redistributed to troves
        // and the errors for all yangs
        let cumulative_error: Wad = get_redistributed_debt_error(shrine, yangs, expected_redistribution_id);

        let actual_redistributed_debt: Wad = (recipient_troves_yang2_amt * yang2_unit_debt)
            + (recipient_troves_yang2_amt * yang1_to_yang2_unit_debt)
            + (recipient_troves_yang2_amt * yang3_to_yang2_unit_debt);
        assert(
            redistributed_trove_health.debt == actual_redistributed_debt + cumulative_error, 'debt invariant failed'
        );

        assert(
            redistributed_trove_health.debt == recipient_troves_debt_increment + cumulative_error,
            'loss of precision in pulling'
        );

        // Note that we cannot fully check the updated value of the recipient trove here because
        // we need the oracle to update the yang price for yang2 based on the new asset amount per
        // yang2, but we can check the increase in value from yang1 and yang3.
        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let (yang3_price, _, _) = shrine.get_current_yang_price(yang3_addr);
        let expected_recipient_trove1_value: Wad = before_recipient_trove1_health.value
            + (recipient_trove1_yang1_amt * yang1_price)
            + (recipient_trove1_yang3_amt * yang3_price);

        common::assert_equalish(
            after_recipient_trove1_health.value,
            expected_recipient_trove1_value,
            10_u128.into(), // error margin
            'wrong recipient trove1 value'
        );

        let expected_redistribution_id: u32 = 1;

        let expected_events = array![
            (
                shrine.contract_address,
                shrine_contract::Event::TroveRedistributed(
                    shrine_contract::TroveRedistributed {
                        redistribution_id: expected_redistribution_id,
                        trove_id: redistributed_trove,
                        debt: redistributed_trove_health.debt,
                    }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);

        shrine_utils::assert_shrine_invariants(shrine, yangs, 3);
    }

    #[test]
    fn test_shrine_one_exceptional_redistribution_two_recipient_yangs() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        // Manually set up troves so that the redistributed trove (trove 1) uses all three yangs
        // while the recipient troves (troves 2 and 3) use only yang2 and yang3
        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs_reversed();
        let yang1_addr = *yangs.at(2);
        let yang2_addr = *yangs.at(1);
        let yang3_addr = *yangs.at(0);

        let trove1_owner = common::trove1_owner_addr();
        let redistributed_trove: u64 = common::TROVE_1;

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.deposit(yang1_addr, redistributed_trove, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, redistributed_trove, shrine_utils::TROVE1_YANG2_DEPOSIT.into());
        shrine.deposit(yang3_addr, redistributed_trove, shrine_utils::TROVE1_YANG3_DEPOSIT.into());
        shrine.forge(trove1_owner, redistributed_trove, shrine_utils::TROVE1_FORGE_AMT.into(), 0_u128.into());

        let trove2_owner = common::trove2_owner_addr();
        let recipient_trove1: u64 = common::TROVE_2;
        shrine.deposit(yang2_addr, recipient_trove1, TROVE2_YANG2_DEPOSIT.into());
        shrine.deposit(yang3_addr, recipient_trove1, TROVE2_YANG3_DEPOSIT.into());
        shrine.forge(trove2_owner, recipient_trove1, TROVE2_FORGE_AMT.into(), 0_u128.into());

        let trove3_owner = common::trove3_owner_addr();
        let recipient_trove2: u64 = common::TROVE_3;
        shrine.deposit(yang2_addr, recipient_trove2, TROVE3_YANG2_DEPOSIT.into());
        shrine.deposit(yang3_addr, recipient_trove2, TROVE3_YANG3_DEPOSIT.into());
        shrine.forge(trove3_owner, recipient_trove2, TROVE3_FORGE_AMT.into(), 0_u128.into());

        let before_recipient_trove1_health: Health = shrine.get_trove_health(recipient_trove1);
        let before_recipient_trove2_health: Health = shrine.get_trove_health(recipient_trove2);

        let total_recipient_troves_value: Wad = before_recipient_trove1_health.value
            + before_recipient_trove2_health.value;
        let expected_recipient_trove1_pct: Ray = wadray::rdiv_ww(
            before_recipient_trove1_health.value, total_recipient_troves_value
        );
        let expected_recipient_trove2_pct: Ray = wadray::rdiv_ww(
            before_recipient_trove2_health.value, total_recipient_troves_value
        );

        let total_recipient_troves_yang2: Wad = (TROVE2_YANG2_DEPOSIT + TROVE3_YANG2_DEPOSIT).into();
        let total_recipient_troves_yang3: Wad = (TROVE2_YANG3_DEPOSIT + TROVE3_YANG3_DEPOSIT).into();

        // Simulate purge with 0 yin to update the trove's debt
        let redistributed_trove_health: Health = shrine.get_trove_health(redistributed_trove);
        shrine.melt(trove1_owner, redistributed_trove, WadZeroable::zero());

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(redistributed_trove, redistributed_trove_health.debt, RAY_ONE.into());

        let expected_redistribution_id: u32 = 1;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');

        // Check redistributions attributed to recipient troves

        // Calculate the percentage of debt redistributed to each yang, and each recipient trove's entitlement
        // to each portion.
        let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
        let redistributed_yang1_value: Wad = shrine_utils::TROVE1_YANG1_DEPOSIT.into() * yang1_price;

        let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);
        let redistributed_yang2_value: Wad = shrine_utils::TROVE1_YANG2_DEPOSIT.into() * yang2_price;

        let (yang3_price, _, _) = shrine.get_current_yang_price(yang3_addr);
        let redistributed_yang3_value: Wad = shrine_utils::TROVE1_YANG3_DEPOSIT.into() * yang3_price;

        // Amount of debt redistributed for each yang
        let redistributed_yang1_debt: Wad = wadray::rmul_wr(
            redistributed_trove_health.debt,
            wadray::rdiv_ww(redistributed_yang1_value, redistributed_trove_health.value)
        );

        let redistributed_yang2_debt: Wad = wadray::rmul_wr(
            redistributed_trove_health.debt,
            wadray::rdiv_ww(redistributed_yang2_value, redistributed_trove_health.value)
        );

        let redistributed_yang3_debt: Wad = wadray::rmul_wr(
            redistributed_trove_health.debt,
            wadray::rdiv_ww(redistributed_yang3_value, redistributed_trove_health.value)
        );

        // Sanity check
        assert(
            redistributed_yang1_debt
                + redistributed_yang2_debt
                + redistributed_yang3_debt < redistributed_trove_health.debt,
            'should not exceed trove debt'
        );

        let recipient_troves_value: Wad = before_recipient_trove1_health.value + before_recipient_trove2_health.value;
        let recipient_troves_yang2_amt: Wad = (TROVE2_YANG2_DEPOSIT + TROVE3_YANG2_DEPOSIT).into();
        let recipient_troves_yang2_value: Wad = recipient_troves_yang2_amt * yang2_price;

        let recipient_troves_yang3_amt: Wad = (TROVE2_YANG3_DEPOSIT + TROVE3_YANG3_DEPOSIT).into();
        let recipient_troves_yang3_value: Wad = recipient_troves_yang3_amt * yang3_price;

        let yang1_debt_redistributed_to_yang2: Wad = wadray::rmul_wr(
            redistributed_yang1_debt, wadray::rdiv_ww(recipient_troves_yang2_value, recipient_troves_value),
        );
        let yang1_debt_redistributed_to_yang3: Wad = wadray::rmul_wr(
            redistributed_yang1_debt, wadray::rdiv_ww(recipient_troves_yang3_value, recipient_troves_value),
        );

        assert(
            yang1_debt_redistributed_to_yang2 + yang1_debt_redistributed_to_yang3 <= redistributed_yang1_debt,
            'should not exceed'
        );

        let recipient_trove1_yang2_pct: Ray = wadray::rdiv_ww(TROVE2_YANG2_DEPOSIT.into(), recipient_troves_yang2_amt);
        let recipient_trove2_yang2_pct: Ray = wadray::rdiv_ww(TROVE3_YANG2_DEPOSIT.into(), recipient_troves_yang2_amt);

        let recipient_trove1_yang3_pct: Ray = wadray::rdiv_ww(TROVE2_YANG3_DEPOSIT.into(), recipient_troves_yang3_amt);
        let recipient_trove2_yang3_pct: Ray = wadray::rdiv_ww(TROVE3_YANG3_DEPOSIT.into(), recipient_troves_yang3_amt);

        let expected_recipient_trove1_attr_debt: Wad = {
            // Redistributed debt from yang 1 to yang 2
            wadray::rmul_wr(yang1_debt_redistributed_to_yang2, recipient_trove1_yang2_pct)
                + // Redistributed debt from yang 1 to yang 3
                wadray::rmul_wr(yang1_debt_redistributed_to_yang3, recipient_trove1_yang3_pct)
                + // Redistributed debt from yang 2 to yang 2
                wadray::rmul_wr(redistributed_yang2_debt, recipient_trove1_yang2_pct)
                + // Redistributed debt from yang 3 to yang 3
                wadray::rmul_wr(redistributed_yang3_debt, recipient_trove1_yang3_pct)
        };

        let expected_recipient_trove2_attr_debt: Wad = {
            // Redistributed debt from yang 1 to yang 2
            wadray::rmul_wr(yang1_debt_redistributed_to_yang2, recipient_trove2_yang2_pct)
                + // Redistributed debt from yang 1 to yang 3
                wadray::rmul_wr(yang1_debt_redistributed_to_yang3, recipient_trove2_yang3_pct)
                + // Redistributed debt from yang 2 to yang 2
                wadray::rmul_wr(redistributed_yang2_debt, recipient_trove2_yang2_pct)
                + // Redistributed debt from yang 3 to yang 3
                wadray::rmul_wr(redistributed_yang3_debt, recipient_trove2_yang3_pct)
        };

        let expected_recipient_trove1_yang1_amt: Wad = wadray::rmul_wr(
            shrine_utils::TROVE1_YANG1_DEPOSIT.into(), expected_recipient_trove1_pct
        );
        let expected_recipient_trove1_attr_yangs: Span<YangBalance> = array![
            YangBalance { yang_id: 1, amount: expected_recipient_trove1_yang1_amt },
        ]
            .span();

        let (recipient_trove1_attr_yangs, recipient_trove1_attr_debt) = shrine
            .get_redistributions_attributed_to_trove(recipient_trove1);
        common::assert_yang_balances_equalish(
            recipient_trove1_attr_yangs,
            expected_recipient_trove1_attr_yangs,
            (WAD_ONE / 100).into(),
            'wrong attributed yangs'
        );
        common::assert_equalish(
            recipient_trove1_attr_debt,
            expected_recipient_trove1_attr_debt,
            (WAD_ONE / 100).into(),
            'wrong attributed debt'
        );

        let expected_recipient_trove2_yang1_amt: Wad = wadray::rmul_wr(
            shrine_utils::TROVE1_YANG1_DEPOSIT.into(), expected_recipient_trove2_pct
        );
        let expected_recipient_trove2_attr_yangs: Span<YangBalance> = array![
            YangBalance { yang_id: 1, amount: expected_recipient_trove2_yang1_amt },
        ]
            .span();

        let (recipient_trove2_attr_yangs, recipient_trove2_attr_debt) = shrine
            .get_redistributions_attributed_to_trove(recipient_trove2);
        common::assert_yang_balances_equalish(
            recipient_trove2_attr_yangs,
            expected_recipient_trove2_attr_yangs,
            (WAD_ONE / 100).into(),
            'wrong attributed yangs'
        );
        common::assert_equalish(
            recipient_trove2_attr_debt,
            expected_recipient_trove2_attr_debt,
            (WAD_ONE / 100).into(),
            'wrong attributed debt'
        );

        // Trigger an update in recipient troves with an empty melt
        shrine.melt(trove1_owner, recipient_trove1, WadZeroable::zero());
        shrine.melt(trove1_owner, recipient_trove2, WadZeroable::zero());

        assert(shrine.get_trove_redistribution_id(recipient_trove1) == expected_redistribution_id, 'wrong id');
        assert(shrine.get_trove_redistribution_id(recipient_trove2) == expected_redistribution_id, 'wrong id');

        let after_recipient_trove1_health: Health = shrine.get_trove_health(recipient_trove1);
        let after_recipient_trove2_health: Health = shrine.get_trove_health(recipient_trove2);

        //
        // Yangs assertions
        //

        // Check that recipient troves receive trove 1's yang1
        assert(shrine.get_deposit(yang1_addr, redistributed_trove).is_zero(), 'should be 0 yang 1 left');
        let recipient_trove1_yang1_amt: Wad = shrine.get_deposit(yang1_addr, recipient_trove1);
        common::assert_equalish(
            recipient_trove1_yang1_amt,
            expected_recipient_trove1_yang1_amt,
            100_u128.into(), // error margin
            'wrong recipient trove 1 yang 1'
        );

        let recipient_trove2_yang1_amt: Wad = shrine.get_deposit(yang1_addr, recipient_trove2);
        common::assert_equalish(
            recipient_trove2_yang1_amt,
            expected_recipient_trove2_yang1_amt,
            100_u128.into(), // error margin
            'wrong recipient trove 2 yang 1'
        );

        common::assert_equalish(
            recipient_trove1_yang1_amt + recipient_trove2_yang1_amt,
            shrine_utils::TROVE1_YANG1_DEPOSIT.into(),
            100_u128.into(), // error margin
            'wrong recipient troves yang 1'
        );

        // Total supply of yang1 should have been reduced by the error from loss of precision
        let exc_yang1_to_yang2_redistribution: ExceptionalYangRedistribution = shrine
            .get_exceptional_redistribution_for_yang_to_yang(yang2_addr, expected_redistribution_id, yang1_addr);
        let exc_yang1_to_yang3_redistribution: ExceptionalYangRedistribution = shrine
            .get_exceptional_redistribution_for_yang_to_yang(yang3_addr, expected_redistribution_id, yang1_addr);
        let expected_redistributed_yang1_amt: Wad = (total_recipient_troves_yang2
            * exc_yang1_to_yang2_redistribution.unit_yang)
            + (total_recipient_troves_yang3 * exc_yang1_to_yang3_redistribution.unit_yang);
        let expected_error: Wad = shrine_utils::TROVE1_YANG1_DEPOSIT.into() - expected_redistributed_yang1_amt;
        assert(
            shrine.get_yang_total(yang1_addr) == shrine_utils::TROVE1_YANG1_DEPOSIT.into() - expected_error,
            'wrong yang 1 total'
        );

        assert(shrine.get_deposit(yang2_addr, redistributed_trove).is_zero(), 'should be 0 yang 2 left');
        assert(shrine.get_deposit(yang3_addr, redistributed_trove).is_zero(), 'should be 0 yang 3 left');

        //
        // Debt assertions
        //

        // Calculate the percentage of debt redistributed to each yang, and each recipient trove's entitlement
        // to each portion.
        let recipient_troves_value: Wad = before_recipient_trove1_health.value + before_recipient_trove2_health.value;
        let recipient_troves_yang2_amt: Wad = (TROVE2_YANG2_DEPOSIT + TROVE3_YANG2_DEPOSIT).into();
        let recipient_troves_yang2_value: Wad = recipient_troves_yang2_amt * yang2_price;

        let recipient_troves_yang3_amt: Wad = (TROVE2_YANG3_DEPOSIT + TROVE3_YANG3_DEPOSIT).into();
        let recipient_troves_yang3_value: Wad = recipient_troves_yang3_amt * yang3_price;

        let yang2_unit_debt: Wad = shrine.get_redistribution_for_yang(yang2_addr, expected_redistribution_id).unit_debt;
        let yang3_unit_debt: Wad = shrine.get_redistribution_for_yang(yang3_addr, expected_redistribution_id).unit_debt;
        let yang1_to_yang2_unit_debt: Wad = shrine
            .get_exceptional_redistribution_for_yang_to_yang(yang2_addr, expected_redistribution_id, yang1_addr)
            .unit_debt;
        let yang1_to_yang3_unit_debt: Wad = shrine
            .get_exceptional_redistribution_for_yang_to_yang(yang3_addr, expected_redistribution_id, yang1_addr)
            .unit_debt;

        let yang1_debt_redistributed_to_yang2: Wad = wadray::rmul_wr(
            redistributed_yang1_debt, wadray::rdiv_ww(recipient_troves_yang2_value, recipient_troves_value),
        );
        let yang1_debt_redistributed_to_yang3: Wad = wadray::rmul_wr(
            redistributed_yang1_debt, wadray::rdiv_ww(recipient_troves_yang3_value, recipient_troves_value),
        );

        assert(
            yang1_debt_redistributed_to_yang2 + yang1_debt_redistributed_to_yang3 <= redistributed_yang1_debt,
            'should not exceed'
        );

        let expected_recipient_trove1_debt: Wad = before_recipient_trove1_health.debt
            + expected_recipient_trove1_attr_debt;

        common::assert_equalish(
            after_recipient_trove1_health.debt,
            expected_recipient_trove1_debt,
            100_u128.into(), // error margin
            'wrong recipient trove 1 debt',
        );

        let expected_recipient_trove2_debt: Wad = before_recipient_trove2_health.debt
            + expected_recipient_trove2_attr_debt;

        common::assert_equalish(
            after_recipient_trove2_health.debt,
            expected_recipient_trove2_debt,
            100_u128.into(), // error margin
            'wrong recipient trove 2 debt',
        );

        let recipient_troves_debt_increment: Wad = (after_recipient_trove1_health.debt
            - before_recipient_trove1_health.debt)
            + (after_recipient_trove2_health.debt - before_recipient_trove2_health.debt);
        common::assert_equalish(
            redistributed_trove_health.debt,
            recipient_troves_debt_increment,
            100_u128.into(), // error margin
            'wrong recipients debt increment',
        );

        // Check invariant that redistributed unit debt should be equal to all debt redistributed to troves
        // and the errors for all yangs
        let cumulative_error: Wad = get_redistributed_debt_error(shrine, yangs, expected_redistribution_id);

        let actual_redistributed_debt: Wad = (recipient_troves_yang2_amt * yang2_unit_debt)
            + (recipient_troves_yang2_amt * yang1_to_yang2_unit_debt)
            + (recipient_troves_yang3_amt * yang3_unit_debt)
            + (recipient_troves_yang3_amt * yang1_to_yang3_unit_debt);
        assert(
            redistributed_trove_health.debt == actual_redistributed_debt + cumulative_error, 'debt invariant failed'
        );

        common::assert_equalish(
            redistributed_trove_health.debt,
            recipient_troves_debt_increment + cumulative_error,
            5_u128.into(), // error margin
            'loss of precision in pulling',
        );

        // Note that we cannot fully check the updated value of the recipient trove here because
        // we need the oracle to update the yang price for yang2 and yang3 based on the new asset
        // amount yang, but we can check the increase in value from yang1.
        let expected_recipient_trove1_value: Wad = before_recipient_trove1_health.value
            + (recipient_trove1_yang1_amt * yang1_price);
        common::assert_equalish(
            after_recipient_trove1_health.value,
            expected_recipient_trove1_value,
            100_u128.into(), // error margin
            'wrong recipient trove 1 value'
        );

        shrine_utils::assert_shrine_invariants(shrine, yangs, 3);
    }

    #[test]
    fn test_shrine_redistribution_after_unpulled_exceptional_redistribution() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        // Manually set up troves so that the redistributed trove (trove 1) uses all three yangs
        // while the recipient troves (trove 2 and 3) uses only yang 2.
        let yangs: Span<ContractAddress> = shrine_utils::three_yang_addrs_reversed();
        let yang1_addr = *yangs.at(2);
        let yang2_addr = *yangs.at(1);
        let yang3_addr = *yangs.at(0);

        let trove1_owner = common::trove1_owner_addr();
        let redistributed_trove1: u64 = common::TROVE_1;

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.deposit(yang1_addr, redistributed_trove1, shrine_utils::TROVE1_YANG1_DEPOSIT.into());
        shrine.deposit(yang2_addr, redistributed_trove1, shrine_utils::TROVE1_YANG2_DEPOSIT.into());
        shrine.deposit(yang3_addr, redistributed_trove1, shrine_utils::TROVE1_YANG3_DEPOSIT.into());
        let redistributed_trove1_debt: Wad = shrine_utils::TROVE1_FORGE_AMT.into();
        shrine.forge(trove1_owner, redistributed_trove1, redistributed_trove1_debt, 0_u128.into());

        let trove2_owner = common::trove2_owner_addr();
        let recipient_trove: u64 = common::TROVE_2;
        shrine.deposit(yang2_addr, recipient_trove, TROVE2_YANG2_DEPOSIT.into());
        shrine.forge(trove2_owner, recipient_trove, TROVE2_FORGE_AMT.into(), 0_u128.into());

        let trove3_owner = common::trove3_owner_addr();
        let redistributed_trove2: u64 = common::TROVE_3;
        shrine.deposit(yang2_addr, redistributed_trove2, TROVE3_YANG2_DEPOSIT.into());
        shrine.forge(trove3_owner, redistributed_trove2, TROVE3_FORGE_AMT.into(), 0_u128.into());

        let shrine_health: Health = shrine.get_shrine_health();
        let start_total_debt: Wad = shrine_health.debt;

        // Simulate purge with 0 yin to update the trove's debt
        let before_recipient_trove_health: Health = shrine.get_trove_health(recipient_trove);
        // Redistributed trove 2 is first a recipient in the first redistribution
        let before_recipient_trove2_health: Health = shrine.get_trove_health(redistributed_trove2);

        let total_recipient_troves_value: Wad = before_recipient_trove_health.value
            + before_recipient_trove2_health.value;
        let expected_recipient_trove1_pct: Ray = wadray::rdiv_ww(
            before_recipient_trove_health.value, total_recipient_troves_value
        );

        shrine.melt(trove1_owner, redistributed_trove1, WadZeroable::zero());
        shrine.redistribute(redistributed_trove1, redistributed_trove1_debt, RAY_ONE.into());

        let expected_redistribution_id: u32 = 1;
        let first_redistribution_yang2_unit_debt: Wad = shrine
            .get_redistribution_for_yang(yang2_addr, expected_redistribution_id)
            .unit_debt;
        let first_redistribution_yang1_to_yang2_unit_debt: Wad = shrine
            .get_exceptional_redistribution_for_yang_to_yang(yang2_addr, expected_redistribution_id, yang1_addr)
            .unit_debt;
        let first_redistribution_yang3_to_yang2_unit_debt: Wad = shrine
            .get_exceptional_redistribution_for_yang_to_yang(yang2_addr, expected_redistribution_id, yang3_addr)
            .unit_debt;

        // At this point, both troves 2 and 3 have some amount of each yang.
        // Redistribute trove 3 next to check that the originally redistributed
        // yang 1 for trove 3 is properly redistributed to trove 2, even if trove 2
        // is not updated.
        let redistributed_trove2_health: Health = shrine.get_trove_health(redistributed_trove2);
        shrine.melt(trove3_owner, redistributed_trove2, WadZeroable::zero());
        shrine.redistribute(redistributed_trove2, redistributed_trove2_health.debt, RAY_ONE.into());

        assert(shrine.get_redistributions_count() == 2, 'wrong redistributions count');

        // Check redistributions attributed to recipient troves
        let expected_recipient_trove_yang1_amt: Wad = wadray::rmul_wr(
            shrine_utils::TROVE1_YANG1_DEPOSIT.into(), expected_recipient_trove1_pct
        );
        // Recipient trove's yang 3 amount should be the amount received from the first
        // redistribution, since the second redistribution would have rebased
        let expected_recipient_trove_yang3_amt: Wad = wadray::rmul_wr(
            shrine_utils::TROVE1_YANG3_DEPOSIT.into(), expected_recipient_trove1_pct
        );
        let expected_recipient_trove_attr_yangs: Span<YangBalance> = array![
            YangBalance { yang_id: 1, amount: expected_recipient_trove_yang1_amt },
            YangBalance { yang_id: 3, amount: expected_recipient_trove_yang3_amt },
        ]
            .span();

        let expected_recipient_trove_attr_debt: Wad = (shrine_utils::TROVE1_FORGE_AMT + TROVE3_FORGE_AMT).into();

        let (recipient_trove_attr_yangs, recipient_trove_attr_debt) = shrine
            .get_redistributions_attributed_to_trove(recipient_trove);
        common::assert_yang_balances_equalish(
            recipient_trove_attr_yangs,
            expected_recipient_trove_attr_yangs,
            (WAD_ONE / 100).into(),
            'wrong attributed yangs'
        );
        common::assert_equalish(
            recipient_trove_attr_debt,
            expected_recipient_trove_attr_debt,
            (WAD_ONE / 100).into(),
            'wrong attributed debt'
        );

        // Trigger an update in recipient troves with an empty melt
        shrine.melt(trove1_owner, recipient_trove, WadZeroable::zero());

        let expected_redistribution_id: u32 = 2;
        assert(shrine.get_trove_redistribution_id(recipient_trove) == 2, 'wrong id');

        let after_recipient_trove_health: Health = shrine.get_trove_health(recipient_trove);

        let recipient_trove_yang1_amt: Wad = shrine.get_deposit(yang1_addr, recipient_trove);
        let recipient_trove_yang2_amt: Wad = TROVE2_YANG2_DEPOSIT.into();
        let recipient_trove_yang3_amt: Wad = shrine.get_deposit(yang3_addr, recipient_trove);
        let second_redistribution_yang1_unit_debt: Wad = shrine
            .get_redistribution_for_yang(yang1_addr, expected_redistribution_id)
            .unit_debt;
        let second_redistribution_yang2_unit_debt: Wad = shrine
            .get_redistribution_for_yang(yang2_addr, expected_redistribution_id)
            .unit_debt;
        let second_redistribution_yang3_unit_debt: Wad = shrine
            .get_redistribution_for_yang(yang3_addr, expected_redistribution_id)
            .unit_debt;

        //
        // Debt assertion
        //

        // Recipient trove should have the total debt before all redistributions
        // minus some loss of precision
        common::assert_equalish(
            after_recipient_trove_health.debt,
            start_total_debt,
            10_u128.into(), // error margin
            'wrong recipient trove debt'
        );

        let cumulative_error: Wad = get_redistributed_debt_error(shrine, yangs, expected_redistribution_id);

        let actual_redistributed_debt: Wad = (recipient_trove_yang2_amt * first_redistribution_yang2_unit_debt)
            + (recipient_trove_yang2_amt * first_redistribution_yang1_to_yang2_unit_debt)
            + (recipient_trove_yang2_amt * first_redistribution_yang3_to_yang2_unit_debt)
            + (recipient_trove_yang1_amt * second_redistribution_yang1_unit_debt)
            + (recipient_trove_yang2_amt * second_redistribution_yang2_unit_debt)
            + (recipient_trove_yang3_amt * second_redistribution_yang3_unit_debt);
        let total_redistributed_debt: Wad = (shrine_utils::TROVE1_FORGE_AMT + TROVE3_FORGE_AMT).into();

        assert(total_redistributed_debt == actual_redistributed_debt + cumulative_error, 'debt invariant failed');

        assert(
            start_total_debt == after_recipient_trove_health.debt + cumulative_error, 'loss of precision in pulling'
        );

        //
        // Yangs assertions
        //

        assert(shrine.get_deposit(yang1_addr, redistributed_trove2).is_zero(), 'should be 0 yang 1 left');
        // Recipient trove's yang 1 amount should be the amount received from the first
        // redistribution, since the second redistribution would have rebased
        let recipient_trove_yang1_amt: Wad = shrine.get_deposit(yang1_addr, recipient_trove);
        common::assert_equalish(
            recipient_trove_yang1_amt,
            expected_recipient_trove_yang1_amt,
            100_u128.into(), // error margin
            'wrong recipient trove yang 1'
        );
        // Check that the second redistributed trove's yang1 has been rebased
        common::assert_equalish(
            shrine.get_yang_total(yang1_addr),
            recipient_trove_yang1_amt + shrine.get_initial_yang_amt(yang1_addr),
            20_u128.into(), // error margin due to loss of precision in favour of protocol
            'wrong total yang 1'
        );

        assert(shrine.get_deposit(yang2_addr, redistributed_trove2).is_zero(), 'should be 0 yang 2 left');
        // Recipient trove's yang2 should stay constant since all redistributions were via rebasing
        assert(recipient_trove_yang2_amt == TROVE2_YANG2_DEPOSIT.into(), 'wrong recipient trove yang 2');
        assert(
            shrine.get_yang_total(yang2_addr) == TROVE2_YANG2_DEPOSIT.into() + shrine.get_initial_yang_amt(yang2_addr),
            'wrong total yang 2'
        );

        assert(shrine.get_deposit(yang3_addr, redistributed_trove2).is_zero(), 'should be 0 yang 3 left');
        common::assert_equalish(
            recipient_trove_yang3_amt,
            expected_recipient_trove_yang3_amt,
            100_u128.into(), // error margin
            'wrong recipient trove yang 3'
        );
        // Check that the second redistributed trove's yang3 has been rebased
        common::assert_equalish(
            shrine.get_yang_total(yang3_addr),
            recipient_trove_yang3_amt + shrine.get_initial_yang_amt(yang3_addr),
            10_u128.into(), // error margin due to loss of precision in favour of protocol
            'wrong total yang 3'
        );

        shrine_utils::assert_shrine_invariants(shrine, yangs, 3);
    }

    // Redistribution with only 1 trove.
    // Since the trove's yangs are zeroed, the initial yang would essentially "receive"
    // the trove's value via rebasing. The trove's debt would also be zeroed even though
    // it was not distributed at all. However, the debt would still be backed, and the
    // value can be accessed in the event of a shutdown.
    #[test]
    fn test_shrine_redistribution_only_one_trove_remaining() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);

        start_prank(CheatTarget::All, shrine_utils::admin());
        setup_trove1(shrine);

        // Simulate purge with 0 yin to update the trove's debt
        start_prank(CheatTarget::All, shrine_utils::admin());
        let trove1_owner = common::trove1_owner_addr();
        let redistributed_trove = common::TROVE_1;
        let redistributed_trove_health: Health = shrine.get_trove_health(redistributed_trove);
        shrine.melt(trove1_owner, redistributed_trove, WadZeroable::zero());

        assert(shrine.get_redistributions_count() == 0, 'wrong start state');
        shrine.redistribute(redistributed_trove, redistributed_trove_health.debt, RAY_ONE.into());

        let expected_redistribution_id: u32 = 1;
        assert(shrine.get_redistributions_count() == expected_redistribution_id, 'wrong redistribution count');

        let after_trove_health: Health = shrine.get_trove_health(common::TROVE_2);
        assert(after_trove_health.value.is_zero(), 'wrong value post redistribution');
        assert(after_trove_health.debt.is_zero(), 'wrong debt after redistribution');

        assert(shrine.get_trove_redistribution_id(common::TROVE_2) == 0, 'wrong redistribution id');
        // Trigger an update in trove 2 with an empty melt
        shrine.melt(trove1_owner, common::TROVE_2, WadZeroable::zero());
        assert(shrine.get_trove_redistribution_id(common::TROVE_2) == expected_redistribution_id, 'wrong id');

        shrine_utils::assert_shrine_invariants(shrine, shrine_utils::two_yang_addrs(), 3);
    }

    // This test asserts that the sum of troves' debt after pulling redistributed debt does not
    // exceed the total debt.
    // Note that yangs 1 and 2 are normally redistributed, and yang 3 is exceptionally
    // redistributed.
    #[test]
    fn test_multi_troves_system_debt_not_exceeded() {
        let shrine: IShrineDispatcher = redistribution_setup(Option::None);

        let yangs: Span<ContractAddress> = shrine_utils::two_yang_addrs();
        let yang1_addr = *yangs.at(0);
        let yang2_addr = *yangs.at(1);

        // Create another 10 troves with different collateral amounts
        let mut idx: u64 = 0;
        let new_troves_count: u64 = 10;
        start_prank(CheatTarget::All, shrine_utils::admin());
        loop {
            if idx == new_troves_count {
                break;
            }

            let trove_idx: u64 = 4 + idx;
            let tmp_multiplier: u128 = (idx + 1).into();
            shrine.deposit(yang1_addr, trove_idx, (tmp_multiplier * 100000000000000000).into()); // idx * 0.1 Wad
            shrine.deposit(yang2_addr, trove_idx, (tmp_multiplier * 200000000000000000).into()); // idx * 0.2 Wad

            idx += 1;
        };

        shrine.redistribute(common::TROVE_1, shrine_utils::TROVE1_FORGE_AMT.into(), RAY_ONE.into());

        shrine_utils::assert_shrine_invariants(shrine, yangs, 13);
    }

    #[test]
    #[should_panic(expected: ('SH: pct_val_to_redistribute > 1',))]
    fn test_shrine_redistribution_gt_one_ray_pct_value_to_redistribute_fail() {
        let shrine: IShrineDispatcher = redistribution_setup(Option::None);

        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine.redistribute(common::TROVE_1, 1_u128.into(), (RAY_ONE + RAY_PERCENT).into());
    }
}
