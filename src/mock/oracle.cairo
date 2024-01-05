// mock oracle contract for storing token prices
// and advancing shrine on request

use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
trait MockOracle<TContractState> {
    fn set_token_price(ref self: TContractState, token: ContractAddress, price: Wad);
}

#[starknet::contract]
mod mock_oracle {
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use starknet::ContractAddress;
    use wadray::Wad;

    #[storage]
    struct Storage {
        known_tokens: LegacyMap<u8, ContractAddress>,
        known_tokens_count: u8,
        latest_prices: LegacyMap<ContractAddress, Wad>,
        shrine: IShrineDispatcher
    }

    #[constructor]
    fn constructor(ref self: ContractState, shrine: ContractAddress) {
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
    }

    #[abi(embed_v0)]
    impl MockImpl of super::MockOracle<ContractState> {
        fn set_token_price(ref self: ContractState, token: ContractAddress, price: Wad) {
            let mut i = self.known_tokens_count.read();
            loop {
                if i.is_zero() {
                    self.known_tokens_count.write(self.known_tokens_count.read() + 1);
                    self.known_tokens.write(self.known_tokens_count.read(), token);
                    break;
                }
                let known_token = self.known_tokens.read(i);
                if known_token == token {
                    break;
                }

                i -= 1;
            };

            self.latest_prices.write(token, price);
        }
    }

    #[abi(embed_v0)]
    impl OracleImpl of opus::interfaces::IOracle::IOracle<ContractState> {
        fn update_prices(ref self: ContractState) {
            let mut i = self.known_tokens_count.read();
            loop {
                if i.is_zero() {
                    break;
                }
                let token = self.known_tokens.read(i);
                let price = self.latest_prices.read(token);
                self.shrine.read().advance(token, price);
            };
        }
    }
}
