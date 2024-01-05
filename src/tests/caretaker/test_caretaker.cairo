mod test_caretaker {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use debug::PrintTrait;
    use opus::core::caretaker::caretaker as caretaker_contract;
    use opus::core::roles::{caretaker_roles, shrine_roles};
    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::ICaretaker::{ICaretakerDispatcher, ICaretakerDispatcherTrait};
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::abbot::utils::abbot_utils;
    use opus::tests::caretaker::utils::caretaker_utils;
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::{AssetBalance, Health};
    use opus::utils::math::fixed_point_to_wad;
    use snforge_std::{start_prank, stop_prank, CheatTarget, spy_events, SpyOn, EventSpy, EventAssertions};
    use starknet::{ContractAddress};
    use wadray::{Ray, Wad, WadZeroable, WAD_ONE};

    #[test]
    fn test_caretaker_setup() {
        let (caretaker, shrine, _, _, _, _) = caretaker_utils::caretaker_deploy();

        let caretaker_ac = IAccessControlDispatcher { contract_address: caretaker.contract_address };

        assert(caretaker_ac.get_admin() == caretaker_utils::admin(), 'setup admin');
        assert(caretaker_ac.get_roles(caretaker_utils::admin()) == caretaker_roles::SHUT, 'admin roles');

        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        assert(shrine_ac.has_role(shrine_roles::KILL, caretaker.contract_address), 'caretaker cant kill shrine');
    }

    #[test]
    #[should_panic(expected: ('CA: System is live',))]
    fn test_caretaker_setup_preview_release_throws() {
        let (caretaker, _, _, _, _, _) = caretaker_utils::caretaker_deploy();
        caretaker.preview_release(1);
    }

    #[test]
    #[should_panic(expected: ('CA: System is live',))]
    fn test_caretaker_setup_preview_reclaim_throws() {
        let (caretaker, _, _, _, _, _) = caretaker_utils::caretaker_deploy();
        caretaker.preview_reclaim(WAD_ONE.into());
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_shut_by_badguy_throws() {
        let (caretaker, _, _, _, _, _) = caretaker_utils::caretaker_deploy();
        start_prank(CheatTarget::One(caretaker.contract_address), common::badguy());
        caretaker.shut();
    }

    #[test]
    fn test_shut() {
        let (caretaker, shrine, abbot, _sentinel, yangs, gates) = caretaker_utils::caretaker_deploy();
        let mut spy = spy_events(SpyOn::One(caretaker.contract_address));

        // user 1 with 950 yin and 2 different yangs
        let user1 = common::trove1_owner_addr();
        let trove1_forge_amt: Wad = (950 * WAD_ONE).into();
        common::fund_user(user1, yangs, abbot_utils::initial_asset_amts());
        common::open_trove_helper(
            abbot, user1, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, trove1_forge_amt
        );

        // user 2 with 50 yin and 1 yang
        let user2 = common::trove2_owner_addr();
        let trove2_forge_amt: Wad = (50 * WAD_ONE).into();
        common::fund_user(user2, yangs, abbot_utils::initial_asset_amts());
        let (eth_yang, eth_gate, eth_yang_amt) = caretaker_utils::only_eth(yangs, gates);
        common::open_trove_helper(abbot, user2, eth_yang, eth_yang_amt, eth_gate, trove2_forge_amt);

        let total_yin: Wad = trove1_forge_amt + trove2_forge_amt;
        let shrine_health: Health = shrine.get_shrine_health();
        let backing: Ray = wadray::rdiv_ww(total_yin, shrine_health.value);

        let y0 = IERC20Dispatcher { contract_address: *yangs[0] };
        let y1 = IERC20Dispatcher { contract_address: *yangs[1] };

        let g0_before_balance: Wad = y0.balance_of(*gates.at(0).contract_address).try_into().unwrap();
        let g1_before_balance: Wad = y1.balance_of(*gates.at(1).contract_address).try_into().unwrap();
        let y0_backing = wadray::wmul_wr(g0_before_balance, backing).into();
        let y1_backing = wadray::wmul_wr(g1_before_balance, backing).into();

        start_prank(CheatTarget::One(caretaker.contract_address), caretaker_utils::admin());
        caretaker.shut();

        // assert Shrine killed
        assert(!shrine.get_live(), 'shrine should be dead');

        // expecting the gates to have their original balance reduced by the amount needed to cover yin
        let g0_expected_balance: Wad = g0_before_balance - y0_backing;
        let g1_expected_balance: Wad = g1_before_balance - y1_backing;
        let tolerance: Wad = 10_u128.into();

        // assert gates have their balance reduced
        let g0_after_balance: Wad = y0.balance_of(*gates.at(0).contract_address).try_into().unwrap();
        let g1_after_balance: Wad = y1.balance_of(*gates.at(1).contract_address).try_into().unwrap();
        common::assert_equalish(g0_after_balance, g0_expected_balance, tolerance, 'gate 0 balance after shut');
        common::assert_equalish(g1_after_balance, g1_expected_balance, tolerance, 'gate 1 balance after shut');

        // assert the balance diff is now in the hands of the Caretaker
        let caretaker_y0_balance: Wad = y0.balance_of(caretaker.contract_address).try_into().unwrap();
        let caretaker_y1_balance: Wad = y1.balance_of(caretaker.contract_address).try_into().unwrap();
        common::assert_equalish(caretaker_y0_balance, y0_backing, tolerance, 'caretaker yang0 balance');
        common::assert_equalish(caretaker_y1_balance, y1_backing, tolerance, 'caretaker yang1 balance');

        let expected_events = array![
            (caretaker.contract_address, caretaker_contract::Event::Shut(caretaker_contract::Shut {})),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_release() {
        let (caretaker, shrine, abbot, _sentinel, yangs, gates) = caretaker_utils::caretaker_deploy();
        let mut spy = spy_events(SpyOn::One(caretaker.contract_address));

        // user 1 with 10000 yin and 2 different yangs
        let user1 = common::trove1_owner_addr();
        let trove1_deposit_amts = abbot_utils::open_trove_yang_asset_amts();
        let trove1_forge_amt: Wad = (10000 * WAD_ONE).into();
        common::fund_user(user1, yangs, abbot_utils::initial_asset_amts());
        let trove1_id = common::open_trove_helper(abbot, user1, yangs, trove1_deposit_amts, gates, trove1_forge_amt);

        // user 2 with 100 yin and 1 yang
        let user2 = common::trove2_owner_addr();
        let trove2_forge_amt: Wad = (1000 * WAD_ONE).into();
        common::fund_user(user2, yangs, abbot_utils::initial_asset_amts());
        let (eth_yang, eth_gate, eth_yang_amt) = caretaker_utils::only_eth(yangs, gates);
        let trove2_id = common::open_trove_helper(abbot, user2, eth_yang, eth_yang_amt, eth_gate, trove2_forge_amt);

        let total_yin: Wad = trove1_forge_amt + trove2_forge_amt;
        let shrine_health: Health = shrine.get_shrine_health();
        let backing: Ray = wadray::rdiv_ww(total_yin, shrine_health.value);

        let y0 = IERC20Dispatcher { contract_address: *yangs[0] };
        let y1 = IERC20Dispatcher { contract_address: *yangs[1] };

        let user1_yang0_before_balance: u256 = y0.balance_of(user1);
        let user1_yang1_before_balance: u256 = y1.balance_of(user1);
        let trove1_yang0_deposit: Wad = shrine.get_deposit(*yangs[0], trove1_id);
        let trove1_yang1_deposit: Wad = shrine.get_deposit(*yangs[1], trove1_id);

        start_prank(CheatTarget::One(caretaker.contract_address), caretaker_utils::admin());
        caretaker.shut();

        start_prank(CheatTarget::One(caretaker.contract_address), user1);
        let trove1_released_assets: Span<AssetBalance> = caretaker.release(trove1_id);

        let user1_yang0_after_balance: u256 = y0.balance_of(user1);
        let user1_yang1_after_balance: u256 = y1.balance_of(user1);

        // assert released amount for eth
        let eth_tolerance: Wad = 10_u128.into(); // 10 wei
        let expected_release_y0: Wad = trove1_yang0_deposit - wadray::rmul_rw(backing, trove1_yang0_deposit);
        common::assert_equalish(
            (*trove1_released_assets.at(0).amount).into(), expected_release_y0, eth_tolerance, 'y0 release'
        );

        // assert released amount for wbtc (need to deal w/ different decimals)
        let wbtc_tolerance: Wad = (2 * 10000000000_u128).into(); // 2 satoshi
        let wbtc_deposit: Wad = fixed_point_to_wad(*trove1_deposit_amts[1], common::WBTC_DECIMALS);
        let expected_release_y1: Wad = wbtc_deposit - wadray::rmul_rw(backing, trove1_yang1_deposit);
        let actual_release_y1: Wad = fixed_point_to_wad(*trove1_released_assets.at(1).amount, common::WBTC_DECIMALS);
        common::assert_equalish(actual_release_y1, expected_release_y1, wbtc_tolerance, 'y1 release');

        // assert all deposits were released and assets are back in user's account
        assert(*trove1_released_assets.at(0).address == *yangs[0], 'yang 1 not released #1');
        assert(*trove1_released_assets.at(1).address == *yangs[1], 'yang 2 not released #1');
        assert(
            user1_yang0_after_balance == user1_yang0_before_balance + (*trove1_released_assets.at(0).amount).into(),
            'user1 yang0 after balance'
        );
        assert(
            user1_yang1_after_balance == user1_yang1_before_balance + (*trove1_released_assets.at(1).amount).into(),
            'user1 yang1 after balance'
        );

        // assert nothing's left in the shrine for the released trove
        assert(shrine.get_deposit(*yangs[0], trove1_id).is_zero(), 'trove1 yang0 deposit');
        assert(shrine.get_deposit(*yangs[1], trove1_id).is_zero(), 'trove1 yang1 deposit');

        // sanity check that for user with only one yang, release reports a 0 asset amount
        start_prank(CheatTarget::One(caretaker.contract_address), user2);
        let trove2_released_assets: Span<AssetBalance> = caretaker.release(trove2_id);
        assert(*trove2_released_assets.at(0).address == *yangs[0], 'yang 1 not released #2');
        assert(*trove2_released_assets.at(1).address == *yangs[1], 'yang 2 not released #2');
        assert((*trove2_released_assets.at(1).amount).is_zero(), 'incorrect release');

        let expected_events = array![
            (
                caretaker.contract_address,
                caretaker_contract::Event::Release(
                    caretaker_contract::Release { user: user1, trove_id: trove1_id, assets: trove1_released_assets, }
                )
            ),
            (
                caretaker.contract_address,
                caretaker_contract::Event::Release(
                    caretaker_contract::Release { user: user2, trove_id: trove2_id, assets: trove2_released_assets, }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_preview_reclaim_more_than_total_yin() {
        let (caretaker, _, abbot, _sentinel, yangs, gates) = caretaker_utils::caretaker_deploy();

        // user 1 with 10000 yin and 2 different yangs
        let user1 = common::trove1_owner_addr();
        let trove1_forge_amt: Wad = (10000 * WAD_ONE).into();
        common::fund_user(user1, yangs, abbot_utils::initial_asset_amts());
        common::open_trove_helper(
            abbot, user1, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, trove1_forge_amt
        );

        start_prank(CheatTarget::One(caretaker.contract_address), caretaker_utils::admin());
        caretaker.shut();

        let (reclaimed_yin, reclaimable_assets) = caretaker.preview_reclaim(trove1_forge_amt + WAD_ONE.into());
        let caretaker_balances: Span<Span<u128>> = common::get_token_balances(
            yangs, array![caretaker.contract_address].span()
        );
        // Transform caretaker balance to a single array
        let caretaker_balances_flattened: Span<u128> = array![
            *caretaker_balances.at(0)[0], *caretaker_balances.at(1)[0],
        ]
            .span();
        let expected_reclaimable_assets: Span<AssetBalance> = common::combine_assets_and_amts(
            yangs, caretaker_balances_flattened
        );
        assert(reclaimable_assets == expected_reclaimable_assets, 'wrong reclaimable assets');
        assert(reclaimed_yin == trove1_forge_amt, 'wrong reclaimed yin');
    }

    #[test]
    fn test_reclaim() {
        let (caretaker, shrine, abbot, _sentinel, yangs, gates) = caretaker_utils::caretaker_deploy();
        let mut spy = spy_events(SpyOn::One(caretaker.contract_address));

        // user 1 with 10000 yin and 2 different yangs
        let user1 = common::trove1_owner_addr();
        let trove1_forge_amt: Wad = (10000 * WAD_ONE).into();
        common::fund_user(user1, yangs, abbot_utils::initial_asset_amts());
        common::open_trove_helper(
            abbot, user1, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, trove1_forge_amt
        );

        // transfer some yin from user1 elsewhere
        // => user1 got scammed, poor guy
        let scammer = common::badguy();
        let scam_amt: u256 = (4000 * WAD_ONE).into();
        start_prank(CheatTarget::One(shrine.contract_address), user1);
        IERC20Dispatcher { contract_address: shrine.contract_address }.transfer(scammer, scam_amt);
        stop_prank(CheatTarget::One(shrine.contract_address));
        let y0 = IERC20Dispatcher { contract_address: *yangs[0] };
        let y1 = IERC20Dispatcher { contract_address: *yangs[1] };

        let user1_yang0_before_balance: u256 = y0.balance_of(user1);
        let user1_yang1_before_balance: u256 = y1.balance_of(user1);
        let scammer_yang0_before_balance: u256 = y0.balance_of(scammer);
        let scammer_yang1_before_balance: u256 = y1.balance_of(scammer);

        start_prank(CheatTarget::One(caretaker.contract_address), caretaker_utils::admin());
        caretaker.shut();

        //
        // user1 reclaim
        //

        // save Caretaker yang balance after shut but before reclaim
        let ct_yang0_before_balance: u256 = y0.balance_of(caretaker.contract_address);
        let ct_yang1_before_balance: u256 = y1.balance_of(caretaker.contract_address);

        // do the reclaiming
        start_prank(CheatTarget::One(caretaker.contract_address), user1);
        let user1_yin: Wad = shrine.get_yin(user1);
        let (user1_reclaimed_yin, user1_reclaimed_assets) = caretaker.reclaim(user1_yin);

        // assert none of user's yin is left
        assert(shrine.get_yin(user1).is_zero(), 'user yin balance');
        // assert scammer still has theirs
        assert(shrine.get_yin(scammer) == scam_amt.try_into().unwrap(), 'scammer yin balance 1');

        let ct_yang0_after_balance: u256 = y0.balance_of(caretaker.contract_address);
        let ct_yang1_after_balance: u256 = y1.balance_of(caretaker.contract_address);
        let user1_yang0_after_balance: u256 = y0.balance_of(user1);
        let user1_yang1_after_balance: u256 = y1.balance_of(user1);

        // assert yangs have been transfered from Caretaker to user
        let ct_yang0_diff = ct_yang0_before_balance - ct_yang0_after_balance;
        let ct_yang1_diff = ct_yang1_before_balance - ct_yang1_after_balance;
        let user1_yang0_diff = user1_yang0_after_balance - user1_yang0_before_balance;
        let user1_yang1_diff = user1_yang1_after_balance - user1_yang1_before_balance;

        assert(ct_yang0_diff == user1_yang0_diff, 'user1 yang0 diff');
        assert(ct_yang1_diff == user1_yang1_diff, 'user1 yang1 diff');
        assert(ct_yang0_diff == (*user1_reclaimed_assets.at(0).amount).into(), 'user1 reclaimed yang0');
        assert(ct_yang1_diff == (*user1_reclaimed_assets.at(1).amount).into(), 'user1 reclaimed yang1');

        assert(user1_reclaimed_yin == user1_yin, 'user1 reclaimed yin');

        //
        // scammer reclaim
        //

        let tolerance: Wad = 10_u128.into();

        // save Caretaker yang balance after first reclaim but before the second
        let ct_yang0_before_balance: u256 = y0.balance_of(caretaker.contract_address);
        let ct_yang1_before_balance: u256 = y1.balance_of(caretaker.contract_address);

        // do the reclaiming
        start_prank(CheatTarget::One(caretaker.contract_address), scammer);
        let scammer_yin: Wad = shrine.get_yin(scammer);
        let (scammer_reclaimed_yin, scammer_reclaimed_assets) = caretaker.reclaim(scammer_yin);

        // assert all yin has been reclaimed
        assert(shrine.get_yin(scammer).is_zero(), 'scammer yin balance 2');

        let ct_yang0_after_balance: u256 = y0.balance_of(caretaker.contract_address);
        let ct_yang1_after_balance: u256 = y1.balance_of(caretaker.contract_address);
        let scammer_yang0_after_balance: u256 = y0.balance_of(scammer);
        let scammer_yang1_after_balance: u256 = y1.balance_of(scammer);

        let ct_yang0_diff: Wad = (ct_yang0_before_balance - ct_yang0_after_balance).try_into().unwrap();
        let ct_yang1_diff: Wad = (ct_yang1_before_balance - ct_yang1_after_balance).try_into().unwrap();
        let scammer_yang0_diff: Wad = (scammer_yang0_after_balance - scammer_yang0_before_balance).try_into().unwrap();
        let scammer_yang1_diff: Wad = (scammer_yang1_after_balance - scammer_yang1_before_balance).try_into().unwrap();

        common::assert_equalish(ct_yang0_diff, scammer_yang0_diff, tolerance, 'scammer yang0 diff');
        common::assert_equalish(ct_yang1_diff, scammer_yang1_diff, tolerance, 'scammer yang1 diff');
        common::assert_equalish(
            ct_yang0_diff, (*scammer_reclaimed_assets.at(0).amount).into(), tolerance, 'scammer reclaimed yang0'
        );
        common::assert_equalish(
            ct_yang1_diff, (*scammer_reclaimed_assets.at(1).amount).into(), tolerance, 'scammer reclaimed yang1'
        );
        assert(scammer_reclaimed_yin == scammer_yin, 'scammer reclaimed yin');

        let expected_events = array![
            (
                caretaker.contract_address,
                caretaker_contract::Event::Reclaim(
                    caretaker_contract::Reclaim { user: user1, yin_amt: user1_yin, assets: user1_reclaimed_assets, }
                )
            ),
            (
                caretaker.contract_address,
                caretaker_contract::Event::Reclaim(
                    caretaker_contract::Reclaim {
                        user: scammer, yin_amt: scammer_yin, assets: scammer_reclaimed_assets,
                    }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);

        // assert that caretaker has no assets remaining
        let mut caretaker_assets: Span<Span<u128>> = common::get_token_balances(
            yangs, array![caretaker.contract_address].span()
        );
        loop {
            match caretaker_assets.pop_front() {
                Option::Some(caretaker_asset_arr) => {
                    let caretaker_asset: u128 = *caretaker_asset_arr[0];
                    assert(caretaker_asset.is_zero(), 'caretaker asset should be 0');
                },
                Option::None => { break; }
            };
        };
    }

    #[test]
    fn test_shut_during_armageddon() {
        let (caretaker, shrine, abbot, _sentinel, yangs, gates) = caretaker_utils::caretaker_deploy();
        let mut spy = spy_events(SpyOn::One(caretaker.contract_address));

        // user 1 with 10000 yin and 2 different yangs
        let user1 = common::trove1_owner_addr();
        let trove1_forge_amt: Wad = (10000 * WAD_ONE).into();
        common::fund_user(user1, yangs, abbot_utils::initial_asset_amts());
        let trove1_id = common::open_trove_helper(
            abbot, user1, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, trove1_forge_amt
        );

        let y0 = IERC20Dispatcher { contract_address: *yangs[0] };
        let y1 = IERC20Dispatcher { contract_address: *yangs[1] };

        let gate0_before_balance: Wad = y0.balance_of(*gates.at(0).contract_address).try_into().unwrap();
        let gate1_before_balance: Wad = y1.balance_of(*gates.at(1).contract_address).try_into().unwrap();

        // manipulate prices to be waaaay below start price to force
        // all yang deposits to be used to back yin
        shrine_utils::make_root(shrine.contract_address, caretaker_utils::admin());
        start_prank(
            CheatTarget::Multiple(array![shrine.contract_address, caretaker.contract_address]), caretaker_utils::admin()
        );
        let new_eth_price: Wad = (50 * WAD_ONE).into();
        let new_wbtc_price: Wad = (20 * WAD_ONE).into();
        shrine.advance(*yangs[0], new_eth_price);
        shrine.advance(*yangs[1], new_wbtc_price);

        caretaker.shut();
        stop_prank(CheatTarget::Multiple(array![shrine.contract_address, caretaker.contract_address]));

        let tolerance: Wad = 1_u128.into();

        // assert nothing's left in the gates and everything is now owned by Caretaker
        let gate0_after_balance: Wad = y0.balance_of(*gates.at(0).contract_address).try_into().unwrap();
        let gate1_after_balance: Wad = y1.balance_of(*gates.at(1).contract_address).try_into().unwrap();
        let ct_yang0_balance: Wad = y0.balance_of(caretaker.contract_address).try_into().unwrap();
        let ct_yang1_balance: Wad = y1.balance_of(caretaker.contract_address).try_into().unwrap();

        common::assert_equalish(gate0_after_balance, WadZeroable::zero(), tolerance, 'gate0 after balance');
        common::assert_equalish(gate1_after_balance, WadZeroable::zero(), tolerance, 'gate1 after balance');
        common::assert_equalish(ct_yang0_balance, gate0_before_balance, tolerance, 'caretaker yang0 after balance');
        common::assert_equalish(ct_yang1_balance, gate1_before_balance, tolerance, 'caretaker yang1 after balance');

        // calling release still works, but nothing gets released
        start_prank(CheatTarget::One(caretaker.contract_address), user1);
        let released_assets: Span<AssetBalance> = caretaker.release(trove1_id);

        // 0 released amounts also mean no `sentinel.exit` and `shrine.seize`
        assert((*released_assets.at(0).amount).is_zero(), 'incorrect armageddon release 1');
        assert((*released_assets.at(1).amount).is_zero(), 'incorrect armageddon release 2');

        let expected_events = array![
            (caretaker.contract_address, caretaker_contract::Event::Shut(caretaker_contract::Shut {})),
            (
                caretaker.contract_address,
                caretaker_contract::Event::Release(
                    caretaker_contract::Release { user: user1, trove_id: trove1_id, assets: released_assets, }
                )
            ),
        ];
        spy.assert_emitted(@expected_events);
    }


    #[test]
    #[should_panic(expected: ('CA: System is live',))]
    fn test_release_when_system_live_reverts() {
        let (caretaker, _, _, _, _, _) = caretaker_utils::caretaker_deploy();
        start_prank(CheatTarget::One(caretaker.contract_address), caretaker_utils::admin());
        caretaker.release(1);
    }

    #[test]
    #[should_panic(expected: ('CA: Owner should not be zero',))]
    fn test_release_foreign_trove_reverts() {
        let (caretaker, _, _, _, _, _) = caretaker_utils::caretaker_deploy();
        start_prank(CheatTarget::One(caretaker.contract_address), caretaker_utils::admin());
        caretaker.shut();
        caretaker.release(1);
    }

    #[test]
    #[should_panic(expected: ('CA: System is live',))]
    fn test_reclaim_when_system_live_reverts() {
        let (caretaker, _, _, _, _, _) = caretaker_utils::caretaker_deploy();
        start_prank(CheatTarget::One(caretaker.contract_address), caretaker_utils::admin());
        caretaker.reclaim(WAD_ONE.into());
    }

    #[test]
    #[should_panic(expected: ('SH: Insufficient yin balance',))]
    fn test_reclaim_insufficient_yin() {
        let (caretaker, shrine, abbot, _, yangs, gates) = caretaker_utils::caretaker_deploy();

        // opening a trove
        let user1 = common::trove1_owner_addr();
        let trove1_forge_amt: Wad = (10000 * WAD_ONE).into();
        common::fund_user(user1, yangs, abbot_utils::initial_asset_amts());
        common::open_trove_helper(
            abbot, user1, yangs, abbot_utils::open_trove_yang_asset_amts(), gates, trove1_forge_amt
        );

        // Transferring some of user1's yin to someone else
        // This is because in `shrine.melt_helper`, which is called by `shrine.eject`, which is called by `reclaim`,
        // the yin `amount` is deducted first from the user's balance and only then from the total.
        //
        // This means that if the user attempts to deduct more yin than exists, the transaction will obviously fail
        // since the user can't have more yin than the total supply. However, if the yin was first deducted from
        // `total_yin` in `shrine.melt_helper`, then the transaction would still fail, but this test wouldn't
        // actually be testing the correct thing, which is that users shouldn't be able to deduct more yin than they personally
        // have.
        //
        // In other words, we do the transfer to ensure that the test still tests the correct thing regardless of the order
        // of operations in `shrine.melt_helper`.
        let user2 = common::trove2_owner_addr();
        let transfer_amt: u256 = (4000 * WAD_ONE).into();
        start_prank(CheatTarget::One(caretaker.contract_address), user1);
        IERC20Dispatcher { contract_address: shrine.contract_address }.transfer(user2, transfer_amt);

        // Activating global settlement mode
        start_prank(CheatTarget::One(caretaker.contract_address), caretaker_utils::admin());
        caretaker.shut();

        // User1 attempts to reclaim more yin than they have
        start_prank(CheatTarget::One(caretaker.contract_address), user1);
        let user1_yin: Wad = shrine.get_yin(user1);
        // This should revert
        caretaker.reclaim(user1_yin + 1_u128.into());
    }
}
