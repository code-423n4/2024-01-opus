use starknet::ContractAddress;

#[starknet::interface]
trait IFlashMint<TContractState> {
    // external
    fn flash_loan(
        ref self: TContractState,
        receiver: ContractAddress,
        token: ContractAddress,
        amount: u256,
        call_data: Span<felt252>
    ) -> bool;
    // view
    fn max_flash_loan(self: @TContractState, token: ContractAddress) -> u256;
    fn flash_fee(self: @TContractState, token: ContractAddress, amount: u256) -> u256;
}
