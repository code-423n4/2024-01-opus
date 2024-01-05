#[starknet::component]
mod address_registry_component {
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{ContractAddress};

    #[storage]
    struct Storage {
        entries_count: u32,
        entry_ids: LegacyMap::<ContractAddress, u32>,
        entries: LegacyMap::<u32, ContractAddress>,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        EntryAdded: EntryAdded,
        EntryRemoved: EntryRemoved,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct EntryAdded {
        entry: ContractAddress,
        entry_id: u32
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct EntryRemoved {
        entry: ContractAddress,
        entry_id: u32
    }

    #[generate_trait]
    impl AddressRegistryHelpers<
        TContractState, +HasComponent<TContractState>
    > of AddressRegistryHelpersTrait<TContractState> {
        //
        // getters
        //

        fn get_entry(self: @ComponentState<TContractState>, entry_id: u32) -> ContractAddress {
            self.entries.read(entry_id)
        }

        fn get_entries(self: @ComponentState<TContractState>) -> Span<ContractAddress> {
            let mut entries: Array<ContractAddress> = ArrayTrait::new();

            let mut entry_id: u32 = 1;
            let loop_end: u32 = self.entries_count.read() + 1;
            loop {
                if entry_id == loop_end {
                    break entries.span();
                }

                let entry: ContractAddress = self.entries.read(entry_id);
                if entry.is_non_zero() {
                    entries.append(self.entries.read(entry_id));
                }

                entry_id += 1;
            }
        }

        //
        // setters
        //

        fn add_entry(ref self: ComponentState<TContractState>, entry: ContractAddress) -> Result<u32, felt252> {
            if self.entry_ids.read(entry).is_non_zero() {
                return Result::Err('AR: Entry already exists');
            }
            let entry_id: u32 = self.entries_count.read() + 1;

            self.entries_count.write(entry_id);
            self.entry_ids.write(entry, entry_id);
            self.entries.write(entry_id, entry);

            self.emit(EntryAdded { entry, entry_id });

            Result::Ok(entry_id)
        }

        fn remove_entry(
            ref self: ComponentState<TContractState>, entry: ContractAddress
        ) -> Result<ContractAddress, felt252> {
            let entry_id: u32 = self.entry_ids.read(entry);
            if entry_id.is_zero() {
                return Result::Err('AR: Entry does not exist');
            }

            // Reset entry
            self.entry_ids.write(entry, 0);
            self.entries.write(entry_id, ContractAddressZeroable::zero());

            self.emit(EntryRemoved { entry, entry_id });

            Result::Ok(entry)
        }
    }
}
