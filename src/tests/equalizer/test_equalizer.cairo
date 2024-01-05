mod test_equalizer {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use cmp::min;
    use debug::PrintTrait;
    use integer::BoundedU128;
    use opus::core::equalizer::equalizer as equalizer_contract;
    use opus::core::roles::equalizer_roles;
    use opus::core::shrine::shrine;
    use opus::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use opus::interfaces::IEqualizer::{IEqualizerDispatcher, IEqualizerDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::equalizer::utils::equalizer_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::Health;
    use snforge_std::{declare, start_prank, stop_prank, CheatTarget, spy_events, SpyOn, EventSpy, EventAssertions};
    use starknet::testing::{set_block_timestamp};
    use starknet::{ContractAddress, get_block_timestamp};
    use wadray::{Ray, SignedWad, Wad, WadZeroable, WAD_ONE};

    #[test]
    fn test_equalizer_deploy() {
        let (_, equalizer, allocator) = equalizer_utils::equalizer_deploy(Option::None);

        assert(equalizer.get_allocator() == allocator.contract_address, 'wrong allocator address');

        let equalizer_ac = IAccessControlDispatcher { contract_address: equalizer.contract_address };
        let admin = shrine_utils::admin();
        assert(equalizer_ac.get_admin() == admin, 'wrong admin');
        assert(equalizer_ac.get_roles(admin) == equalizer_roles::default_admin_role(), 'wrong role');
        assert(equalizer_ac.has_role(equalizer_roles::SET_ALLOCATOR, admin), 'role not granted');
    }

    #[test]
    fn test_equalize_pass() {
        let (shrine, equalizer, _) = equalizer_utils::equalizer_deploy(Option::None);
        let mut spy = spy_events(SpyOn::One(equalizer.contract_address));

        let surplus: Wad = (500 * WAD_ONE).into();
        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        shrine.adjust_budget(surplus.into());
        assert(shrine.get_budget() == surplus.into(), 'sanity check');

        let before_total_yin = shrine.get_total_yin();
        let before_equalizer_yin: Wad = shrine.get_yin(equalizer.contract_address);

        let minted_surplus: Wad = equalizer.equalize();
        assert(surplus == minted_surplus, 'surplus mismatch');

        let after_equalizer_yin: Wad = shrine.get_yin(equalizer.contract_address);
        assert(after_equalizer_yin == before_equalizer_yin + surplus, 'surplus not received');

        // Check remaining surplus
        assert(shrine.get_budget().is_zero(), 'surplus should be zeroed');

        assert(shrine.get_total_yin() == before_total_yin + minted_surplus, 'wrong total yin');

        let expected_events = array![
            (
                equalizer.contract_address,
                equalizer_contract::Event::Equalize(equalizer_contract::Equalize { yin_amt: surplus.into() })
            ),
        ];
        spy.assert_emitted(@expected_events);

        // Assert that calling equalize again passes when budget is zero
        assert(equalizer.equalize().is_zero(), 'minted surplus should be zero');

        // Create a deficit
        let deficit = SignedWad { val: (500 * WAD_ONE), sign: true };
        shrine.adjust_budget(deficit);

        assert(equalizer.equalize().is_zero(), 'minted surplus should be zero');
    }

    #[test]
    fn test_equalize_debt_ceiling_exceeded_pass() {
        let (shrine, equalizer, _) = equalizer_utils::equalizer_deploy(Option::None);
        let mut spy = spy_events(SpyOn::One(equalizer.contract_address));

        let yangs = array![shrine_utils::yang1_addr(), shrine_utils::yang2_addr(),].span();
        let debt_ceiling: Wad = shrine.get_debt_ceiling();

        // deposit 1000 ETH and forge the debt ceiling
        shrine_utils::trove1_deposit(shrine, (1000 * WAD_ONE).into());
        shrine_utils::trove1_forge(shrine, debt_ceiling);
        let eth: ContractAddress = shrine_utils::yang1_addr();
        let (eth_price, _, _) = shrine.get_current_yang_price(eth);

        let mut loop_id = 5;
        let mut start_debt = debt_ceiling;
        loop {
            if loop_id.is_zero() {
                break;
            }

            // accrue interest to exceed the debt ceiling
            common::advance_intervals_and_refresh_prices_and_multiplier(shrine, yangs, 500);

            // update price to speed up calculation
            start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
            shrine.advance(eth, eth_price);
            stop_prank(CheatTarget::One(shrine.contract_address));

            shrine_utils::trove1_deposit(shrine, WadZeroable::zero());
            let trove_health: Health = shrine.get_trove_health(common::TROVE_1);
            let expected_surplus: Wad = trove_health.debt - start_debt;

            assert(shrine.get_budget() == expected_surplus.into(), 'sanity check');

            let before_total_yin = shrine.get_total_yin();
            let before_equalizer_yin: Wad = shrine.get_yin(equalizer.contract_address);

            let minted_surplus: Wad = equalizer.equalize();
            assert(minted_surplus == expected_surplus, 'surplus mismatch');

            let total_yin: Wad = shrine.get_total_yin();
            assert(total_yin > start_debt, 'below debt ceiling');

            let after_equalizer_yin: Wad = shrine.get_yin(equalizer.contract_address);
            assert(after_equalizer_yin == before_equalizer_yin + expected_surplus, 'surplus not received');

            // Check remaining surplus
            assert(shrine.get_budget().is_zero(), 'surplus should be zeroed');

            assert(shrine.get_total_yin() == before_total_yin + minted_surplus, 'wrong total yin');

            let expected_events = array![
                (
                    equalizer.contract_address,
                    equalizer_contract::Event::Equalize(
                        equalizer_contract::Equalize { yin_amt: expected_surplus.into() }
                    )
                ),
            ];
            spy.assert_emitted(@expected_events);

            start_debt = total_yin;

            loop_id -= 1;
        }
    }

    #[test]
    fn test_allocate_pass() {
        let (shrine, equalizer, _) = equalizer_utils::equalizer_deploy(Option::None);
        let mut spy = spy_events(SpyOn::One(equalizer.contract_address));

        // Simulate minted surplus by injecting to Equalizer directly
        start_prank(CheatTarget::Multiple(array![shrine.contract_address]), shrine_utils::admin());
        let surplus: Wad = (1000 * WAD_ONE + 123).into();
        shrine.inject(equalizer.contract_address, surplus);

        let recipients = equalizer_utils::initial_recipients();
        let percentages = equalizer_utils::initial_percentages();

        let mut tokens: Array<ContractAddress> = array![shrine.contract_address];
        let mut before_balances = common::get_token_balances(tokens.span(), recipients);
        let mut before_yin_balances = *before_balances.pop_front().unwrap();

        stop_prank(CheatTarget::One(shrine.contract_address));

        equalizer.allocate();

        let mut after_balances = common::get_token_balances(tokens.span(), recipients);
        let mut after_yin_balances = *after_balances.pop_front().unwrap();

        let mut allocated = WadZeroable::zero();
        let mut percentages_copy = percentages;
        loop {
            match percentages_copy.pop_front() {
                Option::Some(percentage) => {
                    let expected_increment = wadray::rmul_rw(*percentage, surplus);
                    // sanity check
                    assert(expected_increment.is_non_zero(), 'increment is zero');

                    let before_yin_bal = *before_yin_balances.pop_front().unwrap();
                    let after_yin_bal = *after_yin_balances.pop_front().unwrap();
                    assert(after_yin_bal == before_yin_bal + expected_increment.val, 'wrong recipient balance');

                    allocated += expected_increment;
                },
                Option::None => { break; }
            };
        };
        assert(surplus == allocated + shrine.get_yin(equalizer.contract_address), 'allocated mismatch');

        let expected_events = array![
            (
                equalizer.contract_address,
                equalizer_contract::Event::Allocate(
                    equalizer_contract::Allocate { recipients, percentages, amount: allocated }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_allocate_zero_amount_pass() {
        let (shrine, equalizer, _) = equalizer_utils::equalizer_deploy(Option::None);

        assert(shrine.get_yin(equalizer.contract_address).is_zero(), 'sanity check');

        equalizer.allocate();
    }

    #[test]
    fn test_normalize_pass() {
        let (shrine, equalizer, _) = equalizer_utils::equalizer_deploy(Option::None);
        let mut spy = spy_events(SpyOn::One(equalizer.contract_address));

        let inject_amt: Wad = (5000 * WAD_ONE).into();
        let mut normalize_amts: Span<Wad> = array![
            WadZeroable::zero(),
            (inject_amt.val - 1).into(),
            inject_amt,
            (inject_amt.val + 1).into(), // exceeds deficit, but should be capped in `normalize`
        ]
            .span();

        let admin: ContractAddress = shrine_utils::admin();
        start_prank(CheatTarget::Multiple(array![shrine.contract_address, equalizer.contract_address]), admin);

        loop {
            match normalize_amts.pop_front() {
                Option::Some(normalize_amt) => {
                    // Create the deficit
                    let deficit = SignedWad { val: inject_amt.val, sign: true };
                    shrine.adjust_budget(deficit);
                    assert(shrine.get_budget() == deficit, 'sanity check #1');

                    // Mint the deficit amount to the admin
                    shrine.inject(admin, inject_amt);

                    let normalized_amt: Wad = equalizer.normalize(*normalize_amt);

                    let expected_normalized_amt: Wad = min(deficit.val.into(), *normalize_amt);
                    assert(normalized_amt == expected_normalized_amt, 'wrong normalized amt');
                    assert(shrine.get_budget() == deficit + expected_normalized_amt.into(), 'wrong remaining deficit');

                    // Event is emitted only if non-zero amount of deficit was wiped
                    if expected_normalized_amt.is_non_zero() {
                        let expected_events = array![
                            (
                                equalizer.contract_address,
                                equalizer_contract::Event::Normalize(
                                    equalizer_contract::Normalize { caller: admin, yin_amt: expected_normalized_amt }
                                )
                            ),
                        ];
                        spy.assert_emitted(@expected_events);
                    }

                    // Reset by normalizing all remaining deficit
                    equalizer.normalize(BoundedU128::max().into());

                    assert(shrine.get_budget().is_zero(), 'sanity check #2');

                    // Assert nothing happens if we try to normalize again
                    equalizer.normalize(BoundedU128::max().into());

                    assert(shrine.get_budget().is_zero(), 'sanity check #3');
                },
                Option::None => { break; }
            };
        };
    }

    #[test]
    fn test_set_allocator_pass() {
        let allocator_class = Option::Some(declare('allocator'));
        let (_, equalizer, allocator) = equalizer_utils::equalizer_deploy(allocator_class);
        let mut spy = spy_events(SpyOn::One(equalizer.contract_address));

        let new_recipients = equalizer_utils::new_recipients();
        let mut new_percentages = equalizer_utils::new_percentages();
        let new_allocator = equalizer_utils::allocator_deploy(new_recipients, new_percentages, allocator_class);

        start_prank(CheatTarget::One(equalizer.contract_address), shrine_utils::admin());
        equalizer.set_allocator(new_allocator.contract_address);

        // Check allocator is updated
        assert(equalizer.get_allocator() == new_allocator.contract_address, 'allocator not updated');

        let expected_events = array![
            (
                equalizer.contract_address,
                equalizer_contract::Event::AllocatorUpdated(
                    equalizer_contract::AllocatorUpdated {
                        old_address: allocator.contract_address, new_address: new_allocator.contract_address
                    }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_allocator_fail() {
        let allocator_class = Option::Some(declare('allocator'));
        let (_, equalizer, _) = equalizer_utils::equalizer_deploy(allocator_class);
        let new_allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::new_recipients(), equalizer_utils::new_percentages(), allocator_class
        );

        start_prank(CheatTarget::One(equalizer.contract_address), common::badguy());
        equalizer.set_allocator(new_allocator.contract_address);
    }
}
