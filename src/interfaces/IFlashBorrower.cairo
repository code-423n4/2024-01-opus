use starknet::ContractAddress;

#[starknet::interface]
trait IFlashBorrower<TContractState> {
    // external
    fn on_flash_loan(
        ref self: TContractState,
        initiator: ContractAddress,
        token: ContractAddress,
        amount: u256,
        fee: u256,
        call_data: Span<felt252>
    ) -> u256;
}
