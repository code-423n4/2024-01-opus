mod test_address_registry {
    use opus::tests::common;
    use opus::tests::utils::mock_address_registry::mock_address_registry;
    use opus::utils::address_registry::address_registry_component::AddressRegistryHelpers;
    use opus::utils::address_registry::address_registry_component;
    use snforge_std::cheatcodes::events::EventAssertions;
    use snforge_std::{spy_events, SpyOn, EventSpy, EventFetcher, event_name_hash, Event, test_address,};
    use starknet::contract_address::{ContractAddress, ContractAddressZeroable, contract_address_try_from_felt252};

    //
    // Constants
    //

    const ENTRY1_ADDR: felt252 = 'entry 1';
    const ENTRY2_ADDR: felt252 = 'entry 2';
    const ENTRY3_ADDR: felt252 = 'entry 3';

    fn entry1() -> ContractAddress {
        contract_address_try_from_felt252(ENTRY1_ADDR).unwrap()
    }

    fn entry2() -> ContractAddress {
        contract_address_try_from_felt252(ENTRY2_ADDR).unwrap()
    }

    fn entry3() -> ContractAddress {
        contract_address_try_from_felt252(ENTRY3_ADDR).unwrap()
    }

    fn zero_addr() -> ContractAddress {
        ContractAddressZeroable::zero()
    }

    //
    // Test setup
    //

    fn state() -> mock_address_registry::ContractState {
        mock_address_registry::contract_state_for_testing()
    }

    //
    // Tests
    //

    #[test]
    fn test_setup() {
        let state = state();

        let empty_entries: Span<ContractAddress> = array![].span();
        assert(state.address_registry.get_entries() == empty_entries, 'should be empty');
    }

    #[test]
    fn test_add_and_remove_entry() {
        let mut state = state();

        let mut spy = spy_events(SpyOn::One(test_address()));

        // add first entry
        // order: 1

        let res = state.address_registry.add_entry(entry1());

        let expected_entry_id: u32 = 1;
        assert(res.unwrap() == expected_entry_id, 'error');

        spy.fetch_events();

        let mut event_id = 0;
        let (_, event) = spy.events.at(event_id);
        assert(*event.keys[1] == event_name_hash('EntryAdded'), 'wrong event name #1');
        assert(*event.data[0] == ENTRY1_ADDR, 'should be entry 1');
        assert(*event.data[1] == expected_entry_id.into(), 'should be ID 1');

        assert(state.address_registry.get_entry(expected_entry_id) == entry1(), 'wrong entry #1');
        let expected_entries: Span<ContractAddress> = array![entry1()].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #1');

        // add second entry
        // order: 1, 2

        let res = state.address_registry.add_entry(entry2());

        let expected_entry_id: u32 = 2;
        assert(res.unwrap() == expected_entry_id, 'error');

        spy.fetch_events();

        event_id += 1;
        let (_, event) = spy.events.at(event_id);
        assert(*event.keys[1] == event_name_hash('EntryAdded'), 'wrong event name #2');
        assert(*event.data[0] == ENTRY2_ADDR, 'should be entry 2');
        assert(*event.data[1] == expected_entry_id.into(), 'should be ID 2');

        assert(state.address_registry.get_entry(expected_entry_id) == entry2(), 'wrong entry #2');
        let expected_entries: Span<ContractAddress> = array![entry1(), entry2()].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #2');

        // add third entry
        // order: 1, 2, 3

        let res = state.address_registry.add_entry(entry3());

        let expected_entry_id: u32 = 3;
        assert(res.unwrap() == expected_entry_id, 'error');

        spy.fetch_events();

        event_id += 1;
        let (_, event) = spy.events.at(event_id);
        assert(*event.keys[1] == event_name_hash('EntryAdded'), 'wrong event name #3');
        assert(*event.data[0] == ENTRY3_ADDR, 'should be entry 3');
        assert(*event.data[1] == expected_entry_id.into(), 'should be ID 3');

        assert(state.address_registry.get_entry(expected_entry_id) == entry3(), 'wrong entry #3');
        let expected_entries: Span<ContractAddress> = array![entry1(), entry2(), entry3()].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #3');

        // remove entry at last index 
        // order: 1, 2, _

        let res = state.address_registry.remove_entry(entry3());
        assert(res.unwrap() == entry3(), 'error');

        let expected_entry_id: u32 = 3;

        spy.fetch_events();

        event_id += 1;
        let (_, event) = spy.events.at(event_id);
        assert(*event.keys[1] == event_name_hash('EntryRemoved'), 'wrong event name #4');
        assert(*event.data[0] == ENTRY3_ADDR, 'should be entry 3');
        assert(*event.data[1] == expected_entry_id.into(), 'should be ID 3');

        assert(state.address_registry.get_entry(expected_entry_id).is_zero(), 'wrong entry #4');
        let expected_entries: Span<ContractAddress> = array![entry1(), entry2()].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #4');

        // add back removed entry
        // order: 1, 2, _, 3
        let res = state.address_registry.add_entry(entry3());

        let expected_entry_id: u32 = 4;
        assert(res.unwrap() == expected_entry_id, 'error');

        spy.fetch_events();

        event_id += 1;
        let (_, event) = spy.events.at(event_id);
        assert(*event.keys[1] == event_name_hash('EntryAdded'), 'wrong event name #5');
        assert(*event.data[0] == ENTRY3_ADDR, 'should be entry 3');
        assert(*event.data[1] == expected_entry_id.into(), 'should be ID 4');

        assert(state.address_registry.get_entry(expected_entry_id) == entry3(), 'wrong entry #5');
        let expected_entries: Span<ContractAddress> = array![entry1(), entry2(), entry3()].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #5');

        // remove entry at first index
        // order: _, 2, _, 3
        let res = state.address_registry.remove_entry(entry1());
        assert(res.unwrap() == entry1(), 'error');
        let expected_entry_id: u32 = 1;

        spy.fetch_events();

        event_id += 1;
        let (_, event) = spy.events.at(event_id);
        assert(*event.keys[1] == event_name_hash('EntryRemoved'), 'wrong event name #6');
        assert(*event.data[0] == ENTRY1_ADDR, 'should be entry 1');
        assert(*event.data[1] == expected_entry_id.into(), 'should be ID 1');

        assert(state.address_registry.get_entry(expected_entry_id).is_zero(), 'wrong entry #6');
        let expected_entries: Span<ContractAddress> = array![entry2(), entry3()].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #6');

        // add back removed entry
        // order: _, 2, _, 3, 1
        let res = state.address_registry.add_entry(entry1());

        let expected_entry_id: u32 = 5;
        assert(res.unwrap() == expected_entry_id, 'error');

        spy.fetch_events();

        event_id += 1;
        let (_, event) = spy.events.at(event_id);
        assert(*event.keys[1] == event_name_hash('EntryAdded'), 'wrong event name #7');
        assert(*event.data[0] == ENTRY1_ADDR, 'should be entry 1');
        assert(*event.data[1] == expected_entry_id.into(), 'should be ID 5');

        assert(state.address_registry.get_entry(expected_entry_id) == entry1(), 'wrong entry #7');
        let expected_entries: Span<ContractAddress> = array![entry2(), entry3(), entry1()].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #7');

        // reset to zero
        let _ = state.address_registry.remove_entry(entry1());
        let _ = state.address_registry.remove_entry(entry2());
        let _ = state.address_registry.remove_entry(entry3());

        let expected_entries: Span<ContractAddress> = array![].span();
        assert(state.address_registry.get_entries() == expected_entries, 'wrong entries #8');
    }

    #[test]
    fn test_add_duplicate_entry_fail() {
        let mut state = state();

        let _ = state.address_registry.add_entry(entry1());
        let res = state.address_registry.add_entry(entry1());
        assert(res.unwrap_err() == 'AR: Entry already exists', 'wrong error');
    }

    #[test]
    fn test_remove_non_existent_entry_fail() {
        let mut state = state();

        let res = state.address_registry.remove_entry(entry1());
        assert(res.unwrap_err() == 'AR: Entry does not exist', 'wrong error');
    }
}
