mod equalizer_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::core::allocator::allocator as allocator_contract;
    use opus::core::equalizer::equalizer as equalizer_contract;
    use opus::core::roles::{equalizer_roles, shrine_roles};
    use opus::interfaces::IAllocator::{IAllocatorDispatcher, IAllocatorDispatcherTrait};
    use opus::interfaces::IEqualizer::{IEqualizerDispatcher, IEqualizerDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, CheatTarget};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{ContractAddress, contract_address_to_felt252, contract_address_try_from_felt252,};
    use wadray::Ray;

    //
    // Convenience helpers
    //

    fn initial_recipients() -> Span<ContractAddress> {
        let mut recipients: Array<ContractAddress> = array![
            contract_address_try_from_felt252('recipient 1').unwrap(),
            contract_address_try_from_felt252('recipient 2').unwrap(),
            contract_address_try_from_felt252('recipient 3').unwrap(),
        ];
        recipients.span()
    }

    fn new_recipients() -> Span<ContractAddress> {
        let mut recipients: Array<ContractAddress> = array![
            contract_address_try_from_felt252('new recipient 1').unwrap(),
            contract_address_try_from_felt252('new recipient 2').unwrap(),
            contract_address_try_from_felt252('new recipient 3').unwrap(),
            contract_address_try_from_felt252('new recipient 4').unwrap(),
        ];
        recipients.span()
    }

    fn initial_percentages() -> Span<Ray> {
        let mut percentages: Array<Ray> = array![
            150000000000000000000000000_u128.into(), // 15% (Ray)
            500000000000000000000000000_u128.into(), // 50% (Ray)
            350000000000000000000000000_u128.into(), // 35% (Ray)
        ];
        percentages.span()
    }

    fn new_percentages() -> Span<Ray> {
        let mut percentages: Array<Ray> = array![
            125000000000000000000000000_u128.into(), // 12.5% (Ray)
            372500000000000000000000000_u128.into(), // 37.25% (Ray)
            216350000000000000000000000_u128.into(), // 21.635% (Ray)
            286150000000000000000000000_u128.into(), // 28.615% (Ray)
        ];
        percentages.span()
    }

    // Percentages do not add to 1
    fn invalid_percentages() -> Span<Ray> {
        let mut percentages: Array<Ray> = array![
            150000000000000000000000000_u128.into(), // 15% (Ray)
            500000000000000000000000000_u128.into(), // 50% (Ray)
            350000000000000000000000001_u128.into(), // (35 + 1E-27)% (Ray)
        ];
        percentages.span()
    }

    //
    // Test setup helpers
    //

    fn allocator_deploy(
        mut recipients: Span<ContractAddress>, mut percentages: Span<Ray>, allocator_class: Option<ContractClass>
    ) -> IAllocatorDispatcher {
        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(shrine_utils::admin()), recipients.len().into(),
        ];

        loop {
            match recipients.pop_front() {
                Option::Some(recipient) => { calldata.append(contract_address_to_felt252(*recipient)); },
                Option::None => { break; }
            };
        };

        calldata.append(percentages.len().into());
        loop {
            match percentages.pop_front() {
                Option::Some(percentage) => {
                    let val: felt252 = (*percentage.val).into();
                    calldata.append(val);
                },
                Option::None => { break; }
            };
        };

        let allocator_class = match allocator_class {
            Option::Some(class) => class,
            Option::None => declare('allocator')
        };
        let allocator_addr = allocator_class.deploy(@calldata).expect('failed allocator deploy');

        IAllocatorDispatcher { contract_address: allocator_addr }
    }

    fn equalizer_deploy(
        allocator_class: Option<ContractClass>
    ) -> (IShrineDispatcher, IEqualizerDispatcher, IAllocatorDispatcher) {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        equalizer_deploy_with_shrine(shrine.contract_address, allocator_class)
    }

    fn equalizer_deploy_with_shrine(
        shrine: ContractAddress, allocator_class: Option<ContractClass>
    ) -> (IShrineDispatcher, IEqualizerDispatcher, IAllocatorDispatcher) {
        let allocator: IAllocatorDispatcher = allocator_deploy(
            initial_recipients(), initial_percentages(), allocator_class
        );
        let admin = shrine_utils::admin();

        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(admin),
            contract_address_to_felt252(shrine),
            contract_address_to_felt252(allocator.contract_address),
        ];

        let equalizer_class = declare('equalizer');
        let equalizer_addr = equalizer_class.deploy(@calldata).expect('failed equalizer deploy');

        let equalizer_ac: IAccessControlDispatcher = IAccessControlDispatcher { contract_address: equalizer_addr };
        start_prank(CheatTarget::Multiple(array![equalizer_addr, shrine]), admin);
        equalizer_ac.grant_role(equalizer_roles::default_admin_role(), admin);

        let shrine_ac: IAccessControlDispatcher = IAccessControlDispatcher { contract_address: shrine };
        shrine_ac.grant_role(shrine_roles::equalizer(), equalizer_addr);

        stop_prank(CheatTarget::Multiple(array![equalizer_addr, shrine]));

        (
            IShrineDispatcher { contract_address: shrine },
            IEqualizerDispatcher { contract_address: equalizer_addr },
            allocator
        )
    }
}
