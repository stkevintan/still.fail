# mbui platform host, message delivery, and Android allocator (for agents)

## Adding a host call

- Add the field to `Host` (and its default in `Host::noop()`, or `Option` + `Host::<method>` self-dispatch if derived from other primitives) plus the package-level forwarder in `libs/ui/src/hostapi/host.mbt`.
- Wire the platform side in `make_native_host` (`libs/ui/src/host/native_host.mbt`), and add the `FakeHost` method + wire it in `FakeHost::as_host` (`libs/ui/src/ui/fake_host.mbt`) if tests need non-default behavior.
- Regenerate the Wasm side of `extern "C"` declarations (`*_wasm.mbt` and `libs/ui/src/host/wasm_shell.c`) via `libs/ui/tools/wasmhost` (run `apps/mbui/scripts/wasm-app.sh build`, verified by `check`).

## Between-frame delivery

- Deliver external host posts (`mb_post`, `MB_OUTSIDE_POSTED`, `messages_between`) and system picker results (`MB_OUTSIDE_PICK`, `outside_take`) between frames so signal-only updates land before frame start and are not delayed until a full rebuild.
- `FakeHost` delivers posts at their exact clock timestamp between frames in order so all frame rates behave identically (`tester_host_wbtest`). Verified across hosts by `libs/ui/scripts/host_contract.sh` (`linux posted`, `linux picked`) and `libs/ui/test/web/posted.test.mjs`.
- Any tree update received during a frame must draw in that same frame (`view_owes`).
- Synchronous test/replay cores deliver through `answered_from_outside`, deferring answers requested inside a computed getter until `@signals.after_computing` (`libs/ui/src/ui/answered_in_read_wbtest.mbt`).
- An in-process core running its own fiber loop hands work to frames via `@ui.on_frame_take` and `@ui.wake_frame` (coalescing to one frame, taken once at frame start, `libs/ui/src/ui/frame_take_wbtest.mbt`), never via host posts or timers.

## The Android app's allocator

- MoonBit's runtime on Android links mimalloc 2.1.7 from source into `libmbui.so` (`libs/ui/scripts/android.sh`: `MOONBIT_ALLOCATOR_MIMALLOC`, `mimalloc_obj`), without overriding system `malloc` (leaving scudo for the rest of the process).
- Compile through `libs/ui/src/host/mimalloc_android.c`, which undefines `SYS_*` so mimalloc calls libc instead of raw `syscall()` (Android seccomp kills raw `access`).
- Measured on 349 KB `chat` JSON parse/free (median ms): mimalloc is ~2.6-3x faster than scudo on device and emulator. Accepted trade-offs: no scudo hardening/MTE for MoonBit heap, ~145 KB app / ~56 KB APK size, and retained free memory. Do not revert without re-measuring.
- Every Android C translation unit (including the Wasm shell) must use matching allocator `CFLAGS` (`mbc check`), or freeing across allocators corrupts memory. iOS stays on the system allocator until CI builds it with mimalloc.
