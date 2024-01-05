#[starknet::contract]
mod caretaker {
    use access_control::access_control_component;
    use cmp::min;
    use opus::core::roles::caretaker_roles;
    use opus::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use opus::interfaces::ICaretaker::ICaretaker;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IEqualizer::{IEqualizerDispatcher, IEqualizerDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::types::{AssetBalance, Health};
    use opus::utils::reentrancy_guard::reentrancy_guard_component;
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use wadray::{Ray, RAY_ONE, Wad};

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);
    component!(path: reentrancy_guard_component, storage: reentrancy_guard, event: ReentrancyGuardEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    impl ReentrancyGuardHelpers = reentrancy_guard_component::ReentrancyGuardHelpers<ContractState>;

    //
    // Constants
    //

    // A dummy trove ID for Caretaker, required in Gate to emit events
    const DUMMY_TROVE_ID: u64 = 0;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        #[substorage(v0)]
        reentrancy_guard: reentrancy_guard_component::Storage,
        // Abbot associated with the Shrine for this Caretaker
        abbot: IAbbotDispatcher,
        // Equalizer associated with the Shrine for this Caretaker
        equalizer: IEqualizerDispatcher,
        // Sentinel associated with the Shrine for this Caretaker
        sentinel: ISentinelDispatcher,
        // Shrine associated with this Caretaker
        shrine: IShrineDispatcher,
        // Amount of yin remaining to be backed by this Caretaker's assets after shutdown
        reclaimable_yin: Wad,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
        Shut: Shut,
        Release: Release,
        Reclaim: Reclaim,
        // Component events
        ReentrancyGuardEvent: reentrancy_guard_component::Event
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Shut {}

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Release {
        #[key]
        user: ContractAddress,
        #[key]
        trove_id: u64,
        assets: Span<AssetBalance>
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Reclaim {
        #[key]
        user: ContractAddress,
        yin_amt: Wad,
        assets: Span<AssetBalance>
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        shrine: ContractAddress,
        abbot: ContractAddress,
        sentinel: ContractAddress,
        equalizer: ContractAddress
    ) {
        self.access_control.initializer(admin, Option::Some(caretaker_roles::default_admin_role()));

        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.equalizer.write(IEqualizerDispatcher { contract_address: equalizer });
    }

    //
    // External Caretaker functions
    //

    #[abi(embed_v0)]
    impl ICaretakerImpl of ICaretaker<ContractState> {
        //
        // View functions
        //

        // Simulates the effects of `release` at the current on-chain conditions.
        fn preview_release(self: @ContractState, trove_id: u64) -> Span<AssetBalance> {
            let shrine: IShrineDispatcher = self.shrine.read();

            assert(shrine.get_live() == false, 'CA: System is live');

            let sentinel: ISentinelDispatcher = self.sentinel.read();
            let yangs: Span<ContractAddress> = sentinel.get_yang_addresses();

            let mut releasable_assets: Array<AssetBalance> = ArrayTrait::new();
            let mut yangs_copy = yangs;

            loop {
                match yangs_copy.pop_front() {
                    Option::Some(yang) => {
                        let deposited_yang: Wad = shrine.get_deposit(*yang, trove_id);

                        let asset_amt: u128 = if deposited_yang.is_zero() {
                            0
                        } else {
                            sentinel.convert_to_assets(*yang, deposited_yang)
                        };

                        releasable_assets.append(AssetBalance { address: *yang, amount: asset_amt });
                    },
                    Option::None => { break releasable_assets.span(); },
                };
            }
        }

        // Simulates the effects of `reclaim` at the current on-chain conditions.
        // Returns a tuple of:
        // 1. the amount of yin reclaimable
        // 2. an array of asset amounts to be received based on (1)
        fn preview_reclaim(self: @ContractState, yin: Wad) -> (Wad, Span<AssetBalance>) {
            let shrine: IShrineDispatcher = self.shrine.read();

            assert(shrine.get_live() == false, 'CA: System is live');

            // Cap percentage of amount to be reclaimed to 100% to catch
            // invalid values beyond total yin
            let remaining_reclaimable_yin: Wad = self.reclaimable_yin.read();
            let capped_yin: Wad = min(yin, remaining_reclaimable_yin);
            let pct_to_reclaim: Ray = wadray::rdiv_ww(capped_yin, remaining_reclaimable_yin);

            let yangs: Span<ContractAddress> = self.sentinel.read().get_yang_addresses();

            let mut reclaimable_assets: Array<AssetBalance> = ArrayTrait::new();
            let caretaker = get_contract_address();
            let mut yangs_copy = yangs;
            loop {
                match yangs_copy.pop_front() {
                    Option::Some(yang) => {
                        let asset = IERC20Dispatcher { contract_address: *yang };
                        let caretaker_balance: u128 = asset.balance_of(caretaker).try_into().unwrap();
                        let asset_amt: Wad = wadray::rmul_rw(pct_to_reclaim, caretaker_balance.into());
                        reclaimable_assets.append(AssetBalance { address: *yang, amount: asset_amt.val });
                    },
                    Option::None => { break (capped_yin, reclaimable_assets.span()); },
                };
            }
        }

        //
        // Core functions
        //

        // Admin will initially have access to `shut`.
        fn shut(ref self: ContractState) {
            self.access_control.assert_has_role(caretaker_roles::SHUT);

            let shrine: IShrineDispatcher = self.shrine.read();

            // Prevent repeated `shut`
            assert(shrine.get_live(), 'CA: System is not live');

            // Mint surplus debt
            // Note that the total system debt may stil be higher than total yin after this
            // final minting of surplus debt due to loss of precision. However, any such
            // excess system debt is inconsequential because only the total yin supply will
            // be backed by collateral, and it would not be possible to mint this excess
            // system debt from this point onwards. Therefore, this excess system debt would
            // not affect the accounting for `release` and `reclaim` in this contract.
            self.equalizer.read().equalize();

            // Calculate the percentage of collateral needed to back all troves' yin 1 : 1
            // based on the last value of all collateral in Shrine. We can use the total troves' 
            // debt from the Shrine's Health as a proxy for total yin minted by troves because 
            // we would have minted any surplus budget via `Equalizer.equalize` in the preceding step.
            let shrine_health: Health = shrine.get_shrine_health();
            let backing_pct: Ray = wadray::rdiv_ww(shrine_health.debt, shrine_health.value);
            self.reclaimable_yin.write(shrine_health.debt);

            // Cap the percentage to 100%
            let capped_backing_pct: Ray = min(backing_pct, RAY_ONE.into());

            // Loop through yangs and transfer the amount of each yang asset needed to back
            // yin to this contract. This is equivalent to a final redistribution enforced
            // on all trove owners.
            // Since yang assets are transferred out of the Gate and the total number of yang
            // is not updated in Shrine, the asset amount per yang in Gate will decrease.
            let sentinel: ISentinelDispatcher = self.sentinel.read();
            let yangs: Span<ContractAddress> = sentinel.get_yang_addresses();
            let caretaker = get_contract_address();

            let mut yangs_copy = yangs;
            loop {
                match yangs_copy.pop_front() {
                    Option::Some(yang) => {
                        let backed_yang: Wad = wadray::rmul_rw(capped_backing_pct, shrine.get_yang_total(*yang));
                        sentinel.exit(*yang, caretaker, DUMMY_TROVE_ID, backed_yang);
                    },
                    Option::None => { break; },
                };
            };

            // Kill modules
            shrine.kill();

            // Note that Absorber is not killed. When the final debt surplus is minted, the
            // absorber may be an allocated recipient. If the Absorber has been completely
            // drained (i.e. no shares in current epoch), receives a portion of the minted
            // debt surplus and is killed, then the final yin surplus will be inaccessible
            // if users can no longer call `Absorber.provide()`. Therefore, we do not kill
            // the Absorber, and allow the first provider in such a situation to gain a windfall
            // of the final debt surplus minted to the Absorber.

            self.emit(Shut {});
        }

        // Releases all remaining collateral in a trove to the trove owner directly.
        // - Note that after `shut` is triggered, the amount of yang in a trove will be fixed,
        //   but the asset amount per yang may have decreased because the assets needed to back
        //   yin 1 : 1 have been transferred from the Gates to the Caretaker.
        // Returns a tuple of arrays of the released asset addresses and released asset amounts
        // denominated in each respective asset's decimals.
        fn release(ref self: ContractState, trove_id: u64) -> Span<AssetBalance> {
            let shrine: IShrineDispatcher = self.shrine.read();

            assert(shrine.get_live() == false, 'CA: System is live');

            // reentrancy guard is used as a precaution
            self.reentrancy_guard.start();

            // Assert caller is trove owner
            let trove_owner: ContractAddress = self
                .abbot
                .read()
                .get_trove_owner(trove_id)
                .expect('CA: Owner should not be zero');
            assert(trove_owner == get_caller_address(), 'CA: Not trove owner');

            let sentinel: ISentinelDispatcher = self.sentinel.read();
            let yangs: Span<ContractAddress> = sentinel.get_yang_addresses();

            let mut released_assets: Array<AssetBalance> = ArrayTrait::new();
            let mut yangs_copy = yangs;

            // Loop over yangs deposited in trove and transfer to trove owner
            loop {
                match yangs_copy.pop_front() {
                    Option::Some(yang) => {
                        let deposited_yang: Wad = shrine.get_deposit(*yang, trove_id);
                        let asset_amt: u128 = if deposited_yang.is_zero() {
                            0
                        } else {
                            let exit_amt: u128 = sentinel.exit(*yang, trove_owner, trove_id, deposited_yang);
                            // Seize the collateral only after assets have been
                            // transferred so that the asset amount per yang in Gate
                            // does not change and user receives the correct amount
                            shrine.seize(*yang, trove_id, deposited_yang);
                            exit_amt
                        };
                        released_assets.append(AssetBalance { address: *yang, amount: asset_amt });
                    },
                    Option::None => { break; },
                };
            };

            self.emit(Release { user: trove_owner, trove_id, assets: released_assets.span() });

            self.reentrancy_guard.end();
            released_assets.span()
        }

        // Allow yin holders to burn their yin and receive their proportionate share of collateral assets
        // in the Caretaker contract based on the amount of yin as a proportion of total supply.
        // Example: assuming total system yin of 1_000, and Caretaker has a yang A asset balance of 4_000.
        //          User A and User B each wants to reclaim 100 yin, and expects to receive the same amount
        //          of yang assets from the Caretaker regardless of who does so first.
        //          1. User A reclaims 100 yin, amounting to 100 / 1_000 = 10%, which entitles him to receive
        //             10% * 4_000 = 400 yang A assets from the Caretaker.
        //
        //             After User A reclaims, total system yin decreaes to 900, and the Caretaker's balance of
        //             yang A assets decreases to 3_600.
        //
        //          2. User B reclaims 100 yin, amounting to 100 / 900 = 11.11%, which entitles him to receive
        //             11.1% * 3_600 = 400 yang A assets approximately.
        //
        // Returns a tuple of:
        // 1. the amount of yin reclaimed
        // 2. an array of asset amounts to be received based on (1)
        fn reclaim(ref self: ContractState, yin: Wad) -> (Wad, Span<AssetBalance>) {
            let shrine: IShrineDispatcher = self.shrine.read();

            assert(shrine.get_live() == false, 'CA: System is live');

            // reentrancy guard is used as a precaution
            self.reentrancy_guard.start();

            let caller = get_caller_address();

            // Calculate amount of collateral corresponding to amount of yin reclaimed.
            // This needs to be done before burning the reclaimed yin amount from the caller
            // or the total supply would be incorrect.
            let (reclaimable_yin, reclaimable_assets) = self.preview_reclaim(yin);
            self.reclaimable_yin.write(self.reclaimable_yin.read() - reclaimable_yin);

            // This call will revert if `yin` is greater than the caller's balance.
            shrine.eject(caller, reclaimable_yin);

            // Loop through yangs and transfer a proportionate share of each yang asset in
            // the Caretaker to caller
            let mut reclaimable_assets_copy = reclaimable_assets;
            loop {
                match reclaimable_assets_copy.pop_front() {
                    Option::Some(reclaimable_asset) => {
                        if (*reclaimable_asset.amount).is_zero() {
                            continue;
                        }

                        let success: bool = IERC20Dispatcher { contract_address: *reclaimable_asset.address }
                            .transfer(caller, (*reclaimable_asset.amount).into());
                        assert(success, 'CA: Asset transfer failed');
                    },
                    Option::None => { break; },
                };
            };

            self.emit(Reclaim { user: caller, yin_amt: reclaimable_yin, assets: reclaimable_assets });

            self.reentrancy_guard.end();
            (reclaimable_yin, reclaimable_assets)
        }
    }
}
