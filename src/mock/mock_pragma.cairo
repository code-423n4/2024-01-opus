use opus::types::pragma::PragmaPricesResponse;

// A modified version of `PragmaPricesResponse` struct that drops `expiration_timestamp`, 
// which is an `Option`. Otherwise, trying to write `expiration_timestamp` to storage 
// when its value is `Option::None` causes the value of `price` to be zero.
#[derive(Copy, Drop, Serde, starknet::Store)]
struct PragmaPricesResponseWrapper {
    price: u128,
    decimals: u32,
    last_updated_timestamp: u64,
    num_sources_aggregated: u32,
}

#[starknet::interface]
trait IMockPragma<TContractState> {
    // Note that `get_data_median()` is part of `IPragmaOracleDispatcher`
    fn next_get_data_median(ref self: TContractState, pair_id: felt252, price_response: PragmaPricesResponse);
}

#[starknet::contract]
mod mock_pragma {
    use opus::interfaces::external::IPragmaOracle;
    use opus::types::pragma::{DataType, PragmaPricesResponse};
    use super::{IMockPragma, PragmaPricesResponseWrapper};

    #[storage]
    struct Storage {
        // Mapping from pair ID to price response data struct
        price_response: LegacyMap::<felt252, PragmaPricesResponseWrapper>,
    }

    #[abi(embed_v0)]
    impl IMockPragmaImpl of IMockPragma<ContractState> {
        fn next_get_data_median(ref self: ContractState, pair_id: felt252, price_response: PragmaPricesResponse) {
            self
                .price_response
                .write(
                    pair_id,
                    PragmaPricesResponseWrapper {
                        price: price_response.price,
                        decimals: price_response.decimals,
                        last_updated_timestamp: price_response.last_updated_timestamp,
                        num_sources_aggregated: price_response.num_sources_aggregated,
                    }
                );
        }
    }

    #[abi(embed_v0)]
    impl IPragmaOracleImpl of IPragmaOracle<ContractState> {
        fn get_data_median(self: @ContractState, data_type: DataType) -> PragmaPricesResponse {
            match data_type {
                DataType::SpotEntry(pair_id) => {
                    let wrapper: PragmaPricesResponseWrapper = self.price_response.read(pair_id);

                    PragmaPricesResponse {
                        price: wrapper.price,
                        decimals: wrapper.decimals,
                        last_updated_timestamp: wrapper.last_updated_timestamp,
                        num_sources_aggregated: wrapper.num_sources_aggregated,
                        expiration_timestamp: Option::None,
                    }
                },
                DataType::FutureEntry(_) => { panic_with_felt252('only spot') },
                DataType::GenericEntry(_) => { panic_with_felt252('only spot') },
            }
        }
    }
}
