// Real MoonBit pilot slice transpiled LIVE by `mbt2pion --mode publish`
// during `run_pilot.sh` (zero hand-editing of generated `.pion` output!),
// AND compiled directly by `moon build --target wasm-gc` in `moon_pilot`.

// 1. Value-returning `guard` false branch (aligned to `controls/player_parts.mbt:435`)
pub fn film_facts_guard(w : Double, h : Double) -> String {
  guard w > 0.0 && h > 0.0 else { "" }
  "ok"
}

// 2. Top-level indirect forward `let` (scalar + heap `Array[String]`, preventing SIGSEGV 139)
//    plus `fn init` scheduled into `00_init_order.pion`.
pub let init_log : Array[String] = []
pub let fwd_scalar : Int = read_base_scalar() + 1
pub let base_scalar : Int = 42
pub let fwd_heap : Array[String] = read_base_heap()
pub let base_heap : Array[String] = ["alpha", "beta"]

fn read_base_scalar() -> Int {
  base_scalar
}

fn read_base_heap() -> Array[String] {
  [base_heap[0], base_heap[1]]
}

fn init {
  init_log.push("init_ran:" + fwd_scalar.to_string() + ":" + fwd_heap[0] + ":" + fwd_heap[1])
}

// 3. Optional-parameter forwarding `relay(x?) -> tally(x?)` with lazy side-effect default
let default_eval_count : Array[Int] = [0]
let eval_order_log : Array[String] = []

pub fn reset_opt_logs() -> Unit {
  default_eval_count[0] = 0
  eval_order_log.clear()
}

pub fn get_default_eval_count() -> Int {
  default_eval_count[0]
}

pub fn get_eval_order_log() -> String {
  let mut out = ""
  for i = 0; i < eval_order_log.length(); i = i + 1 {
    if i > 0 {
      out = out + ","
    }
    out = out + eval_order_log[i]
  }
  out
}

fn compute_lazy_default() -> Int {
  default_eval_count[0] = default_eval_count[0] + 1
  eval_order_log.push("default")
  17
}

pub fn record_arg(tag : String, v : Int) -> Int {
  eval_order_log.push(tag)
  v
}

pub fn tally(base : Int, x? : Int = compute_lazy_default()) -> Int {
  base + x
}

pub fn relay(base : Int, x? : Int) -> Int {
  tally(base, x?)
}

// 4. Two distinct `#callsite(autofill(loc))` `SourceLoc` callsites (must never collapse)
#callsite(autofill(loc))
pub fn audit_fault_loc(loc~ : SourceLoc) -> String {
  loc.to_string()
}

pub fn audit_fault_pair() -> (String, String) {
  let first = audit_fault_loc()
  let second = audit_fault_loc()
  (first, second)
}
