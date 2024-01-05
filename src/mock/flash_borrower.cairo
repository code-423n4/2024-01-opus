#[starknet::contract]
mod flash_borrower {
    use opus::core::flash_mint::flash_mint::ON_FLASH_MINT_SUCCESS;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IFlashBorrower::IFlashBorrower;
    use opus::interfaces::IFlashMint::{IFlashMintDispatcher, IFlashMintDispatcherTrait};
    use starknet::{contract_address_const, get_contract_address, ContractAddress};

    const VALID_USAGE: felt252 = 0;
    const ATTEMPT_TO_STEAL: felt252 = 1;
    const ATTEMPT_TO_REENTER: felt252 = 2;

    #[storage]
    struct Storage {
        flashmint: IFlashMintDispatcher,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        FlashLoancall_dataReceived: FlashLoancall_dataReceived,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct FlashLoancall_dataReceived {
        initiator: ContractAddress,
        token: ContractAddress,
        amount: u256,
        fee: u256,
        call_data: Span<felt252>
    }

    #[constructor]
    fn constructor(ref self: ContractState, flashmint: ContractAddress) {
        self.flashmint.write(IFlashMintDispatcher { contract_address: flashmint });
    }

    #[abi(embed_v0)]
    impl IFlashBorrowerImpl of IFlashBorrower<ContractState> {
        fn on_flash_loan(
            ref self: ContractState,
            initiator: ContractAddress,
            token: ContractAddress,
            amount: u256,
            fee: u256,
            mut call_data: Span<felt252>
        ) -> u256 {
            let call_data_copy = call_data;

            let should_return_correct: bool = *call_data.pop_front().unwrap() != 0;
            let action: felt252 = *call_data.pop_front().unwrap();

            if action == VALID_USAGE {
                assert(
                    IERC20Dispatcher { contract_address: token }.balance_of(get_contract_address()) == amount,
                    'FB: incorrect loan amount'
                );
            } else if action == ATTEMPT_TO_STEAL {
                IERC20Dispatcher { contract_address: token }.transfer(contract_address_const::<0xbeef>(), amount);
            } else if action == ATTEMPT_TO_REENTER {
                self.flashmint.read().flash_loan(initiator, token, amount, call_data_copy);
            }

            // Emit event so tests can check that the function arguments are correct
            self
                .emit(
                    FlashLoancall_dataReceived {
                        initiator: initiator, token: token, amount: amount, fee: fee, call_data: call_data_copy
                    }
                );

            if should_return_correct {
                ON_FLASH_MINT_SUCCESS
            } else {
                0xbadbeef_u256
            }
        }
    }
}
