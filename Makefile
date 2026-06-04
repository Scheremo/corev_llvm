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
LLVM_TARGETS_TO_BUILD ?= host;RISCV
PACKAGE_NAME ?= llvm-corev-toolchain
PACKAGE_STAGE ?= $(BUILD_ROOT)/package/$(PACKAGE_NAME)
PACKAGE_ARCHIVE ?= $(BUILD_ROOT)/artifacts/$(PACKAGE_NAME).tar.gz

JOBS ?= 8
LLVM_PARALLEL_LINK_JOBS ?= 1
TMP ?= /private/tmp

ABI := ilp32
COREV_SDK_TRIPLE := riscv32-corev-elf
COREV_SDK_CLANG_LIB_TRIPLE := riscv32-corev-unknown-elf
COREV_SDK_RUNTIME_TRIPLE := riscv32-unknown-elf
COREV_SDK_RUNTIME_CLANG_LIB_TRIPLE := riscv32-unknown-unknown-elf
COREV_SDK_GENERIC_MULTILIBS ?= \
	rv32i/ilp32 \
	rv32im/ilp32 \
	rv32iac/ilp32 \
	rv32imac/ilp32 \
	rv32if/ilp32f \
	rv32ifd/ilp32d \
	rv32g/ilp32d \
	rv32imafc/ilp32f \
	rv32imafdc/ilp32d
COREV_SDK_GENERIC_MULTILIB_ALIASES ?= \
	rv32ic/ilp32:rv32i/ilp32 \
	rv32imc/ilp32:rv32im/ilp32 \
	rv32imac_zicsr_zifencei/ilp32:rv32imac/ilp32 \
	rv32ifc/ilp32f:rv32if/ilp32f \
	rv32ifdc/ilp32d:rv32ifd/ilp32d \
	rv32imafdc/ilp32f:rv32imafc/ilp32f \
	rv32gc/ilp32f:rv32imafc/ilp32f \
	rv32gc/ilp32d:rv32imafdc/ilp32d \
	rv32imf_zicsr_zifencei_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32f:rv32imf_zicsr_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32f \
	rv32imfc_zicsr_zifencei_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32f:rv32imfc_zicsr_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32f
COREV_SDK_COREV_MULTILIBS ?= \
	rv32im_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32 \
	rv32imc_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32 \
	rv32imf_zicsr_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32f \
	rv32imfc_zicsr_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32f \
	rv32im_zicsr_zfinx_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32 \
	rv32imc_zicsr_zfinx_xcvalu_xcvbi_xcvbitmanip_xcvmac_xcvmem_xcvsimd/ilp32
COREV_SDK_MULTILIBS ?= $(COREV_SDK_GENERIC_MULTILIBS) $(COREV_SDK_COREV_MULTILIBS)
COREV_SDK_LLVM_MULTILIB := $(firstword $(COREV_SDK_MULTILIBS))
COREV_SDK_ARCH := $(word 1,$(subst /, ,$(COREV_SDK_LLVM_MULTILIB)))
COREV_SDK_ABI := $(word 2,$(subst /, ,$(COREV_SDK_LLVM_MULTILIB)))
COREV_SDK_MULTILIB_TARGET_NAMES := $(subst /,_,$(COREV_SDK_MULTILIBS))
COREV_SDK_RUNTIME_TARGETS := $(addprefix install-llvm-runtime-,$(COREV_SDK_MULTILIB_TARGET_NAMES))
LLVM_MULTILIB_STAMP_DIR ?= $(BUILD_ROOT)/llvm-runtimes-multilib-stamps
LLVM_MULTILIB_STAMPS := $(addprefix $(LLVM_MULTILIB_STAMP_DIR)/,$(addsuffix .stamp,$(COREV_SDK_MULTILIB_TARGET_NAMES)))
CLANG_RUNTIMES_ROOT ?= $(LLVM_BUILD_DIR)/lib/clang-runtimes
COREV_SDK_RUNTIME_SYSROOT ?= $(CLANG_RUNTIMES_ROOT)/$(COREV_SDK_RUNTIME_TRIPLE)/$(COREV_SDK_LLVM_MULTILIB)
PICOLIBC_SYSROOT ?= $(COREV_SDK_RUNTIME_SYSROOT)
PICOLIBC_CROSS_FILE ?= $(ROOT)/build-picolibc-corev-llvm.cross

LLVM_TOOLS := clang lld llvm-ar llvm-ranlib llvm-objcopy llvm-objdump llvm-readobj llvm-nm llvm-size llvm-strip llc llvm-mc FileCheck
LLVM_CLANG := $(LLVM_BUILD_DIR)/bin/clang
LLVM_CLANGXX := $(LLVM_BUILD_DIR)/bin/clang++
LLVM_LLC := $(LLVM_BUILD_DIR)/bin/llc
LLVM_MC := $(LLVM_BUILD_DIR)/bin/llvm-mc

.PHONY: all build build-llvm sanity sanity-llvm versions \
	build-llvm-runtimes install-llvm-runtimes install-llvm-runtimes-one install-llvm-multilib-yaml sanity-llvm-runtimes \
	print-llvm-multilibs $(COREV_SDK_RUNTIME_TARGETS) \
	ci-llvm-toolchain \
	package-llvm-toolchain package-stage-llvm-toolchain sanity-package-llvm-toolchain \
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
		-DLLVM_TARGETS_TO_BUILD='$(LLVM_TARGETS_TO_BUILD)' \
		-DLLVM_INCLUDE_TESTS=ON \
		-DCLANG_INCLUDE_TESTS=ON \
		-DLLVM_ENABLE_ASSERTIONS=ON \
		-DLLVM_ENABLE_ZSTD=OFF \
		-DLLVM_PARALLEL_LINK_JOBS=$(LLVM_PARALLEL_LINK_JOBS)
	touch $@

print-llvm-multilibs:
	@printf '%s\n' $(COREV_SDK_MULTILIBS)

build-llvm-runtimes: $(LLVM_RUNTIMES_BUILD_DIR)/.corev-configured
	cmake --build $(LLVM_RUNTIMES_BUILD_DIR) --parallel $(JOBS)

install-llvm-runtimes: $(LLVM_MULTILIB_STAMPS) install-llvm-multilib-yaml

define COREV_LLVM_RUNTIME_TARGET
$(LLVM_MULTILIB_STAMP_DIR)/$(subst /,_,$(1)).stamp: Makefile build-llvm install-llvm-multilib-yaml
	mkdir -p $(LLVM_MULTILIB_STAMP_DIR)
	$$(MAKE) install-llvm-runtimes-one \
		COREV_SDK_LLVM_MULTILIB=$(1) \
		PICOLIBC_CROSS_FILE=$(BUILD_ROOT)/build-picolibc-corev-llvm-$(subst /,_,$(1)).cross \
		PICOLIBC_BUILD_DIR=$(BUILD_ROOT)/build-picolibc-riscv-$(subst /,_,$(1)) \
		COREV_SDK_RUNTIME_SYSROOT=$(CLANG_RUNTIMES_ROOT)/$(COREV_SDK_RUNTIME_TRIPLE)/$(1) \
		LLVM_RUNTIMES_BUILD_DIR=$(BUILD_ROOT)/build-llvm-riscv-runtimes-$(subst /,_,$(1))
	touch $$@

install-llvm-runtime-$(subst /,_,$(1)): $(LLVM_MULTILIB_STAMP_DIR)/$(subst /,_,$(1)).stamp
endef

$(foreach multilib,$(COREV_SDK_MULTILIBS),$(eval $(call COREV_LLVM_RUNTIME_TARGET,$(multilib))))

install-llvm-runtimes-one: build-llvm-runtimes
	cmake --build $(LLVM_RUNTIMES_BUILD_DIR) --target install --parallel $(JOBS)
	mkdir -p $(LLVM_BUILD_DIR)/lib/clang/$(LLVM_VERSION_MAJOR)/lib/$(COREV_SDK_CLANG_LIB_TRIPLE)
	mkdir -p $(LLVM_BUILD_DIR)/lib/clang/$(LLVM_VERSION_MAJOR)/lib/$(COREV_SDK_RUNTIME_CLANG_LIB_TRIPLE)
	cp $(LLVM_BUILD_DIR)/lib/generic/libclang_rt.builtins-riscv32.a \
		$(LLVM_BUILD_DIR)/lib/clang/$(LLVM_VERSION_MAJOR)/lib/$(COREV_SDK_CLANG_LIB_TRIPLE)/libclang_rt.builtins.a
	cp $(LLVM_BUILD_DIR)/lib/generic/libclang_rt.builtins-riscv32.a \
		$(LLVM_BUILD_DIR)/lib/clang/$(LLVM_VERSION_MAJOR)/lib/$(COREV_SDK_RUNTIME_CLANG_LIB_TRIPLE)/libclang_rt.builtins.a
	mkdir -p $(COREV_SDK_RUNTIME_SYSROOT)/lib $(COREV_SDK_RUNTIME_SYSROOT)/include
	cp $(LLVM_BUILD_DIR)/lib/libc++.a \
		$(LLVM_BUILD_DIR)/lib/libc++abi.a \
		$(LLVM_BUILD_DIR)/lib/libunwind.a \
		$(LLVM_BUILD_DIR)/lib/clang/$(LLVM_VERSION_MAJOR)/lib/$(COREV_SDK_CLANG_LIB_TRIPLE)/libclang_rt.builtins.a \
		$(COREV_SDK_RUNTIME_SYSROOT)/lib/
	rm -rf $(COREV_SDK_RUNTIME_SYSROOT)/include/c++
	$(MAKE) install-llvm-multilib-yaml

install-llvm-multilib-yaml: build-llvm
	mkdir -p $(CLANG_RUNTIMES_ROOT)
	rm -f $(CLANG_RUNTIMES_ROOT)/multilib.yaml
	printf '%s\n' 'MultilibVersion: 1.0' '' 'Variants:' > $(CLANG_RUNTIMES_ROOT)/multilib.yaml.tmp
	for multilib in $(COREV_SDK_MULTILIBS); do \
		arch=$${multilib%%/*}; \
		abi=$${multilib##*/}; \
		flags=$$($(LLVM_CLANG) --target=$(COREV_SDK_TRIPLE) -march=$$arch -mabi=$$abi -print-multi-flags-experimental | sed -n '/^-march=/p;/^-mabi=/p' | paste -sd, -); \
		printf '%s\n' "- Dir: $(COREV_SDK_RUNTIME_TRIPLE)/$$multilib" "  Flags: [$${flags}]" >> $(CLANG_RUNTIMES_ROOT)/multilib.yaml.tmp; \
	done
	printf '%s\n' '' 'Mappings:' >> $(CLANG_RUNTIMES_ROOT)/multilib.yaml.tmp
	for alias in $(COREV_SDK_GENERIC_MULTILIB_ALIASES); do \
		from=$${alias%%:*}; \
		to=$${alias##*:}; \
		from_arch=$${from%%/*}; \
		from_abi=$${from##*/}; \
		to_arch=$${to%%/*}; \
		to_abi=$${to##*/}; \
		from_march=$$($(LLVM_CLANG) --target=$(COREV_SDK_TRIPLE) -march=$$from_arch -mabi=$$from_abi -print-multi-flags-experimental | sed -n '/^-march=/p'); \
		to_march=$$($(LLVM_CLANG) --target=$(COREV_SDK_TRIPLE) -march=$$to_arch -mabi=$$to_abi -print-multi-flags-experimental | sed -n '/^-march=/p'); \
		printf '%s\n' "- Match: $${from_march}" "  Flags: [$${to_march}]" >> $(CLANG_RUNTIMES_ROOT)/multilib.yaml.tmp; \
	done
	cp $(CLANG_RUNTIMES_ROOT)/multilib.yaml.tmp $(CLANG_RUNTIMES_ROOT)/multilib.yaml
	rm -f $(CLANG_RUNTIMES_ROOT)/multilib.yaml.tmp

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
		-Dlibdir=lib \
		-Dmultilib=false \
		-Dtests=false \
		-Dpicocrt=false \
		-Dsemihost=false \
		-Dspecsdir=none \
		-Dposix-console=true \
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
		-DCMAKE_SYSROOT=$(CLANG_RUNTIMES_ROOT) \
		-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
		-DCMAKE_C_FLAGS='-march=$(COREV_SDK_ARCH) -mabi=$(COREV_SDK_ABI)' \
		-DCMAKE_CXX_FLAGS='-march=$(COREV_SDK_ARCH) -mabi=$(COREV_SDK_ABI)' \
		-DCMAKE_ASM_FLAGS='-march=$(COREV_SDK_ARCH) -mabi=$(COREV_SDK_ABI)' \
		-DCMAKE_EXE_LINKER_FLAGS='-fuse-ld=lld --rtlib=compiler-rt' \
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

check-clang:
	cmake --build $(LLVM_BUILD_DIR) --target check-clang --parallel $(JOBS)

check-llvm:
	cmake --build $(LLVM_BUILD_DIR) --target check-llvm --parallel $(JOBS)

check-lld:
	cmake --build $(LLVM_BUILD_DIR) --target check-lld --parallel $(JOBS)

ci-llvm-toolchain: build-llvm install-llvm-runtimes check-clang check-llvm check-lld

package-llvm-toolchain: package-stage-llvm-toolchain sanity-package-llvm-toolchain
	mkdir -p $(dir $(PACKAGE_ARCHIVE))
	rm -f $(PACKAGE_ARCHIVE)
	tar -C $(dir $(PACKAGE_STAGE)) -czf $(PACKAGE_ARCHIVE) $(notdir $(PACKAGE_STAGE))

package-stage-llvm-toolchain: install-llvm-runtimes
	rm -rf $(PACKAGE_STAGE)
	mkdir -p $(PACKAGE_STAGE)/bin $(PACKAGE_STAGE)/include $(PACKAGE_STAGE)/lib $(PACKAGE_STAGE)/share/cmake/corev-llvm
	for tool in \
		clang:clang \
		clang++:clang++ \
		cc:clang \
		c++:clang++ \
		ld:ld.lld \
		ld.lld:ld.lld \
		lld:lld \
		ar:llvm-ar \
		ranlib:llvm-ranlib \
		objcopy:llvm-objcopy \
		objdump:llvm-objdump \
		readelf:llvm-readelf \
		readobj:llvm-readobj \
		size:llvm-size \
		strip:llvm-strip \
		nm:llvm-nm; do \
		dst=$${tool%%:*}; \
		src=$${tool##*:}; \
		cp -L $(LLVM_BUILD_DIR)/bin/$$src $(PACKAGE_STAGE)/bin/$(COREV_SDK_TRIPLE)-$$dst; \
		chmod +x $(PACKAGE_STAGE)/bin/$(COREV_SDK_TRIPLE)-$$dst; \
	done
	cp -R $(LLVM_BUILD_DIR)/lib/clang $(PACKAGE_STAGE)/lib/clang
	cp -R $(CLANG_RUNTIMES_ROOT) $(PACKAGE_STAGE)/lib/clang-runtimes
	if [ -d $(LLVM_BUILD_DIR)/include/c++ ]; then cp -R $(LLVM_BUILD_DIR)/include/c++ $(PACKAGE_STAGE)/include/c++; fi
	if [ -d $(LLVM_BUILD_DIR)/share/libc++ ]; then mkdir -p $(PACKAGE_STAGE)/share && cp -R $(LLVM_BUILD_DIR)/share/libc++ $(PACKAGE_STAGE)/share/libc++; fi
	if [ -f $(LLVM_BUILD_DIR)/lib/libc++.modules.json ]; then cp $(LLVM_BUILD_DIR)/lib/libc++.modules.json $(PACKAGE_STAGE)/lib/libc++.modules.json; fi
	printf '%s\n' \
		'set(CMAKE_SYSTEM_NAME Generic)' \
		'set(CMAKE_SYSTEM_PROCESSOR riscv32)' \
		'' \
		'get_filename_component(_COREV_LLVM_PREFIX "$${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)' \
		'' \
		'set(COREV_LLVM_TARGET "$(COREV_SDK_TRIPLE)" CACHE STRING "CORE-V LLVM target triple")' \
		'set(COREV_MARCH "$(COREV_SDK_ARCH)" CACHE STRING "CORE-V RISC-V ISA string")' \
		'set(COREV_MABI "$(COREV_SDK_ABI)" CACHE STRING "CORE-V RISC-V ABI")' \
		'' \
		'set(CMAKE_C_COMPILER "$${_COREV_LLVM_PREFIX}/bin/$(COREV_SDK_TRIPLE)-clang" CACHE FILEPATH "")' \
		'set(CMAKE_CXX_COMPILER "$${_COREV_LLVM_PREFIX}/bin/$(COREV_SDK_TRIPLE)-clang++" CACHE FILEPATH "")' \
		'set(CMAKE_ASM_COMPILER "$${_COREV_LLVM_PREFIX}/bin/$(COREV_SDK_TRIPLE)-clang" CACHE FILEPATH "")' \
		'' \
		'set(CMAKE_AR "$${_COREV_LLVM_PREFIX}/bin/$(COREV_SDK_TRIPLE)-ar" CACHE FILEPATH "")' \
		'set(CMAKE_RANLIB "$${_COREV_LLVM_PREFIX}/bin/$(COREV_SDK_TRIPLE)-ranlib" CACHE FILEPATH "")' \
		'set(CMAKE_LINKER "$${_COREV_LLVM_PREFIX}/bin/$(COREV_SDK_TRIPLE)-ld.lld" CACHE FILEPATH "")' \
		'set(CMAKE_OBJCOPY "$${_COREV_LLVM_PREFIX}/bin/$(COREV_SDK_TRIPLE)-objcopy" CACHE FILEPATH "")' \
		'set(CMAKE_OBJDUMP "$${_COREV_LLVM_PREFIX}/bin/$(COREV_SDK_TRIPLE)-objdump" CACHE FILEPATH "")' \
		'set(CMAKE_SIZE "$${_COREV_LLVM_PREFIX}/bin/$(COREV_SDK_TRIPLE)-size" CACHE FILEPATH "")' \
		'' \
		'set(CMAKE_C_COMPILER_TARGET "$${COREV_LLVM_TARGET}")' \
		'set(CMAKE_CXX_COMPILER_TARGET "$${COREV_LLVM_TARGET}")' \
		'set(CMAKE_ASM_COMPILER_TARGET "$${COREV_LLVM_TARGET}")' \
		'' \
		'set(CMAKE_C_FLAGS_INIT "-march=$${COREV_MARCH} -mabi=$${COREV_MABI}")' \
		'set(CMAKE_CXX_FLAGS_INIT "-march=$${COREV_MARCH} -mabi=$${COREV_MABI}")' \
		'set(CMAKE_ASM_FLAGS_INIT "-march=$${COREV_MARCH} -mabi=$${COREV_MABI}")' \
		'set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld --rtlib=compiler-rt")' \
		'' \
		'set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)' \
		> $(PACKAGE_STAGE)/share/cmake/corev-llvm/$(COREV_SDK_TRIPLE).cmake

sanity-package-llvm-toolchain: package-stage-llvm-toolchain
	rm -rf $(BUILD_ROOT)/package-smoke
	mkdir -p $(BUILD_ROOT)/package-smoke/src $(BUILD_ROOT)/package-smoke/build
	printf '%s\n' \
		'cmake_minimum_required(VERSION 3.20)' \
		'project(corev_package_smoke C CXX ASM)' \
		'add_library(corev_package_smoke STATIC smoke.c smoke.cc smoke.S)' \
		> $(BUILD_ROOT)/package-smoke/src/CMakeLists.txt
	printf '%s\n' 'int smoke_c(void) { return 0; }' > $(BUILD_ROOT)/package-smoke/src/smoke.c
	printf '%s\n' 'int smoke_cxx() { return 0; }' > $(BUILD_ROOT)/package-smoke/src/smoke.cc
	printf '%s\n' '.text' '.globl smoke_asm' 'smoke_asm:' '  ret' > $(BUILD_ROOT)/package-smoke/src/smoke.S
	cmake -S $(BUILD_ROOT)/package-smoke/src -B $(BUILD_ROOT)/package-smoke/build \
		-DCMAKE_TOOLCHAIN_FILE=$(PACKAGE_STAGE)/share/cmake/corev-llvm/$(COREV_SDK_TRIPLE).cmake \
		-DCOREV_MARCH=$(COREV_SDK_ARCH) \
		-DCOREV_MABI=$(COREV_SDK_ABI)
	cmake --build $(BUILD_ROOT)/package-smoke/build --parallel $(JOBS)
	$(PACKAGE_STAGE)/bin/$(COREV_SDK_TRIPLE)-clang -print-multi-directory \
		--target=$(COREV_SDK_TRIPLE) -march=$(COREV_SDK_ARCH) -mabi=$(COREV_SDK_ABI)

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
	rm -rf $(CLANG_RUNTIMES_ROOT)
	rm -rf $(BUILD_ROOT)/build-llvm-riscv-runtimes-*
	rm -rf $(BUILD_ROOT)/build-picolibc-riscv-*
	rm -f $(BUILD_ROOT)/build-picolibc-corev-llvm-*.cross
