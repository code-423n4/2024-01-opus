mod test_allocator {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::core::allocator::allocator as allocator_contract;
    use opus::core::roles::allocator_roles;
    use opus::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use opus::tests::common;
    use opus::tests::equalizer::utils::equalizer_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{start_prank, stop_prank, CheatTarget, spy_events, SpyOn, EventSpy, EventAssertions};
    use starknet::ContractAddress;
    use wadray::Ray;

    #[test]
    fn test_allocator_deploy() {
        let allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::initial_recipients(), equalizer_utils::initial_percentages(), Option::None
        );

        let expected_recipients = equalizer_utils::initial_recipients();
        let expected_percentages = equalizer_utils::initial_percentages();

        let (recipients, percentages) = allocator.get_allocation();

        assert(recipients == expected_recipients, 'wrong recipients');
        assert(percentages == expected_percentages, 'wrong percentages');
        assert(recipients.len() == 3, 'wrong array length');
        assert(recipients.len() == percentages.len(), 'array length mismatch');

        let allocator_ac = IAccessControlDispatcher { contract_address: allocator.contract_address };
        let admin = shrine_utils::admin();
        assert(allocator_ac.get_admin() == admin, 'wrong admin');
        assert(allocator_ac.get_roles(admin) == allocator_roles::SET_ALLOCATION, 'wrong role');
        assert(allocator_ac.has_role(allocator_roles::SET_ALLOCATION, admin), 'role not granted');
    }

    #[test]
    #[should_panic(expected: ('failed allocator deploy',))]
    fn test_allocator_deploy_input_arrays_mismatch_fail() {
        let mut recipients = equalizer_utils::initial_recipients();
        let _ = recipients.pop_front();

        let test_allocator_deploy_input_arrays_mismatch_fail = equalizer_utils::allocator_deploy(
            recipients, equalizer_utils::initial_percentages(), Option::None
        );
    }

    #[test]
    #[should_panic(expected: ('failed allocator deploy',))]
    fn test_allocator_deploy_no_recipients_fail() {
        let recipients: Array<ContractAddress> = ArrayTrait::new();
        let percentages: Array<Ray> = ArrayTrait::new();

        let _ = equalizer_utils::allocator_deploy(recipients.span(), percentages.span(), Option::None);
    }

    #[test]
    #[should_panic(expected: ('failed allocator deploy',))]
    fn test_allocator_deploy_invalid_percentage_fail() {
        let _ = equalizer_utils::allocator_deploy(
            equalizer_utils::initial_recipients(), equalizer_utils::invalid_percentages(), Option::None
        );
    }

    #[test]
    fn test_set_allocation_pass() {
        let allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::initial_recipients(), equalizer_utils::initial_percentages(), Option::None
        );

        let mut spy = spy_events(SpyOn::One(allocator.contract_address));

        start_prank(CheatTarget::One(allocator.contract_address), shrine_utils::admin());
        let new_recipients = equalizer_utils::new_recipients();
        let new_percentages = equalizer_utils::new_percentages();
        allocator.set_allocation(new_recipients, new_percentages);

        let (recipients, percentages) = allocator.get_allocation();
        assert(recipients == new_recipients, 'wrong recipients');
        assert(percentages == new_percentages, 'wrong percentages');
        assert(recipients.len() == 4, 'wrong array length');
        assert(recipients.len() == percentages.len(), 'array length mismatch');

        let expected_events = array![
            (
                allocator.contract_address,
                allocator_contract::Event::AllocationUpdated(
                    allocator_contract::AllocationUpdated { recipients, percentages }
                )
            ),
        ];

        spy.assert_emitted(@expected_events);
    }

    #[test]
    #[should_panic(expected: ('AL: Array lengths mismatch',))]
    fn test_set_allocation_arrays_mismatch_fail() {
        let allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::initial_recipients(), equalizer_utils::initial_percentages(), Option::None
        );

        start_prank(CheatTarget::One(allocator.contract_address), shrine_utils::admin());
        let new_recipients = equalizer_utils::new_recipients();
        let mut new_percentages = equalizer_utils::new_percentages();
        let _ = new_percentages.pop_front();
        allocator.set_allocation(new_recipients, new_percentages);
    }

    #[test]
    #[should_panic(expected: ('AL: No recipients',))]
    fn test_set_allocation_no_recipients_fail() {
        let allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::initial_recipients(), equalizer_utils::initial_percentages(), Option::None
        );

        start_prank(CheatTarget::One(allocator.contract_address), shrine_utils::admin());
        let recipients: Array<ContractAddress> = ArrayTrait::new();
        let percentages: Array<Ray> = ArrayTrait::new();
        allocator.set_allocation(recipients.span(), percentages.span());
    }

    #[test]
    #[should_panic(expected: ('AL: sum(percentages) != RAY_ONE',))]
    fn test_set_allocation_invalid_percentage_fail() {
        let allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::initial_recipients(), equalizer_utils::initial_percentages(), Option::None
        );

        start_prank(CheatTarget::One(allocator.contract_address), shrine_utils::admin());
        let mut new_recipients = equalizer_utils::new_recipients();
        // Pop one off new recipients to set it to same length as invalid percentages
        let _ = new_recipients.pop_front();
        let new_percentages = equalizer_utils::invalid_percentages();
        allocator.set_allocation(new_recipients, new_percentages);
    }

    #[test]
    #[should_panic(expected: ('Caller missing role',))]
    fn test_set_allocation_unauthorized_fail() {
        let allocator = equalizer_utils::allocator_deploy(
            equalizer_utils::initial_recipients(), equalizer_utils::initial_percentages(), Option::None
        );

        start_prank(CheatTarget::One(allocator.contract_address), common::badguy());
        allocator.set_allocation(equalizer_utils::new_recipients(), equalizer_utils::new_percentages());
    }
}
