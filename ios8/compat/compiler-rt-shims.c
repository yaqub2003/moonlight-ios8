//
// Builtins normally provided by Xcode's compiler-rt (libclang_rt.ios.a),
// which isn't part of the stock LLVM toolchain used for the iOS 8 build.
// (libSystem on iOS provides most other compiler-rt routines itself.)
//

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// OpenSSL calls __atomic_is_lock_free() at runtime on 32-bit ARM. The
// function name clashes with the compiler builtin, so it's defined via an
// assembler label. ARMv7 has exclusive load/store instructions for 1, 2, 4
// and (with LDREXD/STREXD, given 8-byte alignment) 8 byte objects.
bool ml_atomic_is_lock_free(size_t size, const volatile void *ptr) __asm__("___atomic_is_lock_free");

bool ml_atomic_is_lock_free(size_t size, const volatile void *ptr)
{
    uintptr_t address = (uintptr_t)ptr;

    switch (size) {
    case 1:
        return true;
    case 2:
    case 4:
    case 8:
        return (address & (size - 1)) == 0;
    default:
        return false;
    }
}
