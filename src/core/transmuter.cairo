#[starknet::contract]
mod transmuter {
    use access_control::access_control_component;
    use cmp::min;
    use opus::core::roles::transmuter_roles;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::ITransmuter::ITransmuter;
    use opus::utils::math::{fixed_point_to_wad, wad_to_fixed_point};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use wadray::{Ray, SignedWad, Wad, WadZeroable, WAD_ONE};

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    //
    // Constants
    //

    // Upper bound of the maximum amount of yin that can be minted via this Transmuter as a 
    // percentage of total yin supply: 100% (Ray)
    const PERCENTAGE_CAP_UPPER_BOUND: u128 = 1000000000000000000000000000;
    // Percentage cap at deployment: 10% (Ray)
    const INITIAL_PERCENTAGE_CAP: u128 = 100000000000000000000000000;

    // Upper bound of the fee as a percentage that can be charged for both: 1% (Ray)
    // 1. swapping yin for the asset when `reverse` is enabled; and
    // 2. swapping asset for yin,
    // This is not set at deployment so it defaults to 0%.
    const FEE_UPPER_BOUND: u128 = 10000000000000000000000000;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        // The Shrine associated with this Transmuter
        shrine: IShrineDispatcher,
        // The asset that can be swapped for yin via this Transmuter
        asset: IERC20Dispatcher,
        // The total yin transmuted 
        total_transmuted: Wad,
        // The maximum amount of yin that can be minted via this Transmuter
        ceiling: Wad,
        // The maximum amount of yin that can be minted via this Transmuter
        // as a percentage of the total yin supply
        percentage_cap: Ray,
        // Keeps track of whether the Transmuter currently allows for users
        // to burn yin and receive the asset
        reversibility: bool,
        // Fee to be charged for each `reverse` transaction
        reverse_fee: Ray,
        // Fee to be charged for each `transmute` transaction
        transmute_fee: Ray,
        // Keeps track of whether the Transmuter is live or killed
        is_live: bool,
        // Keeps track of whether `reclaim` has started after Transmuter is killed
        is_reclaimable: bool,
        // The address to receive any excess assets
        receiver: ContractAddress,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
        CeilingUpdated: CeilingUpdated,
        Killed: Killed,
        PercentageCapUpdated: PercentageCapUpdated,
        ReceiverUpdated: ReceiverUpdated,
        Reclaim: Reclaim,
        Reverse: Reverse,
        ReverseFeeUpdated: ReverseFeeUpdated,
        ReversibilityToggled: ReversibilityToggled,
        Settle: Settle,
        Sweep: Sweep,
        Transmute: Transmute,
        TransmuteFeeUpdated: TransmuteFeeUpdated,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct CeilingUpdated {
        old_ceiling: Wad,
        new_ceiling: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Killed {}

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct PercentageCapUpdated {
        cap: Ray
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct ReceiverUpdated {
        old_receiver: ContractAddress,
        new_receiver: ContractAddress
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Reclaim {
        #[key]
        user: ContractAddress,
        asset_amt: u128,
        yin_amt: Wad,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Reverse {
        #[key]
        user: ContractAddress,
        asset_amt: u128,
        yin_amt: Wad,
        fee: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct ReverseFeeUpdated {
        old_fee: Ray,
        new_fee: Ray
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct ReversibilityToggled {
        reversibility: bool
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Settle {
        deficit: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Sweep {
        #[key]
        recipient: ContractAddress,
        asset_amt: u128
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Transmute {
        #[key]
        user: ContractAddress,
        asset_amt: u128,
        yin_amt: Wad,
        fee: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct TransmuteFeeUpdated {
        old_fee: Ray,
        new_fee: Ray
    }

    // Constructor

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        shrine: ContractAddress,
        asset: ContractAddress,
        receiver: ContractAddress,
        ceiling: Wad,
    ) {
        self.access_control.initializer(admin, Option::Some(transmuter_roles::default_admin_role()));

        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.asset.write(IERC20Dispatcher { contract_address: asset });
        self.is_live.write(true);

        self.set_ceiling_helper(ceiling);
        self.set_receiver_helper(receiver);
        self.set_percentage_cap_helper(INITIAL_PERCENTAGE_CAP.into());

        // Reversibility is enabled at deployment
        self.reversibility.write(true);
    }

    //
    // External Transmuter functions
    //

    #[abi(embed_v0)]
    impl ITransmuterImpl of ITransmuter<ContractState> {
        //
        // Getters
        //
        fn get_asset(self: @ContractState) -> ContractAddress {
            self.asset.read().contract_address
        }

        fn get_total_transmuted(self: @ContractState) -> Wad {
            self.total_transmuted.read()
        }

        fn get_ceiling(self: @ContractState) -> Wad {
            self.ceiling.read()
        }

        fn get_percentage_cap(self: @ContractState) -> Ray {
            self.percentage_cap.read()
        }

        fn get_receiver(self: @ContractState) -> ContractAddress {
            self.receiver.read()
        }

        fn get_reversibility(self: @ContractState) -> bool {
            self.reversibility.read()
        }

        fn get_transmute_fee(self: @ContractState) -> Ray {
            self.transmute_fee.read()
        }

        fn get_reverse_fee(self: @ContractState) -> Ray {
            self.reverse_fee.read()
        }

        fn get_live(self: @ContractState) -> bool {
            self.is_live.read()
        }

        fn get_reclaimable(self: @ContractState) -> bool {
            self.is_reclaimable.read()
        }

        //
        // Setters
        //

        fn set_ceiling(ref self: ContractState, ceiling: Wad) {
            self.access_control.assert_has_role(transmuter_roles::SET_CEILING);

            self.set_ceiling_helper(ceiling);
        }

        fn set_percentage_cap(ref self: ContractState, cap: Ray) {
            self.access_control.assert_has_role(transmuter_roles::SET_PERCENTAGE_CAP);

            self.set_percentage_cap_helper(cap);
        }

        fn set_receiver(ref self: ContractState, receiver: ContractAddress) {
            self.access_control.assert_has_role(transmuter_roles::SET_RECEIVER);

            self.set_receiver_helper(receiver);
        }

        fn toggle_reversibility(ref self: ContractState) {
            self.access_control.assert_has_role(transmuter_roles::TOGGLE_REVERSIBILITY);

            let reversibility: bool = !self.reversibility.read();
            self.reversibility.write(reversibility);
            self.emit(ReversibilityToggled { reversibility });
        }

        fn set_transmute_fee(ref self: ContractState, fee: Ray) {
            self.access_control.assert_has_role(transmuter_roles::SET_FEES);

            self.assert_valid_fee(fee);
            let old_fee: Ray = self.transmute_fee.read();
            self.transmute_fee.write(fee);

            self.emit(TransmuteFeeUpdated { old_fee, new_fee: fee });
        }

        fn set_reverse_fee(ref self: ContractState, fee: Ray) {
            self.access_control.assert_has_role(transmuter_roles::SET_FEES);

            self.assert_valid_fee(fee);
            let old_fee: Ray = self.reverse_fee.read();
            self.reverse_fee.write(fee);

            self.emit(ReverseFeeUpdated { old_fee, new_fee: fee });
        }

        // One way function to enable `reclaim` after Transmuter is killed.
        // This should be called after the assets backing the total transmuted amount
        // have been transferred back to the Transmuter after shutdown.
        fn enable_reclaim(ref self: ContractState) {
            self.access_control.assert_has_role(transmuter_roles::ENABLE_RECLAIM);

            assert(!self.is_live.read(), 'TR: Transmuter is live');
            self.is_reclaimable.write(true);
        }

        // 
        // Core functions - View
        //

        // Returns the amount of yin that a user will receive for the given asset amount
        // based on current on-chain conditions
        fn preview_transmute(self: @ContractState, asset_amt: u128) -> Wad {
            let (yin_amt, _) = self.preview_transmute_helper(asset_amt);
            yin_amt
        }

        // Returns the amount of stablecoin asset that a user will receive for the given yin amount
        // based on current on-chain conditions.
        // Note that it does not guarantee the Transmuter has sufficient asset for reverse.
        fn preview_reverse(self: @ContractState, yin_amt: Wad) -> u128 {
            let (asset_amt, _) = self.preview_reverse_helper(yin_amt);
            asset_amt
        }

        //
        // Core functions - External
        //

        // Deducts the transmute fee, if any, from the asset amount to be transmuted,
        // and converts the remainder to yin at a ratio of 1 : 1, scaled to Wad precision.
        // Reverts if:
        // 1. User has insufficent assets;
        // 2. Transmuter's ceiling will be exceeded;
        // 3. Transmuter's cap as a percentage of total yin will be exceeded;
        // 4. Yin's price is below 1; or
        // 5. Shrine's ceiling will be exceeded.
        fn transmute(ref self: ContractState, asset_amt: u128) {
            // `preview_transmute_helper` checks for liveness
            let (yin_amt, fee) = self.preview_transmute_helper(asset_amt);

            self.total_transmuted.write(self.total_transmuted.read() + yin_amt + fee);

            let user: ContractAddress = get_caller_address();
            let shrine: IShrineDispatcher = self.shrine.read();
            shrine.inject(user, yin_amt);

            if fee.is_non_zero() {
                shrine.adjust_budget(fee.into());
            }

            // Transfer asset to Transmuter
            let success: bool = self.asset.read().transfer_from(user, get_contract_address(), asset_amt.into());
            assert(success, 'TR: Asset transfer failed');

            self.emit(Transmute { user, asset_amt, yin_amt, fee });
        }

        // Swaps yin for the stablecoin asset at a ratio of 1 : 1, scaled down from Wad precision.
        // Reverts if:
        // 1. Reverse is not enabled;
        // 2. User has insufficient yin; or
        // 3. Transmuter has insufficent assets corresponding to the burnt yin.
        fn reverse(ref self: ContractState, yin_amt: Wad) {
            // `preview_reverse_helper` checks for liveness and reversibility
            let (asset_amt, fee) = self.preview_reverse_helper(yin_amt);

            // Decrement total transmuted amount by yin amount to be reversed 
            // excluding the fee. The fee is excluded because this Transmuter
            // is still liable to back the amount of yin representing the fee 
            // (when it is added to the Shrine's budget and eventually minted 
            // via the Equalizer) with the corresponding amount of assets, 
            // particularly in the event of shutdown.
            self.total_transmuted.write(self.total_transmuted.read() - yin_amt + fee);

            // Burn the entire yin amount from user, and add the fee to the budget
            let user: ContractAddress = get_caller_address();
            let shrine: IShrineDispatcher = self.shrine.read();
            shrine.eject(user, yin_amt);

            if fee.is_non_zero() {
                shrine.adjust_budget(fee.into());
            }

            // Transfer asset to user
            // Note that the assets backing the fee is excluded from the assets transferred
            // to the user, and is retained in the Transmuter.
            let success: bool = self.asset.read().transfer(user, asset_amt.into());
            assert(success, 'TR: Asset transfer failed');

            self.emit(Reverse { user, asset_amt, yin_amt, fee });
        }

        // Transfers assets in the Transmuter to the receiver
        fn sweep(ref self: ContractState, asset_amt: u128) {
            self.assert_live();

            self.access_control.assert_has_role(transmuter_roles::SWEEP);

            let asset: IERC20Dispatcher = self.asset.read();
            let asset_balance: u128 = asset.balance_of(get_contract_address()).try_into().unwrap();
            let capped_asset_amt: u128 = min(asset_balance, asset_amt);

            if capped_asset_amt.is_zero() {
                return;
            }

            let recipient: ContractAddress = self.receiver.read();
            asset.transfer(recipient, capped_asset_amt.into());
            self.emit(Sweep { recipient, asset_amt: capped_asset_amt });
        }

        // 
        // Isolated deprecation
        // 

        // Irreversibly deprecate this Transmuter only by settling its debt and transferring 
        // all of its yin and asset to the receiver.
        fn settle(ref self: ContractState) {
            self.assert_live();

            self.access_control.assert_has_role(transmuter_roles::SETTLE);

            // Pay down the Transmuter's debt using the Transmuter's yin balance,
            // capped at the total debt transmuted.
            let transmuter: ContractAddress = get_contract_address();
            let shrine: IShrineDispatcher = self.shrine.read();
            let yin_amt: Wad = shrine.get_yin(transmuter);

            let mut total_transmuted: Wad = self.total_transmuted.read();
            let settle_amt: Wad = min(total_transmuted, yin_amt);
            total_transmuted -= settle_amt;

            self.total_transmuted.write(WadZeroable::zero());
            self.is_live.write(false);

            shrine.eject(transmuter, settle_amt);

            // Incur deficit if any
            if total_transmuted.is_non_zero() {
                self.shrine.read().adjust_budget(SignedWad { val: total_transmuted.val, sign: true });
            }

            // Transfer all remaining yin and all assets to receiver
            let yin = IERC20Dispatcher { contract_address: shrine.contract_address };
            let receiver: ContractAddress = self.receiver.read();
            yin.transfer(receiver, (yin_amt - settle_amt).into());

            let asset: IERC20Dispatcher = self.asset.read();
            asset.transfer(receiver, asset.balance_of(transmuter));

            // Emit event
            self.emit(Settle { deficit: total_transmuted })
        }

        //
        // Global shutdown
        //

        fn kill(ref self: ContractState) {
            self.access_control.assert_has_role(transmuter_roles::KILL);
            self.is_live.write(false);
            self.emit(Killed {});
        }

        fn preview_reclaim(self: @ContractState, yin: Wad) -> u128 {
            let (_, asset_amt) = self.preview_reclaim_helper(yin);
            asset_amt
        }

        // Note that the amount of asset that can be claimed is no longer pegged 1 : 1
        // because we do not make any assumptions as to the amount of assets held by the 
        // Transmuter.
        fn reclaim(ref self: ContractState, yin: Wad) {
            // `preview_reclaim` checks that reclaim is enabled
            let (capped_yin, asset_amt) = self.preview_reclaim_helper(yin);
            if asset_amt.is_zero() {
                return;
            }

            self.total_transmuted.write(self.total_transmuted.read() - capped_yin);
            let caller: ContractAddress = get_caller_address();
            self.shrine.read().eject(caller, capped_yin);
            self.asset.read().transfer(caller, asset_amt.into());

            self.emit(Reclaim { user: caller, asset_amt, yin_amt: capped_yin });
        }
    }

    #[generate_trait]
    impl TransmuterHelpers of TransmuterHelpersTrait {
        #[inline(always)]
        fn assert_live(self: @ContractState) {
            assert(self.is_live.read(), 'TR: Transmuter is not live');
        }

        #[inline(always)]
        fn assert_valid_fee(self: @ContractState, fee: Ray) {
            assert(fee <= FEE_UPPER_BOUND.into(), 'TR: Exceeds max fee');
        }

        // Checks it is valid to mint the given amount of yin based on current
        // on-chain conditions
        #[inline(always)]
        fn assert_can_transmute(self: @ContractState, amt_to_mint: Wad) {
            let shrine: IShrineDispatcher = self.shrine.read();
            let yin_price_ge_peg: bool = shrine.get_yin_spot_price() >= WAD_ONE.into();

            let cap: Wad = wadray::rmul_wr(shrine.get_total_yin(), self.percentage_cap.read());
            let ceiling: Wad = self.ceiling.read();
            let minted: Wad = self.total_transmuted.read();
            let is_lt_cap_and_ceiling: bool = minted + amt_to_mint <= min(cap, ceiling);

            assert(yin_price_ge_peg && is_lt_cap_and_ceiling, 'TR: Transmute is paused');
        }

        fn set_ceiling_helper(ref self: ContractState, ceiling: Wad) {
            let old_ceiling: Wad = self.ceiling.read();
            self.ceiling.write(ceiling);

            self.emit(CeilingUpdated { old_ceiling, new_ceiling: ceiling });
        }

        fn set_receiver_helper(ref self: ContractState, receiver: ContractAddress) {
            assert(receiver.is_non_zero(), 'TR: Zero address');
            let old_receiver: ContractAddress = self.receiver.read();
            self.receiver.write(receiver);

            self.emit(ReceiverUpdated { old_receiver, new_receiver: receiver });
        }

        fn set_percentage_cap_helper(ref self: ContractState, cap: Ray) {
            assert(cap <= PERCENTAGE_CAP_UPPER_BOUND.into(), 'TR: Exceeds upper bound');
            self.percentage_cap.write(cap);

            self.emit(PercentageCapUpdated { cap });
        }

        // Returns a tuple of
        // 1. the total amount of yin that a user is expected to receive less the fee
        // 2. the amount of yin in Wad charged as fee
        // based on current on-chain conditions
        fn preview_transmute_helper(self: @ContractState, asset_amt: u128) -> (Wad, Wad) {
            self.assert_live();

            let yin_amt: Wad = fixed_point_to_wad(asset_amt, self.asset.read().decimals());
            self.assert_can_transmute(yin_amt);

            let fee: Wad = wadray::rmul_wr(yin_amt, self.transmute_fee.read());

            (yin_amt - fee, fee)
        }

        // Returns a tuple of:
        // 1. the amount of asset that a user is expected to receive less the fee
        // 2. the amount of yin in Wad charged as fee
        // based on current on-chain conditions
        fn preview_reverse_helper(self: @ContractState, yin_amt: Wad) -> (u128, Wad) {
            self.assert_live();

            assert(self.reversibility.read(), 'TR: Reverse is paused');

            let fee: Wad = wadray::rmul_wr(yin_amt.into(), self.reverse_fee.read());

            let asset: IERC20Dispatcher = self.asset.read();
            let asset_amt: u128 = wad_to_fixed_point(yin_amt - fee, asset.decimals());

            assert(asset.balance_of(get_contract_address()) >= asset_amt.into(), 'TR: Insufficient assets');

            (asset_amt, fee)
        }

        // Returns a tuple of:
        // 1. the amount of yin that can be reclaimed, capped by what is still reclaimable; and
        // 2. the amount of asset that a user is expected to receive for `reclaim` after the 
        //    Transmuter is killed.
        fn preview_reclaim_helper(self: @ContractState, yin_amt: Wad) -> (Wad, u128) {
            assert(self.is_reclaimable.read(), 'TR: Reclaim unavailable');

            let reclaimable_yin: Wad = self.total_transmuted.read();
            let capped_yin: Wad = min(yin_amt, reclaimable_yin);

            let asset_balance: Wad = self.asset.read().balance_of(get_contract_address()).try_into().unwrap();

            if asset_balance.is_zero() {
                (WadZeroable::zero(), 0)
            } else {
                (capped_yin, ((capped_yin / self.total_transmuted.read()) * asset_balance).val)
            }
        }
    }
}
