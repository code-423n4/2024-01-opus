#[starknet::contract]
mod mock_address_registry {
    use opus::utils::address_registry::address_registry_component;
    use starknet::ContractAddress;

    component!(path: address_registry_component, storage: address_registry, event: AddressRegistryEvent);

    impl AddressRegistryHelpers = address_registry_component::AddressRegistryHelpers<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        address_registry: address_registry_component::Storage
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        AddressRegistryEvent: address_registry_component::Event
    }
}
