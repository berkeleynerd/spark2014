# Building GNATprove on OpenBSD 7.9

This document records the complete process of building GNATprove (SPARK 2014)
on OpenBSD 7.9/amd64. It serves as a reproducibility guide and documents
all patches needed across the dependency stack.

## Environment

| Component | Version |
|-----------|---------|
| OS | OpenBSD 7.9 amd64 |
| GCC/GNAT | 15.2.0 (system package) |
| Ada runtime | /usr/local/lib/gcc/x86_64-unknown-openbsd/15.2.0/adalib |
| Alire | 3.0.0-dev |
| OCaml | 4.14.2 (system package) |
| opam | 2.5.0 |

## Prerequisites (system packages)

```sh
doas pkg_add ocaml opam z3 autoconf-2.72 gmake gtar
doas pkg_add ocaml-graph ocaml-menhir ocaml-zarith ocaml-num ocamlbuild ocaml-yojson
```

Also needed:
- `pyyaml` for Python: `python3 -m pip install --user --break-system-packages pyyaml`
- An `unzip` shim if not installed (alr needs it)
- Symlinks: `ln -sf /usr/local/bin/gtar ~/.local/bin/tar` and `ln -sf /usr/local/bin/gmake ~/.local/bin/make`

## Build Overview

```
opam (Phase 0) → Why3 (Phase 1) → Alt-Ergo (Phase 2) → GNATprove (Phase 3)
                                                              ↓
                                                    gnat2why + gnatprove
                                                    + gnatwhy3 (why3 fork)
```

### Phase 0: opam bootstrap

```sh
opam init --bare --disable-sandboxing --no-setup -y
opam switch create default 4.14.2 --no-install
eval $(opam env --switch=default)
```

Set `AUTOCONF_VERSION=2.72` for the entire session (OpenBSD's autoconf wrapper
requires it).

### Phase 1: Why3 (opam)

```sh
opam install why3 -y           # 1.8.2 — used for solver detection/config
```

Note: Why3 1.8.2 detects Z3 4.16.0 with a "version not recognized" warning.
This is harmless — Why3 still uses it. Verify:

```sh
why3 config detect
why3 prove -P z3 /tmp/test.mlw  # should return "Valid"
```

### Phase 2: Alt-Ergo (opam)

```sh
opam install alt-ergo -y --assume-depexts  # 2.4.3
```

### Phase 3: SPARK2014 / GNATprove

#### 3a. Get the matching SPARK branch

The `fsf-15` branch of SPARK2014 tracks the GCC 15.x release series. Fetch it
as a tarball (the branch was removed from the GitHub repo after release):

```sh
wget https://github.com/AdaCore/spark2014/tarball/fsf-15 -O spark2014-fsf15.tar.gz
tar xzf spark2014-fsf15.tar.gz --strip-components=1 -C spark2014-fsf15
```

#### 3b. Get matching GCC Ada frontend sources

gnat2why needs the GCC Ada compiler frontend sources:

```sh
wget https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz
tar xf gcc-15.2.0.tar.xz gcc-15.2.0/gcc/ada
ln -sf /path/to/gcc-15.2.0/gcc/ada spark2014-fsf15/gnat2why/gnat_src
```

**Known issue:** SPARK `fsf-15` was released against GCC 15.1.0, but we have
15.2.0. Flow analysis (`--mode=flow`) works correctly. Proof mode
(`--mode=prove`) crashes in gnat2why with `"string expected"` due to internal
AST node layout changes between 15.1 and 15.2. To fix: use GCC 15.1.0 sources
instead (not yet tested).

#### 3c. GCC inline.ads patch

gnat2why references `Inline.GNATprove_Inline_Success_Msg` and
`Inline.GNATprove_Inline_Failure_Msg` which don't exist in FSF GNAT's
`inline.ads`. Add them:

```ada
-- In gcc-15.2.0/gcc/ada/inline.ads, after "package Inline is":
   GNATprove_Inline_Success_Msg : Boolean := False;
   GNATprove_Inline_Failure_Msg : Boolean := False;
```

#### 3d. Why3 submodule (fsf-15 branch)

```sh
git clone --branch fsf-15 https://github.com/AdaCore/why3.git why3-fsf15
ln -sf /path/to/why3-fsf15 spark2014-fsf15/why3
```

Apply the patches from `berkeleynerd/why3` `openbsd-port` branch:
- `mysexplib-dummy.ml`: populate empty Std/Std_big_int module stubs
- `gnat_ast_to_ptree.ml`: stub direct Sexplib reference

#### 3e. Ada library dependencies

Build via Alire with libgpr2 25.0.0:

```sh
mkdir gpr2_build && cd gpr2_build
cat > alire.toml << 'EOF'
name = "gpr2_build"
version = "0.1.0-dev"
description = ""
authors = ["build"]
licenses = "MIT"
[[depends-on]]
libgpr2 = "25.0.0"
EOF
CFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib" alr build
```

Also clone and build sarif-ada:
```sh
git clone --depth=1 https://github.com/AdaCore/sarif-ada.git
cd sarif-ada && gprbuild -p -Psarif_ada.gpr
```

#### 3f. Apply patches and build

See the `openbsd-port` branch of this repo for the gnatprove.gpr patches.
Key changes:
- Relax `-gnatyg`/`-gnatwae` to `-gnatwa -gnatwJ`
- Add `x86_64-unknown-openbsd` to platform and pthread cases
- Add `src/common/x86_64-unknown-openbsd` symlink to `x86_64-freebsd`

Apply gnatcoll patches (see `berkeleynerd/gnatcoll-core` `openbsd-port`):
- `libc-wrappers.c`: posix_fadvise no-op on OpenBSD
- `gnatcoll_core.gpr`: document -ldl issue

Apply libgpr2 patches (see `berkeleynerd/gpr` `openbsd-port`):
- `gpr2_shared.gpr`: remove -gnatwe, document warning issues

Then build:
```sh
make setup
make -j4
```

#### 3g. Install

```sh
# Copy data files
cp -r share/spark/* install/share/spark/
# Copy why3 binaries
cp why3/bin/gnatwhy3.opt install/libexec/spark/bin/gnatwhy3
cp why3/lib/why3server install/libexec/spark/bin/why3server
# Copy why3 drivers
mkdir -p install/share/spark/drivers
cp why3/drivers/*.drv install/share/spark/drivers/
# Filter gnatprove.conf to only z3+altergo
python3 -c "import json; ..."
```

## Current Status

| Component | Status |
|-----------|--------|
| safec compiler | ✅ Full build/test/samples |
| gnat2why | ✅ Built |
| gnatprove | ✅ Built |
| gnatwhy3 | ✅ Built |
| --mode=flow | ✅ Works |
| --mode=prove | ❌ Crashes (15.1 vs 15.2 mismatch) |

## Forked Repos

All patches are on the `openbsd-port` branch of these forks:

| Repo | Upstream | Fork |
|------|----------|------|
| spark2014 | AdaCore/spark2014 | berkeleynerd/spark2014 |
| why3 | AdaCore/why3 | berkeleynerd/why3 |
| gnatcoll-core | AdaCore/gnatcoll-core | berkeleynerd/gnatcoll-core |
| gpr (libgpr2) | AdaCore/gpr | berkeleynerd/gpr |
