#[starknet::contract]
mod transmuter_registry {
    use access_control::access_control_component;
    use opus::core::roles::transmuter_registry_roles;
    use opus::interfaces::ITransmuter::{ITransmuterDispatcher, ITransmuterDispatcherTrait, ITransmuterRegistry};
    use opus::utils::address_registry::address_registry_component;
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable};

    //
    // Components
    //

    component!(path: access_control_component, storage: access_control, event: AccessControlEvent);
    component!(path: address_registry_component, storage: registry, event: AddressRegistryEvent);

    #[abi(embed_v0)]
    impl AccessControlPublic = access_control_component::AccessControl<ContractState>;

    impl AccessControlHelpers = access_control_component::AccessControlHelpers<ContractState>;
    impl AddressRegistryHelpers = address_registry_component::AddressRegistryHelpers<ContractState>;

    //
    // Storage
    //

    #[storage]
    struct Storage {
        // components
        #[substorage(v0)]
        access_control: access_control_component::Storage,
        #[substorage(v0)]
        registry: address_registry_component::Storage,
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AccessControlEvent: access_control_component::Event,
        AddressRegistryEvent: address_registry_component::Event,
    }

    //
    // Constructor
    //

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        self.access_control.initializer(admin, Option::Some(transmuter_registry_roles::default_admin_role()));
    }

    //
    // External Transmuter registry functions
    //

    #[abi(embed_v0)]
    impl ITransmuterRegistryImpl of ITransmuterRegistry<ContractState> {
        fn get_transmuters(self: @ContractState) -> Span<ContractAddress> {
            self.registry.get_entries()
        }

        fn add_transmuter(ref self: ContractState, transmuter: ContractAddress) {
            self.access_control.assert_has_role(transmuter_registry_roles::MODIFY);

            self.registry.add_entry(transmuter).expect('TRR: Transmuter already exists');
        }

        fn remove_transmuter(ref self: ContractState, transmuter: ContractAddress) {
            self.access_control.assert_has_role(transmuter_registry_roles::MODIFY);

            self.registry.remove_entry(transmuter).expect('TRR: Transmuter does not exist');
        }
    }
}
