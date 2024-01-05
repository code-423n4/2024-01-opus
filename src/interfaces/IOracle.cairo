use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
trait IOracle<TContractState> {
    // human readable identifier
    fn get_name(self: @TContractState) -> felt252;

    fn get_oracle(self: @TContractState) -> ContractAddress;

    // has to be ref self to allow emitting events from the function
    fn fetch_price(ref self: TContractState, yang: ContractAddress, force_update: bool) -> Result<Wad, felt252>;
}
