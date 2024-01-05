use integer::u256_sqrt;
use math::Oneable;
use wadray::{Ray, u128_rdiv, u128_rmul, Wad, WAD_DECIMALS};


fn sqrt(x: Ray) -> Ray {
    let scaled_val: u256 = x.val.into() * wadray::RAY_SCALE.into();
    u256_sqrt(scaled_val).into()
}

fn pow<T, impl TMul: Mul<T>, impl TOneable: Oneable<T>, impl TDrop: Drop<T>, impl TCopy: Copy<T>>(
    x: T, mut n: u8
) -> T {
    if n == 0 {
        TOneable::one()
    } else if n == 1 {
        x
    } else if n % 2 == 0 {
        pow(x * x, n / 2)
    } else {
        x * pow(x * x, (n - 1) / 2)
    }
}

fn fixed_point_to_wad(n: u128, decimals: u8) -> Wad {
    assert(decimals <= WAD_DECIMALS, 'More than 18 decimals');
    let scale: u128 = pow(10_u128, WAD_DECIMALS - decimals);
    (n * scale).into()
}

fn wad_to_fixed_point(n: Wad, decimals: u8) -> u128 {
    assert(decimals <= WAD_DECIMALS, 'More than 18 decimals');
    let scale: u128 = pow(10_u128, WAD_DECIMALS - decimals);
    n.val / scale
}

#[inline(always)]
fn scale_u128_by_ray(lhs: u128, rhs: Ray) -> u128 {
    u128_rmul(lhs, rhs.val)
}

#[inline(always)]
fn div_u128_by_ray(lhs: u128, rhs: Ray) -> u128 {
    u128_rdiv(lhs, rhs.val)
}
