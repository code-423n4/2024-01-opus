mod caretaker_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use debug::PrintTrait;
    use opus::core::caretaker::caretaker as caretaker_contract;
    use opus::core::roles::{sentinel_roles, shrine_roles};
    use opus::interfaces::IAbbot::IAbbotDispatcher;
    use opus::interfaces::ICaretaker::ICaretakerDispatcher;
    use opus::interfaces::IGate::IGateDispatcher;
    use opus::interfaces::ISentinel::ISentinelDispatcher;
    use opus::interfaces::IShrine::IShrineDispatcher;
    use opus::tests::abbot::utils::abbot_utils;
    use opus::tests::equalizer::utils::equalizer_utils;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, start_warp, CheatTarget};
    use starknet::{ContractAddress, contract_address_try_from_felt252, contract_address_to_felt252};

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('caretaker admin').unwrap()
    }

    // returns the addrs of caretaker, shrine, abbot, sentinel, [yangs addrs], [gate dispatchers]
    fn caretaker_deploy() -> (
        ICaretakerDispatcher,
        IShrineDispatcher,
        IAbbotDispatcher,
        ISentinelDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>
    ) {
        start_warp(CheatTarget::All, shrine_utils::DEPLOYMENT_TIMESTAMP);

        let (shrine, sentinel, abbot, yangs, gates) = abbot_utils::abbot_deploy(
            Option::None, Option::None, Option::None, Option::None, Option::None
        );
        let (shrine, equalizer, _allocator) = equalizer_utils::equalizer_deploy_with_shrine(
            shrine.contract_address, Option::None
        );

        let calldata: Array<felt252> = array![
            contract_address_to_felt252(admin()),
            contract_address_to_felt252(shrine.contract_address),
            contract_address_to_felt252(abbot.contract_address),
            contract_address_to_felt252(sentinel.contract_address),
            contract_address_to_felt252(equalizer.contract_address),
        ];

        let caretaker_class = declare('caretaker');
        let caretaker = caretaker_class.deploy(@calldata).expect('failed deploy caretaker');

        // allow Caretaker to do its business with Shrine
        start_prank(CheatTarget::One(shrine.contract_address), shrine_utils::admin());
        IAccessControlDispatcher { contract_address: shrine.contract_address }
            .grant_role(shrine_roles::caretaker(), caretaker);

        // allow Caretaker to call exit in Sentinel during shut
        start_prank(CheatTarget::One(sentinel.contract_address), sentinel_utils::admin());
        IAccessControlDispatcher { contract_address: sentinel.contract_address }
            .grant_role(sentinel_roles::caretaker(), caretaker);

        stop_prank(CheatTarget::Multiple(array![shrine.contract_address, sentinel.contract_address]));

        let caretaker = ICaretakerDispatcher { contract_address: caretaker };

        (caretaker, shrine, abbot, sentinel, yangs, gates)
    }

    fn only_eth(
        yangs: Span<ContractAddress>, gates: Span<IGateDispatcher>
    ) -> (Span<ContractAddress>, Span<IGateDispatcher>, Span<u128>) {
        let mut eth_yang = array![*yangs[0]];
        let mut eth_gate = array![*gates[0]];
        let mut eth_amount = array![abbot_utils::ETH_DEPOSIT_AMT];

        (eth_yang.span(), eth_gate.span(), eth_amount.span())
    }
}
