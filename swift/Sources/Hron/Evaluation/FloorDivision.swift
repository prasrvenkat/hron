func floorDivide<T: BinaryInteger>(_ a: T, _ b: T) -> T {
  let quotient = a / b
  return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
}

func floorModulo<T: BinaryInteger>(_ a: T, _ b: T) -> T {
  a - floorDivide(a, b) * b
}
