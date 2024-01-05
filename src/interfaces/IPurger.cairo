use opus::types::AssetBalance;
use starknet::ContractAddress;
use wadray::{Ray, Wad};

#[starknet::interface]
trait IPurger<TContractState> {
    // view
    fn preview_liquidate(self: @TContractState, trove_id: u64) -> Option<(Ray, Wad)>;
    fn preview_absorb(self: @TContractState, trove_id: u64) -> Option<(Ray, Wad, Wad)>;
    fn is_absorbable(self: @TContractState, trove_id: u64) -> bool;
    fn get_penalty_scalar(self: @TContractState) -> Ray;
    // external
    fn set_penalty_scalar(ref self: TContractState, new_scalar: Ray);
    fn liquidate(ref self: TContractState, trove_id: u64, amt: Wad, recipient: ContractAddress) -> Span<AssetBalance>;
    fn absorb(ref self: TContractState, trove_id: u64) -> Span<AssetBalance>;
}
