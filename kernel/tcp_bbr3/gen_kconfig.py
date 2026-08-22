#!/usr/bin/env python3
# gen_kconfig.py - autoconf-style kernel API prober.
#
# For every line in the api list file:
#     <C code> KERNEL_CONFIG_EOL <more C code> // MACRO_NAME
# a throwaway kernel module is test-compiled (and linked via modpost) against
# the target kernel tree. If it builds, `#define MACRO_NAME 1` is written to
# the output header; otherwise the macro stays undefined.
#
# Usage:
#   gen_kconfig.py <kernel_source_path> <output_config_file> <compiler> <api_list_file> \
#                  [-j N] [-a ARCH] [-d]
#
# Example:
#   python3 gen_kconfig.py /lib/modules/$(uname -r)/build kernel_config.h gcc kapi_checklist -j8
#   python3 gen_kconfig.py ~/src/linux-5.4  kernel_config.h aarch64-linux-gnu-gcc kapi_checklist -a arm64

import os
import sys
import shlex
import tempfile
import argparse
import subprocess
import concurrent.futures

Debug = False


def parse_oneline(oneline):
    s, macro_name = oneline.rsplit('//', 1)
    return s.replace('KERNEL_CONFIG_EOL', '\n'), macro_name.strip()


def is_clang(cc):
    """clang, clang-18, /usr/bin/clang, ... => True"""
    return os.path.basename(cc).startswith("clang")


def compiler_prefix(cc):
    """arm-linux-gnueabihf-gcc => arm-linux-gnueabihf-
    (paths are allowed too: /opt/x/bin/arm-linux-gcc => /opt/x/bin/arm-linux-)
    """
    if is_clang(cc):
        return ""
    idx = cc.rfind("gcc")
    if idx < 0:
        raise RuntimeError(f"invalid compiler: {cc}")
    return cc[:idx]


def cmd2str(argv):
    try:
        return shlex.join(argv)
    except AttributeError:
        return " ".join(argv)


class KernelApiChecker:
    def __init__(self, mp, arch, kernel_source_path, output_config_file,
                 compiler, api_list_file):
        self.mp = mp
        self.arch = arch
        self.kernel_source_path = kernel_source_path
        self.output_config_file = output_config_file
        self.compiler = compiler
        self.api_list_file = api_list_file

    def create_test(self, snippet):
        test_code = f"""
#include <linux/kernel.h>
#include <linux/module.h>

{snippet}

static int __init test_init_module(void)
{{
    return 0;
}}
module_init(test_init_module);

static void __exit test_cleanup_module(void)
{{
}}
module_exit(test_cleanup_module);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Test module for gen_kconfig.py");
"""
        if Debug:
            print(test_code)
        return test_code

    def compile_test_code(self, test_code):
        with tempfile.TemporaryDirectory() as test_dir:
            kdir = self.kernel_source_path

            with open(os.path.join(test_dir, "Makefile"), "w") as f:
                f.write(f"""\
KDIR ?= {kdir}
pwd=$(shell pwd)

obj-m := main.o
ccflags-y := -Wno-missing-declarations -Wno-missing-prototypes

all:
\t$(MAKE) -C $(KDIR) M=$(pwd) modules

clean:
\t$(MAKE) -C $(KDIR) M=$(pwd) clean
""")
            with open(os.path.join(test_dir, "main.c"), "w") as f:
                f.write(test_code)

            makecall = ["make", "-C", test_dir]
            # Probes only test whether the code *compiles*: a kernel tree that
            # was never fully built has no Module.symvers, so modpost would
            # fail on vmlinux-resident symbols (e.g. __x86_return_thunk).
            # Downgrade modpost errors to warnings. Note this means EXPORT
            # availability is NOT verified by probes; the real module build
            # (without this flag) stays strict.
            makecall.append("KBUILD_MODPOST_WARN=1")
            if self.arch:
                makecall.append(f"ARCH={self.arch}")
            if is_clang(self.compiler):
                makecall.append("LLVM=1")
            elif self.compiler not in ("gcc", "cc"):
                makecall.append(f"CROSS_COMPILE={compiler_prefix(self.compiler)}")
            if Debug:
                print(cmd2str(makecall))
            try:
                subprocess.check_output(
                    makecall,
                    stderr=subprocess.STDOUT if Debug else subprocess.DEVNULL,
                )
                return True
            except subprocess.CalledProcessError as e:
                if Debug:
                    print(e.output.decode(errors="replace"))
                return False

    def process_api(self, api):
        sources, api_name = parse_oneline(api)
        test_code = self.create_test(sources)
        if self.compile_test_code(test_code):
            return api_name, f"#define {api_name} 1"
        return api_name, f"/* #undef {api_name} (not available) */"

    def read_api_list(self):
        apis = []
        seen = set()
        with open(self.api_list_file, "r") as f:
            for lineno, line in enumerate(f, 1):
                line = line.strip()
                # probe lines start with '#include'; comments must not
                if not line or (line.startswith('#') and
                                not line.startswith('#include')):
                    continue
                if '//' not in line:
                    raise RuntimeError(
                        f"{self.api_list_file}:{lineno}: missing '// MACRO' suffix")
                macro = line.rsplit('//', 1)[1].strip()
                if macro in seen:
                    continue
                seen.add(macro)
                apis.append(line)
        return apis

    def generate_config_header(self):
        apis = self.read_api_list()
        results = {}

        if self.mp:
            with concurrent.futures.ThreadPoolExecutor(max_workers=self.mp) as ex:
                futs = {ex.submit(self.process_api, api): api for api in apis}
                for fut in concurrent.futures.as_completed(futs):
                    api = futs[fut]
                    try:
                        name, line = fut.result()
                        results[name] = line
                    except Exception as exc:
                        print(f'{api} generated an exception: {exc}')
                        sys.exit(1)
        else:
            for api in apis:
                name, line = self.process_api(api)
                results[name] = line

        # Keep checklist order so the generated file is deterministic.
        config_lines = []
        for api in apis:
            macro = api.rsplit('//', 1)[1].strip()
            line = results[macro]
            print(line)
            config_lines.append(line)
        return config_lines

    def write_config_file(self, args, config_lines):
        n_ok = sum(1 for l in config_lines if l.startswith('#define'))
        with open(self.output_config_file, "w") as f:
            f.write("#pragma once\n\n")
            f.write("/* Generated by gen_kconfig.py - do not edit. */\n")
            f.write(f"/* kernel source path: {args.kernel_source_path} */\n")
            f.write(f"/* compiler: {args.compiler} */\n")
            f.write(f"/* probes passed: {n_ok}/{len(config_lines)} */\n\n")
            f.write("\n".join(config_lines))
            f.write("\n")
        print(f"{self.output_config_file}: {n_ok}/{len(config_lines)} probes passed")

    def run(self, args):
        config_lines = self.generate_config_header()
        self.write_config_file(args, config_lines)


def main():
    parser = argparse.ArgumentParser(
        description='Generate kernel compatible config header')
    parser.add_argument('kernel_source_path', help='Path to kernel source.')
    parser.add_argument('output_config_file', help='Output configuration header file')
    parser.add_argument('compiler', help='Compiler to use')
    parser.add_argument('api_list_file', help='File containing list of APIs to check')
    parser.add_argument('-d', '--debug', action='store_true', help='debug mode')
    parser.add_argument('-j', '--multiprocessing', help='multi processing mode', type=int)
    parser.add_argument('-a', '--arch', help='Kernel build arch', default='')

    args = parser.parse_args()

    if not os.path.isdir(args.kernel_source_path):
        parser.error(f"kernel source path not found: {args.kernel_source_path}\n"
                     "hint: it must be prepared for module builds "
                     "(e.g. 'make defconfig && make modules_prepare')")

    global Debug
    Debug = args.debug

    checker = KernelApiChecker(args.multiprocessing, args.arch,
                               args.kernel_source_path,
                               args.output_config_file,
                               args.compiler, args.api_list_file)
    checker.run(args)


if __name__ == "__main__":
    main()
