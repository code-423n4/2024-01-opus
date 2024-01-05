#[starknet::contract]
mod sentinel {
    use access_control::access_control_component;
    use opus::core::roles::sentinel_roles;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::ISentinel::ISentinel;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::types::YangSuspensionStatus;
    use opus::utils::math::fixed_point_to_wad;
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable};
    use starknet::{get_block_timestamp, get_caller_address};
    use wadray::{Ray, Wad, WadZeroable};

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

    // Helper constant to set the starting index for iterating over the
    // yangs in the order they were added
    const LOOP_START: u64 = 1;

    const INITIAL_DEPOSIT_AMT: u128 = 1000;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        // mapping between a yang address and our deployed Gate
        yang_to_gate: LegacyMap::<ContractAddress, IGateDispatcher>,
        // length of the yang_addresses array
        yang_addresses_count: u64,
        // 0-based array of yang addresses added to the Shrine via this Sentinel
        yang_addresses: LegacyMap::<u64, ContractAddress>,
        // The Shrine associated with this Sentinel
        shrine: IShrineDispatcher,
        // mapping between a yang address and the cap on the yang's asset in the
        // asset's decimals
        yang_asset_max: LegacyMap::<ContractAddress, u128>,
        // mapping between a yang address and whether its Gate is live
        yang_is_live: LegacyMap::<ContractAddress, bool>,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
        YangAdded: YangAdded,
        YangAssetMaxUpdated: YangAssetMaxUpdated,
        GateKilled: GateKilled,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct YangAdded {
        #[key]
        yang: ContractAddress,
        gate: ContractAddress
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct YangAssetMaxUpdated {
        #[key]
        yang: ContractAddress,
        old_max: u128,
        new_max: u128
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct GateKilled {
        #[key]
        yang: ContractAddress,
        gate: ContractAddress
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress, shrine: ContractAddress) {
        self.access_control.initializer(admin, Option::Some(sentinel_roles::default_admin_role()));
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
    }

    //
    // External Sentinel functions
    //

    #[abi(embed_v0)]
    impl ISentinelImpl of ISentinel<ContractState> {
        //
        // Getters
        //

        fn get_gate_address(self: @ContractState, yang: ContractAddress) -> ContractAddress {
            self.yang_to_gate.read(yang).contract_address
        }

        fn get_gate_live(self: @ContractState, yang: ContractAddress) -> bool {
            self.yang_is_live.read(yang)
        }

        fn get_yang_addresses(self: @ContractState) -> Span<ContractAddress> {
            let mut idx: u64 = LOOP_START;
            let loop_end: u64 = self.yang_addresses_count.read() + LOOP_START;
            let mut addresses: Array<ContractAddress> = ArrayTrait::new();
            loop {
                if idx == loop_end {
                    break addresses.span();
                }
                addresses.append(self.yang_addresses.read(idx));
                idx += 1;
            }
        }

        fn get_yang_addresses_count(self: @ContractState) -> u64 {
            self.yang_addresses_count.read()
        }

        fn get_yang(self: @ContractState, idx: u64) -> ContractAddress {
            self.yang_addresses.read(idx)
        }

        fn get_yang_asset_max(self: @ContractState, yang: ContractAddress) -> u128 {
            self.yang_asset_max.read(yang)
        }

        fn get_asset_amt_per_yang(self: @ContractState, yang: ContractAddress) -> Wad {
            let gate: IGateDispatcher = self.yang_to_gate.read(yang);
            gate.get_asset_amt_per_yang()
        }

        //
        // View functions
        //

        // This can be used to simulate the effects of `enter`.
        fn convert_to_yang(self: @ContractState, yang: ContractAddress, asset_amt: u128) -> Wad {
            let gate: IGateDispatcher = self.yang_to_gate.read(yang);
            self.assert_can_enter(yang, gate, asset_amt);
            gate.convert_to_yang(asset_amt)
        }

        // This can be used to simulate the effects of `exit`.
        fn convert_to_assets(self: @ContractState, yang: ContractAddress, yang_amt: Wad) -> u128 {
            let gate: IGateDispatcher = self.yang_to_gate.read(yang);
            assert(gate.contract_address.is_non_zero(), 'SE: Yang not added');
            gate.convert_to_assets(yang_amt)
        }

        //
        // Setters
        //

        fn add_yang(
            ref self: ContractState,
            yang: ContractAddress,
            yang_asset_max: u128,
            yang_threshold: Ray,
            yang_price: Wad,
            yang_rate: Ray,
            gate: ContractAddress
        ) {
            self.access_control.assert_has_role(sentinel_roles::ADD_YANG);
            assert(yang.is_non_zero(), 'SE: Yang cannot be zero address');
            assert(gate.is_non_zero(), 'SE: Gate cannot be zero address');
            assert(self.yang_to_gate.read(yang).contract_address.is_zero(), 'SE: Yang already added');

            let gate = IGateDispatcher { contract_address: gate };
            assert(gate.get_asset() == yang, 'SE: Asset of gate is not yang');

            let index: u64 = self.yang_addresses_count.read() + 1;
            self.yang_addresses_count.write(index);
            self.yang_addresses.write(index, yang);
            self.yang_to_gate.write(yang, gate);
            self.yang_is_live.write(yang, true);
            self.yang_asset_max.write(yang, yang_asset_max);

            // Require an initial deposit when adding a yang to prevent first depositor from front-running
            let yang_erc20 = IERC20Dispatcher { contract_address: yang };
            // scale `asset_amt` up by the difference to match `Wad` precision of yang
            let initial_yang_amt: Wad = fixed_point_to_wad(INITIAL_DEPOSIT_AMT, yang_erc20.decimals());
            let initial_deposit_amt: u256 = INITIAL_DEPOSIT_AMT.into();

            let caller: ContractAddress = get_caller_address();
            let success: bool = yang_erc20.transfer_from(caller, gate.contract_address, initial_deposit_amt);
            assert(success, 'SE: Yang transfer failed');

            let shrine: IShrineDispatcher = self.shrine.read();
            shrine.add_yang(yang, yang_threshold, yang_price, yang_rate, initial_yang_amt);

            // Events
            self.emit(YangAdded { yang, gate: gate.contract_address });
            self.emit(YangAssetMaxUpdated { yang, old_max: 0, new_max: yang_asset_max });
        }

        fn set_yang_asset_max(ref self: ContractState, yang: ContractAddress, new_asset_max: u128) {
            self.access_control.assert_has_role(sentinel_roles::SET_YANG_ASSET_MAX);

            let gate: IGateDispatcher = self.yang_to_gate.read(yang);
            assert(gate.contract_address.is_non_zero(), 'SE: Yang not added');

            let old_asset_max: u128 = self.yang_asset_max.read(yang);
            self.yang_asset_max.write(yang, new_asset_max);

            self.emit(YangAssetMaxUpdated { yang, old_max: old_asset_max, new_max: new_asset_max });
        }

        fn kill_gate(ref self: ContractState, yang: ContractAddress) {
            self.access_control.assert_has_role(sentinel_roles::KILL_GATE);

            self.yang_is_live.write(yang, false);

            self.emit(GateKilled { yang, gate: self.yang_to_gate.read(yang).contract_address });
        }

        fn suspend_yang(ref self: ContractState, yang: ContractAddress) {
            self.access_control.assert_has_role(sentinel_roles::UPDATE_YANG_SUSPENSION);
            self.shrine.read().suspend_yang(yang);
        }

        fn unsuspend_yang(ref self: ContractState, yang: ContractAddress) {
            self.access_control.assert_has_role(sentinel_roles::UPDATE_YANG_SUSPENSION);
            self.shrine.read().unsuspend_yang(yang);
        }

        //
        // Core functions
        //

        fn enter(
            ref self: ContractState, yang: ContractAddress, user: ContractAddress, trove_id: u64, asset_amt: u128
        ) -> Wad {
            self.access_control.assert_has_role(sentinel_roles::ENTER);

            let gate: IGateDispatcher = self.yang_to_gate.read(yang);

            self.assert_can_enter(yang, gate, asset_amt);
            gate.enter(user, trove_id, asset_amt)
        }

        fn exit(
            ref self: ContractState, yang: ContractAddress, user: ContractAddress, trove_id: u64, yang_amt: Wad
        ) -> u128 {
            self.access_control.assert_has_role(sentinel_roles::EXIT);
            let gate: IGateDispatcher = self.yang_to_gate.read(yang);
            assert(gate.contract_address.is_non_zero(), 'SE: Yang not added');

            gate.exit(user, trove_id, yang_amt)
        }
    }

    //
    // Internal Sentinel functions
    //

    #[generate_trait]
    impl SentinelHelpers of SentinelHelpersTrait {
        // Helper function to check that `enter` is a valid operation at the current
        // on-chain conditions
        #[inline(always)]
        fn assert_can_enter(self: @ContractState, yang: ContractAddress, gate: IGateDispatcher, enter_amt: u128) {
            assert(gate.contract_address.is_non_zero(), 'SE: Yang not added');
            assert(self.yang_is_live.read(yang), 'SE: Gate is not live');
            let suspension_status: YangSuspensionStatus = self.shrine.read().get_yang_suspension_status(yang);
            assert(suspension_status == YangSuspensionStatus::None, 'SE: Yang suspended');
            let current_total: u128 = gate.get_total_assets();
            let max_amt: u128 = self.yang_asset_max.read(yang);
            assert(current_total + enter_amt <= max_amt, 'SE: Exceeds max amount allowed');
        }
    }
}
