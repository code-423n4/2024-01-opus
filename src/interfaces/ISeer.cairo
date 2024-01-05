use starknet::ContractAddress;

#[starknet::interface]
trait ISeer<TContractState> {
    fn get_oracles(self: @TContractState) -> Span<ContractAddress>;
    fn get_update_frequency(self: @TContractState) -> u64;
    fn set_oracles(ref self: TContractState, oracles: Span<ContractAddress>);
    fn set_update_frequency(ref self: TContractState, new_frequency: u64);
    fn update_prices(ref self: TContractState);
}
