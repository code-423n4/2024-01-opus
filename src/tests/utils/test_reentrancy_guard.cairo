mod tests {
    use opus::tests::utils::mock_reentrancy_guard::{IMockReentrancyGuard, mock_reentrancy_guard};
    use opus::utils::reentrancy_guard::reentrancy_guard_component::{ReentrancyGuardHelpers};
    use opus::utils::reentrancy_guard::reentrancy_guard_component;

    fn state() -> mock_reentrancy_guard::ContractState {
        mock_reentrancy_guard::contract_state_for_testing()
    }

    #[test]
    fn test_reentrancy_guard_pass() {
        let mut state = state();

        // It should be possible to call the guarded function multiple times in succession.
        state.guarded_func(false);
        state.guarded_func(false);
        state.guarded_func(false);
    }

    #[test]
    #[should_panic(expected: ('RG: reentrant call',))]
    fn test_reentrancy_guard_fail() {
        let mut state = state();
        // Calling the guarded function from inside itself should fail.
        state.guarded_func(true);
    }
}
