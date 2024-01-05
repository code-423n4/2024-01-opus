mod gate_utils {
    use integer::BoundedInt;
    use opus::core::gate::gate as gate_contract;
    use opus::interfaces::IERC20::{
        IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait
    };
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, start_warp, CheatTarget};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::{ContractAddress, contract_address_to_felt252, contract_address_try_from_felt252};
    use wadray::{Ray, Wad, WadZeroable};

    //
    // Address constants
    //

    fn mock_sentinel() -> ContractAddress {
        contract_address_try_from_felt252('mock sentinel').unwrap()
    }

    //
    // Test setup helpers
    //

    fn gate_deploy(
        token: ContractAddress, shrine: ContractAddress, sentinel: ContractAddress, gate_class: Option<ContractClass>,
    ) -> ContractAddress {
        start_warp(CheatTarget::All, shrine_utils::DEPLOYMENT_TIMESTAMP);

        let calldata: Array<felt252> = array![
            contract_address_to_felt252(shrine),
            contract_address_to_felt252(token),
            contract_address_to_felt252(sentinel),
        ];

        let gate_class = match gate_class {
            Option::Some(class) => class,
            Option::None => declare('gate'),
        };
        gate_class.deploy(@calldata).expect('gate deploy failed')
    }

    fn eth_gate_deploy(token_class: Option<ContractClass>) -> (ContractAddress, ContractAddress, ContractAddress) {
        let shrine = shrine_utils::shrine_deploy(Option::None);
        let eth: ContractAddress = common::eth_token_deploy(token_class);
        let gate: ContractAddress = gate_deploy(eth, shrine, mock_sentinel(), Option::None);
        (shrine, eth, gate)
    }

    fn wbtc_gate_deploy(token_class: Option<ContractClass>) -> (ContractAddress, ContractAddress, ContractAddress) {
        let shrine = shrine_utils::shrine_deploy(Option::None);
        let wbtc: ContractAddress = common::wbtc_token_deploy(token_class);
        let gate: ContractAddress = gate_deploy(wbtc, shrine, mock_sentinel(), Option::None);
        (shrine, wbtc, gate)
    }

    fn add_eth_as_yang(shrine: ContractAddress, eth: ContractAddress) {
        start_prank(CheatTarget::One(shrine), shrine_utils::admin());
        let shrine = IShrineDispatcher { contract_address: shrine };
        shrine
            .add_yang(
                eth,
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                WadZeroable::zero() // initial amount
            );
        shrine.set_debt_ceiling(shrine_utils::DEBT_CEILING.into());
        stop_prank(CheatTarget::One(shrine.contract_address));
    }

    fn add_wbtc_as_yang(shrine: ContractAddress, wbtc: ContractAddress) {
        start_prank(CheatTarget::One(shrine), shrine_utils::admin());
        let shrine = IShrineDispatcher { contract_address: shrine };
        shrine
            .add_yang(
                wbtc,
                shrine_utils::YANG2_THRESHOLD.into(),
                shrine_utils::YANG2_START_PRICE.into(),
                shrine_utils::YANG2_BASE_RATE.into(),
                WadZeroable::zero() // initial amount
            );
        shrine.set_debt_ceiling(shrine_utils::DEBT_CEILING.into());
        stop_prank(CheatTarget::One(shrine.contract_address));
    }

    fn approve_gate_for_token(gate: ContractAddress, token: ContractAddress, user: ContractAddress) {
        // user no-limit approves gate to handle their share of token
        start_prank(CheatTarget::One(token), user);
        IERC20Dispatcher { contract_address: token }.approve(gate, BoundedInt::max());
        stop_prank(CheatTarget::One(token));
    }

    fn rebase(gate: ContractAddress, token: ContractAddress, amount: u128) {
        IMintableDispatcher { contract_address: token }.mint(gate, amount.into());
    }
}
