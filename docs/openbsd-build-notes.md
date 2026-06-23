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

Also needed (user-space, no root):
- PyYAML: `python3 -m pip install --user --break-system-packages pyyaml`
- `unzip` shim: Python `zipfile`-backed wrapper at `~/.local/bin/unzip`
- Symlinks: `gtar → tar`, `gmake → make`, `pkg-config → pkgconf`

## Build Overview

```
opam (Phase 0) → Why3 (Phase 1) → Alt-Ergo (Phase 2) → GNATprove (Phase 3)
```

### Phase 0: opam bootstrap

```sh
opam init --bare --disable-sandboxing --no-setup -y
opam switch create default 4.14.2 --no-install
eval $(opam env --switch=default)
export AUTOCONF_VERSION=2.72  # required for entire session
```

### Phase 1: Why3 (opam) — 1.8.2

```sh
opam install why3 -y
why3 config detect  # Z3 4.16 detected with version warning (harmless)
```

### Phase 2: Alt-Ergo (opam) — 2.4.3

```sh
opam install alt-ergo -y --assume-depexts
```

### Phase 3: SPARK2014 / GNATprove

#### 3a. Get the matching SPARK branch

The `fsf-15` branch tracks the GCC 15.x release series. Download as
tarball (branch was removed from GitHub after release):

```sh
curl -L https://github.com/AdaCore/spark2014/tarball/fsf-15 -O
tar xzf fsf-15 -C spark2014-fsf15 --strip-components=1
```

#### 3b. Get GCC Ada frontend sources

gnat2why needs the GCC Ada compiler frontend sources. We use GCC 15.2.0
(the `fsf-15` SPARK branch was released against 15.1.0, but 15.2.0 works
correctly — the initial "string expected" crash we saw was due to missing
installation files, NOT a version mismatch):

```sh
curl -L https://ftp.gnu.org/gnu/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz -O
tar xf gcc-15.2.0.tar.xz gcc-15.2.0/gcc/ada
ln -sf /path/to/gcc-15.2.0/gcc/ada spark2014-fsf15/gnat2why/gnat_src
ln -sf /path/to/gcc-15.2.0/gcc/ada spark2014-fsf15/gnat2why/gnat-src
```

**Patch `gcc-15.2.0/gcc/ada/inline.ads`** — add after `package Inline is:`

```ada
   GNATprove_Inline_Success_Msg : Boolean := False;
   GNATprove_Inline_Failure_Msg : Boolean := False;
```

#### 3c. Why3 submodule (fsf-15 branch)

```sh
git clone --branch fsf-15 https://github.com/AdaCore/why3.git why3-fsf15
ln -sf /path/to/why3-fsf15 spark2014-fsf15/why3
```

Apply patches from `berkeleynerd/why3` `openbsd-port` branch.

#### 3d. Ada library dependencies (via Alire)

Build libgpr2 25.0.0, gnatcoll 25.0.0, xmlada 25.0.0 via Alire. Also
clone and build `sarif-ada`.

Apply gnatcoll patches (see `berkeleynerd/gnatcoll-core`):
- `libc-wrappers.c`: posix_fadvise no-op on OpenBSD
- `gnatcoll_core.gpr`: remove `-ldl` (OpenBSD has dl in libc)

Apply libgpr2 patches (see `berkeleynerd/gpr`):
- `gpr2_shared.gpr`: remove `-gnatwe`, relax strict switches

#### 3e. Apply gnatprove patches (this repo's `openbsd-port` branch)

1. Relax `-gnatyg`/`-gnatwae` to `-gnatwa -gnatwJ`
2. Add `x86_64-unknown-openbsd` to platform + pthread cases
3. Create `src/common/x86_64-unknown-openbsd` → `x86_64-freebsd` symlink

#### 3f. Build

```sh
make setup
make -j4
```

#### 3g. Install (manual — OpenBSD's install(1) lacks GNU -c -m syntax)

`make install-all` fails because OpenBSD's `/usr/bin/install` doesn't
support GNU install syntax. Manually copy files instead:

```sh
# Why3 binaries
cp why3/bin/gnatwhy3.opt install/libexec/spark/bin/gnatwhy3
cp why3/lib/why3server install/libexec/spark/bin/why3server
cp why3/bin/why3session.opt install/libexec/spark/bin/gnatwhy3session

# Why3 plugins (CRITICAL — without gnat_json.cmxs, gnatwhy3 can't parse VCs)
mkdir -p install/libexec/spark/lib/why3/plugins
cp why3/lib/plugins/*.cmxs install/libexec/spark/lib/why3/plugins/

# Why3 standard library (CRITICAL — without these, drivers fail to load)
mkdir -p install/libexec/spark/share/why3/theories
cp -r why3/stdlib/* install/libexec/spark/share/why3/theories/
cp -r why3/stdlib/* install/libexec/spark/lib/why3/

# Why3 drivers + gen files
mkdir -p install/libexec/spark/share/why3/drivers
cp why3/drivers/*.drv why3/drivers/*.gen install/libexec/spark/share/why3/drivers/

# SPARK data files
cp -r share/spark/* install/share/spark/
```

**Key discovery:** The "string expected" / "GCC error" crashes during
`--mode=prove` were caused by missing installation files (plugins,
stdlib, drivers), NOT by a GCC version mismatch. Once these files are
in the correct relocatable paths, `--mode=prove` works perfectly with
GCC 15.2.0.

#### 3h. Filter gnatprove.conf

Remove provers you don't have installed:

```python
import json
conf = "install/share/spark/config/gnatprove.conf"
with open(conf) as f: d = json.load(f)
d["provers"] = [p for p in d["provers"] if p["name"] in ("Z3", "altergo")]
with open(conf, "w") as f: json.dump(d, f, indent=2)
```

## Current Status

| Component | Status |
|-----------|--------|
| safec compiler | ✅ Full build/test/samples |
| gnatprove --version | ✅ FSF 15.0 |
| gnatprove --mode=flow | ✅ Works |
| gnatprove --mode=prove --level=1 | ✅ Works (Z3 + Alt-Ergo + CVC5) |
| gnatprove --mode=prove --level=2 | ✅ Works (1/460 fails — hard float VC) |
| Full Safe-lang proof suite | ✅ 459 proved, 1 failed |
| CVC5 1.3.4 | ✅ Built from upstream source |

### CVC5 build

CVC5 1.3.4 built from `cvc5/cvc5` repo with system GMP (requires
`gmpxx` package for the C++ bindings). Static build with auto-download
for other deps (CaDiCaL, LibPoly, SymFPU). Note: AdaCore's patched CVC
fork (branch `spark-15.0` at `github.com/AdaCore/cvc5`) has SPARK-specific
solver heuristics for hard floating-point VCs, but builds with
autoconf/ANTLR3 which requires additional porting effort.

## Forked Repos

All patches are on the `openbsd-port` branch of these forks:

| Repo | Upstream | Fork |
|------|----------|------|
| spark2014 | AdaCore/spark2014 | berkeleynerd/spark2014 |
| why3 | AdaCore/why3 | berkeleynerd/why3 |
| gnatcoll-core | AdaCore/gnatcoll-core | berkeleynerd/gnatcoll-core |
| gpr (libgpr2) | AdaCore/gpr | berkeleynerd/gpr |
