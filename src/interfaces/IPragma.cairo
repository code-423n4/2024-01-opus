use starknet::ContractAddress;

#[starknet::interface]
trait IPragma<TContractState> {
    fn set_yang_pair_id(ref self: TContractState, yang: ContractAddress, pair_id: felt252);
    fn set_price_validity_thresholds(ref self: TContractState, freshness: u64, sources: u32);
}
