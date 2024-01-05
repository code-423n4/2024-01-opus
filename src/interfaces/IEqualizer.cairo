use starknet::ContractAddress;
use wadray::Wad;

#[starknet::interface]
trait IEqualizer<TContractState> {
    // getter
    fn get_allocator(self: @TContractState) -> ContractAddress;
    // external
    fn set_allocator(ref self: TContractState, allocator: ContractAddress);
    fn allocate(ref self: TContractState);
    fn equalize(ref self: TContractState) -> Wad;
    fn normalize(ref self: TContractState, yin_amt: Wad) -> Wad;
}
