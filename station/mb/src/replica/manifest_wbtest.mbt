///|
fn make_hex(prefix : String, fill : Char) -> String {
  prefix + String::make(64 - prefix.length(), fill)
}

///|
test "encode_transcript_manifest: empty set canonical JSON and roundtrip" {
  let enc = encode_transcript_manifest([])
  assert_eq(@utf8.decode(enc.root_bytes[:]), "{\"v\":1,\"buckets\":{}}")
  assert_eq(enc.buckets.length(), 0)
  assert_eq(enc.leaves.length(), 0)
  let budget = Ref(0)
  let parsed = parse_root_manifest(enc.root_bytes, enc.root_hash, budget)
  assert_eq(parsed.length(), 0)
  assert_eq(budget.val, enc.root_bytes.length())
}

///|
test "encode_transcript_manifest: 256-bucket sorting and canonical leaf formatting" {
  let h_ff_2 = make_hex("ff", '2')
  let h_ff_1 = make_hex("ff", '1')
  let h_00_b = make_hex("00", 'b')
  let h_00_a = make_hex("00", 'a')
  let h_7a_0 = make_hex("7a", '0')
  let enc = encode_transcript_manifest([
    (h_ff_2, 200.0),
    (h_00_b, 42.0),
    (h_7a_0, 0.0),
    (h_ff_1, 100.0),
    (h_00_a, 10.0),
  ])
  assert_eq(enc.buckets.map(b => b.0), ["00", "7a", "ff"])
  assert_eq(enc.leaves.length(), 3)
  let leaf00 = enc.leaves[0]
  assert_eq(leaf00.0, "00")
  assert_eq(@utf8.decode(leaf00.2[:]), "{\"v\":1,\"files\":{\"" + h_00_a + "\":10,\"" + h_00_b + "\":42}}")
  let budget_b = Ref(0)
  let budget_e = Ref(0)
  let root = parse_root_manifest(enc.root_bytes, enc.root_hash, budget_b)
  assert_eq(root.length(), 3)
  for leaf in enc.leaves {
    let parsed = parse_leaf_manifest(leaf.2, leaf.1, leaf.0, budget_b, budget_e)
    assert_true(parsed.length() >= 1)
  }
  assert_eq(budget_e.val, 5)
}

///|
test "parse_root_manifest & parse_leaf_manifest: adversarial inputs rejected" {
  let h_0a = make_hex("0a", '1')
  let h_0b = make_hex("0b", '2')
  let leaf_ok = @utf8.encode("{\"v\":1,\"files\":{\"" + h_0a + "\":123}}")
  let leaf_ok_hash = @hash.sha256_hex(leaf_ok[:])

  // 1. Tampered sha256
  let tampered_hash = make_hex("ff", 'f')
  assert_true(
    (try {
      ignore(parse_leaf_manifest(leaf_ok, tampered_hash, "0a", Ref(0), Ref(0)))
      false
    } catch {
      _ => true
    }),
  )

  // 2. Wrong version v=2
  let bad_v = @utf8.encode("{\"v\":2,\"buckets\":{}}")
  let bad_v_h = @hash.sha256_hex(bad_v[:])
  assert_true(
    (try {
      ignore(parse_root_manifest(bad_v, bad_v_h, Ref(0)))
      false
    } catch {
      _ => true
    }),
  )

  // 3. Extra top-level key
  let extra_k = @utf8.encode("{\"v\":1,\"buckets\":{},\"extra\":1}")
  let extra_k_h = @hash.sha256_hex(extra_k[:])
  assert_true(
    (try {
      ignore(parse_root_manifest(extra_k, extra_k_h, Ref(0)))
      false
    } catch {
      _ => true
    }),
  )

  // 4. Duplicate JSON key (top-level and nested, including \u0076 escape)
  let dup_top = @utf8.encode("{\"v\":1,\"\\u0076\":1,\"buckets\":{}}")
  let dup_top_h = @hash.sha256_hex(dup_top[:])
  assert_true(
    (try {
      ignore(parse_root_manifest(dup_top, dup_top_h, Ref(0)))
      false
    } catch {
      _ => true
    }),
  )
  let dup_nested = @utf8.encode("{\"v\":1,\"files\":{\"" + h_0a + "\":1,\"" + h_0a + "\":2}}")
  let dup_nested_h = @hash.sha256_hex(dup_nested[:])
  assert_true(
    (try {
      ignore(parse_leaf_manifest(dup_nested, dup_nested_h, "0a", Ref(0), Ref(0)))
      false
    } catch {
      _ => true
    }),
  )

  // 5. Invalid bucket key ("0G", "0", "000")
  for bad_b in ["0G", "0", "000"] {
    let raw = @utf8.encode("{\"v\":1,\"buckets\":{\"" + bad_b + "\":\"" + leaf_ok_hash + "\"}}")
    let rh = @hash.sha256_hex(raw[:])
    assert_true(
      (try {
        ignore(parse_root_manifest(raw, rh, Ref(0)))
        false
      } catch {
        _ => true
      }),
    )
  }

  // 6. Bucket prefix mismatch (chunk starts with 0b inside bucket 0a)
  let mismatch = @utf8.encode("{\"v\":1,\"files\":{\"" + h_0b + "\":10}}")
  let mismatch_h = @hash.sha256_hex(mismatch[:])
  assert_true(
    (try {
      ignore(parse_leaf_manifest(mismatch, mismatch_h, "0a", Ref(0), Ref(0)))
      false
    } catch {
      _ => true
    }),
  )

  // 7. Invalid compSize (negative, -0, fractional, scientific, > MAX_SAFE_INTEGER, leading zero)
  for bad_sz in ["-1", "-0", "1.5", "1.0", "1e0", "1E2", "01", "9007199254740992", "99999999999999999999"] {
    let raw = @utf8.encode("{\"v\":1,\"files\":{\"" + h_0a + "\":" + bad_sz + "}}")
    let rh = @hash.sha256_hex(raw[:])
    assert_true(
      (try {
        ignore(parse_leaf_manifest(raw, rh, "0a", Ref(0), Ref(0)))
        false
      } catch {
        _ => true
      }),
    )
  }

  // 7b. Encoder rejects -0.0 (parity with TS) and accepts 0.0 and MAX_SAFE_INTEGER
  let neg_zero = -0.0
  assert_true(
    (try {
      ignore(encode_transcript_manifest([(h_0a, neg_zero)]))
      false
    } catch {
      _ => true
    }),
  )
  let max_safe_enc = encode_transcript_manifest([(h_0a, 9007199254740991.0)])
  let max_safe_leaf = max_safe_enc.leaves[0]
  let max_safe_parsed = parse_leaf_manifest(max_safe_leaf.2, max_safe_leaf.1, max_safe_leaf.0, Ref(0), Ref(0))
  assert_eq(max_safe_parsed.length(), 1)
  assert_eq(max_safe_parsed[0].1, 9007199254740991.0)

  // 8. Budget bombs: byte cap (>64 MiB) & entry cap (>500,000, enforced during JSON parse)
  assert_true(
    (try {
      ignore(parse_leaf_manifest(leaf_ok, leaf_ok_hash, "0a", Ref(manifest_max_bytes), Ref(0)))
      false
    } catch {
      _ => true
    }),
  )
  assert_true(
    (try {
      ignore(parse_leaf_manifest(leaf_ok, leaf_ok_hash, "0a", Ref(0), Ref(manifest_max_entries)))
      false
    } catch {
      _ => true
    }),
  )
  // 2 entries when only 1 entry remains in budget -> rejected during parse
  let h_0a_2 = make_hex("0a", '2')
  let two_entries = @utf8.encode("{\"v\":1,\"files\":{\"" + h_0a + "\":1,\"" + h_0a_2 + "\":2}}")
  let two_entries_h = @hash.sha256_hex(two_entries[:])
  assert_true(
    (try {
      ignore(parse_leaf_manifest(two_entries, two_entries_h, "0a", Ref(0), Ref(manifest_max_entries - 1)))
      false
    } catch {
      _ => true
    }),
  )
}
