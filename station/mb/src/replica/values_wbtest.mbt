///|
test "set_all is set of each pair in turn" {
  let n = fn(x : Double) -> JValue { Num(x) }
  let cases : Array[(JValue, Array[(String, JValue)])] = [
    (Obj([("a", n(1)), ("b", n(2)), ("a", n(3)), ("c", n(4))]), [("a", n(9)), ("d", n(5)), ("c", n(8))]),
    (Obj([]), [("x", n(1)), ("y", n(2))]),
    (Null, [("x", n(1))]),
    (Null, []),
    (Obj([("a", n(1))]), []),
  ]
  for c in cases {
    let mut one = c.0
    for p in c.1 {
      one = set(one, p.0, p.1)
    }
    assert_eq(stringify(set_all(c.0, c.1)), stringify(one))
  }
}
