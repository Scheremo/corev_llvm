# Reproducible LLVM, picolibc, and bare-metal runtime build flow for the
# CORE-V XCV porting workspace. This intentionally excludes xcvhwlp and xcvelw.

SHELL := /bin/zsh

ROOT := $(CURDIR)
BUILD_ROOT ?= $(ROOT)
LLVM_SRC := $(ROOT)/llvm-project/llvm
PICOLIBC_SRC := $(ROOT)/picolibc

LLVM_BUILD_DIR ?= $(ROOT)/build-llvm-riscv
LLVM_RUNTIMES_BUILD_DIR ?= $(ROOT)/build-llvm-riscv-runtimes
PICOLIBC_BUILD_DIR ?= $(ROOT)/build-picolibc-riscv
LLVM_VERSION_MAJOR ?= 23

JOBS ?= 8
TMP ?= /private/tmp

ABI := ilp32
COREV_SDK_TRIPLE := riscv32-corev-elf
COREV_SDK_CLANG_LIB_TRIPLE := riscv32-corev-unknown-elf
COREV_SDK_MULTILIBS ?= \
	rv32im_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32 \
	rv32imc_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32 \
	rv32imf_zicsr_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32f \
	rv32imfc_zicsr_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32f \
	rv32im_zicsr_zfinx_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32 \
	rv32imc_zicsr_zfinx_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32
COREV_SDK_LLVM_MULTILIB := $(firstword $(COREV_SDK_MULTILIBS))
COREV_SDK_ARCH := $(word 1,$(subst /, ,$(COREV_SDK_LLVM_MULTILIB)))
COREV_SDK_ABI := $(word 2,$(subst /, ,$(COREV_SDK_LLVM_MULTILIB)))
COREV_SDK_MULTILIB_TARGET_NAMES := $(subst /,_,$(COREV_SDK_MULTILIBS))
COREV_SDK_RUNTIME_TARGETS := $(addprefix install-llvm-runtime-,$(COREV_SDK_MULTILIB_TARGET_NAMES))
LLVM_MULTILIB_STAMP_DIR ?= $(BUILD_ROOT)/llvm-runtimes-multilib-stamps
LLVM_MULTILIB_STAMPS := $(addprefix $(LLVM_MULTILIB_STAMP_DIR)/,$(addsuffix .stamp,$(COREV_SDK_MULTILIB_TARGET_NAMES)))
PICOLIBC_SYSROOT ?= $(LLVM_BUILD_DIR)/picolibc/$(COREV_SDK_TRIPLE)
PICOLIBC_CROSS_FILE ?= $(ROOT)/build-picolibc-corev-llvm.cross

LLVM_TOOLS := clang lld llvm-ar llvm-ranlib llvm-objcopy llvm-objdump llvm-nm llvm-strip llc llvm-mc FileCheck
LLVM_CLANG := $(LLVM_BUILD_DIR)/bin/clang
LLVM_CLANGXX := $(LLVM_BUILD_DIR)/bin/clang++
LLVM_LLC := $(LLVM_BUILD_DIR)/bin/llc
LLVM_MC := $(LLVM_BUILD_DIR)/bin/llvm-mc

.PHONY: all build build-llvm sanity sanity-llvm versions \
	build-llvm-runtimes install-llvm-runtimes install-llvm-runtimes-one sanity-llvm-runtimes \
	print-llvm-multilibs $(COREV_SDK_RUNTIME_TARGETS) \
	ci-llvm-toolchain \
	build-picolibc install-picolibc sanity-picolibc \
	clean-sanity clean-llvm-build clean-llvm-runtimes-build

all: build sanity

build: build-llvm

build-llvm: $(LLVM_BUILD_DIR)/.corev-configured
	cmake --build $(LLVM_BUILD_DIR) --target $(LLVM_TOOLS) --parallel $(JOBS)

$(LLVM_BUILD_DIR)/.corev-configured: Makefile
	cmake -G Ninja -S $(LLVM_SRC) -B $(LLVM_BUILD_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DLLVM_ENABLE_PROJECTS='clang;lld' \
		-DLLVM_TARGETS_TO_BUILD=RISCV \
		-DLLVM_INCLUDE_TESTS=ON \
		-DCLANG_INCLUDE_TESTS=ON \
		-DLLVM_ENABLE_ASSERTIONS=ON \
		-DLLVM_ENABLE_ZSTD=OFF
	touch $@

print-llvm-multilibs:
	@printf '%s\n' $(COREV_SDK_MULTILIBS)

build-llvm-runtimes: $(LLVM_RUNTIMES_BUILD_DIR)/.corev-configured
	cmake --build $(LLVM_RUNTIMES_BUILD_DIR) --parallel $(JOBS)

install-llvm-runtimes: $(LLVM_MULTILIB_STAMPS)

define COREV_LLVM_RUNTIME_TARGET
$(LLVM_MULTILIB_STAMP_DIR)/$(subst /,_,$(1)).stamp: Makefile build-llvm
	mkdir -p $(LLVM_MULTILIB_STAMP_DIR)
	$$(MAKE) install-llvm-runtimes-one \
		COREV_SDK_LLVM_MULTILIB=$(1) \
		PICOLIBC_CROSS_FILE=$(BUILD_ROOT)/build-picolibc-corev-llvm-$(subst /,_,$(1)).cross \
		PICOLIBC_BUILD_DIR=$(BUILD_ROOT)/build-picolibc-riscv-$(subst /,_,$(1)) \
		LLVM_RUNTIMES_BUILD_DIR=$(BUILD_ROOT)/build-llvm-riscv-runtimes-$(subst /,_,$(1))
	touch $$@

install-llvm-runtime-$(subst /,_,$(1)): $(LLVM_MULTILIB_STAMP_DIR)/$(subst /,_,$(1)).stamp
endef

$(foreach multilib,$(COREV_SDK_MULTILIBS),$(eval $(call COREV_LLVM_RUNTIME_TARGET,$(multilib))))

install-llvm-runtimes-one: build-llvm-runtimes
	cmake --build $(LLVM_RUNTIMES_BUILD_DIR) --target install --parallel $(JOBS)
	mkdir -p $(LLVM_BUILD_DIR)/lib/clang/$(LLVM_VERSION_MAJOR)/lib/$(COREV_SDK_CLANG_LIB_TRIPLE)
	cp $(LLVM_BUILD_DIR)/lib/generic/libclang_rt.builtins-riscv32.a \
		$(LLVM_BUILD_DIR)/lib/clang/$(LLVM_VERSION_MAJOR)/lib/$(COREV_SDK_CLANG_LIB_TRIPLE)/libclang_rt.builtins.a
	mkdir -p $(LLVM_BUILD_DIR)/lib/$(COREV_SDK_LLVM_MULTILIB)
	cp $(LLVM_BUILD_DIR)/lib/libc++.a \
		$(LLVM_BUILD_DIR)/lib/libc++abi.a \
		$(LLVM_BUILD_DIR)/lib/libunwind.a \
		$(LLVM_BUILD_DIR)/lib/clang/$(LLVM_VERSION_MAJOR)/lib/$(COREV_SDK_CLANG_LIB_TRIPLE)/libclang_rt.builtins.a \
		$(LLVM_BUILD_DIR)/lib/$(COREV_SDK_LLVM_MULTILIB)/

$(PICOLIBC_CROSS_FILE): Makefile build-llvm
	mkdir -p $(PICOLIBC_BUILD_DIR)
	printf '%s\n' \
		'[binaries]' \
		"c = ['$(LLVM_CLANG)', '--target=$(COREV_SDK_TRIPLE)', '-march=$(COREV_SDK_ARCH)', '-mabi=$(COREV_SDK_ABI)', '-nostdlib', '-ffreestanding']" \
		"ar = '$(LLVM_BUILD_DIR)/bin/llvm-ar'" \
		"as = ['$(LLVM_CLANG)', '--target=$(COREV_SDK_TRIPLE)', '-march=$(COREV_SDK_ARCH)', '-mabi=$(COREV_SDK_ABI)']" \
		"ld = '$(LLVM_BUILD_DIR)/bin/ld.lld'" \
		"c_ld = '$(LLVM_BUILD_DIR)/bin/ld.lld'" \
		"nm = '$(LLVM_BUILD_DIR)/bin/llvm-nm'" \
		"strip = '$(LLVM_BUILD_DIR)/bin/llvm-strip'" \
		'' \
		'[host_machine]' \
		"system = 'none'" \
		"cpu_family = 'riscv32'" \
		"cpu = 'riscv'" \
		"endian = 'little'" \
		'' \
		'[properties]' \
		"skip_sanity_check = true" \
		"has_link_defsym = true" \
		"target_c_args = ['-march=$(COREV_SDK_ARCH)', '-mabi=$(COREV_SDK_ABI)', '-ffreestanding', '-fno-builtin']" \
		"c_link_args = ['-Wl,-m,elf32lriscv']" \
		> $@

build-picolibc: $(PICOLIBC_BUILD_DIR)/.corev-configured
	meson compile -C $(PICOLIBC_BUILD_DIR) -j $(JOBS)

install-picolibc: build-picolibc
	meson install -C $(PICOLIBC_BUILD_DIR)

$(PICOLIBC_BUILD_DIR)/.corev-configured: Makefile $(PICOLIBC_CROSS_FILE)
	meson setup $(PICOLIBC_BUILD_DIR) $(PICOLIBC_SRC) --wipe \
		--cross-file $(PICOLIBC_CROSS_FILE) \
		--prefix=$(PICOLIBC_SYSROOT) \
		-Dincludedir=include \
		-Dlibdir=lib/$(COREV_SDK_LLVM_MULTILIB) \
		-Dmultilib=false \
		-Dtests=false \
		-Dpicocrt=false \
		-Dsemihost=false \
		-Dspecsdir=none \
		-Dthread-local-storage=false \
		-Dnewlib-global-errno=true \
		-Dsingle-thread=true \
		-Dformat-default=integer \
		-Dio-long-long=true
	touch $@

$(LLVM_RUNTIMES_BUILD_DIR)/.corev-configured: Makefile build-llvm install-picolibc
	cmake -G Ninja -S $(ROOT)/llvm-project/runtimes -B $(LLVM_RUNTIMES_BUILD_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=$(LLVM_BUILD_DIR) \
		-DCMAKE_C_COMPILER=$(LLVM_CLANG) \
		-DCMAKE_CXX_COMPILER=$(LLVM_CLANGXX) \
		-DCMAKE_ASM_COMPILER=$(LLVM_CLANG) \
		-DCMAKE_AR=$(LLVM_BUILD_DIR)/bin/llvm-ar \
		-DCMAKE_RANLIB=$(LLVM_BUILD_DIR)/bin/llvm-ranlib \
		-DCMAKE_OBJCOPY=$(LLVM_BUILD_DIR)/bin/llvm-objcopy \
		-DCMAKE_SYSTEM_NAME=Generic \
		-DCMAKE_SYSTEM_PROCESSOR=riscv32 \
		-DCMAKE_C_COMPILER_TARGET=$(COREV_SDK_TRIPLE) \
		-DCMAKE_CXX_COMPILER_TARGET=$(COREV_SDK_TRIPLE) \
		-DCMAKE_ASM_COMPILER_TARGET=$(COREV_SDK_TRIPLE) \
		-DCMAKE_SYSROOT=$(PICOLIBC_SYSROOT) \
		-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
		-DCMAKE_C_FLAGS='-march=$(COREV_SDK_ARCH) -mabi=$(COREV_SDK_ABI)' \
		-DCMAKE_CXX_FLAGS='-march=$(COREV_SDK_ARCH) -mabi=$(COREV_SDK_ABI)' \
		-DCMAKE_ASM_FLAGS='-march=$(COREV_SDK_ARCH) -mabi=$(COREV_SDK_ABI)' \
		-DCMAKE_EXE_LINKER_FLAGS='-fuse-ld=lld --rtlib=compiler-rt -L$(PICOLIBC_SYSROOT)/lib/$(COREV_SDK_LLVM_MULTILIB)' \
		-DLLVM_DEFAULT_TARGET_TRIPLE=$(COREV_SDK_TRIPLE) \
		-DLLVM_ENABLE_RUNTIMES='compiler-rt;libunwind;libcxxabi;libcxx' \
		-DLLVM_INCLUDE_TESTS=OFF \
		-DRUNTIMES_USE_LIBC=picolibc \
		-DCOMPILER_RT_BUILD_BUILTINS=ON \
		-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
		-DCOMPILER_RT_BAREMETAL_BUILD=ON \
		-DCOMPILER_RT_BUILD_SANITIZERS=OFF \
		-DCOMPILER_RT_BUILD_XRAY=OFF \
		-DCOMPILER_RT_BUILD_PROFILE=OFF \
		-DCOMPILER_RT_BUILD_MEMPROF=OFF \
		-DCOMPILER_RT_BUILD_ORC=OFF \
		-DLIBUNWIND_IS_BAREMETAL=ON \
		-DLIBUNWIND_ENABLE_SHARED=OFF \
		-DLIBUNWIND_ENABLE_THREADS=OFF \
		-DLIBUNWIND_ENABLE_EXCEPTIONS=OFF \
		-DLIBUNWIND_USE_COMPILER_RT=ON \
		-DLIBUNWIND_SHARED_OUTPUT_NAME=unwind_shared \
		-DLIBCXXABI_BAREMETAL=ON \
		-DLIBCXXABI_ENABLE_SHARED=OFF \
		-DLIBCXXABI_ENABLE_THREADS=OFF \
		-DLIBCXXABI_ENABLE_EXCEPTIONS=OFF \
		-DLIBCXXABI_USE_LLVM_UNWINDER=ON \
		-DLIBCXXABI_USE_COMPILER_RT=ON \
		-DLIBCXXABI_SHARED_OUTPUT_NAME=c++abi_shared \
		-DLIBCXX_ENABLE_SHARED=OFF \
		-DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON \
		-DLIBCXX_ENABLE_THREADS=OFF \
		-DLIBCXX_ENABLE_MONOTONIC_CLOCK=OFF \
		-DLIBCXX_ENABLE_FILESYSTEM=OFF \
		-DLIBCXX_ENABLE_RANDOM_DEVICE=OFF \
		-DLIBCXX_ENABLE_LOCALIZATION=OFF \
		-DLIBCXX_ENABLE_WIDE_CHARACTERS=OFF \
		-DLIBCXX_USE_COMPILER_RT=ON \
		-DLIBCXX_SHARED_OUTPUT_NAME=c++_shared
	touch $@

versions: build
	$(LLVM_CLANG) --version
	$(LLVM_LLC) --version | sed -n '1,8p'

sanity: sanity-llvm

$(TMP)/corev-sanity-llvm-alu.c:
	printf '%s\n' \
		'#include <riscv_corev_alu.h>' \
		'int f(int x) {' \
		'  return __riscv_cv_alu_clip(x, 3);' \
		'}' > $@

sanity-llvm: build-llvm $(TMP)/corev-sanity-llvm-alu.c
	$(LLVM_CLANG) --target=riscv32-unknown-elf -march=rv32i_xcvalu \
		-mabi=$(ABI) -O2 -S $(TMP)/corev-sanity-llvm-alu.c \
		-o $(TMP)/llvm-clang-alu.s
	$(LLVM_LLC) -O0 -mtriple=riscv32 -mattr=+m,+xcvalu \
		-verify-machineinstrs $(ROOT)/llvm-project/llvm/test/CodeGen/RISCV/xcvalu.ll \
		-o $(TMP)/llvm-xcvalu.s
	$(LLVM_LLC) -mtriple=riscv32 -mattr=+m,+xcvmac \
		-verify-machineinstrs $(ROOT)/llvm-project/llvm/test/CodeGen/RISCV/xcvmac.ll \
		-o $(TMP)/llvm-xcvmac.s
	$(LLVM_LLC) -O3 -mtriple=riscv32 -mattr=+xcvbitmanip \
		-verify-machineinstrs $(ROOT)/llvm-project/llvm/test/CodeGen/RISCV/xcvbitmanip.ll \
		-o $(TMP)/llvm-xcvbitmanip.s
	$(LLVM_LLC) -O3 -mtriple=riscv32 -mattr=+xcvbi \
		-verify-machineinstrs $(ROOT)/llvm-project/llvm/test/CodeGen/RISCV/xcvbi.ll \
		-o $(TMP)/llvm-xcvbi.s
	$(LLVM_LLC) -O3 -mtriple=riscv32 -mattr=+xcvmem \
		-verify-machineinstrs $(ROOT)/llvm-project/llvm/test/CodeGen/RISCV/xcvmem.ll \
		-o $(TMP)/llvm-xcvmem.s
	$(LLVM_MC) -triple=riscv32 --mattr=+xcvsimd -show-encoding \
		$(ROOT)/llvm-project/llvm/test/MC/RISCV/corev/XCVsimd.s \
		-o $(TMP)/llvm-xcvsimd-mc.s
	printf 'cv.add.h t0, t1, t2\ncv.mac a2, a0, a1\ncv.extract a0, a0, 2, 1\ncv.bneimm a0, 7, label\nlabel:\ncv.lw t0, (t1), 4\n' | \
		$(LLVM_MC) -triple=riscv32 \
		-mattr=+xcvsimd,+xcvmac,+xcvbitmanip,+xcvbi,+xcvmem \
		-show-encoding
	rg -n 'cv\.' $(TMP)/llvm-clang-alu.s $(TMP)/llvm-xcvalu.s \
		$(TMP)/llvm-xcvmac.s $(TMP)/llvm-xcvbitmanip.s \
		$(TMP)/llvm-xcvbi.s $(TMP)/llvm-xcvmem.s $(TMP)/llvm-xcvsimd-mc.s

sanity-llvm-runtimes: install-llvm-runtimes
	test -f $(LLVM_BUILD_DIR)/lib/clang/$(LLVM_VERSION_MAJOR)/lib/$(COREV_SDK_CLANG_LIB_TRIPLE)/libclang_rt.builtins.a
	for multilib in $(COREV_SDK_MULTILIBS); do \
		test -f $(LLVM_BUILD_DIR)/lib/$$multilib/libc++.a; \
		test -f $(LLVM_BUILD_DIR)/lib/$$multilib/libclang_rt.builtins.a; \
	done
	printf '%s\n' \
		'#include <array>' \
		'std::array<int, 2> f() { return {1, 2}; }' \
		'int main() { return f()[0] - 1; }' > $(TMP)/corev-libcxx-sanity.cpp
	for multilib in $(COREV_SDK_MULTILIBS); do \
		arch=$${multilib%%/*}; \
		abi=$${multilib##*/}; \
		$(LLVM_CLANGXX) --target=$(COREV_SDK_TRIPLE) --sysroot=$(PICOLIBC_SYSROOT) \
			-march=$$arch -mabi=$$abi -stdlib=libc++ \
			-fuse-ld=$(LLVM_BUILD_DIR)/bin/ld.lld --rtlib=compiler-rt \
			-L$(LLVM_BUILD_DIR)/lib/$$multilib \
			$(TMP)/corev-libcxx-sanity.cpp -c -o $(TMP)/corev-libcxx-sanity-$${arch}-$${abi}.o; \
	done

ci-llvm-toolchain: build-llvm sanity-llvm sanity-llvm-runtimes

clean-sanity:
	rm -f $(TMP)/llvm-clang-alu.s $(TMP)/llvm-xcvalu.s \
		$(TMP)/llvm-xcvmac.s $(TMP)/llvm-xcvbitmanip.s \
		$(TMP)/llvm-xcvbi.s $(TMP)/llvm-xcvmem.s $(TMP)/llvm-xcvsimd-mc.s \
		$(TMP)/corev-sanity-llvm-alu.c

clean-llvm-build:
	rm -rf $(LLVM_BUILD_DIR)

clean-llvm-runtimes-build:
	rm -rf $(LLVM_RUNTIMES_BUILD_DIR)
	rm -rf $(LLVM_MULTILIB_STAMP_DIR)
	rm -rf $(BUILD_ROOT)/build-llvm-riscv-runtimes-*
	rm -rf $(BUILD_ROOT)/build-picolibc-riscv-*
	rm -f $(BUILD_ROOT)/build-picolibc-corev-llvm-*.cross
