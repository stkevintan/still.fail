#!/bin/bash
# The app and its release variants share mbc's objects only when built by the same compiler. Use Visual Studio's
# clang-cl when installed (faster than cl on the runner), but leave an explicit MBC_REAL_CC and machines without it alone.
if [ -z "${MBC_REAL_CC:-}" ] && [ -n "${llvmX64:-}" ] && [ -f "$(cygpath -u "$llvmX64")/clang-cl.exe" ]; then
  export MBC_REAL_CC="$llvmX64\\clang-cl.exe"
fi
case "${MBC_REAL_CC:-}" in
  *clang-cl|*clang-cl.exe)
    # This may be sourced by the release workflow as well as win.sh when it builds an older, reviewed revision.
    # MoonBit invokes the cl.exe shim with MSVC flags only; clang-cl does not default to MSVC's wrapping signed
    # arithmetic or no-TBAA aliasing (unlike moon on macOS/Linux, which passes -fwrapv -fno-strict-aliasing).
    # Without -fwrapv, wrapping Int arithmetic (e.g. demo/main.mbt's LCG) triggers signed-overflow UB in /O2.
    # MoonBit's runtime also passes int32_t * for DWORD *.
    for f in /clang:-fwrapv /clang:-fno-strict-aliasing /clang:-Wno-error=incompatible-pointer-types; do
      case " ${CL:-} " in
        *" $f "*) ;;
        *) export CL="$f ${CL:-}" ;;
      esac
    done ;;
esac
