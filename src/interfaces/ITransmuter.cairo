use starknet::ContractAddress;
use wadray::{Ray, Wad};

#[starknet::interface]
trait ITransmuter<TContractState> {
    // getters
    fn get_asset(self: @TContractState) -> ContractAddress;
    fn get_total_transmuted(self: @TContractState) -> Wad;
    fn get_ceiling(self: @TContractState) -> Wad;
    fn get_percentage_cap(self: @TContractState) -> Ray;
    fn get_receiver(self: @TContractState) -> ContractAddress;
    fn get_reversibility(self: @TContractState) -> bool;
    fn get_transmute_fee(self: @TContractState) -> Ray;
    fn get_reverse_fee(self: @TContractState) -> Ray;
    fn get_live(self: @TContractState) -> bool;
    fn get_reclaimable(self: @TContractState) -> bool;
    // setters
    fn set_ceiling(ref self: TContractState, ceiling: Wad);
    fn set_percentage_cap(ref self: TContractState, cap: Ray);
    fn set_receiver(ref self: TContractState, receiver: ContractAddress);
    fn toggle_reversibility(ref self: TContractState);
    fn set_transmute_fee(ref self: TContractState, fee: Ray);
    fn set_reverse_fee(ref self: TContractState, fee: Ray);
    fn enable_reclaim(ref self: TContractState);
    // core functions
    fn preview_transmute(self: @TContractState, asset_amt: u128) -> Wad;
    fn preview_reverse(self: @TContractState, yin_amt: Wad) -> u128;
    fn transmute(ref self: TContractState, asset_amt: u128);
    fn reverse(ref self: TContractState, yin_amt: Wad);
    fn sweep(ref self: TContractState, asset_amt: u128);
    // isolated deprecation
    fn settle(ref self: TContractState);
    // global shutdown
    fn kill(ref self: TContractState);
    fn preview_reclaim(self: @TContractState, yin: Wad) -> u128;
    fn reclaim(ref self: TContractState, yin: Wad);
}

#[starknet::interface]
trait ITransmuterRegistry<TContractState> {
    // getters
    fn get_transmuters(self: @TContractState) -> Span<ContractAddress>;
    // setters
    fn add_transmuter(ref self: TContractState, transmuter: ContractAddress);
    fn remove_transmuter(ref self: TContractState, transmuter: ContractAddress);
}
