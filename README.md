# sashimi

> [!WARNING]
> under construction: don't use. or do, but you've been warned. this is a scaffold to flesh out where the tool cuts are, it doesn't actually do anything "real" yet. as the tools get built out to do real stuff, it is very likely the interfaces, and possibly names, will change.

**sashimi** is an experimental kit of unix flavoured tools. each tool is meant to do one thing, and do it well. the idea is the tools can be swapped and composed as needed without needing to know about each other. for example, you could use the following recipe:

```sh
sashimi catch data 203.0.113.7:8333 range 0 999 | sashimi cut data > frames
```

this downloads a thousand blocks from a peer, trusted or not, into `data/blocks/`, and parses each one into a frame (header, merkle root, inputs, outputs) for whatever you want to build on top. other ideas:

* streaming blocks into `cut` to test new block parsing strategies for speed
* streaming signatures into `sashimi seal` to test the performance of a signature verification algorithm on novel hardware, or pointing the node at your own verifier with `--seal ./my-seal`
* seamlessly swapping out different backends for storing and retrieving blocks and coins

a few more recipes:

```sh
# a throwaway chain to play with, served on localhost
sashimi farm demo 300
sashimi serve demo 127.0.0.1:18333 &

# sync a node from it, then follow the chain as it grows
sashimi run node 127.0.0.1:18333
sashimi tail node 127.0.0.1:18333

# headers first, then the best chain
sashimi catch data 127.0.0.1:18333 headers && sashimi heads data

# what is on disk, and what is not
sashimi stock data | head
sashimi gaps data

# fill the gaps yourself, then commit everything: what was on disk and what just arrived
{ sashimi stock data; sashimi gaps data | while read a b; do sashimi catch data 127.0.0.1:18333 range $a $b; done; } | sashimi commit data

# replay a chain already on disk, four parsers and four checkers, sixty-four megabytes of recent coins in memory
sashimi stock data | sashimi commit data --cutters 4 --graders 4 --window 64M

# parse in parallel from a shell, output still in height order
sashimi stock data | sashimi spread 4 cut data > frames
```

look at the testing and benchmark scripts, which are all shell scripts calling these tools. neat! every tool answers `--help`, and `zig build` installs a man page per tool.

## sashimi run, sashimi tail

`run` syncs a node by orchestrating the various tools, and `tail` keeps it at the tip afterwards. this also has some unique benefits like:

* simplicity by leaning on well understood unix concepts like caching and streams
* running isolated, e.g., each peer runs in their own process
* scaling efficiently to differently resourced environments

## building, installing, testing

all the typical zig stuff, zig 0.16:

```sh
zig build                                   # zig-out/bin/sashimi and one sashimi-<tool> command per tool
zig build -Doptimize=ReleaseFast -p ~/.local    # install for you (~/.local/bin, man pages in ~/.local/share/man)
sudo zig build -Doptimize=ReleaseSafe -p /usr/local   # install system wide
zig build -Dtools=                          # bare command names instead of sashimi-<tool>
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseFast -p ./pi   # cross build for a pi

zig build test                              # unit tests
zig build e2e                               # the whole pipe on a fake chain
sh test/bench.sh pi5 45                     # synthetic load: does the pipeline keep the cores busy
sh test/store_bench.sh 100 300              # how many spends reach the coin store as the window grows
```

uninstalling is deleting the `sashimi*` files in the prefix's `bin` and `share/man/man1`.
