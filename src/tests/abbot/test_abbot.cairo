mod test_abbot {
    use debug::PrintTrait;
    use opus::core::abbot::abbot as abbot_contract;
    use opus::core::sentinel::sentinel as sentinel_contract;
    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::abbot::utils::abbot_utils;
    use opus::tests::common;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::{AssetBalance, Health};
    use opus::utils::math::fixed_point_to_wad;
    use snforge_std::{start_prank, stop_prank, CheatTarget, spy_events, SpyOn, EventSpy, EventAssertions};
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable};
    use wadray::{Wad, WadZeroable, WAD_SCALE};

    //
    // Tests
    //

    #[test]
    fn test_open_trove_pass() {
        let (shrine, _, abbot, yangs, gates) = abbot_utils::abbot_deploy(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        let mut spy = spy_events(SpyOn::One(abbot.contract_address));

        // Deploying the first trove
        let trove_owner: ContractAddress = common::trove1_owner_addr();
        let forge_amt: Wad = abbot_utils::OPEN_TROVE_FORGE_AMT.into();
        common::fund_user(trove_owner, yangs, abbot_utils::initial_asset_amts());
        let deposited_amts: Span<u128> = abbot_utils::open_trove_yang_asset_amts();
        let trove_id: u64 = common::open_trove_helper(abbot, trove_owner, yangs, deposited_amts, gates, forge_amt);

        // Check trove ID
        let expected_trove_id: u64 = 1;
        assert(trove_id == expected_trove_id, 'wrong trove ID');
        assert(
            abbot.get_trove_owner(expected_trove_id).expect('should not be zero') == trove_owner, 'wrong trove owner'
        );
        assert(abbot.get_troves_count() == expected_trove_id, 'wrong troves count');

        let mut expected_user_trove_ids: Array<u64> = array![expected_trove_id];
        assert(abbot.get_user_trove_ids(trove_owner) == expected_user_trove_ids.span(), 'wrong user trove ids');

        let mut yangs_total: Array<Wad> = ArrayTrait::new();
        // Check yangs
        let mut yangs_copy = yangs;
        let mut deposited_amts_copy = deposited_amts;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    let decimals: u8 = IERC20Dispatcher { contract_address: *yang }.decimals();
                    let expected_initial_yang: Wad = fixed_point_to_wad(
                        sentinel_contract::INITIAL_DEPOSIT_AMT, decimals
                    );
                    let expected_deposited_yang: Wad = fixed_point_to_wad(
                        *deposited_amts_copy.pop_front().unwrap(), decimals
                    );
                    let expected_yang_total: Wad = expected_initial_yang + expected_deposited_yang;
                    assert(shrine.get_yang_total(*yang) == expected_yang_total, 'wrong yang total #1');
                    yangs_total.append(expected_yang_total);

                    assert(
                        shrine.get_deposit(*yang, trove_id) == expected_deposited_yang, 'wrong trove yang balance #1'
                    );
                },
                Option::None => { break; },
            };
        };

        // Check trove's debt
        let trove_health: Health = shrine.get_trove_health(expected_trove_id);
        assert(trove_health.debt == forge_amt, 'wrong trove debt');

        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.debt == forge_amt, 'wrong total debt');

        // User opens another trove
        let second_forge_amt: Wad = 1666000000000000000000_u128.into();
        let mut second_deposit_amts = abbot_utils::subsequent_deposit_amts();
        let second_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner, yangs, second_deposit_amts, gates, second_forge_amt
        );

        let expected_trove_id: u64 = 2;
        assert(second_trove_id == expected_trove_id, 'wrong trove ID');
        assert(
            abbot.get_trove_owner(expected_trove_id).expect('should not be zero') == trove_owner, 'wrong trove owner'
        );
        assert(abbot.get_troves_count() == expected_trove_id, 'wrong troves count');

        expected_user_trove_ids.append(expected_trove_id);
        assert(abbot.get_user_trove_ids(trove_owner) == expected_user_trove_ids.span(), 'wrong user trove ids');

        // Check yangs
        let mut yangs_total = yangs_total.span();
        let mut yangs_copy = yangs;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    let decimals: u8 = IERC20Dispatcher { contract_address: *yang }.decimals();
                    let before_yang_total: Wad = *yangs_total.pop_front().unwrap();
                    let expected_deposited_yang: Wad = fixed_point_to_wad(
                        *second_deposit_amts.pop_front().unwrap(), decimals
                    );
                    let expected_yang_total: Wad = before_yang_total + expected_deposited_yang;
                    assert(shrine.get_yang_total(*yang) == expected_yang_total, 'wrong yang total #2');

                    assert(
                        shrine.get_deposit(*yang, second_trove_id) == expected_deposited_yang,
                        'wrong trove yang balance #2'
                    );
                },
                Option::None => { break; },
            };
        };

        let shrine_health: Health = shrine.get_shrine_health();
        assert(shrine_health.debt == forge_amt + second_forge_amt, 'wrong total debt #2');

        let expected_events = array![
            (
                abbot.contract_address,
                abbot_contract::Event::TroveOpened(
                    abbot_contract::TroveOpened { user: trove_owner, trove_id: trove_id, }
                )
            ),
            (
                abbot.contract_address,
                abbot_contract::Event::TroveOpened(
                    abbot_contract::TroveOpened { user: trove_owner, trove_id: second_trove_id, }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);

        shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    #[should_panic(expected: ('ABB: No yangs',))]
    fn test_open_trove_no_yangs_fail() {
        let (_, _, abbot, _, _) = abbot_utils::abbot_deploy(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );
        let trove_owner: ContractAddress = common::trove1_owner_addr();

        let yangs: Array<ContractAddress> = ArrayTrait::new();
        let yang_amts: Array<u128> = ArrayTrait::new();
        let forge_amt: Wad = 1_u128.into();
        let max_forge_fee_pct: Wad = WadZeroable::zero();

        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);
        let yang_assets: Span<AssetBalance> = common::combine_assets_and_amts(yangs.span(), yang_amts.span());
        abbot.open_trove(yang_assets, forge_amt, max_forge_fee_pct);
    }

    #[test]
    #[should_panic(expected: ('SE: Yang not added',))]
    fn test_open_trove_invalid_yang_fail() {
        let (_, _, abbot, _, _) = abbot_utils::abbot_deploy(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        let invalid_yang: ContractAddress = sentinel_utils::dummy_yang_addr();
        let mut yangs: Array<ContractAddress> = array![invalid_yang];
        let mut yang_amts: Array<u128> = array![WAD_SCALE];
        let forge_amt: Wad = 1_u128.into();
        let max_forge_fee_pct: Wad = WadZeroable::zero();

        let yang_assets: Span<AssetBalance> = common::combine_assets_and_amts(yangs.span(), yang_amts.span());
        abbot.open_trove(yang_assets, forge_amt, max_forge_fee_pct);
    }

    #[test]
    fn test_close_trove_pass() {
        let (shrine, _, abbot, yangs, _, trove_owner, trove_id, _, _) = abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        let mut spy = spy_events(SpyOn::One(abbot.contract_address));

        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);
        abbot.close_trove(trove_id);

        let mut yangs_copy = yangs;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => { assert(shrine.get_deposit(*yang, trove_id).is_zero(), 'wrong yang amount'); },
                Option::None => { break; },
            };
        };

        let trove_health: Health = shrine.get_trove_health(trove_id);
        assert(trove_health.debt.is_zero(), 'wrong trove debt');

        let expected_events = array![
            (abbot.contract_address, abbot_contract::Event::TroveClosed(abbot_contract::TroveClosed { trove_id })),
        ];
        spy.assert_emitted(@expected_events);

        shrine_utils::assert_shrine_invariants(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    #[should_panic(expected: ('ABB: Not trove owner',))]
    fn test_close_non_owner_fail() {
        let (_, _, abbot, _, _, _, trove_id, _, _) = abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        start_prank(CheatTarget::One(abbot.contract_address), common::badguy());
        abbot.close_trove(trove_id);
    }

    #[test]
    fn test_deposit_pass() {
        let (shrine, _, abbot, yangs, gates, trove_owner, trove_id, deposited_amts, _) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);
        let mut yangs_copy = yangs;
        let mut deposited_amts_copy = deposited_amts;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    let before_trove_yang: Wad = shrine.get_deposit(*yang, trove_id);
                    let decimals: u8 = IERC20Dispatcher { contract_address: *yang }.decimals();
                    let deposit_amt: u128 = *deposited_amts_copy.pop_front().unwrap();
                    let expected_deposited_yang: Wad = fixed_point_to_wad(deposit_amt, decimals);
                    abbot.deposit(trove_id, AssetBalance { address: *yang, amount: deposit_amt });
                    let after_trove_yang: Wad = shrine.get_deposit(*yang, trove_id);
                    assert(after_trove_yang == before_trove_yang + expected_deposited_yang, 'wrong yang amount #1');

                    // Depositing 0 should pass
                    abbot.deposit(trove_id, AssetBalance { address: *yang, amount: 0_u128 });
                    assert(shrine.get_deposit(*yang, trove_id) == after_trove_yang, 'wrong yang amount #2');
                },
                Option::None => { break; },
            };
        };

        // Check that non-owner can deposit to trove
        let non_owner: ContractAddress = common::trove2_owner_addr();
        let mut non_owner_deposit_amts: Span<u128> = abbot_utils::subsequent_deposit_amts();
        common::fund_user(non_owner, yangs, abbot_utils::initial_asset_amts());

        let mut yangs_copy = yangs;
        let mut gates_copy = gates;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    sentinel_utils::approve_max(*gates_copy.pop_front().unwrap(), *yang, non_owner);

                    let before_trove_yang: Wad = shrine.get_deposit(*yang, trove_id);
                    let decimals: u8 = IERC20Dispatcher { contract_address: *yang }.decimals();
                    let deposit_amt: u128 = *non_owner_deposit_amts.pop_front().unwrap();
                    let expected_deposited_yang: Wad = fixed_point_to_wad(deposit_amt, decimals);

                    start_prank(CheatTarget::One(abbot.contract_address), non_owner);
                    abbot.deposit(trove_id, AssetBalance { address: *yang, amount: deposit_amt });
                    let after_trove_yang: Wad = shrine.get_deposit(*yang, trove_id);
                    assert(after_trove_yang == before_trove_yang + expected_deposited_yang, 'wrong yang amount #3');
                },
                Option::None => { break; },
            };
        };

        shrine_utils::assert_total_yang_invariant(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    #[should_panic(expected: ('SE: Yang not added',))]
    fn test_deposit_zero_address_yang_fail() {
        let (_, _, abbot, _, _, trove_owner, trove_id, _, _) = abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        let asset_addr = ContractAddressZeroable::zero();
        let amount: u128 = 1;

        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);
        abbot.deposit(trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    #[should_panic(expected: ('ABB: Trove ID cannot be 0',))]
    fn test_deposit_zero_trove_id_fail() {
        let (_, _, abbot, yangs, _) = abbot_utils::abbot_deploy(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );
        let trove_owner: ContractAddress = common::trove1_owner_addr();

        let asset_addr = *yangs.at(0);
        let invalid_trove_id: u64 = 0;
        let amount: u128 = 1;

        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);
        abbot.deposit(invalid_trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    #[should_panic(expected: ('SE: Yang not added',))]
    fn test_deposit_invalid_yang_fail() {
        let (_, _, abbot, _, _, trove_owner, trove_id, _, _) = abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);

        let asset_addr = sentinel_utils::dummy_yang_addr();
        let amount: u128 = 0;

        abbot.deposit(trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    #[should_panic(expected: ('ABB: Non-existent trove',))]
    fn test_deposit_non_existent_trove_fail() {
        let (_, _, abbot, yangs, _, trove_owner, trove_id, _, _) = abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        let asset_addr: ContractAddress = *yangs.at(0);
        let amount: u128 = 1;

        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);
        abbot.deposit(trove_id + 1, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    #[should_panic(expected: ('SE: Exceeds max amount allowed',))]
    fn test_deposit_exceeds_asset_cap_fail() {
        let (_, sentinel, abbot, yangs, gates, trove_owner, trove_id, _, _) = abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        let asset_addr: ContractAddress = *yangs.at(0);
        let gate_addr: ContractAddress = *gates.at(0).contract_address;
        let gate_bal = IERC20Dispatcher { contract_address: asset_addr }.balance_of(gate_addr);

        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::admin());
        let new_asset_max: u128 = gate_bal.try_into().unwrap();
        sentinel.set_yang_asset_max(asset_addr, new_asset_max);
        stop_prank(CheatTarget::One(sentinel.contract_address));

        let amount: u128 = 1;
        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);
        abbot.deposit(trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    fn test_withdraw_pass() {
        let (shrine, _, abbot, yangs, _, trove_owner, trove_id, _, _) = abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        let asset_addr: ContractAddress = *yangs.at(0);
        let amount: u128 = WAD_SCALE;
        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);
        abbot.withdraw(trove_id, AssetBalance { address: asset_addr, amount });

        assert(
            shrine.get_deposit(asset_addr, trove_id) == (abbot_utils::ETH_DEPOSIT_AMT - amount).into(),
            'wrong yang amount'
        );

        shrine_utils::assert_total_yang_invariant(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    #[should_panic(expected: ('SE: Yang not added',))]
    fn test_withdraw_zero_address_yang_fail() {
        let (_, _, abbot, _, _, trove_owner, trove_id, _, _) = abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        let asset_addr = ContractAddressZeroable::zero();
        let amount: u128 = 1;

        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);
        abbot.withdraw(trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    #[should_panic(expected: ('SE: Yang not added',))]
    fn test_withdraw_invalid_yang_fail() {
        let (_, _, abbot, _, _, trove_owner, trove_id, _, _) = abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);

        let asset_addr = sentinel_utils::dummy_yang_addr();
        let amount: u128 = 0;

        abbot.withdraw(trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    #[should_panic(expected: ('ABB: Not trove owner',))]
    fn test_withdraw_non_owner_fail() {
        let (_, _, abbot, yangs, _, _, trove_id, _, _) = abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        start_prank(CheatTarget::One(abbot.contract_address), common::badguy());

        let asset_addr: ContractAddress = *yangs.at(0);
        let amount: u128 = 0;

        abbot.withdraw(trove_id, AssetBalance { address: asset_addr, amount });
    }

    #[test]
    fn test_forge_pass() {
        let (shrine, _, abbot, yangs, _, trove_owner, trove_id, _, forge_amt) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        let additional_forge_amt: Wad = abbot_utils::OPEN_TROVE_FORGE_AMT.into();
        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);
        abbot.forge(trove_id, additional_forge_amt, WadZeroable::zero());

        let after_trove_health: Health = shrine.get_trove_health(trove_id);
        assert(after_trove_health.debt == forge_amt + additional_forge_amt, 'wrong trove debt');
        assert(shrine.get_yin(trove_owner) == forge_amt + additional_forge_amt, 'wrong yin balance');

        shrine_utils::assert_total_troves_debt_invariant(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    #[should_panic(expected: ('SH: Trove LTV is too high',))]
    fn test_forge_ltv_unsafe_fail() {
        let (shrine, _, abbot, yangs, gates, trove_owner, trove_id, _, _) = abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        // deploy another trove to prevent recovery mode        
        common::open_trove_helper(
            abbot,
            common::trove1_owner_addr(),
            yangs,
            abbot_utils::open_trove_yang_asset_amts(),
            gates,
            WadZeroable::zero()
        );

        assert(!shrine.is_recovery_mode(), 'recovery mode');

        let unsafe_forge_amt: Wad = shrine.get_max_forge(trove_id) + 2_u128.into();
        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);
        abbot.forge(trove_id, unsafe_forge_amt, WadZeroable::zero());
    }

    #[test]
    #[should_panic(expected: ('ABB: Not trove owner',))]
    fn test_forge_non_owner_fail() {
        let (_, _, abbot, _, _, _, trove_id, _, _) = abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        start_prank(CheatTarget::One(abbot.contract_address), common::badguy());
        abbot.forge(trove_id, WadZeroable::zero(), WadZeroable::zero());
    }

    #[test]
    fn test_melt_pass() {
        let (shrine, _, abbot, yangs, gates, trove_owner, trove_id, _, start_forge_amt) =
            abbot_utils::deploy_abbot_and_open_trove(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );

        let before_trove_health: Health = shrine.get_trove_health(trove_id);
        let before_yin: Wad = shrine.get_yin(trove_owner);

        let melt_amt: Wad = (before_yin.val / 2).into();
        start_prank(CheatTarget::One(abbot.contract_address), trove_owner);
        abbot.melt(trove_id, melt_amt);

        let after_trove_health: Health = shrine.get_trove_health(trove_id);
        assert(after_trove_health.debt == before_trove_health.debt - melt_amt, 'wrong trove debt');
        assert(shrine.get_yin(trove_owner) == before_yin - melt_amt, 'wrong yin balance');

        // Test non-owner melting
        let non_owner: ContractAddress = common::trove2_owner_addr();
        common::fund_user(non_owner, yangs, abbot_utils::initial_asset_amts());
        let non_owner_forge_amt = start_forge_amt;
        common::open_trove_helper(
            abbot, non_owner, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, non_owner_forge_amt
        );

        start_prank(CheatTarget::One(abbot.contract_address), non_owner);
        abbot.melt(trove_id, after_trove_health.debt);

        let final_trove_health: Health = shrine.get_trove_health(trove_id);
        assert(final_trove_health.debt.is_zero(), 'wrong trove debt');

        shrine_utils::assert_total_troves_debt_invariant(shrine, yangs, abbot.get_troves_count());
    }

    #[test]
    fn test_get_user_trove_ids() {
        let (_, _, abbot, yangs, gates) = abbot_utils::abbot_deploy(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );
        let trove_owner1: ContractAddress = common::trove1_owner_addr();
        let trove_owner2: ContractAddress = common::trove2_owner_addr();

        let forge_amt: Wad = abbot_utils::OPEN_TROVE_FORGE_AMT.into();
        common::fund_user(trove_owner1, yangs, abbot_utils::initial_asset_amts());
        common::fund_user(trove_owner2, yangs, abbot_utils::initial_asset_amts());

        let first_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner1, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, forge_amt
        );
        let second_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner2, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, forge_amt
        );
        let third_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner1, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, forge_amt
        );
        let fourth_trove_id: u64 = common::open_trove_helper(
            abbot, trove_owner2, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, forge_amt
        );

        let mut expected_owner1_trove_ids: Array<u64> = array![first_trove_id, third_trove_id];
        let mut expected_owner2_trove_ids: Array<u64> = array![second_trove_id, fourth_trove_id];
        let empty_user_trove_ids: Span<u64> = ArrayTrait::new().span();

        assert(abbot.get_user_trove_ids(trove_owner1) == expected_owner1_trove_ids.span(), 'wrong user trove IDs');
        assert(abbot.get_user_trove_ids(trove_owner2) == expected_owner2_trove_ids.span(), 'wrong user trove IDs');
        assert(abbot.get_troves_count() == 4, 'wrong troves count');

        let non_user: ContractAddress = common::trove3_owner_addr();
        assert(abbot.get_user_trove_ids(non_user) == empty_user_trove_ids, 'wrong non user trove IDs');
    }
}
