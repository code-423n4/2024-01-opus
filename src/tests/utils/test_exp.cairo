mod test_exp {
    use opus::tests::common::assert_equalish;
    use opus::utils::exp::exp;
    use wadray::{WAD_ONE, WAD_PERCENT, Wad};


    // Acceptable error for e^x where x <= 20. Corresponds to 0.000000000001 (10^-12) precision
    const ACCEPTABLE_ERROR: u128 = 1000000;

    #[test]
    fn test_exp_basic() {
        // Basic tests
        assert(exp(Wad { val: 0 }) == Wad { val: WAD_ONE }, 'Incorrect e^0 result');
        assert(exp(Wad { val: WAD_ONE }) == Wad { val: 2718281828459045235 }, 'Incorrect e^1 result');

        let res = exp(Wad { val: WAD_PERCENT * 2 });
        assert_equalish(
            res, Wad { val: 1020201340026755810 }, ACCEPTABLE_ERROR.into(), 'exp-test: error exceeds bounds'
        );

        let res = exp(Wad { val: WAD_ONE * 10 });
        assert_equalish(
            res, Wad { val: 22026465794806716516957 }, ACCEPTABLE_ERROR.into(), 'exp-test: error exceeds bounds'
        );

        let res = exp(Wad { val: WAD_ONE * 20 });
        assert_equalish(
            res, Wad { val: 485165195409790277969106830 }, ACCEPTABLE_ERROR.into(), 'exp-test: error exceeds bounds'
        );

        // Highest possible value the function will accept
        exp(Wad { val: 42600000000000000000 });
    }

    #[test]
    fn test_exp_add() {
        // Exponent law: e^x * e^y = e^(x + y)
        let a: Wad = exp(Wad { val: WAD_ONE });
        let a: Wad = a * a;

        let b: Wad = exp(Wad { val: 2 * WAD_ONE });

        //e^1 * e^1 = e^2
        assert_equalish(a, b, ACCEPTABLE_ERROR.into(), 'exp-test: error exceeds bounds');
    }

    #[test]
    fn test_exp_sub() {
        //Exponent law: e^x / e^y = e^(x - y)
        let a: Wad = exp(Wad { val: 8 * WAD_ONE });
        let b: Wad = exp(Wad { val: 3 * WAD_ONE });
        let c: Wad = exp(Wad { val: 5 * WAD_ONE });

        assert_equalish(a / b, c, ACCEPTABLE_ERROR.into(), 'exp-test: error exceeds bounds');
    }


    #[test]
    #[should_panic(expected: ('exp: x is out of bounds',))]
    fn test_exp_fail() {
        let _ = exp(Wad { val: 42600000000000000001 });
    }
}
