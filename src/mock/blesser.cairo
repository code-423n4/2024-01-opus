#[starknet::contract]
mod blesser {
    use access_control::access_control_component;
    use opus::core::roles::blesser_roles;
    use opus::interfaces::IAbsorber::IBlesser;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{ContractAddress, get_contract_address};

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;
    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        asset: IERC20Dispatcher,
        absorber: ContractAddress,
        bless_amt: u128,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        asset: ContractAddress,
        absorber: ContractAddress,
        bless_amt: u128
    ) {
        self.access_control.initializer(admin, Option::None);
        self.access_control.grant_role_helper(blesser_roles::default_admin_role(), absorber);

        self.asset.write(IERC20Dispatcher { contract_address: asset });
        self.absorber.write(absorber);
        self.bless_amt.write(bless_amt);
    }

    #[abi(embed_v0)]
    impl IBlesserImpl of IBlesser<ContractState> {
        fn preview_bless(self: @ContractState) -> u128 {
            self.preview_bless_internal(self.asset.read())
        }

        fn bless(ref self: ContractState) -> u128 {
            self.access_control.assert_has_role(blesser_roles::BLESS);

            let asset: IERC20Dispatcher = self.asset.read();
            let bless_amt: u256 = self.preview_bless_internal(asset).into();
            asset.transfer(self.absorber.read(), bless_amt);
            bless_amt.try_into().unwrap()
        }
    }

    #[generate_trait]
    impl MockBlesserInternalFunctions of MockBlesserInternalFunctionsTrait {
        fn preview_bless_internal(self: @ContractState, asset: IERC20Dispatcher) -> u128 {
            let balance: u128 = asset.balance_of(get_contract_address()).try_into().unwrap();
            let bless_amt: u128 = self.bless_amt.read();
            if balance < bless_amt {
                0
            } else {
                bless_amt
            }
        }
    }
}
