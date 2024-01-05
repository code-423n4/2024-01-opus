mod types;

mod core {
    mod abbot;
    mod absorber;
    mod allocator;
    mod caretaker;
    mod controller;
    mod equalizer;
    mod flash_mint;
    mod gate;
    mod purger;
    mod roles;
    mod seer;
    mod sentinel;
    mod shrine;
    mod transmuter;
    mod transmuter_registry;
}

mod external {
    mod pragma;
}

mod interfaces {
    mod IAbbot;
    mod IAbsorber;
    mod IAllocator;
    mod ICaretaker;
    mod IController;
    mod IERC20;
    mod IEqualizer;
    mod IFlashBorrower;
    mod IFlashMint;
    mod IGate;
    mod IOracle;
    mod IPragma;
    mod IPurger;
    mod ISRC5;
    mod ISeer;
    mod ISentinel;
    mod IShrine;
    mod ITransmuter;
    mod external;
}

mod utils {
    mod address_registry;
    mod exp;
    mod math;
    mod reentrancy_guard;
}

// mock used for local devnet deployment
mod mock {
    mod blesser;
    mod erc20;
    mod erc20_mintable;
    mod flash_borrower;
    mod flash_liquidator;
    mod mock_pragma;
//mod oracle;
}

#[cfg(test)]
mod tests {
    mod common;
    mod test_types;
    mod abbot {
        mod test_abbot;
        mod utils;
    }
    mod absorber {
        mod test_absorber;
        mod utils;
    }
    mod caretaker {
        mod test_caretaker;
        mod utils;
    }
    mod controller {
        mod test_controller;
        mod utils;
    }
    mod equalizer {
        mod test_allocator;
        mod test_equalizer;
        mod utils;
    }
    mod external {
        mod test_pragma;
        mod utils;
    }
    mod flash_mint {
        mod test_flash_mint;
        mod utils;
    }
    mod gate {
        mod test_gate;
        mod utils;
    }
    mod purger {
        mod test_purger;
        mod utils;
    }
    mod sentinel {
        mod test_sentinel;
        mod utils;
    }
    mod seer {
        mod test_seer;
        mod utils;
    }
    mod shrine {
        mod test_shrine;
        mod test_shrine_compound;
        mod test_shrine_redistribution;
        mod utils;
    }
    mod transmuter {
        mod test_transmuter;
        mod test_transmuter_registry;
        mod utils;
    }
    mod utils {
        mod mock_address_registry;
        mod mock_reentrancy_guard;
        mod test_address_registry;
        mod test_exp;
        mod test_math;
        mod test_reentrancy_guard;
    }
}
