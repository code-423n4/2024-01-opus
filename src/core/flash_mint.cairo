//
//
//   Flash minting
//
//         |
//        / \
//       / _ \
//      |.o '.|
//      |'._.'|
//      |     |
//    ,'| LFG |`.
//   /  |  |  |  \
//   |,-'--|--'-.|
//
//

#[starknet::contract]
mod flash_mint {
    use opus::interfaces::IFlashBorrower::{IFlashBorrowerDispatcher, IFlashBorrowerDispatcherTrait};
    use opus::interfaces::IFlashMint::IFlashMint;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::utils::reentrancy_guard::reentrancy_guard_component;
    use starknet::{ContractAddress, get_caller_address};
    use wadray::{Wad, WadZeroable};

    // The value of keccak256("ERC3156FlashBorrower.onFlashLoan") as per EIP3156
    // it is supposed to be returned from the onFlashLoan function by the receiver
    const ON_FLASH_MINT_SUCCESS: u256 = 0x439148f0bbc682ca079e46d6e2c2f0c1e3b820f1a291b069d8882abf8cf18dd9_u256;

    // Percentage value of Yin's total supply that can be flash minted (wad)
    const FLASH_MINT_AMOUNT_PCT: u128 = 50000000000000000;
    const FLASH_FEE: u256 = 0;

    component!(path: reentrancy_guard_component, storage: reentrancy_guard, event: ReentrancyGuardEvent);

    impl ReentrancyGuardHelpers = reentrancy_guard_component::ReentrancyGuardHelpers<ContractState>;

    #[storage]
    struct Storage {
        shrine: IShrineDispatcher,
        // components
        #[substorage(v0)]
        reentrancy_guard: reentrancy_guard_component::Storage,
    }


    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        FlashMint: FlashMint,
        // Component events
        ReentrancyGuardEvent: reentrancy_guard_component::Event
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct FlashMint {
        #[key]
        initiator: ContractAddress,
        #[key]
        receiver: ContractAddress,
        token: ContractAddress,
        amount: u256
    }

    #[constructor]
    fn constructor(ref self: ContractState, shrine: ContractAddress) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
    }


    #[abi(embed_v0)]
    impl IFlashMintImpl of IFlashMint<ContractState> {
        //
        // View Functions
        //
        fn max_flash_loan(self: @ContractState, token: ContractAddress) -> u256 {
            let shrine: IShrineDispatcher = self.shrine.read();

            // Can only flash mint our own synthetic
            if token == shrine.contract_address {
                let supply: Wad = shrine.get_total_yin();
                return (supply * FLASH_MINT_AMOUNT_PCT.into()).val.into();
            }

            0_u256
        }

        fn flash_fee(self: @ContractState, token: ContractAddress, amount: u256) -> u256 {
            // as per EIP3156, if a token is not supported, this function must revert
            // and we only support flash minting of our own synthetic
            assert(self.shrine.read().contract_address == token, 'FM: Unsupported token');

            FLASH_FEE
        }

        //
        // External Functions
        //

        fn flash_loan(
            ref self: ContractState,
            receiver: ContractAddress,
            token: ContractAddress,
            amount: u256,
            call_data: Span<felt252>
        ) -> bool {
            // prevents looping which would lead to excessive minting
            // we only allow a FLASH_MINT_AMOUNT_PCT percentage of total
            // yin to be minted, as per spec
            self.reentrancy_guard.start();

            assert(amount <= self.max_flash_loan(token), 'FM: amount exceeds maximum');

            let shrine = self.shrine.read();

            let amount_wad: Wad = amount.try_into().unwrap();

            // temporarily increase the debt ceiling by the loan amount so that
            // flash loans still work when total yin is at or exceeds the debt ceiling
            let ceiling: Wad = shrine.get_debt_ceiling();
            let total_yin: Wad = shrine.get_total_yin();
            let budget_adjustment: Wad = match shrine.get_budget().try_into() {
                Option::Some(surplus) => { surplus },
                Option::None => { WadZeroable::zero() }
            };
            let adjust_ceiling: bool = total_yin + amount_wad + budget_adjustment > ceiling;
            if adjust_ceiling {
                shrine.set_debt_ceiling(total_yin + amount_wad + budget_adjustment);
            }

            shrine.inject(receiver, amount_wad);

            let initiator: ContractAddress = get_caller_address();

            let borrower_resp: u256 = IFlashBorrowerDispatcher { contract_address: receiver }
                .on_flash_loan(initiator, token, amount, FLASH_FEE, call_data);

            assert(borrower_resp == ON_FLASH_MINT_SUCCESS, 'FM: on_flash_loan failed');

            // This function in Shrine takes care of balance validation
            shrine.eject(receiver, amount_wad);

            if adjust_ceiling {
                shrine.set_debt_ceiling(ceiling);
            }

            self.emit(FlashMint { initiator, receiver, token, amount });

            self.reentrancy_guard.end();

            true
        }
    }
}
