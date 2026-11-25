// Tests for Ed25519 verification, release feed parsing, delta selection, and host integration.

///|
test "ed25519 rfc8032 test vectors" {
  // RFC 8032 Section 7.1 Test 1 (empty message)
  let pk1 = @codec.from_hex(
    "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
  )
  let sig1 = @codec.from_hex(
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155" +
    "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
  )
  assert_true(@updater.verify_ed25519(pk1, b"", sig1))

  // RFC 8032 Section 7.1 Test 2 (1-byte message 0x72)
  let pk2 = @codec.from_hex(
    "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
  )
  let sig2 = @codec.from_hex(
    "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da" +
    "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
  )
  assert_true(@updater.verify_ed25519(pk2, b"\x72", sig2))

  // RFC 8032 Section 7.1 Test 3 (2-byte message 0xaf82)
  let pk3 = @codec.from_hex(
    "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
  )
  let sig3 = @codec.from_hex(
    "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac" +
    "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
  )
  assert_true(@updater.verify_ed25519(pk3, b"\xaf\x82", sig3))

  // Negative cases: tampered message, tampered signature, wrong key, S >= L
  assert_false(@updater.verify_ed25519(pk1, b"x", sig1))
  assert_false(@updater.verify_ed25519(pk2, b"\x72", sig1))
  assert_false(@updater.verify_ed25519(pk1, b"\x72", sig2))
  let bad_sig = Bytes::makei(64, fn(i) {
    if i == 10 {
      (sig3[i].to_int() ^ 1).to_byte()
    } else {
      sig3[i]
    }
  })
  assert_false(@updater.verify_ed25519(pk3, b"\xaf\x82", bad_sig))
  let bad_s = Bytes::makei(64, fn(i) {
    if i >= 32 {
      b'\xff'
    } else {
      sig1[i]
    }
  })
  assert_false(@updater.verify_ed25519(pk1, b"", bad_s))
  assert_false(@updater.verify_ed25519(b"short", b"", sig1))
  assert_false(@updater.verify_ed25519(pk1, b"", b"short"))
}

///|
test "key_id matches sha256 prefix" {
  let pk = @codec.from_hex(
    "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
  )
  let kid = @updater.key_id(pk)
  assert_eq(kid.length(), 16)
  assert_true(@zip.sha256(pk).has_prefix(kid))
}

///|
test "resolve_url handles slashes" {
  assert_eq(
    @updater.resolve_url("https://dl.example.com/releases/", "/app-1.zip"),
    "https://dl.example.com/releases/app-1.zip",
  )
  assert_eq(
    @updater.resolve_url("https://dl.example.com/releases", "app-1.zip"),
    "https://dl.example.com/releases/app-1.zip",
  )
  assert_eq(@updater.resolve_url("", "app-1.zip"), "app-1.zip")
}

///|
test "parse_feed and pick_delta_json" {
  let sha_full = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let sha_raw = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let sha_signed_raw = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  let sha_delta = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  let json =
    #|{
    #|  "version": "1.2.3",
    #|  "versionCode": 42,
    #|  "file": "builds/app-42.zip",
    #|  "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    #|  "size": 10000,
    #|  "raw": {
    #|    "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    #|    "size": 20000
    #|  },
    #|  "deltas": [
    #|    { "from": 40, "file": "deltas/40-to-42.delta", "sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", "size": 12000 },
    #|    { "from": 41, "file": "../escape.delta", "sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", "size": 500 },
    #|    { "from": 41, "file": "deltas/41-to-42.delta", "sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", "size": 1500 }
    #|  ]
    #|}
  let feed = match @updater.parse_feed(json) {
    Ok(f) => f
    Err(e) => fail("unexpected error: \{e}")
  }
  assert_eq(feed.version, "1.2.3")
  assert_eq(feed.version_code, 42)
  assert_eq(feed.sha256, sha_full)
  assert_eq(feed.size, 10000L)
  // Build 40 delta is larger than full size -> skipped
  assert_eq(@updater.pick_delta_json(feed, 40, "https://cdn.example.com/"), "")
  // Build 41 skips ../escape.delta and picks valid delta using feed.raw
  let got = @updater.pick_delta_json(feed, 41, "https://cdn.example.com/")
  assert_eq(
    got,
    "{\"url\":\"https://cdn.example.com/deltas/41-to-42.delta\",\"sha256\":\"" +
    sha_delta +
    "\",\"size\":1500,\"makes_sha256\":\"" +
    sha_raw +
    "\",\"makes_size\":20000}",
  )
  // Signed raw overrides unsigned feed.raw
  let got_signed = @updater.pick_delta_json(
    feed,
    41,
    "https://cdn.example.com",
    signed_raw=Some({ sha256: sha_signed_raw, size: 25000L }),
    use_signed_raw=true,
  )
  assert_eq(
    got_signed,
    "{\"url\":\"https://cdn.example.com/deltas/41-to-42.delta\",\"sha256\":\"" +
    sha_delta +
    "\",\"size\":1500,\"makes_sha256\":\"" +
    sha_signed_raw +
    "\",\"makes_size\":25000}",
  )
  // use_signed_raw=true with signed_raw=None refuses delta
  assert_eq(
    @updater.pick_delta_json(
      feed,
      41,
      "https://cdn.example.com",
      signed_raw=None,
      use_signed_raw=true,
    ),
    "",
  )
  // Reject path traversal in feed.file
  let bad_feed =
    #|{"version":"1.0.0","versionCode":2,"file":"../evil.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":100}
  assert_true(@updater.parse_feed(bad_feed) is Err(_))
}

///|
test "parse_update_state covers all phases" {
  assert_true(@updater.parse_update_state("").phase == Idle)
  assert_true(
    @updater.parse_update_state("{\"phase\":\"waiting\",\"percent\":0}").phase ==
    Waiting,
  )
  let dl = @updater.parse_update_state(
    "{\"phase\":\"downloading\",\"percent\":45,\"error\":\"\",\"file\":\"app-42.zip\"}",
  )
  assert_true(dl.phase == Downloading)
  assert_eq(dl.percent, 45)
  assert_eq(dl.file, "app-42.zip")
  assert_true(
    @updater.parse_update_state("{\"phase\":\"retrying\",\"percent\":45}").phase ==
    Retrying,
  )
  assert_true(
    @updater.parse_update_state("{\"phase\":\"ready\",\"percent\":100}").phase ==
    Ready,
  )
  assert_true(
    @updater.parse_update_state("{\"phase\":\"allow\",\"percent\":100}").phase ==
    Asking,
  )
  assert_true(
    @updater.parse_update_state("{\"phase\":\"asking\",\"percent\":100}").phase ==
    Asking,
  )
  assert_true(
    @updater.parse_update_state("{\"phase\":\"installing\",\"percent\":100}").phase ==
    Installing,
  )
  let failed = @updater.parse_update_state(
    "{\"phase\":\"failed\",\"percent\":-1,\"error\":\"network error\",\"file\":\"app-42.zip\"}",
  )
  assert_true(failed.phase == Failed)
  assert_eq(failed.error, "network error")
}

///|
priv struct FakeUpdateHost {
  ver : Int
  state_json : String
  mut fetch_calls : Int
  mut last_url : String
  mut last_sha : String
  mut last_size : Double
  mut last_name : String
  mut last_now : Bool
  mut last_delta : String
  mut applied_note : String
}

///|
fn FakeUpdateHost::as_host(self : FakeUpdateHost) -> @hostapi.Host {
  {
    ..@hostapi.Host::noop(),
    app_version: fn() { self.ver },
    update_state: fn() { self.state_json },
    update_fetch: fn(url, sha256, size, name, now, delta) {
      self.fetch_calls += 1
      self.last_url = url
      self.last_sha = sha256
      self.last_size = size
      self.last_name = name
      self.last_now = now
      self.last_delta = delta
    },
    update_apply: fn(note) { self.applied_note = note },
  }
}

///|
test "check_and_fetch host integration and signature gating" {
  let prev = @hostapi.host()
  let fake : FakeUpdateHost = {
    ver: 41,
    state_json: "{\"phase\":\"ready\",\"percent\":100,\"error\":\"\",\"file\":\"app-42.zip\"}",
    fetch_calls: 0,
    last_url: "",
    last_sha: "",
    last_size: 0.0,
    last_name: "",
    last_now: false,
    last_delta: "",
    applied_note: "",
  }
  @hostapi.set_host(fake.as_host())

  assert_true(@updater.status().phase == Ready)
  @updater.apply(note="updated")
  assert_eq(fake.applied_note, "updated")

  let feed_json =
    #|{
    #|  "version": "1.2.3",
    #|  "versionCode": 42,
    #|  "file": "builds/app-42.zip",
    #|  "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    #|  "size": 10000,
    #|  "deltas": [
    #|    { "from": 41, "file": "deltas/41-42.delta", "sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", "size": 1200 }
    #|  ]
    #|}

  // Up to date -> returns Ok(false) and does not call update_fetch
  match @updater.check_and_fetch(feed_json, "https://dl.example.com", current_build=42) {
    Ok(false) => ()
    _ => fail("expected Ok(false)")
  }
  assert_eq(fake.fetch_calls, 0)

  // Public keys provided but feed unsigned -> returns Err and MUST NOT call update_fetch
  let pk1_b64 = @codec.base64(
    @codec.from_hex(
      "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
    ),
  )
  match @updater.check_and_fetch(feed_json, "https://dl.example.com", public_keys=[pk1_b64]) {
    Err(_) => ()
    Ok(_) => fail("expected Err for unsigned feed")
  }
  assert_eq(fake.fetch_calls, 0)

  // Unsigned mode (public_keys=[]) with newer build -> calls update_fetch with expected args
  match @updater.check_and_fetch(feed_json, "https://dl.example.com/", now=true) {
    Ok(true) => ()
    _ => fail("expected Ok(true)")
  }
  assert_eq(fake.fetch_calls, 1)
  assert_eq(fake.last_url, "https://dl.example.com/builds/app-42.zip")
  assert_eq(
    fake.last_sha,
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  assert_eq(fake.last_size, 10000.0)
  assert_eq(fake.last_name, "app-42.zip")
  assert_true(fake.last_now)
  assert_true(fake.last_delta.contains("deltas/41-42.delta"))

  @hostapi.set_host(prev)
}

///|
test "signed feed produced by release tool verifies and selects signed raw delta" {
  // Generated by `libs/ui/scripts/release keygen` + `release feed`
  let pubkey_b64 = "61TERTnHCC53faHwTu8rBrtzwx2F0qLlQmFJE83/EaE="
  let signed_feed_json =
    #|{
    #|  "version": "1.2.0",
    #|  "versionCode": 2,
    #|  "file": "app-v2.zip",
    #|  "sha256": "890550dcf7f04a5a637c1c23ef3adfca98766cdb03fd5fb54fe3893addf0ee61",
    #|  "size": 129448,
    #|  "raw": {
    #|    "sha256": "890550dcf7f04a5a637c1c23ef3adfca98766cdb03fd5fb54fe3893addf0ee61",
    #|    "size": 129448
    #|  },
    #|  "deltas": [
    #|    {
    #|      "from": 1,
    #|      "file": "1-to-2.delta",
    #|      "sha256": "56983c5d2de2ba405ee2e3777e9be31d933d7362728ca86b6219c43c51ae5168",
    #|      "size": 1585
    #|    }
    #|  ],
    #|  "signed": {
    #|    "key": "1b4c62a060554cc7",
    #|    "release": "eyJraW5kIjoiZGVza3RvcC1tYWMiLCJ2ZXJzaW9uIjoiMS4yLjAiLCJidWlsZCI6MiwiZmlsZSI6ImFwcC12Mi56aXAiLCJzaGEyNTYiOiI4OTA1NTBkY2Y3ZjA0YTVhNjM3YzFjMjNlZjNhZGZjYTk4NzY2Y2RiMDNmZDVmYjU0ZmUzODkzYWRkZjBlZTYxIiwic2l6ZSI6MTI5NDQ4LCJyYXciOnsic2hhMjU2IjoiODkwNTUwZGNmN2YwNGE1YTYzN2MxYzIzZWYzYWRmY2E5ODc2NmNkYjAzZmQ1ZmI1NGZlMzg5M2FkZGYwZWU2MSIsInNpemUiOjEyOTQ0OH19",
    #|    "signature": "NwbGj0FxAjo0WOcsAi1zgeFzByR9bt8HnooyEkNJGhtwhETe0+CO9gNPQII9xe2bAeyCIA+F++kv8R74Xwi+Dw=="
    #|  }
    #|}
  let feed = match @updater.parse_feed(signed_feed_json) {
    Ok(f) => f
    Err(e) => fail("parse_feed failed: \{e}")
  }
  let signed_raw = match @updater.verify_feed(
    feed,
    [pubkey_b64],
    expected_kind="desktop-mac",
  ) {
    Ok(r) => r
    Err(e) => fail("verify_feed failed: \{e}")
  }
  assert_true(signed_raw is Some(_))
  // Wrong kind must fail verification
  assert_true(
    @updater.verify_feed(feed, [pubkey_b64], expected_kind="desktop-win")
    is Err(_),
  )
  // Full check_and_fetch with signature verification enabled
  let prev = @hostapi.host()
  let fake : FakeUpdateHost = {
    ver: 1,
    state_json: "",
    fetch_calls: 0,
    last_url: "",
    last_sha: "",
    last_size: 0.0,
    last_name: "",
    last_now: false,
    last_delta: "",
    applied_note: "",
  }
  @hostapi.set_host(fake.as_host())
  match @updater.check_and_fetch(
    signed_feed_json,
    "https://releases.example.com/mac",
    public_keys=[pubkey_b64],
    expected_kind="desktop-mac",
  ) {
    Ok(true) => ()
    _ => fail("expected Ok(true) for verified signed feed")
  }
  assert_eq(fake.fetch_calls, 1)
  assert_eq(fake.last_url, "https://releases.example.com/mac/app-v2.zip")
  assert_eq(fake.last_name, "app-v2.zip")
  assert_eq(
    fake.last_delta,
    "{\"url\":\"https://releases.example.com/mac/1-to-2.delta\",\"sha256\":\"56983c5d2de2ba405ee2e3777e9be31d933d7362728ca86b6219c43c51ae5168\",\"size\":1585,\"makes_sha256\":\"890550dcf7f04a5a637c1c23ef3adfca98766cdb03fd5fb54fe3893addf0ee61\",\"makes_size\":129448}",
  )
  @hostapi.set_host(prev)
}
